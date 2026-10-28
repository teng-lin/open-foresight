import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/application_services/audio_application_port.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

class AudioOwner implements AudioApplicationLifecycle {
  final entered = Completer<void>();
  Completer<void>? modelExit, clearExit, closedExit;
  bool rejectModel = false;
  @override
  bool busy = false;
  int suspends = 0, resumes = 0, clears = 0, closes = 0;
  Object? disconnected;
  @override
  Future<void> suspendForModelChange() async {
    suspends++;
    if (!entered.isCompleted) entered.complete();
    await modelExit?.future;
    if (rejectModel) throw StateError('Unconfirmed model reader');
  }

  @override
  Future<void> resumeAfterModelChange() async {
    resumes++;
  }

  @override
  Future<void> clearWorkspace(Future<void> Function() clear) async {
    clears++;
    if (!entered.isCompleted) entered.complete();
    await clearExit?.future;
    await clear();
  }

  @override
  void invalidateCaller(Object caller) {
    disconnected = caller;
  }

  @override
  Future<void> close() async {
    closes++;
    await closedExit?.future;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Application app;
  late Store store;
  late AudioOwner owner;
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('app-audio-barrier-');
    store = Store('${root.path}/application.db');
    addTearDown(store.close);
    final helper = Helper(
      '${root.path}/unused.sock',
      root.path,
      manageProcess: false,
    );
    addTearDown(helper.close);
    final domain = Domain(store, helper);
    addTearDown(domain.close);
    owner = AudioOwner();
    app = Application(domain, audioLifecycle: owner);
    addTearDown(() async {
      for (final gate in [owner.modelExit, owner.clearExit, owner.closedExit]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
      await app.close();
    });
  });
  File model() =>
      File('${root.path}/speech.model')
        ..writeAsStringSync('synthetic registration');
  test(
    'model reservation encloses actual audio model-reader retirement and resume',
    () async {
      final gate = owner.modelExit = Completer<void>(), file = model();
      final configuring = app.call('models.register', {
        'kind': 'speech',
        'path': file.path,
      });
      await owner.entered.future;
      expect(app.modelBusy, isTrue);
      expect(store.model('speech'), isNull);
      await expectLater(
        app.call('models.register', {'kind': 'speech', 'path': file.path}),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      expect(owner.suspends, 1);
      gate.complete();
      await configuring;
      expect(store.model('speech'), isNotNull);
      expect(owner.resumes, 1);
      expect(app.modelBusy, isFalse);
    },
  );
  test(
    'failed model mutation still resumes work and settles reservation',
    () async {
      await expectLater(
        app.call('models.register', {
          'kind': 'speech',
          'path': '${root.path}/missing',
        }),
        throwsA(anything),
      );
      expect(owner.suspends, 1);
      expect(owner.resumes, 1);
      expect(app.modelBusy, isFalse);
    },
  );
  test(
    'unconfirmed audio suspension prevents mutation and cannot reopen admission',
    () async {
      owner.rejectModel = true;
      await expectLater(
        app.call('models.register', {'kind': 'speech', 'path': model().path}),
        throwsStateError,
      );
      expect(store.model('speech'), isNull);
      expect(owner.resumes, 0);
      expect(app.modelBusy, isFalse);
    },
  );
  test(
    'caller cancellation after model retirement resumes without dispatching',
    () async {
      var current = true;
      final gate = owner.modelExit = Completer<void>();
      final configuring = app.call('models.register', {
        'kind': 'speech',
        'path': model().path,
      }, current: () => current);
      configuring.ignore();
      await owner.entered.future;
      current = false;
      gate.complete();
      await expectLater(configuring, throwsA(isA<RpcError>()));
      expect(store.model('speech'), isNull);
      expect(owner.resumes, 1);
      expect(app.modelBusy, isFalse);
    },
  );
  test(
    'workspace admission closes before asynchronous audio fence and SQL erasure',
    () async {
      store.meeting('Keep until physical fence');
      final gate = owner.clearExit = Completer<void>(),
          epoch = store.workspaceEpoch;
      final clearing = app.call('workspace.clear', {});
      await owner.entered.future;
      expect(store.db.select('SELECT id FROM meetings'), isNotEmpty);
      expect(store.workspaceEpoch, epoch);
      await expectLater(
        app.call('meetings.list', {}),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      gate.complete();
      await clearing;
      expect(store.db.select('SELECT id FROM meetings'), isEmpty);
      expect(store.workspaceEpoch, isNot(epoch));
      expect(owner.clears, 1);
    },
  );
  test(
    'background ownership and caller disconnect reach the actual audio owner',
    () {
      owner.busy = true;
      expect(app.backgroundBusy, isTrue);
      final socketIdentity = Object();
      app.audioCallerDisconnected(socketIdentity);
      expect(identical(owner.disconnected, socketIdentity), isTrue);
    },
  );
  test('application shutdown waits audio owner closure', () async {
    final gate = owner.closedExit = Completer<void>();
    var settled = false;
    final closing = app.close().then((_) => settled = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(owner.closes, 1);
    expect(settled, isFalse);
    gate.complete();
    await closing;
    expect(settled, isTrue);
  });
}
