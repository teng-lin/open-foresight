import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'summary_output.dart';
import 'summary_prompt.dart';

const summaryVersion = 'summary-v1';
const summaryPolicyVersion = 'untrusted-sources-v1';

String summaryDigest(String text) =>
    sha256.convert(utf8.encode(text)).toString();
int summaryWordCount(String text) => RegExp(r'\S+').allMatches(text).length;

class SummaryCheckpoint {
  const SummaryCheckpoint({
    required this.body,
    required this.inputLength,
    required this.inputDigest,
    required this.identity,
  });
  final String body, inputDigest, identity;
  final int inputLength;

  bool accepts(String text, String generationIdentity) =>
      body.trim().isNotEmpty &&
      identity == generationIdentity &&
      inputLength >= 0 &&
      text.length >= inputLength &&
      summaryDigest(text.substring(0, inputLength)) == inputDigest;
}

class SummaryProgress {
  const SummaryProgress(
    this.phase, {
    this.completed = 0,
    this.total = 0,
    this.preview = '',
  });
  final String phase, preview;
  final int completed, total;
  Map<String, Object> get json => {
    'phase': phase,
    'completed': completed,
    'total': total,
    'preview': preview,
  };
}

class SummaryResult {
  const SummaryResult(
    this.body,
    this.mode,
    this.chunks, {
    this.joinClipped = false,
  });
  final String body, mode;
  final int chunks;
  final bool joinClipped;
}

typedef SummaryComplete =
    Future<String> Function(
      String prompt,
      String system,
      void Function(String) preview,
    );

/// Full/incremental/sequential MAP-REDUCE from the recovered dashboard manager.
/// Actual full-prompt admission and prefix fingerprints are port safeguards.
class SummaryGenerator {
  SummaryGenerator({
    required this.complete,
    required this.countTokens,
    required this.checkCurrent,
    required this.onProgress,
    this.contextTokens = 4096,
    this.outputTokens = 1024,
  });
  final SummaryComplete complete;
  final Future<int> Function(String) countTokens;
  final void Function() checkCurrent;
  final void Function(SummaryProgress) onProgress;
  final int contextTokens, outputTokens;

  Future<bool> _fits(String prompt, String instructions) async {
    checkCurrent();
    final count = await countTokens(
      '$summarySourcePolicy$instructions\n\n$prompt',
    );
    checkCurrent();
    // Include the output and conversation framing, rather than treating a
    // word count or serialized max_input_tokens as an enforced token limit.
    return count + outputTokens + 128 <= contextTokens;
  }

  Future<String> _request(
    String prompt,
    String system,
    String phase, {
    int completed = 0,
    int total = 0,
  }) async {
    checkCurrent();
    if (!await _fits(prompt, system)) {
      throw StateError(
        'Summary $phase exceeds the model context. Increase the model context or choose a model with a larger context.',
      );
    }
    onProgress(SummaryProgress(phase, completed: completed, total: total));
    final result = await complete(prompt, '$summarySourcePolicy$system', (
      text,
    ) {
      checkCurrent();
      onProgress(
        SummaryProgress(
          phase,
          completed: completed,
          total: total,
          preview: phase == 'mapping' ? '' : sanitizeSummary(text),
        ),
      );
    });
    checkCurrent();
    if (result.trim().isEmpty) {
      throw StateError('Summary model returned empty output');
    }
    return result.trim();
  }

  Future<SummaryResult> generate(
    String text, {
    required String identity,
    SummaryCheckpoint? checkpoint,
    bool refresh = true,
  }) async {
    checkCurrent();
    final transcript = cleanSummaryTranscript(text);
    if (transcript.isEmpty) throw StateError('No final transcript');
    final compatible = checkpoint?.accepts(transcript, identity) ?? false;
    if (compatible &&
        checkpoint!.inputLength == transcript.length &&
        !refresh) {
      return SummaryResult(checkpoint.body, 'cached', 0);
    }
    final words = summaryWordCount(transcript);
    if (!refresh && words < 100) {
      throw StateError(
        'At least 100 transcript words are required for automatic summary',
      );
    }
    onProgress(const SummaryProgress('planning'));
    if (refresh &&
        compatible &&
        words > contextTokens ~/ 2 &&
        transcript.length > checkpoint!.inputLength) {
      final suffix = transcript.substring(checkpoint.inputLength).trim();
      final prompt = summaryIncrementalPrompt(checkpoint.body, suffix);
      if (suffix.isNotEmpty &&
          summaryWordCount(suffix) <= contextTokens ~/ 2 &&
          await _fits(prompt, summaryIncrementalInstructions)) {
        final body = await _request(
          prompt,
          summaryIncrementalInstructions,
          'updating',
        );
        return SummaryResult(sanitizeSummary(body), 'incremental', 1);
      }
    }
    final full = summaryFullPrompt(transcript);
    if (words <= contextTokens ~/ 2 &&
        await _fits(full, summaryFullInstructions)) {
      return SummaryResult(
        sanitizeSummary(
          await _request(full, summaryFullInstructions, 'summarizing'),
        ),
        'full',
        1,
      );
    }
    // Reject impossible final framing before spending any map requests.
    if (!await _fits(summaryReducePrompt(''), summaryFullInstructions)) {
      throw StateError(
        'Summary reduction instructions exceed the model context. Increase model context.',
      );
    }
    final chunks = await _chunks(transcript);
    final partials = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      checkCurrent();
      partials.add(
        await _request(
          summaryChunkPrompt(chunks[i]),
          summaryMapInstructions,
          'mapping',
          completed: i,
          total: chunks.length,
        ),
      );
      onProgress(
        SummaryProgress('mapping', completed: i + 1, total: chunks.length),
      );
      await Future<void>.delayed(Duration.zero);
    }
    checkCurrent();
    if (partials.isEmpty) throw StateError('No transcript chunks to summarize');
    final reduced = await _reducePartials(partials, chunks.length);
    return SummaryResult(
      sanitizeSummary(reduced.text),
      'map_reduce',
      chunks.length,
      joinClipped: reduced.clipped,
    );
  }

  Future<({String text, bool clipped})> _reducePartials(
    List<String> partials,
    int chunks,
  ) async {
    var joined = await _reductionInput(partials);
    var clipped = false;
    if (joined == null) {
      // Too many topics to retain even a prefix of each in one request.
      // Reduce balanced subtrees first, keeping every map result represented.
      if (partials.length == 1) {
        throw StateError(
          'Summary reduction exceeds the model context. Increase model context.',
        );
      }
      final middle = partials.length ~/ 2;
      final left = await _reducePartials(partials.sublist(0, middle), chunks);
      final right = await _reducePartials(partials.sublist(middle), chunks);
      clipped = left.clipped || right.clipped;
      joined = await _reductionInput([left.text, right.text]);
      if (joined == null) {
        throw StateError(
          'Summary reduction exceeds the model context. Increase model context.',
        );
      }
    }
    final body = await _request(
      summaryReducePrompt(joined.text),
      summaryFullInstructions,
      'reducing',
      completed: chunks,
      total: chunks,
    );
    return (text: body, clipped: clipped || joined.clipped);
  }

  Future<({String text, bool clipped})?> _reductionInput(
    List<String> partials,
  ) async {
    final original = joinSummaryPartials(partials, contextTokens);
    if (await _fits(
      summaryReducePrompt(original.text),
      summaryFullInstructions,
    )) {
      return original;
    }
    // Fit the complete request, preserving a prefix of every map result.
    // Short results are valid too; there is no twenty-character minimum.
    var low = 1, high = partials.map((text) => text.length).reduce(math.max);
    ({String text, bool clipped})? best;
    while (low <= high) {
      checkCurrent();
      final quota = (low + high) ~/ 2;
      final candidate = joinSummaryPartials(
        partials,
        contextTokens,
        partialCharacterLimit: quota,
      );
      if (await _fits(
        summaryReducePrompt(candidate.text),
        summaryFullInstructions,
      )) {
        best = candidate;
        low = quota + 1;
      } else {
        high = quota - 1;
      }
    }
    return best;
  }

  Future<List<String>> _chunks(String text) async {
    final words = text.split(RegExp(r'\s+'));
    final size = math.max(1500, (contextTokens * .375).floor());
    final stride = math.max(1200, (size * .8).floor());
    final chunkBudget = math.max(3000, (contextTokens * .75).floor());
    final chunks = <String>[];
    for (var start = 0; start < words.length;) {
      checkCurrent();
      final end = math.min(words.length, start + size);
      var kept = end - start;
      var chunk = words.sublist(start, end).join(' ');
      final tokens = await countTokens(chunk);
      checkCurrent();
      if (tokens > chunkBudget ||
          !await _fits(summaryChunkPrompt(chunk), summaryMapInstructions)) {
        var low = 1, high = kept, best = 0;
        while (low <= high) {
          final middle = (low + high) ~/ 2;
          final candidate = words.sublist(start, start + middle).join(' ');
          if (await countTokens(candidate) <= chunkBudget &&
              await _fits(
                summaryChunkPrompt(candidate),
                summaryMapInstructions,
              )) {
            best = middle;
            low = middle + 1;
          } else {
            high = middle - 1;
          }
          checkCurrent();
        }
        if (best == 0) {
          throw StateError(
            'A transcript word exceeds the available summary context. Increase model context.',
          );
        }
        kept = best;
        chunk = words.sublist(start, start + kept).join(' ');
      }
      chunks.add(chunk);
      if (start + kept == words.length) break;
      // Advance proportionally after token truncation; never skip uncovered words.
      final advance = (kept * stride / size).floor();
      start += advance.clamp(1, kept > 1 && stride < size ? kept - 1 : kept);
    }
    return chunks;
  }
}

({String text, bool clipped}) joinSummaryPartials(
  List<String> partials,
  int context, {
  int? partialCharacterLimit,
}) {
  const separator = '\n\n---\n\n';
  final cap = math.max(10000, 4 * (context - 1500));
  var clipped = false;
  if (partialCharacterLimit != null) {
    partials = partials.map((text) {
      if (text.length <= partialCharacterLimit) return text;
      clipped = true;
      return '${_prefix(text, partialCharacterLimit)}...';
    }).toList();
  }
  var joined = partials.join(separator);
  if (joined.length > cap) {
    clipped = true;
    final quota = math.max(
      20,
      (cap - separator.length * (partials.length - 1) - 3 * partials.length) ~/
          partials.length,
    );
    joined = partials
        .map((s) => s.length > quota ? '${_prefix(s, quota)}...' : s)
        .join(separator);
    // Never cut off trailing topics. If separators and minimum prefixes still
    // exceed the cap, request admission routes the list through subtrees.
  }
  return (text: joined, clipped: clipped);
}

String _prefix(String text, int limit) {
  // Dart lengths match the reference UTF-16 bookkeeping, but never split a pair.
  var end = math.min(limit, text.length);
  if (end > 0 &&
      end < text.length &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff) {
    end--;
  }
  return text.substring(0, end);
}
