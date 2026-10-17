import 'question_similarity.dart';

final _timestamp = RegExp(r'^\[\d{2}:\d{2}:\d{2}\]\s*');
final _punctuation = RegExp(r"""[-.,?!:;"'()]+""");
final _whitespace = RegExp(r'\s+');
final _nonWords = RegExp(r'[^\p{L}\p{N}\s]+', unicode: true);

String normalizeTranscriptWindow(String text) => text
    .toLowerCase()
    .trim()
    .replaceAll(_timestamp, ' ')
    .replaceAll(_punctuation, ' ')
    .replaceAll(_whitespace, ' ')
    .trim();

String normalizeMeetingQuestion(String text) => text
    .toLowerCase()
    .replaceAll(_nonWords, '')
    .trim()
    .replaceAll(_whitespace, ' ');

/// Reference TextDeduplicator: suppressed repeats also refresh the timestamp.
/// The recovered dynamic dispatch hashes the normalized Dart string.
class QuestionTextDeduplicator {
  QuestionTextDeduplicator();
  QuestionTextDeduplicator._(this._seen);
  Map<int, int> _seen = {};

  QuestionTextDeduplicator copy() => QuestionTextDeduplicator._(Map.of(_seen));

  bool process(String text, int now) {
    final normalized = normalizeTranscriptWindow(text);
    if (normalized.isEmpty) return true;
    final key = normalized.hashCode;
    final previous = _seen[key];
    _seen[key] = now;
    return previous == null || now - previous >= 5000;
  }
}

class QuestionDispatchResult {
  const QuestionDispatchResult({
    required this.accepted,
    required this.normalized,
    this.superseded = const [],
    this.expired = const [],
  });
  final bool accepted;
  final String normalized;
  final List<String> superseded, expired;
}

class _PrefixEntry {
  const _PrefixEntry(this.timestamp, this.tokens);
  final int timestamp;
  final Set<String> tokens;
}

/// Five-second question suppression followed by the reference's twenty-second
/// ordered prefix/similarity filter. Copy before committing durable work so a
/// failed database transaction cannot consume a question's eligibility.
class MeetingQuestionDispatcher {
  MeetingQuestionDispatcher();
  MeetingQuestionDispatcher._(this._deduplicator, this._entries);
  QuestionTextDeduplicator _deduplicator = QuestionTextDeduplicator();
  Map<String, _PrefixEntry> _entries = {};

  MeetingQuestionDispatcher copy() =>
      MeetingQuestionDispatcher._(_deduplicator.copy(), Map.of(_entries));

  QuestionDispatchResult process(String question, int now) {
    final normalized = normalizeMeetingQuestion(question);
    if (!_deduplicator.process(question, now)) {
      return QuestionDispatchResult(accepted: false, normalized: normalized);
    }
    // The reference's empty-normalization branch accepts without changing its
    // prefix state (including without pruning it).
    if (normalized.isEmpty) {
      return QuestionDispatchResult(accepted: true, normalized: normalized);
    }
    final tokens = normalized
        .split(_whitespace)
        .where((s) => s.isNotEmpty)
        .toSet();
    final expired = <String>[];
    _entries.removeWhere((key, entry) {
      if (now - entry.timestamp < 20000) return false;
      expired.add(key);
      return true;
    });
    final superseded = <String>[];
    var accepted = true;
    String? refresh;
    for (final entry in _entries.entries) {
      final old = entry.key;
      if (normalized == old) {
        accepted = false;
        refresh = old;
        break;
      }
      if (normalized.startsWith(old)) {
        superseded.add(old);
        continue;
      }
      if (old.startsWith(normalized)) {
        accepted = false;
        break;
      }
      final similar =
          QuestionSimilarity.jaccard(tokens, entry.value.tokens) >= .7 ||
          QuestionSimilarity.tokenSetRatio(tokens, entry.value.tokens) >= .8 ||
          QuestionSimilarity.partialRatio(normalized, old) >= .9;
      if (!similar) continue;
      if (normalized.length < old.length) {
        accepted = false;
        break;
      }
      superseded.add(old);
    }
    // Collected removals apply even when a later entry suppresses the new text.
    for (final key in superseded) {
      _entries.remove(key);
    }
    if (accepted) {
      _entries[normalized] = _PrefixEntry(now, tokens);
    } else if (refresh != null) {
      _entries[refresh] = _PrefixEntry(now, _entries[refresh]!.tokens);
    }
    return QuestionDispatchResult(
      accepted: accepted,
      normalized: normalized,
      superseded: superseded,
      expired: expired,
    );
  }
}
