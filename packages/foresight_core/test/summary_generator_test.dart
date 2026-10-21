import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/summary_generator.dart';
import 'package:foresight_core/src/summary_output.dart';
import 'package:foresight_core/src/summary_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('frozen original prompts retain their exact bytes and wrappers', () {
    final fixture =
        jsonDecode(
              File('test/fixtures/summary_prompts.json').readAsStringSync(),
            )
            as Map;
    final literals = {
      '37749': summaryExistingStart,
      '37750': summaryExistingEnd,
      '37751': summaryNewEnd,
      '37752': summaryIncrementalInstructions,
      '37753': summaryFullStart,
      '37754': summaryFullEnd,
      '37755': summaryFullInstructions,
      '37765': summaryReduceStart,
      '37766': summaryReduceEnd,
      '37770': summaryChunkStart,
      '37771': summaryChunkEnd,
      '37772': summaryMapInstructions,
    };
    for (final entry in literals.entries) {
      expect(entry.value, fixture[entry.key]['text']);
      expect(
        sha256.convert(utf8.encode(entry.value)).toString(),
        fixture[entry.key]['sha256_utf8'],
      );
    }
    expect(
      summaryFullPrompt('launch'),
      '<meeting_transcript>\nlaunch\n</meeting_transcript>\n',
    );
    expect(
      summaryIncrementalPrompt('old', 'new'),
      '<existing_meeting_brief>\nold\n</existing_meeting_brief>\n\n<new_transcript_section>\nnew\n</new_transcript_section>\n',
    );
    expect(summaryFullInstructions, isNot(contains('# Action Items')));
  });

  late List<({String prompt, String system})> calls;
  late List<SummaryProgress> progress;
  late bool current;
  late SummaryGenerator generator;
  setUp(() {
    calls = [];
    progress = [];
    current = true;
    generator = SummaryGenerator(
      countTokens: (text) async => summaryWordCount(text),
      checkCurrent: () {
        if (!current) throw StateError('cancelled');
      },
      onProgress: progress.add,
      complete: (prompt, system, preview) async {
        calls.add((prompt: prompt, system: system));
        preview('Microphone noted that launch is Friday.');
        return '# Overview\nMicrophone noted that launch is Friday.\n# Details\n* **Launch plan**: Alice owns the release.';
      },
    );
  });

  test(
    'manual brief includes all final text and separate protected system instructions',
    () async {
      final result = await generator.generate(
        'Alice: Launch Friday.',
        identity: 'model',
      );
      expect(result.mode, 'full');
      expect(calls.single.prompt, contains('Alice: Launch Friday.'));
      expect(calls.single.system, startsWith(summarySourcePolicy));
      expect(calls.single.system, endsWith(summaryFullInstructions));
      expect(result.body, contains('It was noted that launch'));
      expect(result.body, contains('Alice owns'));
      expect(progress.last.preview, contains('It was noted that'));
    },
  );

  for (final count in [0, 99, 100, 2048, 2049]) {
    test(
      'automatic admission and half-context boundary $count words',
      () async {
        final text = List.filled(count, 'word').join(' ');
        if (count < 100) {
          await expectLater(
            generator.generate(text, identity: 'model', refresh: false),
            throwsStateError,
          );
          expect(calls, isEmpty);
        } else {
          final result = await generator.generate(
            text,
            identity: 'model',
            refresh: false,
          );
          expect(result.mode, count <= 2048 ? 'full' : 'map_reduce');
        }
      },
    );
  }

  test(
    'incremental refresh requires matching prefix and generation identity',
    () async {
      final previous = List.filled(2100, 'old').join(' ');
      final checkpoint = SummaryCheckpoint(
        body: 'Previous brief',
        inputLength: previous.length,
        inputDigest: summaryDigest(previous),
        identity: 'model',
      );
      final text = '$previous new decision';
      final result = await generator.generate(
        text,
        identity: 'model',
        checkpoint: checkpoint,
      );
      expect(result.mode, 'incremental');
      expect(
        calls.single.prompt,
        contains('<existing_meeting_brief>\nPrevious brief'),
      );
      expect(
        calls.single.prompt,
        contains('<new_transcript_section>\nnew decision'),
      );
      expect(calls.single.system, endsWith(summaryIncrementalInstructions));
      expect(
        checkpoint.accepts(text.replaceFirst('old', 'NEW'), 'model'),
        isFalse,
      );
      expect(checkpoint.accepts(text, 'changed-model-or-prompt'), isFalse);
      expect(checkpoint.accepts('shorter', 'model'), isFalse);
    },
  );

  test(
    'cached unchanged input avoids model work; mismatched identity recomputes',
    () async {
      final checkpoint = SummaryCheckpoint(
        body: 'Accepted',
        inputLength: 5,
        inputDigest: summaryDigest('hello'),
        identity: 'model',
      );
      final result = await generator.generate(
        'hello',
        identity: 'model',
        checkpoint: checkpoint,
        refresh: false,
      );
      expect(result.mode, 'cached');
      expect(calls, isEmpty);
      final replacement = await generator.generate(
        'hello',
        identity: 'new',
        checkpoint: checkpoint,
      );
      expect(replacement.mode, 'full');
    },
  );

  test(
    'long meetings map sequential windows covering every word and reduce once',
    () async {
      final words = List.generate(6000, (i) => 'w$i');
      final result = await generator.generate(
        words.join(' '),
        identity: 'model',
      );
      expect(result.mode, 'map_reduce');
      final maps = calls
          .where((c) => c.prompt.startsWith('<transcript_chunk>'))
          .toList();
      expect(result.chunks, maps.length);
      expect(calls.last.system, endsWith(summaryFullInstructions));
      expect(calls.last.prompt, startsWith(summaryReduceStart));
      final seen = <String>{};
      for (final call in maps) {
        seen.addAll(
          call.prompt.split(RegExp(r'\s+')).where((s) => s.startsWith('w')),
        );
      }
      expect(seen, containsAll(words));
      expect(maps.first.prompt, contains('w0'));
      expect(maps.last.prompt, contains('w5999'));
      expect(calls.length, maps.length + 1);
    },
  );

  test(
    'actual token pressure repartitions without skipping evidence',
    () async {
      final mapped = <String>[];
      final constrained = SummaryGenerator(
        contextTokens: 4096,
        outputTokens: 256,
        countTokens: (s) async => utf8.encode(s).length,
        checkCurrent: () {},
        onProgress: (_) {},
        complete: (prompt, system, preview) async {
          mapped.add(prompt);
          return 'Fact.';
        },
      );
      final words = List.generate(1800, (i) => 'word$i');
      final result = await constrained.generate(
        words.join(' '),
        identity: 'byte-bound',
      );
      expect(result.chunks, greaterThan(1));
      for (final word in words) {
        expect(
          mapped.any((prompt) => RegExp('\\b$word\\b').hasMatch(prompt)),
          isTrue,
          reason: word,
        );
      }
    },
  );

  test('a single map result still receives final brief formatting', () async {
    final single = SummaryGenerator(
      countTokens: (text) async =>
          text.contains(summaryFullStart) ? 5000 : summaryWordCount(text),
      checkCurrent: () {},
      onProgress: (_) {},
      complete: (prompt, system, preview) async {
        calls.add((prompt: prompt, system: system));
        return prompt.startsWith(summaryChunkStart)
            ? '* Launch Friday.'
            : '# Overview\nLaunch Friday.\n# Details\n* **Launch date**: Friday.';
      },
    );
    final result = await single.generate(
      'Alice: launch Friday.',
      identity: 'm',
    );
    expect(result.chunks, 1);
    expect(calls, hasLength(2));
    expect(calls.last.system, endsWith(summaryFullInstructions));
    expect(result.body, contains('# Overview'));
    expect(result.body, contains('# Details'));
  });

  test('many topics reduce in bounded sequential subtrees', () async {
    var maps = 0, reductions = 0;
    final hierarchical = SummaryGenerator(
      countTokens: (text) async =>
          summaryWordCount(text) + '\n\n---\n\n'.allMatches(text).length * 1000,
      checkCurrent: () {},
      onProgress: (_) {},
      complete: (prompt, system, preview) async {
        if (prompt.startsWith(summaryChunkStart)) return 'Topic${++maps}';
        reductions++;
        return RegExp(
          r'Topic\d+',
        ).allMatches(prompt).map((m) => m[0]).join(' ');
      },
    );
    final result = await hierarchical.generate('word ' * 24000, identity: 'm');
    expect(maps, greaterThan(10));
    expect(reductions, greaterThan(1));
    expect(result.chunks, maps);
    for (var i = 1; i <= maps; i++) {
      expect(RegExp('Topic$i\\b').hasMatch(result.body), isTrue);
    }
    expect(result.joinClipped, isFalse);
  });

  test(
    'reduction budgets every topic with system and output overhead',
    () async {
      var maps = 0;
      String? reduction;
      final constrained = SummaryGenerator(
        contextTokens: 4096,
        outputTokens: 1024,
        countTokens: (text) async => utf8.encode(text).length,
        checkCurrent: () {},
        onProgress: (_) {},
        complete: (prompt, system, preview) async {
          expect(
            utf8.encode('$system\n\n$prompt').length + 1024 + 128,
            lessThanOrEqualTo(4096),
          );
          if (prompt.startsWith(summaryChunkStart)) {
            return 'Topic ${++maps}: ${'decision detail ' * 70}';
          }
          reduction = prompt;
          return '# Overview\nAccepted brief';
        },
      );
      final result = await constrained.generate(
        'discussion ' * 1800,
        identity: 'm',
      );
      expect(result.chunks, greaterThan(1));
      expect(result.joinClipped, isTrue);
      for (var i = 1; i <= maps; i++) {
        expect(reduction, contains('Topic $i:'));
      }
    },
  );

  test('impossible reduction framing fails before any map work', () async {
    var reductions = 0, maps = 0;
    final constrained = SummaryGenerator(
      contextTokens: 2800,
      outputTokens: 512,
      countTokens: (text) async => utf8.encode(text).length,
      checkCurrent: () {},
      onProgress: (_) {},
      complete: (prompt, system, preview) async {
        if (prompt.startsWith(summaryChunkStart)) {
          maps++;
          return 'topic detail ' * 50;
        }
        reductions++;
        return 'must not accept';
      },
    );
    await expectLater(
      constrained.generate('discussion ' * 1200, identity: 'm'),
      throwsStateError,
    );
    expect(reductions, 0);
    expect(maps, 0);
  });

  test('cancellation prevents another map or final reduction', () async {
    final cancelled = SummaryGenerator(
      countTokens: (s) async => summaryWordCount(s),
      checkCurrent: () {
        if (!current) throw StateError('cancelled');
      },
      onProgress: (_) {},
      complete: (prompt, system, preview) async {
        calls.add((prompt: prompt, system: system));
        current = false;
        return 'Partial';
      },
    );
    await expectLater(
      cancelled.generate('word ' * 4000, identity: 'model'),
      throwsStateError,
    );
    expect(calls, hasLength(1));
  });

  test(
    'empty output and unfit single words fail without partial success',
    () async {
      final empty = SummaryGenerator(
        countTokens: (_) async => 1,
        checkCurrent: () {},
        onProgress: (_) {},
        complete: (_, __, ___) async => '  ',
      );
      await expectLater(
        empty.generate('meeting', identity: 'm'),
        throwsStateError,
      );
      await expectLater(
        generator.generate('x' * 100, identity: 'm'),
        completes,
      );
      final tooSmall = SummaryGenerator(
        contextTokens: 128,
        countTokens: (s) async => s.length,
        checkCurrent: () {},
        onProgress: (_) {},
        complete: (_, __, ___) async => fail('must not run'),
      );
      await expectLater(
        tooSmall.generate('x', identity: 'm'),
        throwsStateError,
      );
    },
  );

  test('safe joining retains every topic and preserves Unicode pairs', () {
    expect(joinSummaryPartials(['one', 'two'], 4096), (
      text: 'one\n\n---\n\ntwo',
      clipped: false,
    ));
    final result = joinSummaryPartials([
      'A' * 15000,
      'B' * 15000,
      '😀' * 8000,
    ], 4096);
    expect(result.clipped, isTrue);
    expect(result.text.length, lessThanOrEqualTo(10384));
    expect(result.text, contains('A'));
    expect(result.text, contains('B'));
    expect(utf8.decode(utf8.encode(result.text)), result.text);
    final many = joinSummaryPartials(
      List.generate(2000, (i) => 'Topic $i: ${'detail ' * 10}'),
      4096,
    );
    for (var i = 0; i < 2000; i++) {
      expect(many.text, contains('Topic $i:'));
    }
  });

  test('input cleanup and ordered attribution rules preserve real names', () {
    expect(
      cleanSummaryTranscript('Microphone: ready\nRemote: agreed\nAlice: ship'),
      'ready\nagreed\nAlice: ship',
    );
    expect(
      sanitizeSummary(
        'Microphone and Remote agreed that Alice will ship. Remote asked whether Friday works.',
      ),
      'It was discussed that Alice will ship. Questions were raised whether Friday works.',
    );
    expect(
      sanitizeSummary('* **Decision**: Remote approved Alice’s plan.'),
      '* **Decision**: approved Alice’s plan.',
    );
    for (final body in [
      'Remote engineers may relocate.',
      'remote engineers may relocate.',
      'Remote work is supported.',
      'Microphone quality needs improvement.',
    ]) {
      expect(
        sanitizeSummary('* **Hiring policy**: $body'),
        '* **Hiring policy**: $body',
      );
    }
    expect(
      sanitizeSummary('Alice noted that the remote server works.'),
      'Alice noted that the remote server works.',
    );
  });
}
