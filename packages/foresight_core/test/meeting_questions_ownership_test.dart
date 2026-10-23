import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class HeldQuestionsRuntime extends NativeRuntime {
  HeldQuestionsRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>(), release = Completer<void>();
  final cancelled = <String>[];
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {'context_length': 4096};
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    entered.complete();
    await release.future;
    yield {'type': 'delta', 'text': 'Late accepted questions'};
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  bool cancel({String? requestId}) {
    if (requestId != null) cancelled.add(requestId);
    return true;
  }
}

void main() {
  late Directory directory;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late HeldQuestionsRuntime runtime;
  late Application app;
  late int id;
  setUp(() {
    directory = createTestTempDirectorySync('questions-owner-');
    store = Store('${directory.path}/app.db');
    helper = Helper(
      '${directory.path}/helper.sock',
      '${directory.path}/helper',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    runtime = HeldQuestionsRuntime();
    domain.generator = runtime;
    app = Application(domain);
    id = store.meeting('Questions');
    store.transcript(id, 'Alice will ship Friday.', true, 0, 1, 'microphone');
    addTearDown(() async {
      if (!runtime.release.isCompleted) runtime.release.complete();
      await app.close();
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });
  Matcher cancelled() => throwsA(
    isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
  );

  for (final existing in [false, true]) {
    test(
      'Questions reject concurrent artifact changes (existing=$existing)',
      () async {
        if (existing) {
          store.artifact(id, 'questions', 'Original questions', 'fixture');
        }
        final work = app.generateMeeting(id, 'questions');
        final rejected = expectLater(work, cancelled());
        await runtime.entered.future;
        if (existing) {
          final artifact = store.meetingArtifacts(id, 'questions').single;
          store.editArtifact(artifact['id'] as int, 'Desktop questions');
        } else {
          store.artifact(id, 'questions', 'Desktop questions', 'fixture');
        }
        runtime.release.complete();
        await rejected;
        final artifacts = store.meetingArtifacts(id, 'questions');
        expect(artifacts, hasLength(1));
        expect(
          artifacts.single['edited'] ?? artifacts.single['generated'],
          'Desktop questions',
        );
        expect(app.generationReserved, isFalse);
      },
    );
  }

  test(
    'Questions shutdown retains reservation through actual cancellation and rejects late completion',
    () async {
      final work = app.call(Operation.meetingsGenerate.wire, {
        'id': id,
        'kind': 'questions',
        'requestId': 'questions-owned',
      });
      final rejected = expectLater(work, cancelled());
      await runtime.entered.future;
      await Future<void>.delayed(Duration.zero);
      var lateChanges = 0;
      final subscription = app.changes.stream.listen((_) => lateChanges++);
      addTearDown(subscription.cancel);
      var closed = false;
      final closing = app.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(app.generationReserved, isTrue);
      expect(runtime.cancelled, contains('questions-owned'));
      runtime.release.complete();
      await rejected;
      await closing;
      expect(app.generationReserved, isFalse);
      expect(store.meetingArtifacts(id, 'questions'), isEmpty);
      expect(lateChanges, 0);
    },
  );

  test(
    'Questions from a cleared workspace cannot write to a reused meeting ID',
    () async {
      final work = app.generateMeeting(
        id,
        'questions',
        requestId: 'questions-owned',
      );
      final rejected = expectLater(work, cancelled());
      await runtime.entered.future;
      await app.call(Operation.workspaceClear.wire, const {});
      expect(store.meeting('Replacement'), id);
      store.transcript(id, 'Replacement evidence.', true, 0, 1, 'microphone');
      expect(app.generationReserved, isTrue);
      runtime.release.complete();
      await rejected;
      expect(app.generationReserved, isFalse);
      expect(store.meetingArtifacts(id, 'questions'), isEmpty);
    },
  );

  test(
    'Questions success preserves plain internal artifact semantics',
    () async {
      final work = app.generateMeeting(
        id,
        'questions',
        requestId: 'questions-owned',
      );
      await runtime.entered.future;
      runtime.release.complete();
      await work;
      final artifact = store.meetingArtifacts(id, 'questions').single;
      expect(artifact['generated'], 'Late accepted questions');
      expect(artifact['input_revision'], 1);
      expect(artifact['manifest'], isNull);
      expect(store.meetingArtifacts(id, 'summary'), isEmpty);
      expect(app.generationReserved, isFalse);
    },
  );
}
