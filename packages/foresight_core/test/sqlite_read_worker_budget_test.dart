import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/sqlite_read_worker.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late String path;
  late ReadIdentity identity;

  setUp(() {
    final directory = createTestTempDirectorySync('sql-budget-');
    path = '${directory.path}/application.db';
    store = Store(path);
    addTearDown(store.close);
    identity = ReadIdentity(
      owner: 'fixture',
      profile: 'fixture',
      connection: 'fixture',
      epoch: store.workspaceEpoch,
      revision: store.dataRevision,
    );
  });

  ReadWorkerRequest request(String key, [int sequence = 1]) =>
      ReadWorkerRequest(
        projection: 'preference',
        arguments: {'key': key},
        identity: identity,
        sequence: sequence,
      );

  // Only this private synthetic database supplies expensive SQL. The production
  // projection protocol still accepts a preference key, never SQL text.
  void plantLongRead() {
    store.setPreference('slow', 'fixture');
    store.db.execute('ALTER TABLE preferences RENAME TO fixture_preferences');
    store.db.execute('''
CREATE VIEW preferences AS
SELECT key, CASE WHEN key='slow' THEN (
  WITH RECURSIVE counter(x) AS (
    VALUES(0) UNION ALL SELECT x+1 FROM counter WHERE x<1000000000
  ) SELECT CAST(sum(x) AS TEXT) FROM counter
) ELSE value END AS value FROM fixture_preferences
''');
  }

  test('actual startup EOF restarts with fresh worker state', () async {
    final worker = SqliteReadWorker(path);
    addTearDown(worker.close);
    store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
    await expectLater(
      worker.read(request('workspaceEpoch')),
      throwsA(isA<IncompatibleReadSchema>()),
    );
    store.db.execute('PRAGMA user_version=${Store.schemaVersion}');
    final reply = await worker.read(request('workspaceEpoch', 2));
    expect(reply.value, identity.epoch);
    expect(reply.epoch, identity.epoch);
  });

  test(
    'bounded admission refuses excess while retained requests settle',
    () async {
      final worker = SqliteReadWorker(path, maxQueuedReads: 2);
      addTearDown(worker.close);
      final first = worker.read(request('workspaceEpoch'));
      final second = worker.read(request('workspaceEpoch', 2));
      await expectLater(
        worker.read(request('workspaceEpoch', 3)),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      expect((await first).value, identity.epoch);
      expect((await second).value, identity.epoch);
      expect(
        (await worker.read(request('workspaceEpoch', 4))).value,
        identity.epoch,
      );
    },
  );

  test(
    'typed refusal announces capacity only on actual release and close',
    () async {
      plantLongRead();
      final worker = SqliteReadWorker(
        path,
        executionBudget: const Duration(milliseconds: 150),
        maxQueuedReads: 2,
      );
      addTearDown(worker.close);
      await worker.read(request('workspaceEpoch'));
      var notified = 0;
      Future<void> settle() => Future<void>.delayed(Duration.zero);
      final running = expectLater(
        worker.read(request('slow', 2)),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', RpcErrorCode.busy)
              .having((e) => e is ReadAdmissionRejected, 'admission', false),
        ),
      );
      final queuedRequest = request('workspaceEpoch', 3);
      final queued = expectLater(
        worker.read(queuedRequest),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(worker.admitsRead, isFalse);
      await expectLater(
        worker.read(request('workspaceEpoch', 4)),
        throwsA(
          isA<ReadAdmissionRejected>()
              .having((e) => e.code, 'code', RpcErrorCode.busy)
              .having((e) => e.message, 'message', 'Read queue is full'),
        ),
      );
      worker.whenAdmissionAvailable(() => notified++);
      await settle();
      expect(notified, 0);
      // Withdrawing the undispatched reservation is an actual release.
      expect(worker.cancelQueued(queuedRequest), isTrue);
      await queued;
      await settle();
      expect(notified, 1);
      expect(worker.admitsRead, isTrue);
      final next = worker.read(request('workspaceEpoch', 5));
      expect(worker.admitsRead, isFalse);
      worker.whenAdmissionAvailable(() => notified++);
      final withdrawn = worker.whenAdmissionAvailable(() => notified += 100);
      withdrawn();
      await settle();
      expect(notified, 1);
      // Interrupted SQL settles the running reservation; that release notifies.
      await running;
      expect(notified, 2);
      expect((await next).value, identity.epoch);
      worker.whenAdmissionAvailable(() => notified++);
      await settle();
      expect(notified, 3, reason: 'available capacity is announced promptly');
      final held = expectLater(
        worker.read(request('slow', 6)),
        throwsA(isA<RpcError>()),
      );
      final queuedAgain = expectLater(
        worker.read(request('workspaceEpoch', 7)),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(worker.admitsRead, isFalse);
      worker.whenAdmissionAvailable(() => notified++);
      final closing = worker.close();
      await settle();
      expect(notified, 4);
      expect(worker.admitsRead, isTrue);
      await expectLater(
        worker.read(request('workspaceEpoch', 8)),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', RpcErrorCode.cancelled)
              .having((e) => e is ReadAdmissionRejected, 'admission', false),
        ),
      );
      await Future.wait([held, queuedAgain, closing]);
    },
  );

  test('generation exit announces capacity held by a failed startup', () async {
    store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
    final worker = SqliteReadWorker(path, maxQueuedReads: 1);
    addTearDown(worker.close);
    final failed = expectLater(
      worker.read(request('workspaceEpoch')),
      throwsA(isA<IncompatibleReadSchema>()),
    );
    expect(worker.admitsRead, isFalse);
    final announced = Completer<void>();
    worker.whenAdmissionAvailable(announced.complete);
    await failed;
    await announced.future;
    expect(worker.admitsRead, isTrue);
  });

  test(
    'coordinator retains watches beyond real capacity until held SQL settles',
    () async {
      for (var i = 0; i < 6; i++) {
        store.setPreference('fixture.$i', 'value-$i');
      }
      plantLongRead();
      final worker = SqliteReadWorker(
        path,
        executionBudget: const Duration(milliseconds: 150),
        maxQueuedReads: 2,
      );
      final reader = ReadCoordinator(identity: () => identity, worker: worker);
      addTearDown(reader.close);
      ReadQuery<String> preference(String key) => ReadQuery(
        projection: 'preference',
        arguments: {'key': key},
        decode: (value) => value as String,
      );
      final slow = Completer<ReadResult<String>>();
      final slowWatch = reader.watch(preference('slow')).listen((event) {
        if (!slow.isCompleted) slow.complete(event);
      });
      addTearDown(slowWatch.cancel);
      final values = <String, List<ReadResult<String>>>{};
      final outcomes = <Future<ReadResult<String>>>[];
      for (var i = 0; i < 6; i++) {
        final outcome = Completer<ReadResult<String>>();
        outcomes.add(outcome.future);
        final events = values['fixture.$i'] = [];
        final subscription = reader.watch(preference('fixture.$i')).listen((
          event,
        ) {
          events.add(event);
          if (!outcome.isCompleted) outcome.complete(event);
        });
        addTearDown(subscription.cancel);
      }
      while (!reader.busy) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(reader.awaitingAdmission, 5);
      expect(worker.admitsRead, isFalse);
      // The held statement's own budget is a SQL busy failure, published as
      // such; it is never mistaken for an admission refusal.
      final interrupted = await slow.future;
      expect(interrupted.freshness, ReadFreshness.failed);
      expect(interrupted.error!.code, RpcErrorCode.busy);
      expect(interrupted.error, isNot(isA<ReadAdmissionRejected>()));
      for (final result in await Future.wait(outcomes)) {
        expect(result.current, isTrue);
      }
      for (var i = 0; i < 6; i++) {
        expect(values['fixture.$i']!.single.value, 'value-$i');
      }
      expect(reader.awaitingAdmission, 0);
    },
  );

  test('real long projection settles before next job and close', () async {
    plantLongRead();
    final worker = SqliteReadWorker(
      path,
      executionBudget: const Duration(milliseconds: 100),
    );
    addTearDown(worker.close);
    await worker.read(request('workspaceEpoch'));
    final slow = worker.read(request('slow', 2));
    final slowFailure = expectLater(
      slow,
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy)),
    );
    final next = worker.read(request('workspaceEpoch', 3));
    await slowFailure;
    expect((await next).value, identity.epoch);
    final again = worker.read(request('slow', 4));
    final againFailure = expectLater(
      again,
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy)),
    );
    await worker.close();
    await againFailure;
    await expectLater(
      worker.read(request('workspaceEpoch', 5)),
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
    );
  });

  test(
    'subscriber cancellation keeps actual SQL tracked until deadline settlement',
    () async {
      plantLongRead();
      final worker = SqliteReadWorker(
        path,
        executionBudget: const Duration(milliseconds: 150),
      );
      await worker.read(request('workspaceEpoch'));
      final reader = ReadCoordinator(identity: () => identity, worker: worker);
      addTearDown(reader.close);
      final subscription = reader
          .watch<String>(
            ReadQuery(
              projection: 'preference',
              arguments: {'key': 'slow'},
              decode: (value) => value as String,
            ),
          )
          .listen((_) {});
      // Dispatch uses the coordinator's microtask; observing busy is the causal
      // marker rather than relying on the expensive statement's elapsed time.
      while (!reader.busy) {
        await Future<void>.delayed(Duration.zero);
      }
      await subscription.cancel();
      expect(reader.activeReads, 1);
      await reader.close();
      expect(reader.activeReads, 0);
    },
  );

  test(
    'close during startup cancels queued requests and joins actual EOF',
    () async {
      final worker = SqliteReadWorker(path);
      final first = expectLater(
        worker.read(request('workspaceEpoch')),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      final second = expectLater(
        worker.read(request('workspaceEpoch', 2)),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await worker.close();
      await Future.wait([first, second]);
      await worker.close();
    },
  );

  test(
    'unsendable arguments release only the undispatched reservation',
    () async {
      final worker = SqliteReadWorker(path);
      addTearDown(worker.close);
      await worker.read(request('workspaceEpoch'));
      final unsendable = ReceivePort();
      addTearDown(unsendable.close);
      await expectLater(
        worker.read(
          ReadWorkerRequest(
            projection: 'preference',
            arguments: {'key': 'workspaceEpoch', 'unsendable': unsendable},
            identity: identity,
            sequence: 2,
          ),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            RpcErrorCode.invalidArgument,
          ),
        ),
      );
      expect(
        (await worker.read(request('workspaceEpoch', 3))).value,
        identity.epoch,
      );
    },
  );

  test(
    'unsendable dispatch releases its slot and notifies a waiting read',
    () async {
      // One slot, held by an unsendable request queued before the fresh
      // generation attaches; its refusal to send is the only release here.
      final worker = SqliteReadWorker(path, maxQueuedReads: 1);
      final unsendable = ReceivePort();
      addTearDown(unsendable.close);
      final refused = expectLater(
        worker.read(
          ReadWorkerRequest(
            projection: 'preference',
            arguments: {'key': 'workspaceEpoch', 'unsendable': unsendable},
            identity: identity,
            sequence: 1,
          ),
        ),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', RpcErrorCode.invalidArgument)
              .having((e) => e is ReadAdmissionRejected, 'admission', false),
        ),
      );
      expect(worker.admitsRead, isFalse);
      // A stranded waiter would surface as this deadline's busy result.
      final reader = ReadCoordinator(
        identity: () => identity,
        worker: worker,
        deadline: const Duration(seconds: 5),
      );
      addTearDown(reader.close);
      final first = reader
          .watch<String>(
            ReadQuery(
              projection: 'preference',
              arguments: {'key': 'workspaceEpoch'},
              decode: (value) => value as String,
            ),
          )
          .first;
      // Microtasks only: attach and the refused send need port messages.
      await Future<void>.microtask(() {});
      expect(reader.awaitingAdmission, 1);
      await refused;
      final result = await first;
      expect(result.current, isTrue);
      expect(result.value, identity.epoch);
      expect(reader.awaitingAdmission, 0);
    },
  );

  test('owner isolate loss retires its SQL worker after settlement', () async {
    plantLongRead();
    final child = await Process.start(Platform.resolvedExecutable, [
      'test/fixtures/sqlite_reader_owner_exit.dart',
      path,
    ]);
    final stdout = child.stdout.transform(utf8.decoder).join();
    final stderr = child.stderr.transform(utf8.decoder).join();
    int? status;
    try {
      status = await child.exitCode.timeout(const Duration(seconds: 10));
    } finally {
      if (status == null) {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
      final output = await stdout;
      final errors = await stderr;
      expect(status, 0, reason: '$output\n$errors');
      expect(output, contains('owner dispatched and exited'));
      expect(errors, isEmpty);
    }
  });

  test(
    'queue cancellation removes only exact undispatched request identity',
    () async {
      plantLongRead();
      final worker = SqliteReadWorker(
        path,
        executionBudget: const Duration(milliseconds: 100),
      );
      addTearDown(worker.close);
      await worker.read(request('workspaceEpoch'));
      final runningRequest = request('slow', 2);
      final running = expectLater(
        worker.read(runningRequest),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      final queuedRequest = request('workspaceEpoch', 3);
      final queued = expectLater(
        worker.read(queuedRequest),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(worker.cancelQueued(request('workspaceEpoch', 3)), isFalse);
      expect(worker.cancelQueued(runningRequest), isFalse);
      expect(worker.cancelQueued(queuedRequest), isTrue);
      expect(worker.cancelQueued(queuedRequest), isFalse);
      await queued;
      await running;
      expect(
        (await worker.read(request('workspaceEpoch', 4))).value,
        identity.epoch,
      );
    },
  );

  test(
    'subscriber cancellation withdraws queued work before running SQL settles',
    () async {
      plantLongRead();
      final worker = SqliteReadWorker(
        path,
        executionBudget: const Duration(milliseconds: 150),
      );
      await worker.read(request('workspaceEpoch'));
      final running = expectLater(
        worker.read(request('slow', 2)),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      final reader = ReadCoordinator(identity: () => identity, worker: worker);
      addTearDown(reader.close);
      final subscription = reader
          .watch<String>(
            ReadQuery(
              projection: 'preference',
              arguments: {'key': 'workspaceEpoch'},
              decode: (value) => value as String,
            ),
          )
          .listen((_) {});
      while (!reader.busy) {
        await Future<void>.delayed(Duration.zero);
      }
      await subscription.cancel();
      if (reader.busy) {
        await reader.activityChanges.firstWhere((_) => !reader.busy);
      }
      // The coordinator's queued reservation has settled; the separate first
      // job still owns its actual future until SQLite interrupts normally.
      expect(reader.activeReads, 0);
      await running;
      await reader.close();
    },
  );

  test(
    'native deadline settles actual SQL after immediate main VM return',
    () async {
      plantLongRead();
      final child = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/sqlite_reader_owner_exit.dart',
        path,
        'immediate-main-return',
      ]);
      final stdout = child.stdout.transform(utf8.decoder).join();
      final stderr = child.stderr.transform(utf8.decoder).join();
      int? status;
      try {
        status = await child.exitCode.timeout(const Duration(seconds: 10));
      } finally {
        if (status == null) {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
        }
        final output = await stdout;
        final errors = await stderr;
        expect(status, 0, reason: '$output\n$errors');
        expect(output, contains('owner dispatched and exited'));
        expect(errors, isEmpty);
      }
    },
  );

  test(
    'subscriber deadline retains SQL reservation and next job remains independent',
    () async {
      plantLongRead();
      final worker = SqliteReadWorker(
        path,
        executionBudget: const Duration(milliseconds: 150),
      );
      await worker.read(request('workspaceEpoch'));
      final reader = ReadCoordinator(
        identity: () => identity,
        worker: worker,
        deadline: const Duration(milliseconds: 1),
      );
      addTearDown(reader.close);
      final expired = Completer<void>();
      final subscription = reader
          .watch<String>(
            ReadQuery(
              projection: 'preference',
              arguments: {'key': 'slow'},
              decode: (value) => value as String,
            ),
          )
          .listen((event) {
            if (event.freshness == ReadFreshness.busy && !expired.isCompleted) {
              expired.complete();
            }
          });
      await expired.future;
      expect(reader.activeReads, 1);
      await subscription.cancel();
      if (reader.busy) {
        await reader.activityChanges.firstWhere((_) => !reader.busy);
      }
      expect(reader.activeReads, 0);
      expect(
        (await worker.read(request('workspaceEpoch', 2))).value,
        identity.epoch,
      );
      await reader.close();
    },
  );
}
