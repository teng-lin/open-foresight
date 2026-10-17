import 'dart:async';

import 'package:foresight_core/src/reference_note_enhancer.dart';
import 'package:test/test.dart';

class FakeConversation implements NoteEnhancementConversation {
  FakeConversation(
    this.id,
    this.events,
    this.deltas, {
    this.failure,
    this.onClose,
    this.onCancel,
  });
  final int id;
  final List<String> events;
  final List<String> deltas;
  final Object? failure;
  final Future<void> Function()? onClose;
  final Future<void> Function()? onCancel;
  String? prompt;

  @override
  Stream<String> sendMessageStream(String prompt) async* {
    this.prompt = prompt;
    events.add('send$id');
    try {
      for (final delta in deltas) {
        yield delta;
      }
      if (failure case final error?) throw error;
    } finally {
      events.add('iterator$id');
    }
  }

  @override
  Future<void> cancelProcess() async {
    events.add('cancel$id');
    await onCancel?.call();
  }

  @override
  Future<void> close() async {
    events.add('close$id');
    await onClose?.call();
  }
}

void main() {
  test(
    'readiness failure propagates before loading transcript or opening conversation',
    () async {
      final failure = StateError('service unavailable');
      var loaded = false;
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async => throw failure,
        loadEmbeddedTranscript: () async {
          loaded = true;
          return [];
        },
        createConversation: (_) async => throw StateError('unexpected'),
      );
      await expectLater(
        enhancer.enhance(notes: 'raw').toList(),
        throwsA(same(failure)),
      );
      expect(loaded, isFalse);
    },
  );

  test('only final saved batch receives unused decision excerpts', () async {
    final conversations = <FakeConversation>[];
    final enhancer = ReferenceNoteEnhancer(
      ensureReady: () async {},
      loadEmbeddedTranscript: () async => [
        (text: 'Referenced meeting text', embedding: [1.0, 0.0]),
        (text: 'Risk needs review', embedding: [0.0, 1.0]),
      ],
      computeEmbedding: (_) async => [1, 0],
      encodeStopTokens: (_) async => [],
      createConversation: (settings) async {
        expect(settings.stopTokenIds, isNull);
        final conversation = FakeConversation(conversations.length, [], [
          '- Note',
        ]);
        conversations.add(conversation);
        return conversation;
      },
    );
    await enhancer.enhance(notes: 'a\nb\nc\nd\ne\nf').toList();
    expect(conversations, hasLength(2));
    expect(
      conversations.first.prompt,
      isNot(contains('<uncovered_meeting_excerpts>')),
    );
    expect(conversations.last.prompt, contains('<uncovered_meeting_excerpts>'));
    expect(conversations.last.prompt, contains('Risk needs review'));
    conversations.clear();
    await enhancer.enhance(notes: 'a\nb\nc\nd\ne\nf', isLive: true).toList();
    expect(
      conversations.every(
        (item) => !item.prompt!.contains('<uncovered_meeting_excerpts>'),
      ),
      isTrue,
    );
  });

  test(
    'empty and fully preserved notes stop before invoking runtime adapters',
    () async {
      final calls = <String>[];
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async => calls.add('ready'),
        loadEmbeddedTranscript: () async {
          calls.add('chunks');
          return [];
        },
        createConversation: (_) async => throw StateError('unexpected'),
      );
      expect(await enhancer.enhance(notes: '123\n -- ').toList(), [
        'Evaluating notes...',
        '',
      ]);
      expect(
        await enhancer
            .enhance(
              notes: 'first\nsecond',
              existingEnhancedBullets: {0: '- Prior'},
              targetBulletIndices: {},
            )
            .toList(),
        ['Evaluating notes...', '- Prior\n\nsecond', '- Prior\n\nsecond'],
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'six notes use fresh conversations and merge both batches in original order',
    () async {
      final events = <String>[];
      final conversations = <FakeConversation>[];
      final active = <int?>[];
      final settings = <NoteEnhancementConversationSettings>[];
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async => events.add('ready'),
        loadEmbeddedTranscript: () async => [
          (text: 'meeting', embedding: <double>[]),
        ],
        encodeStopTokens: (text) async {
          expect(text, '</output>');
          return [7, 8];
        },
        createConversation: (config) async {
          settings.add(config);
          final id = conversations.length;
          final conversation = FakeConversation(id, events, [
            id == 0 ? '- A\n- B\n- C\n- D' : '- E\n- F',
          ]);
          conversations.add(conversation);
          return conversation;
        },
      );
      final output = await enhancer
          .enhance(notes: 'a\nb\nc\nd\ne\nf', onActiveIndexChanged: active.add)
          .toList();
      expect(output.take(3), [
        'Evaluating notes...',
        'Scanning the transcripts...',
        'Structuring notes...',
      ]);
      expect(output.last, '- A\n\n- B\n\n- C\n\n- D\n\n- E\n\n- F');
      expect(conversations, hasLength(2));
      expect(conversations[0].prompt, contains('<scribble>a</scribble>'));
      expect(conversations[1].prompt, contains('<scribble>e</scribble>'));
      expect(active, [0, 3, 4, 5, null]);
      expect(events, [
        'ready',
        'send0',
        'iterator0',
        'close0',
        'send1',
        'iterator1',
        'close1',
      ]);
      for (final config in settings) {
        expect(config.maxInputTokens, 2048);
        expect(config.stopTokenIds, [
          [7, 8],
        ]);
      }
    },
  );

  test(
    'note embeddings start concurrently before any result completes',
    () async {
      final started = <String>[];
      final gates = [Completer<List<double>>(), Completer<List<double>>()];
      final allStarted = Completer<void>();
      final conversation = FakeConversation(0, [], ['- A\n- B']);
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async {},
        loadEmbeddedTranscript: () async => [
          (text: 'meeting', embedding: [1.0]),
        ],
        computeEmbedding: (text) {
          started.add(text);
          if (started.length == 2) allStarted.complete();
          return gates[started.length - 1].future;
        },
        createConversation: (_) async => conversation,
      );
      final result = enhancer.enhance(notes: 'a\nb').toList();
      await allStarted.future.timeout(const Duration(seconds: 3));
      expect(started, ['a', 'b']);
      expect(conversation.prompt, isNull);
      gates[1].complete([1]);
      gates[0].complete([1]);
      expect((await result).last, '- A\n\n- B');
    },
  );

  test(
    'raw stop marker emits cleaned preview before cancel and closes afterward',
    () async {
      final events = <String>[];
      final conversation = FakeConversation(0, events, [
        '```markdown\n- Kept\n```</output>',
        '- Unread',
      ]);
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async {},
        loadEmbeddedTranscript: () async => [],
        createConversation: (settings) async {
          expect(settings.stopTokenIds, isNull);
          return conversation;
        },
      );
      final output = <String>[];
      await for (final value in enhancer.enhance(notes: 'raw')) {
        output.add(value);
        if (value == '- Kept') events.add('preview');
      }
      expect(output.last, '- Kept');
      expect(events, [
        'send0',
        'preview',
        'cancel0',
        'iterator0',
        'close0',
        'preview',
      ]);
      expect(output.join(), isNot(contains('Unread')));
    },
  );

  test(
    'consumer cancellation disposes iterator then conversation without failing batch',
    () async {
      final events = <String>[];
      final errors = <Object>[];
      final active = <int?>[];
      final conversation = FakeConversation(0, events, [
        '- Preview',
        '- Unread',
      ]);
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async {},
        loadEmbeddedTranscript: () async => [],
        createConversation: (_) async => conversation,
        logBatchError: (error, _) => errors.add(error),
      );
      final output = await enhancer
          .enhance(notes: 'raw', onActiveIndexChanged: active.add)
          .take(4)
          .toList();
      expect(output.last, '- Preview');
      expect(events, ['send0', 'iterator0', 'close0']);
      expect(errors, isEmpty);
      expect(active, [0, 0]);
    },
  );

  test(
    'stream failure falls back for that batch and continues after awaited close',
    () async {
      final events = <String>[];
      final errors = <Object>[];
      var created = 0;
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async {},
        loadEmbeddedTranscript: () async => [],
        createConversation: (_) async {
          final id = created++;
          return FakeConversation(id, events, [
            id == 0 ? '- Unaccepted partial' : '- E\n- F',
          ], failure: id == 0 ? StateError('failed') : null);
        },
        logBatchError: (error, _) => errors.add(error),
      );
      final output = await enhancer.enhance(notes: 'a\nb\nc\nd\ne\nf').toList();
      expect(errors.single, isA<StateError>());
      expect(output.last, '* a\n\n* b\n\n* c\n\n* d\n\n- E\n\n- F');
      expect(events, [
        'send0',
        'iterator0',
        'close0',
        'send1',
        'iterator1',
        'close1',
      ]);
    },
  );

  test('embedding failures propagate without a conversation', () async {
    var created = 0;
    final failure = StateError('embedding failed');
    final enhancer = ReferenceNoteEnhancer(
      ensureReady: () async {},
      loadEmbeddedTranscript: () async => [],
      computeEmbedding: (_) async => throw failure,
      createConversation: (_) async {
        created++;
        return FakeConversation(0, [], []);
      },
    );
    await expectLater(
      enhancer.enhance(notes: 'raw').toList(),
      throwsA(same(failure)),
    );
    expect(created, 0);
  });

  test('close is awaited before the next batch is created', () async {
    final closing = Completer<void>();
    final enteredClose = Completer<void>();
    final events = <String>[];
    var created = 0;
    final enhancer = ReferenceNoteEnhancer(
      ensureReady: () async {},
      loadEmbeddedTranscript: () async => [],
      createConversation: (_) async {
        final id = created++;
        return FakeConversation(
          id,
          events,
          ['- Accepted'],
          onClose: () async {
            if (id == 0) {
              enteredClose.complete();
              await closing.future;
            }
          },
        );
      },
    );
    final output = enhancer.enhance(notes: 'a\nb\nc\nd\ne\nf').toList();
    await enteredClose.future;
    expect(created, 1);
    closing.complete();
    await output;
    expect(created, 2);
    expect(events.indexOf('close0'), lessThan(events.indexOf('send1')));
  });

  for (final batchFails in [false, true]) {
    test(
      'close failure escapes ${batchFails ? 'recovered' : 'successful'} batch',
      () async {
        final events = <String>[];
        final errors = <Object>[];
        final active = <int?>[];
        final output = <String>[];
        final closeFailure = StateError('close failed');
        final closeStack = StackTrace.fromString('original close stack');
        final batchFailure = StateError('generation failed');
        var created = 0;
        final enhancer = ReferenceNoteEnhancer(
          ensureReady: () async {},
          loadEmbeddedTranscript: () async => [],
          createConversation: (_) async => FakeConversation(
            created++,
            events,
            ['- Partial'],
            failure: batchFails ? batchFailure : null,
            onClose: () async =>
                Error.throwWithStackTrace(closeFailure, closeStack),
          ),
          logBatchError: (error, _) => errors.add(error),
        );
        Object? caught;
        StackTrace? caughtStack;
        try {
          await for (final value in enhancer.enhance(
            notes: 'a\nb\nc\nd\ne\nf',
            onActiveIndexChanged: active.add,
          )) {
            output.add(value);
          }
        } catch (error, stack) {
          caught = error;
          caughtStack = stack;
        }
        expect(caught, same(closeFailure));
        expect(caughtStack.toString(), closeStack.toString());
        expect(errors, batchFails ? [same(batchFailure)] : isEmpty);
        expect(created, 1);
        expect(events, ['send0', 'iterator0', 'close0']);
        expect(output.last, contains('Partial'));
        expect(active, isNot(contains(null)));
      },
    );
  }

  test(
    'outer cleanup rethrows a failing batch handler with its stack',
    () async {
      final events = <String>[];
      final failure = StateError('handler failed');
      final failureStack = StackTrace.fromString('original handler stack');
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async {},
        loadEmbeddedTranscript: () async => [],
        createConversation: (_) async => FakeConversation(
          0,
          events,
          [],
          failure: StateError('generation failed'),
        ),
        logBatchError: (_, _) =>
            Error.throwWithStackTrace(failure, failureStack),
      );
      Object? caught;
      StackTrace? caughtStack;
      try {
        await enhancer.enhance(notes: 'raw').toList();
      } catch (error, stack) {
        caught = error;
        caughtStack = stack;
      }
      expect(caught, same(failure));
      expect(caughtStack.toString(), failureStack.toString());
      expect(events, ['send0', 'iterator0', 'close0']);
    },
  );

  test(
    'stop cancellation failure recovers the batch after disposing resources',
    () async {
      final events = <String>[];
      final errors = <Object>[];
      final failure = StateError('cancel failed');
      final enhancer = ReferenceNoteEnhancer(
        ensureReady: () async {},
        loadEmbeddedTranscript: () async => [],
        createConversation: (_) async => FakeConversation(0, events, [
          '- Partial</output>',
        ], onCancel: () async => throw failure),
        logBatchError: (error, _) => errors.add(error),
      );
      final output = await enhancer.enhance(notes: 'raw').toList();
      expect(output.last, '* raw');
      expect(errors, [same(failure)]);
      expect(events, ['send0', 'cancel0', 'iterator0', 'close0']);
    },
  );

  test('close failure replaces a pending outer-handler failure', () async {
    final events = <String>[];
    final handlerFailure = StateError('handler failed');
    final closeFailure = StateError('close failed');
    final enhancer = ReferenceNoteEnhancer(
      ensureReady: () async {},
      loadEmbeddedTranscript: () async => [],
      createConversation: (_) async => FakeConversation(
        0,
        events,
        [],
        failure: StateError('generation failed'),
        onClose: () async => throw closeFailure,
      ),
      logBatchError: (_, _) => throw handlerFailure,
    );
    await expectLater(
      enhancer.enhance(notes: 'raw').toList(),
      throwsA(same(closeFailure)),
    );
    expect(events, ['send0', 'iterator0', 'close0']);
  });

  test('conversation creation failure escapes before batch recovery', () async {
    final failure = StateError('creation failed');
    final errors = <Object>[];
    final enhancer = ReferenceNoteEnhancer(
      ensureReady: () async {},
      loadEmbeddedTranscript: () async => [],
      createConversation: (_) async => throw failure,
      logBatchError: (error, _) => errors.add(error),
    );
    await expectLater(
      enhancer.enhance(notes: 'raw').toList(),
      throwsA(same(failure)),
    );
    expect(errors, isEmpty);
  });
}
