import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_protocol.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const _build =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

final class _Sink implements DiagnosticSink {
  final records = <Map>[];
  final classifications = <DiagnosticRole>[];
  final protections = <(bool, bool)>[];
  bool closed = false, failFirstAppend = false;
  @override
  int get slot => 4;
  @override
  bool get failed => false;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) {
    classifications.add(role);
    protections.add((error, genuineFailure));
    return true;
  }

  @override
  bool append(Uint8List bytes) {
    records.add(jsonDecode(utf8.decode(bytes)) as Map);
    return !(failFirstAppend && records.length == 1);
  }

  @override
  void close() {
    closed = true;
  }
}

/// Deliberately injected protocol/ownership control, not OS/file acceptance.
/// Root's actual child dispatch validates every schema2 payload even here.
final class _Owner implements DiagnosticWorkerOwner {
  _Owner(
    this.context, {
    this.holdFirstAppend = false,
    this.holdFirstClassification = false,
  }) {
    dispatch = DiagnosticStorageWorkerState.forTesting(
      parentPid: context.applicationPid,
      buildId: _build,
      factory: (_, __, ___) => sink,
    );
  }
  final DiagnosticStorageLaunchContext context;
  final bool holdFirstAppend, holdFirstClassification;
  final classificationEntered = Completer<void>(),
      classificationRelease = Completer<void>();
  final sink = _Sink();
  late final DiagnosticStorageWorkerState dispatch;
  final entered = Completer<void>(), release = Completer<void>();
  final calls = <int>[];
  int active = 0, maximumActive = 0, forceCalls = 0;
  bool childUnknown = false, parentSettled = true, throwControls = false;
  DiagnosticWorkerFailure? failAppend;
  @override
  DiagnosticWorkerSnapshot get snapshot {
    if (throwControls) throw StateError('secret canary snapshot');
    return DiagnosticWorkerSnapshot(
      parentSettled: parentSettled,
      childNotLive: !childUnknown && sink.closed,
      buildId: _build,
      slot: sink.slot,
    );
  }

  @override
  Future<DiagnosticWorkerReply> request(DiagnosticWorkerRequest request) async {
    calls.add(request.type);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      final reply = dispatch.handle(request.type, request.payload);
      if (request.type == DiagnosticWorkerFrame.classify &&
          !classificationEntered.isCompleted) {
        classificationEntered.complete();
        if (holdFirstClassification) await classificationRelease.future;
      }
      if (request.type == DiagnosticWorkerFrame.append &&
          !entered.isCompleted) {
        entered.complete();
        if (holdFirstAppend) await release.future;
        final failure = failAppend;
        if (failure != null) throw failure;
      }
      return reply;
    } finally {
      active--;
    }
  }

  @override
  void heartbeat() {}
  @override
  void force() {
    forceCalls++;
    if (throwControls) throw StateError('secret canary force');
  }

  @override
  Future<DiagnosticWorkerCloseResult> close({
    Duration normalBudget = const Duration(milliseconds: 300),
    Duration totalBudget = const Duration(milliseconds: 500),
  }) async {
    if (throwControls) throw StateError('secret canary close');
    if (childUnknown || !parentSettled) {
      return DiagnosticWorkerCloseResult(
        ownerSettled: parentSettled,
        reason: DiagnosticHealthReason.storageWorkerUnknown,
      );
    }
    final result = dispatch.handle(DiagnosticWorkerFrame.retire, Uint8List(0));
    return DiagnosticWorkerCloseResult(
      ownerSettled: parentSettled,
      retired: result.result == DiagnosticWorkerResult.ok,
      childNotLive: true,
      reason: result.reason,
    );
  }
}

void main() {
  for (final duringAppend in [false, true]) {
    test(
      'late ownership during ${duringAppend ? 'append' : 'classification'} survives close until its decision',
      () async {
        final profile = createTestTempDirectorySync('late-classify-');
        _Owner? owner;
        final session = await LoggingSession.startForTesting(
          configuration: const DiagnosticConfiguration(),
          profilePath: profile.path,
          workerFactory: (context) => owner = _Owner(
            context,
            holdFirstClassification: !duringAppend,
            holdFirstAppend: duringAppend,
          ),
        );
        addTearDown(() async {
          if (owner != null && !owner!.classificationRelease.isCompleted) {
            owner!.classificationRelease.complete();
          }
          if (owner != null && !owner!.release.isCompleted)
            owner!.release.complete();
          await session.close();
        });
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
        );
        await eventually(() => owner != null);
        final entered = duringAppend
            ? owner!.entered
            : owner!.classificationEntered;
        final release = duringAppend
            ? owner!.release
            : owner!.classificationRelease;
        await entered.future.timeout(const Duration(seconds: 2));
        final ownership = session.expectOwnershipDecision();
        // A mailbox barrier proves expect_ownership was received during held RPC.
        await session.inspectBudgetForTesting();
        final closing = session.close();
        var closed = false;
        unawaited(closing.then((_) => closed = true));
        // close posts through its existing zero-duration encoder-unwind turn.
        // Its send must precede the classifier ACK on the same writer mailbox.
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        ownership.report(OwnershipDecision.acquired);
        expect(
          closed,
          isFalse,
          reason: 'Close discarded the pending ownership decision',
        );
        final result = await closing.timeout(const Duration(seconds: 1));
        expect(result.flushed, isTrue);
        expect(owner!.sink.records, hasLength(1));
        expect(owner!.sink.classifications.last, DiagnosticRole.service);
        expect(owner!.sink.protections.last, (true, true));
      },
    );
  }

  test(
    'ownership after emptying queue still protects already appended failure',
    () async {
      final profile = createTestTempDirectorySync('late-empty-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) => owner = _Owner(context),
      );
      addTearDown(session.close);
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => owner?.sink.records.length == 1);
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 0,
      );
      final ownership = session.expectOwnershipDecision();
      await session.inspectBudgetForTesting();
      ownership.report(OwnershipDecision.acquired);
      await eventually(
        () => owner!.sink.classifications.last == DiagnosticRole.service,
      );
      expect(owner!.sink.protections.last, (true, true));
      expect(owner!.sink.records, hasLength(1));
    },
  );

  test('worker request owns immutable bounded bytes', () {
    final bytes = Uint8List.fromList([1]);
    final request = DiagnosticWorkerRequest(
      DiagnosticWorkerFrame.append,
      bytes,
    );
    bytes[0] = 2;
    expect(request.payload, [1]);
    expect(() => request.payload[0] = 3, throwsUnsupportedError);
    expect(
      () => DiagnosticWorkerRequest(
        DiagnosticWorkerFrame.append,
        Uint8List(4097),
      ),
      throwsArgumentError,
    );
    expect(
      () => DiagnosticWorkerRequest(255, Uint8List(0)),
      throwsArgumentError,
    );
  });
  test(
    'off, transient, cold and no-profile paths never invoke the worker factory',
    () async {
      for (final mode in ['off', 'transient', 'cold', 'no-profile']) {
        var factories = 0;
        final profile = createTestTempDirectorySync('owner-lazy-');
        final session = await LoggingSession.startForTesting(
          configuration: DiagnosticConfiguration(
            level: mode == 'off' ? DiagnosticLevel.off : DiagnosticLevel.info,
          ),
          role: mode == 'transient'
              ? DiagnosticRole.transient
              : DiagnosticRole.candidate,
          profilePath: mode == 'no-profile' ? null : profile.path,
          workerFactory: (context) {
            factories++;
            return _Owner(context);
          },
        );
        session.producer.emit(
          mode == 'cold'
              ? DiagnosticEvent.serviceStarting
              : DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
        );
        final result = await session.close();
        expect(result.writerExited, isTrue);
        expect(result.ownerSettled, isTrue);
        expect(result.requiresExplicitExit, isFalse);
        expect(factories, 0, reason: mode);
        expect(Directory('${profile.path}/logs').existsSync(), isFalse);
      }
    },
  );

  test(
    'missing production worker factory is memory-only with explicit health',
    () async {
      final profile = createTestTempDirectorySync('owner-missing-');
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
      );
      addTearDown(session.close);
      expect(
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
        ),
        isTrue,
      );
      await eventually(
        () =>
            session.health.reason ==
            DiagnosticHealthReason.storageWorkerUnconfigured,
      );
      final budget = await session.inspectBudgetForTesting();
      expect(budget.queuedRecords, 0);
      expect(budget.queuedBytes, 0);
      expect(session.health.dropped, 1);
      expect(Directory('${profile.path}/logs').existsSync(), isFalse);
      final result = await session.close();
      expect(result.writerExited, isTrue);
      expect(result.ownerSettled, isTrue);
      expect(result.requiresExplicitExit, isFalse);
      expect(result.flushed, isFalse);
      expect(
        session.health.reason,
        DiagnosticHealthReason.storageWorkerUnconfigured,
      );
    },
  );

  test(
    'matching APPEND ACK removes only its prefix while new records append',
    () async {
      final profile = createTestTempDirectorySync('owner-prefix-');
      _Owner? owner;
      var factories = 0;
      final coordinatorIsolate = Isolate.current.controlPort;
      SendPort? factoryIsolate;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) {
          factoryIsolate = Isolate.current.controlPort;
          factories++;
          return owner = _Owner(context, holdFirstAppend: true);
        },
      );
      addTearDown(() async {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
        await session.close();
      });
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => factories == 1);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      expect(factoryIsolate, coordinatorIsolate);
      expect(owner!.context.applicationPid, pid);
      expect(
        owner!.sink.records,
        hasLength(1),
      ); // Dispatch committed; ACK held.
      final first = await session.inspectBudgetForTesting();
      expect(first.queuedRecords, 1);
      expect(first.queuedBytes, greaterThan(0));
      expect(
        first.reservedTrafficBytes,
        lessThanOrEqualTo(LoggingSession.maximumOutstandingBytes),
      );
      expect(
        session.producer.emit(
          DiagnosticEvent.serviceReady,
          DiagnosticComponent.service,
        ),
        isTrue,
      );
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 2,
      );
      expect(owner!.sink.records, hasLength(1));
      owner!.release.complete();
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 0,
      );
      final result = await session.close();
      expect(result.flushed, isTrue);
      expect(result.requiresExplicitExit, isFalse);
      expect(factories, 1);
      expect(owner!.maximumActive, 1);
      expect(owner!.sink.records.map((r) => r['event']), [
        'runtime.failed',
        'service.ready',
      ]);
      expect(owner!.sink.records.map((r) => r['sequence']), [1, 2]);
      for (final record in owner!.sink.records) {
        expect(record['schema'], 2);
        expect(record['pid'], pid);
        expect(record['build_id'], _build);
        expect(record['session'], session.identity.value);
        expect(record['producer'], 'entrypoint:0:1');
      }
    },
  );

  for (final disposed in [false, true]) {
    test(
      'lost APPEND reply disposed=$disposed retains unknown credit and never replays',
      () async {
        final profile = createTestTempDirectorySync('owner-unknown-');
        _Owner? owner;
        var factories = 0;
        final session = await LoggingSession.startForTesting(
          configuration: const DiagnosticConfiguration(),
          profilePath: profile.path,
          workerFactory: (context) {
            factories++;
            return owner = _Owner(context, holdFirstAppend: true);
          },
        );
        addTearDown(() async {
          if (owner != null && !owner!.release.isCompleted) {
            owner!.release.complete();
          }
          await session.close();
        });
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
        );
        await eventually(() => factories == 1);
        await owner!.entered.future.timeout(const Duration(seconds: 2));
        session.producer.emit(
          DiagnosticEvent.serviceReady,
          DiagnosticComponent.service,
        );
        await eventually(
          () async =>
              (await session.inspectBudgetForTesting()).queuedRecords == 2,
        );
        final before = await session.inspectBudgetForTesting();
        owner!.childUnknown = !disposed;
        owner!.failAppend = DiagnosticWorkerFailure(
          DiagnosticHealthReason.storageWorkerUnknown,
          disposed: disposed,
        );
        owner!.release.complete();
        await eventually(
          () =>
              session.health.reason ==
              DiagnosticHealthReason.storageWorkerUnknown,
        );
        final after = await session.inspectBudgetForTesting();
        expect(after.queuedRecords, disposed ? 0 : 2);
        expect(after.queuedBytes, disposed ? 0 : before.queuedBytes);
        expect(
          owner!.calls.where((t) => t == DiagnosticWorkerFrame.append),
          hasLength(1),
        );
        expect(owner!.sink.records, hasLength(1));
        final result = await session.close();
        expect(result.writerExited, isTrue);
        expect(result.ownerSettled, isTrue);
        expect(result.requiresExplicitExit, isFalse);
        expect(result.flushed, isFalse);
        expect(session.health.dropped, disposed ? 2 : 1);
        expect(factories, 1);
      },
    );
  }

  test(
    'close forces a held unknown reply without forcing parent exit for child-only health',
    () async {
      final profile = createTestTempDirectorySync('owner-close-');
      _Owner? owner;
      var factories = 0;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) {
          factories++;
          owner = _Owner(context, holdFirstAppend: true);
          owner!.childUnknown = true;
          return owner!;
        },
      );
      addTearDown(() {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
      });
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => factories == 1);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      final elapsed = Stopwatch()..start();
      final closing = session.close();
      expect(identical(closing, session.close()), isTrue);
      final result = await closing.timeout(const Duration(seconds: 1));
      expect(
        elapsed.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 300)),
      );
      expect(result.writerExited, isTrue);
      expect(result.ownerSettled, isTrue);
      expect(result.requiresExplicitExit, isFalse);
      expect(result.flushed, isFalse);
      expect(owner!.forceCalls, greaterThan(0));
      expect(owner!.sink.records, hasLength(1));
      owner!.release.complete();
    },
  );

  test(
    'unconfirmed parent owner is distinct from settled writer and child health',
    () async {
      final profile = createTestTempDirectorySync('owner-parent-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) {
          owner = _Owner(context);
          owner!.parentSettled = false;
          return owner!;
        },
      );
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => session.health.admitted == 1);
      final result = await session.close();
      expect(result.writerExited, isTrue);
      expect(result.ownerSettled, isFalse);
      expect(result.requiresExplicitExit, isTrue);
    },
  );

  test(
    'late ownership decision classifies the async sink before schema2 data',
    () async {
      final profile = createTestTempDirectorySync('owner-role-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) => owner = _Owner(context),
      );
      final reporter = session.expectOwnershipDecision();
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      final closing = session.close();
      reporter.report(OwnershipDecision.acquired);
      final result = await closing;
      expect(result.flushed, isTrue);
      expect(owner!.sink.classifications, [DiagnosticRole.service]);
      expect(owner!.sink.records.single['schema'], 2);
    },
  );
  test(
    'queued old generation keeps its header and charge through slot reuse',
    () async {
      final profile = createTestTempDirectorySync('owner-generation-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) =>
            owner = _Owner(context, holdFirstAppend: true),
      );
      addTearDown(() async {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
        await session.close();
      });
      final old = session.registerProducer(DiagnosticProducerKind.domain);
      await old.ready;
      expect(
        old.emit(DiagnosticEvent.runtimeFailed, DiagnosticComponent.domain),
        isTrue,
      );
      await eventually(() => owner != null);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      old.close();
      await old.retired.timeout(const Duration(seconds: 2));
      final replacement = session.registerProducer(
        DiagnosticProducerKind.domain,
      );
      await replacement.ready;
      expect(replacement.slot, old.slot);
      expect(replacement.generation, greaterThan(old.generation));
      expect(
        replacement.emit(
          DiagnosticEvent.serviceReady,
          DiagnosticComponent.domain,
        ),
        isTrue,
      );
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 2,
      );
      owner!.release.complete();
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 0,
      );
      await session.close();
      expect(owner!.sink.records.map((r) => r['producer']), [
        'domain:${old.slot}:${old.generation}',
        'domain:${replacement.slot}:${replacement.generation}',
      ]);
      expect(owner!.maximumActive, 1);
    },
  );

  test(
    'summary ACK cannot erase counters accumulated during its write',
    () async {
      final profile = createTestTempDirectorySync('owner-summary-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) =>
            owner = _Owner(context, holdFirstAppend: true),
      );
      addTearDown(() async {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
        await session.close();
      });
      for (var i = 0; i < 7; i++) {
        session.producer.noteDropped(DiagnosticDropReason.correlationCapacity);
      }
      await eventually(() => owner != null);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      expect((owner!.sink.records.single['fields'] as Map)['count'], 7);
      for (var i = 0; i < 11; i++) {
        session.producer.noteDropped(DiagnosticDropReason.correlationCapacity);
      }
      // A writer mailbox barrier proves the new counter message has arrived
      // before the old summary's ACK is allowed to resume the iterator.
      await session.inspectBudgetForTesting();
      owner!.release.complete();
      await eventually(() => owner!.sink.records.length >= 2);
      await session.close();
      expect(owner!.sink.records, hasLength(2));
      expect(owner!.sink.records.map((r) => (r['fields'] as Map)['count']), [
        7,
        11,
      ]);
      expect(
        owner!.sink.records.every((r) => r['producer'] == 'writer:0:0'),
        isTrue,
      );
      expect(owner!.maximumActive, 1);
    },
  );
  test(
    'factory failure never escapes or opens ordinary parent storage',
    () async {
      final profile = createTestTempDirectorySync('owner-factory-');
      var calls = 0;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (_) {
          calls++;
          throw StateError('secret canary factory');
        },
      );
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(
        () =>
            session.health.reason ==
            DiagnosticHealthReason.storageWorkerLaunchFailed,
      );
      final result = await session.close();
      expect(result.requiresExplicitExit, isFalse);
      expect(result.flushed, isFalse);
      expect(calls, 1);
      expect(jsonEncode(session.health.toJson()), isNot(contains('canary')));
      expect(Directory('${profile.path}/logs').existsSync(), isFalse);
    },
  );

  test(
    'throwing owner controls preserve unknown parent state without escaping',
    () async {
      final profile = createTestTempDirectorySync('owner-control-failure-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) =>
            owner = _Owner(context, holdFirstAppend: true),
      );
      addTearDown(() {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
      });
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => owner != null);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      owner!.throwControls = true;
      final result = await session.close();
      expect(result.writerExited, isTrue);
      expect(result.ownerSettled, isFalse);
      expect(result.requiresExplicitExit, isTrue);
      expect(result.flushed, isFalse);
      expect(jsonEncode(session.health.toJson()), isNot(contains('canary')));
      owner!.release.complete();
    },
  );
  test(
    'disabled APPEND ACK refunds only its failed prefix, preserving the newer suffix',
    () async {
      final profile = createTestTempDirectorySync('owner-disabled-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) {
          owner = _Owner(context, holdFirstAppend: true);
          owner!.sink.failFirstAppend = true;
          return owner!;
        },
      );
      addTearDown(() async {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
        await session.close();
      });
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => owner != null);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      session.producer.emit(
        DiagnosticEvent.serviceReady,
        DiagnosticComponent.service,
      );
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 2,
      );
      final two = await session.inspectBudgetForTesting();
      owner!.release.complete();
      await eventually(
        () => session.health.reason == DiagnosticHealthReason.sinkFailed,
      );
      final suffix = await session.inspectBudgetForTesting();
      expect(suffix.queuedRecords, 1);
      expect(suffix.queuedBytes, greaterThan(0));
      expect(suffix.queuedBytes, lessThan(two.queuedBytes));
      expect(session.health.dropped, 1);
      expect(
        owner!.calls.where((t) => t == DiagnosticWorkerFrame.append),
        hasLength(1),
      );
      final result = await session.close();
      expect(result.flushed, isFalse);
      expect(result.requiresExplicitExit, isFalse);
      expect(session.health.dropped, 2);
    },
  );
  test(
    'existing writer tick observes idle child exit without a new record',
    () async {
      final profile = createTestTempDirectorySync('owner-idle-exit-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) => owner = _Owner(context),
      );
      addTearDown(session.close);
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => owner != null);
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 0,
      );
      expect(session.health.reason, DiagnosticHealthReason.healthy);
      owner!.sink.closed =
          true; // Sole owner now authoritatively reports not-live.
      await eventually(
        () =>
            session.health.reason == DiagnosticHealthReason.storageWorkerExited,
        timeout: const Duration(seconds: 2),
      );
      expect(
        owner!.calls.where((t) => t == DiagnosticWorkerFrame.append),
        hasLength(1),
      );
      expect((await session.close()).requiresExplicitExit, isFalse);
    },
  );

  test(
    'status observation disposes an earlier unknown APPEND without replay',
    () async {
      final profile = createTestTempDirectorySync('owner-later-exit-');
      _Owner? owner;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.path,
        workerFactory: (context) =>
            owner = _Owner(context, holdFirstAppend: true),
      );
      addTearDown(() async {
        if (owner != null && !owner!.release.isCompleted) {
          owner!.release.complete();
        }
        await session.close();
      });
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(() => owner != null);
      await owner!.entered.future.timeout(const Duration(seconds: 2));
      owner!.childUnknown = true;
      owner!.failAppend = const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerUnknown,
      );
      owner!.release.complete();
      await eventually(
        () =>
            session.health.reason ==
            DiagnosticHealthReason.storageWorkerUnknown,
      );
      expect((await session.inspectBudgetForTesting()).queuedRecords, 1);
      owner!.sink.closed = true;
      owner!.childUnknown = false;
      await eventually(
        () async =>
            (await session.inspectBudgetForTesting()).queuedRecords == 0,
        timeout: const Duration(seconds: 2),
      );
      expect(
        owner!.calls.where((t) => t == DiagnosticWorkerFrame.append),
        hasLength(1),
      );
      expect(session.health.dropped, 1);
      expect((await session.close()).requiresExplicitExit, isFalse);
    },
  );
}
