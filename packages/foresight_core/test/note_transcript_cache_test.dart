import 'dart:async';

import 'package:foresight_core/src/reference_note_enhancement_chunking.dart';
import 'package:foresight_core/src/reference_note_transcript_cache.dart';
import 'package:test/test.dart';

void main() {
  test(
    'meeting invalidation preserves another complete cached meeting',
    () async {
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (_) async => [1],
        currentIsLive: (_) => false,
        loadSavedTranscript: (id) async => 'Reloaded $id',
      );
      await cache.schedule(1, 'Old one', isLive: false);
      await cache.schedule(2, 'Retained two', isLive: false);
      final retained = cache.getCachedChunks(2);
      cache.invalidate(1);
      expect(cache.getCachedChunks(1), isEmpty);
      expect(identical(cache.getCachedChunks(2), retained), isTrue);
      expect((await cache.getEmbeddedChunks(1)).single.text, 'Reloaded 1');
      expect((await cache.getEmbeddedChunks(2)).single.text, 'Retained two');
    },
  );

  test(
    'meeting invalidation prevents a blocked saved load from scheduling stale text',
    () async {
      final oldLoad = Completer<String>();
      var loads = 0;
      final embedded = <String>[];
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) async {
          embedded.add(text);
          return [1];
        },
        currentIsLive: (_) => false,
        loadSavedTranscript: (_) async =>
            ++loads == 1 ? await oldLoad.future : 'New transcript',
      );
      final obsolete = cache.getEmbeddedChunks(1);
      cache.invalidate(1);
      oldLoad.complete('Old transcript');
      expect(await obsolete, isEmpty);
      expect(cache.getCachedChunks(1), isEmpty);
      expect(embedded, isEmpty);
      expect((await cache.getEmbeddedChunks(1)).single.text, 'New transcript');
      expect(embedded, ['New transcript']);
    },
  );

  test(
    'meeting invalidation prevents old live reader from observing replacement entry',
    () async {
      final oldEmbedding = Completer<List<double>>();
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) async =>
            text == 'Old' ? await oldEmbedding.future : [2],
        currentIsLive: (_) => true,
        loadSavedTranscript: (_) async => '',
      );
      final work = cache.schedule(1, 'Old', isLive: true);
      final obsolete = cache.getEmbeddedChunks(1);
      cache.invalidate(1);
      await cache.schedule(1, 'New', isLive: true);
      oldEmbedding.complete([1]);
      await work;
      expect(await obsolete, isEmpty);
      expect(cache.getCachedChunks(1).single.text, 'New');
    },
  );

  test(
    'workspace clear discards saved loads before they can schedule old text',
    () async {
      final oldLoad = Completer<String>();
      var loads = 0;
      final embedded = <String>[];
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) async {
          embedded.add(text);
          return [1];
        },
        currentIsLive: (_) => false,
        loadSavedTranscript: (_) async =>
            ++loads == 1 ? await oldLoad.future : 'New workspace',
      );
      final obsolete = cache.getEmbeddedChunks(1);
      cache.clear();
      oldLoad.complete('Old workspace');
      expect(await obsolete, isEmpty);
      expect(cache.getCachedChunks(1), isEmpty);
      expect(embedded, isEmpty);
      expect((await cache.getEmbeddedChunks(1)).single.text, 'New workspace');
      expect(embedded, ['New workspace']);
    },
  );

  test(
    'workspace clear prevents an old live reader from returning new same-ID data',
    () async {
      final gate = Completer<List<double>>();
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) async =>
            text == 'Old' ? await gate.future : [2],
        currentIsLive: (_) => true,
        loadSavedTranscript: (_) async => '',
      );
      final running = cache.schedule(1, 'Old', isLive: true);
      final obsolete = cache.getEmbeddedChunks(1);
      cache.clear();
      await cache.schedule(1, 'New', isLive: true);
      gate.complete([1]);
      await running;
      expect(await obsolete, isEmpty);
      expect(cache.getCachedChunks(1).single.text, 'New');
    },
  );

  test('coalesces pending requests and shares the running future', () async {
    final first = Completer<List<double>>();
    final calls = <String>[];
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (text) async {
        calls.add(text);
        return calls.length == 1 ? await first.future : [2];
      },
      currentIsLive: (_) => true,
      loadSavedTranscript: (_) async => throw StateError('live'),
    );
    final running = cache.schedule(1, 'first', isLive: true);
    expect(
      identical(cache.schedule(1, 'obsolete', isLive: true), running),
      isTrue,
    );
    expect(
      identical(cache.schedule(1, 'latest', isLive: true), running),
      isTrue,
    );
    first.complete([1]);
    await running;
    expect(calls, ['first', 'latest']);
    expect((await cache.getEmbeddedChunks(1)).single.text, 'latest');
  });

  test('checks live mode after embedding and discards stale results', () async {
    var live = true;
    final embedding = Completer<List<double>>();
    var savedLoads = 0;
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) => embedding.future,
      currentIsLive: (_) => live,
      loadSavedTranscript: (_) async {
        savedLoads++;
        return '';
      },
    );
    final work = cache.schedule(1, 'live result', isLive: true);
    live = false;
    embedding.complete([1]);
    await work;
    expect(await cache.getEmbeddedChunks(1), isEmpty);
    expect(savedLoads, 1);
    live = true;
    expect(await cache.getEmbeddedChunks(1), isEmpty);
  });

  test('reuses exact text and retries empty embeddings', () async {
    final calls = <String>[];
    final vector = <double>[1];
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (text) async {
        calls.add(text);
        return text == 'empty' && calls.where((s) => s == text).length == 1
            ? []
            : vector;
      },
      currentIsLive: (_) => true,
      loadSavedTranscript: (_) async => '',
    );
    await cache.schedule(1, ' exact ', isLive: true);
    await cache.schedule(1, 'exact', isLive: true);
    expect(calls, ['exact']);
    expect(
      identical((await cache.getEmbeddedChunks(1)).single.embedding, vector),
      isTrue,
    );
    await cache.schedule(1, 'Exact', isLive: true);
    expect(calls, ['exact', 'Exact']);
    await cache.schedule(1, 'empty', isLive: true);
    await cache.schedule(1, 'empty', isLive: true);
    expect(calls, ['exact', 'Exact', 'empty', 'empty']);
  });

  test(
    'embeds chunks sequentially and does not memoize within a pass',
    () async {
      final text = List.filled(320, 'word').join(' ');
      final expected = chunkNoteEnhancementTranscript(text, isLive: true);
      expect(expected.length, 3);
      expect(expected[0], expected[1]);
      final gates = <Completer<List<double>>>[];
      final calls = <String>[];
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) {
          calls.add(text);
          final gate = Completer<List<double>>();
          gates.add(gate);
          return gate.future;
        },
        currentIsLive: (_) => true,
        loadSavedTranscript: (_) async => '',
      );
      final work = cache.schedule(1, text, isLive: true);
      for (var index = 0; index < expected.length; index++) {
        await Future<void>.delayed(Duration.zero);
        expect(calls.length, index + 1);
        gates[index].complete([index.toDouble()]);
      }
      await work;
      expect(calls, expected);
      final previous = await cache.getEmbeddedChunks(1);
      await cache.schedule(1, text, isLive: true);
      expect(calls, expected);
      final reused = await cache.getEmbeddedChunks(1);
      // The later duplicate in the previous pass wins the reuse map.
      expect(identical(reused[0].embedding, previous[2].embedding), isTrue);
    },
  );

  test('retains five entries and refreshes recency on schedule', () async {
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) async => [1],
      currentIsLive: (_) => true,
      loadSavedTranscript: (_) async => '',
    );
    for (var id = 1; id <= 5; id++) {
      await cache.schedule(id, 'meeting $id', isLive: true);
    }
    await cache.schedule(1, 'meeting 1', isLive: true);
    await cache.schedule(6, 'meeting 6', isLive: true);
    expect(await cache.getEmbeddedChunks(2), isEmpty);
    expect((await cache.getEmbeddedChunks(1)).single.text, 'meeting 1');
    for (var id = 3; id <= 6; id++) {
      expect(await cache.getEmbeddedChunks(id), hasLength(1));
    }
  });

  test('live reads await work without loading saved transcripts', () async {
    final gate = Completer<List<double>>();
    var finished = false;
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) => gate.future,
      currentIsLive: (_) => true,
      loadSavedTranscript: (_) async => throw StateError('unexpected load'),
    );
    expect(await cache.getEmbeddedChunks(99), isEmpty);
    final work = cache.schedule(1, 'current', isLive: true);
    final read = cache.getEmbeddedChunks(1).then((value) {
      finished = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    gate.complete([1]);
    await work;
    expect((await read).single.text, 'current');
  });

  test('successful reads promote entries and preserve list identity', () async {
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) async => [1],
      currentIsLive: (_) => true,
      loadSavedTranscript: (_) async => '',
    );
    for (var id = 1; id <= 5; id++) {
      await cache.schedule(id, 'meeting $id', isLive: true);
    }
    final first = await cache.getEmbeddedChunks(1);
    expect(identical(first, cache.getCachedChunks(1)), isTrue);
    await cache.schedule(6, 'meeting 6', isLive: true);
    expect(await cache.getEmbeddedChunks(2), isEmpty);
    expect(identical(await cache.getEmbeddedChunks(1), first), isTrue);
  });

  test('saved reads reload live-mode entries and incomplete vectors', () async {
    var live = true;
    var loads = 0;
    var embeddings = 0;
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) async {
        embeddings++;
        return embeddings == 2 ? [] : [1];
      },
      currentIsLive: (_) => live,
      loadSavedTranscript: (_) async {
        loads++;
        return 'saved';
      },
    );
    await cache.schedule(1, 'live', isLive: true);
    live = false;
    expect((await cache.getEmbeddedChunks(1)).single.embedding, isEmpty);
    expect((await cache.getEmbeddedChunks(1)).single.embedding, [1]);
    expect(loads, 2);
    expect(embeddings, 3);
  });

  test('saved reads load once and reuse complete results unchanged', () async {
    var loads = 0;
    var calls = 0;
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) async {
        calls++;
        return [1];
      },
      currentIsLive: (_) => false,
      loadSavedTranscript: (_) async {
        loads++;
        return ' saved ';
      },
    );
    expect((await cache.getEmbeddedChunks(1)).single.text, 'saved');
    expect((await cache.getEmbeddedChunks(1)).single.text, 'saved');
    expect(loads, 1);
    expect(calls, 1);
  });

  test('saved empty transcripts do not produce embeddings', () async {
    final cache = ReferenceNoteTranscriptCache(
      computeEmbedding: (_) async => throw StateError('unexpected embedding'),
      currentIsLive: (_) => false,
      loadSavedTranscript: (_) async => ' \n ',
    );
    expect(await cache.getEmbeddedChunks(1), isEmpty);
  });

  test(
    'saved reads reload during a drain with complete previous chunks',
    () async {
      final gate = Completer<List<double>>();
      final calls = <String>[];
      var loads = 0;
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) async {
          calls.add(text);
          return text == 'in flight' ? await gate.future : [1];
        },
        currentIsLive: (_) => false,
        loadSavedTranscript: (_) async {
          loads++;
          return 'latest saved';
        },
      );
      await cache.schedule(1, 'previous', isLive: false);
      final running = cache.schedule(1, 'in flight', isLive: false);
      final read = cache.getEmbeddedChunks(1);
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      gate.complete([2]);
      await running;
      expect((await read).single.text, 'latest saved');
      expect(calls, ['previous', 'in flight', 'latest saved']);
    },
  );

  test(
    'propagates embedding failure and permits a later saved read to recover',
    () async {
      final error = StateError('embedding failed');
      var attempts = 0;
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (_) async {
          if (++attempts == 1) throw error;
          return [2];
        },
        currentIsLive: (_) => false,
        loadSavedTranscript: (_) async => 'saved evidence',
      );
      await expectLater(cache.getEmbeddedChunks(1), throwsA(same(error)));
      final recovered = await cache.getEmbeddedChunks(1);
      expect(recovered.single.text, 'saved evidence');
      expect(recovered.single.embedding, [2]);
      expect(attempts, 2);
    },
  );

  test(
    'failure rejects shared pending callers without starting their work; '
    'the next schedule replaces stale pending text and retains prior chunks',
    () async {
      final error = StateError('embedding failed');
      final gate = Completer<List<double>>();
      final texts = <String>[];
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (text) async {
          texts.add(text);
          return text == 'blocked failure' ? await gate.future : [1];
        },
        currentIsLive: (_) => true,
        loadSavedTranscript: (_) async => '',
      );
      await cache.schedule(1, 'previous accepted', isLive: true);
      final work = cache.schedule(1, 'blocked failure', isLive: true);
      final pending = cache.schedule(1, 'stale pending', isLive: true);
      expect(identical(work, pending), isTrue);
      final failedWork = expectLater(work, throwsA(same(error)));
      final failedPending = expectLater(pending, throwsA(same(error)));
      gate.completeError(error);
      await Future.wait([failedWork, failedPending]);
      expect(cache.getCachedChunks(1).single.text, 'previous accepted');
      final next = cache.schedule(1, 'newest transcript', isLive: true);
      expect(identical(next, work), isFalse);
      await next;
      expect(
        (await cache.getEmbeddedChunks(1)).single.text,
        'newest transcript',
      );
      expect(texts, [
        'previous accepted',
        'blocked failure',
        'newest transcript',
      ]);
    },
  );
}
