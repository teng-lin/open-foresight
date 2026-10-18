import 'package:foresight_core/src/rpc_error.dart';
import 'dart:io';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/native_note_enhancement.dart';
import 'package:foresight_core/src/reference_note_enhancer.dart';
import 'package:test/test.dart';

class ConversationRuntime extends NativeRuntime {
  ConversationRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');

  bool supportsStops = true;
  final cancellations = <String?>[];
  List<Map<String, dynamic>> events = [];
  int? receivedLimit;
  List<List<int>>? receivedStops;
  int requests = 0;

  @override
  Map<String, dynamic> get effectiveState => {
    'native_stop_token_sequences': supportsStops,
  };

  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    requests++;
    receivedLimit = maxOutputTokens;
    receivedStops = stopTokenIds;
    yield* Stream.fromIterable(events);
  }

  @override
  bool cancel({String? requestId}) {
    cancellations.add(requestId);
    return true;
  }
}

void main() {
  late ConversationRuntime runtime;
  setUp(() => runtime = ConversationRuntime());
  tearDown(() => runtime.close());
  NativeNoteEnhancementConversation create({List<List<int>>? stops}) =>
      NativeNoteEnhancementConversation.create(
        runtime: runtime,
        requestId: 'notes-1-batch-2',
        settings: NoteEnhancementConversationSettings(stopTokenIds: stops),
      );

  test(
    'converts cumulative previews and repeated final text to deltas',
    () async {
      runtime.events = [
        {'type': 'preview', 'text': '* First'},
        {'type': 'preview', 'text': '* First\n* Second'},
        {'type': 'delta', 'text': '* First\n* Second'},
        {'type': 'done', 'status': 'completed'},
      ];
      final conversation = create(
        stops: [
          [8, 9],
        ],
      );
      expect(await conversation.sendMessageStream('prompt').toList(), [
        '* First',
        '\n* Second',
      ]);
      expect(runtime.receivedLimit, isNull);
      expect(runtime.receivedStops, [
        [8, 9],
      ]);
      await conversation.close();
      expect(runtime.cancellations, ['notes-1-batch-2']);
    },
  );

  test('nonstreamed final answers are delivered once', () async {
    runtime.events = [
      {'type': 'delta', 'text': '* Final'},
      {'type': 'done', 'status': 'completed'},
    ];
    expect(await create().sendMessageStream('prompt').toList(), ['* Final']);
    expect(runtime.receivedStops, isEmpty);
  });

  test('rejects missing native stop support before starting inference', () {
    runtime.supportsStops = false;
    expect(
      () => create(
        stops: [
          [8, 9],
        ],
      ),
      throwsStateError,
    );
    expect(runtime.requests, 0);
    expect(() => create(), returnsNormally);
  });

  test('does not append a contradictory terminal response', () async {
    runtime.events = [
      {'type': 'preview', 'text': '* Streamed'},
      {'type': 'delta', 'text': '* Different'},
      {'type': 'done', 'status': 'completed'},
    ];
    await expectLater(
      create().sendMessageStream('prompt').toList(),
      throwsStateError,
    );
  });

  test(
    'a cancelled native terminal status preserves the cancellation code',
    () async {
      runtime.events = [
        {'type': 'done', 'status': 'cancelled'},
      ];
      await expectLater(
        create().sendMessageStream('prompt').toList(),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
    },
  );

  test('reports failed terminal status and owns idempotent disposal', () async {
    runtime.events = [
      {'type': 'error', 'message': 'decode failed'},
      {'type': 'done', 'status': 'failed'},
    ];
    final conversation = create();
    await expectLater(
      conversation.sendMessageStream('prompt').toList(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('decode failed'),
        ),
      ),
    );
    await conversation.cancelProcess();
    await conversation.close();
    await conversation.close();
    expect(runtime.cancellations, ['notes-1-batch-2', 'notes-1-batch-2']);
    await expectLater(
      conversation.sendMessageStream('again').toList(),
      throwsStateError,
    );
  });
}
