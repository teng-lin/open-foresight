import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/application_services/answer_coordinator.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class IdleRuntime extends NativeRuntime {
  IdleRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  @override
  bool get generating => false;
  @override
  bool cancel({String? requestId}) => true;
}

class HeldRetrieval extends AnswerGateway {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Stream<String> ask(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
    bool useWeb = false,
  }) async* {
    entered.complete();
    await release.future;
    if (!(current?.call() ?? true)) {
      throw RpcError(RpcErrorCode.cancelled, 'cancelled');
    }
    yield 'late answer';
  }
}

void main() {
  late Directory directory;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late IdleRuntime runtime;
  late HeldRetrieval answers;
  late Application app;
  late int id;
  setUp(() {
    directory = createTestTempDirectorySync('automatic-shutdown-');
    store = Store('${directory.path}/app.db');
    helper = Helper(
      '${directory.path}/helper.sock',
      '${directory.path}/helper',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    runtime = IdleRuntime();
    domain.generator = runtime;
    answers = HeldRetrieval();
    app = Application(domain, answers: answers);
    id = store.meeting('Automatic');
    store.db.execute(
      'INSERT INTO meeting_questions(meeting_id,question,normalized,created) VALUES(?,?,?,?)',
      [id, 'Question?', 'question', 1],
    );
    addTearDown(() async {
      if (!answers.release.isCompleted) answers.release.complete();
      await app.close();
      await Future<void>.delayed(Duration.zero);
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });
  test(
    'Application shutdown joins actual automatic retrieval after logical queue cancellation',
    () async {
      app.proactive.notify(id);
      final work = app.proactive.process();
      await answers.entered.future;
      expect(app.proactiveWork, 1);
      await Future<void>.delayed(Duration.zero);
      var lateChanges = 0;
      final subscription = app.changes.stream.listen((_) => lateChanges++);
      addTearDown(subscription.cancel);
      var closed = false;
      final closing = app.close().then((_) => closed = true);
      await work;
      await Future<void>.delayed(Duration.zero);
      expect(app.proactive.running, isFalse);
      expect(app.proactiveWork, 1);
      expect(closed, isFalse);
      answers.release.complete();
      await closing;
      expect(app.proactiveWork, 0);
      expect(lateChanges, 0);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
    },
  );
  test(
    'Foreground yield stays fast while cancelled automatic retrieval drains',
    () async {
      app.proactive.notify(id);
      final work = app.proactive.process();
      await answers.entered.future;
      await app.proactive.yieldToForeground();
      await work;
      expect(answers.release.isCompleted, isFalse);
      expect(app.proactive.running, isFalse);
      expect(app.proactiveWork, 1);
      expect(store.meetingQuestions(id).single['state'], 'queued');
      answers.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(app.proactiveWork, 0);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
    },
  );
}
