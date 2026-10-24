import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:test/test.dart';

import 'test_sinks.dart';

void main() {
  tearDown(LoggingSession.resetForTesting);
  test(
    'classify contention at close is unavailable rather than sink failure',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        role: DiagnosticRole.desktop,
        sinkFactory: contendedSink(capture.port.sendPort),
      );
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      final result = await session.close();
      expect(result.writerExited, isTrue);
      expect(result.flushed, isFalse);
      expect(session.health.reason, DiagnosticHealthReason.storageUnavailable);
      await capture.closed.future;
      expect(capture.records, isEmpty);
    },
  );
  test('healthy drop summaries do not mark genuine retained error', () async {
    final capture = SinkCapture();
    addTearDown(capture.dispose);
    final session = await LoggingSession.startForTesting(
      configuration: const DiagnosticConfiguration(),
      profilePath: 'selected-private-profile',
      role: DiagnosticRole.desktop,
      sinkFactory: memorySink(capture.port.sendPort),
    );
    for (var i = 0; i < 100; i++) {
      session.producer.emit(
        DiagnosticEvent.serviceStarting,
        DiagnosticComponent.service,
      );
    }
    session.producer.close();
    await session.close();
    await capture.closed.future;
    expect(
      capture.records.any(
        (record) => record['event'] == DiagnosticEvent.recordsDropped.wire,
      ),
      isTrue,
    );
    final classifications = capture.messages.whereType<Map>().where(
      (value) => value.containsKey('classified'),
    );
    expect(classifications, isNotEmpty);
    expect(
      classifications.every(
        (value) => value['error'] == false && value['failure'] == false,
      ),
      isTrue,
    );
  });
  test(
    'active tracks registration and retirement without saturation',
    () async {
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
      );
      final producer = session.registerProducer(DiagnosticProducerKind.domain);
      expect(producer.active, isFalse);
      await producer.ready;
      expect(producer.active, isTrue);
      while (producer.emit(
        DiagnosticEvent.serviceStarting,
        DiagnosticComponent.service,
      )) {}
      expect(producer.active, isTrue);
      producer.close();
      expect(producer.active, isFalse);
      for (var i = 0; i < 20; i++) {
        final extra = session.registerProducer(DiagnosticProducerKind.domain);
        await extra.ready;
        if (i >= 14) expect(extra.active, isFalse);
      }
      await session.close();
      expect(session.producer.active, isFalse);
      final off = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.off,
        ),
      );
      expect(off.producer.active, isFalse);
      await off.close();
    },
  );
  test(
    'lazy stack obeys filtering credits retirement and reentrancy',
    () async {
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
      );
      var built = 0;
      SafeDiagnosticStack build() {
        built++;
        throw StateError('synthetic private stack failure');
      }

      expect(
        session.producer.emit(
          DiagnosticEvent.transportActivity,
          DiagnosticComponent.service,
          stackBuilder: build,
        ),
        isFalse,
      );
      expect(built, 0);
      expect(
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
          stackBuilder: build,
        ),
        isFalse,
      );
      expect(built, 1);
      var recursiveFields = 0;
      expect(
        session.producer.emit(
          DiagnosticEvent.serviceStarting,
          DiagnosticComponent.service,
          fields: () {
            expect(
              session.producer.emit(
                DiagnosticEvent.runtimeFailed,
                DiagnosticComponent.service,
                fields: () {
                  recursiveFields++;
                  return {};
                },
                stackBuilder: build,
              ),
              isFalse,
            );
            return {};
          },
        ),
        isTrue,
      );
      expect(recursiveFields, 0);
      expect(built, 1);
      while (session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      )) {}
      expect(
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
          stackBuilder: build,
        ),
        isFalse,
      );
      expect(built, 1);
      await session.close();
      expect(
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
          stackBuilder: build,
        ),
        isFalse,
      );
      expect(built, 1);
    },
  );
  test('off creates no writer endpoint and never evaluates fields', () async {
    final session = await LoggingSession.start(
      configuration: const DiagnosticConfiguration(level: DiagnosticLevel.off),
    );
    var called = false;
    expect(
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
        fields: () {
          called = true;
          throw StateError('never');
        },
      ),
      isFalse,
    );
    expect(called, isFalse);
    expect(session.health.reason, DiagnosticHealthReason.off);
    expect((await session.close()).writerExited, isTrue);
  });
  test(
    'writer assigns safe correlated JSONL header and same-session retry',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        role: DiagnosticRole.desktop,
        sinkFactory: memorySink(capture.port.sendPort),
      );
      session.producer.emit(
        DiagnosticEvent.rpcFailed,
        DiagnosticComponent.desktop,
        fields: () => {
          DiagnosticField.operation: DiagnosticOperation.parse('status')!,
          DiagnosticField.durationUs: 17,
          DiagnosticField.outcome: DiagnosticOutcome.failed,
        },
        request: 3,
        connection: DiagnosticIdentity.random(),
      );
      final result = await session.close();
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(result.writerExited, isTrue);
      expect(result.flushed, isTrue);
      final record = capture.records.single;
      expect(record['schema'], 1);
      expect(record['sequence'], 1);
      expect(record['session'], session.identity.value);
      expect(record['request'], 3);
      expect(record['event'], 'rpc.failed');
      expect(record['producer'], 'entrypoint:0');
      expect(record['fields'], {
        'operation': 'status',
        'durationUs': 17,
        'outcome': 'failed',
      });
    },
  );
  test(
    'production process registry returns one session across Retry',
    () async {
      final first = await LoggingSession.start(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.off,
        ),
      );
      final second = await LoggingSession.start(
        configuration: const DiagnosticConfiguration(),
      );
      expect(identical(first, second), isTrue);
      expect(first.identity.value, second.identity.value);
    },
  );
  test(
    'producer flood is bounded before send and warn capacity remains reserved',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final producers = [
        session.producer,
        for (var i = 1; i < 16; i++)
          session.registerProducer(DiagnosticProducerKind.domain),
      ];
      await Future.wait(producers.map((producer) => producer.ready));
      var admitted = 0, priority = 0;
      for (final producer in producers) {
        for (var i = 0; i < 10000; i++) {
          if (producer.emit(
            DiagnosticEvent.serviceStarting,
            DiagnosticComponent.service,
          )) {
            admitted++;
          }
        }
        var constructed = false;
        expect(
          producer.emit(
            DiagnosticEvent.serviceStarting,
            DiagnosticComponent.service,
            fields: () {
              constructed = true;
              return {};
            },
          ),
          isFalse,
        );
        expect(constructed, isFalse);
        if (producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
          fields: () => {DiagnosticField.category: DiagnosticCategory.internal},
        )) {
          priority++;
        }
      }
      final extra = session.registerProducer(DiagnosticProducerKind.setup);
      expect(
        extra.emit(DiagnosticEvent.runtimeFailed, DiagnosticComponent.tool),
        isFalse,
      );
      expect(admitted, lessThanOrEqualTo(176));
      expect(priority, 16);
      final result = await session.close();
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(result.writerExited, isTrue);
      expect(session.health.highWaterBytes, lessThanOrEqualTo(256 * 1024));
      expect(session.health.highWaterRecords, lessThanOrEqualTo(256));
      expect(session.health.dropped, greaterThan(150000));
      expect(
        capture.records.where((record) => record['level'] == 'error'),
        hasLength(8),
      );
      final summaries = capture.records.where(
        (record) => record['event'] == 'logging.records_dropped',
      );
      expect(summaries, isNotEmpty);
      expect(
        summaries.every((record) => record['producer'] == 'writer:0'),
        isTrue,
      );
      expect(
        summaries.every(
          (record) =>
              (record['fields'] as Map)['count'] is int &&
              (record['fields'] as Map)['firstMs'] is int &&
              (record['fields'] as Map)['lastMs'] is int,
        ),
        isTrue,
      );
    },
  );
  test(
    'session decision survives close before ownership delivery and producer completion',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final reporter = session.expectOwnershipDecision();
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
        fields: () => {DiagnosticField.category: DiagnosticCategory.internal},
      );
      final closing = session.close();
      reporter.report(OwnershipDecision.acquired);
      expect((await closing).writerExited, isTrue);
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(
        capture.messages.whereType<Map>().any(
          (value) =>
              value['classified'] == 'service' && value['failure'] == true,
        ),
        isTrue,
      );
      expect(capture.records, hasLength(1));
    },
  );
  test(
    'terminal unknown fallback never protects a service candidate',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      session.expectOwnershipDecision();
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      session.ownershipWorkerTerminated();
      expect((await session.close()).writerExited, isTrue);
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(
        capture.messages.whereType<Map>().any(
          (value) => value['classified'] == 'service',
        ),
        isFalse,
      );
    },
  );
  test(
    'worker termination fallback survives session close already in progress',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      session.expectOwnershipDecision();
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      final closing = session.close();
      session.ownershipWorkerTerminated();
      final result = await closing;
      expect(result.writerExited, isTrue);
      expect(result.flushed, isTrue);
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(
        capture.messages.whereType<Map>().any(
          (message) => message['classified'] == 'service',
        ),
        isFalse,
      );
    },
  );
  test(
    'throwing sink never escapes and health retains a closed reason only',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: brokenSink(capture.port.sendPort),
      );
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      final result = await session.close();
      expect(result.writerExited, isTrue);
      expect(result.flushed, isFalse);
      expect(jsonEncode(session.health.toJson()).contains('canary'), isFalse);
      expect(session.health.dropped, 1);
      expect(session.health.reason, DiagnosticHealthReason.sinkFailed);
    },
  );
  test(
    'a worker receives a producer and can exit naturally without logger authority',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final done = ReceivePort();
      addTearDown(done.close);
      final exited = ReceivePort();
      addTearDown(exited.close);
      final bootstrap = session.reserveProducer(DiagnosticProducerKind.domain);
      await Isolate.spawn(_worker, [
        bootstrap,
        done.sendPort,
      ], onExit: exited.sendPort);
      expect(
        await done.first.timeout(const Duration(seconds: 2)),
        'worker_done',
      );
      await exited.first.timeout(const Duration(seconds: 2));
      session.producerExited(bootstrap);
      expect((await session.close()).writerExited, isTrue);
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(capture.records.single['producer'], 'domain:1');
    },
  );
  test('an exited ticket cannot attach after its completion barrier', () async {
    final session = await LoggingSession.startForTesting(
      configuration: const DiagnosticConfiguration(),
      role: DiagnosticRole.transient,
    );
    addTearDown(session.close);
    final exited = session.reserveProducer(DiagnosticProducerKind.domain);
    session.producerExited(exited);
    final barrier = session
        .reserveProducer(DiagnosticProducerKind.setup)
        .connect();
    addTearDown(barrier.close);
    await barrier.ready;
    final late = exited.connect();
    addTearDown(late.close);
    await late.ready;
    expect(
      late.emit(DiagnosticEvent.runtimeFailed, DiagnosticComponent.domain),
      isFalse,
    );
  });
  test(
    'overflow off and closed registration retain bounded producer handles',
    () async {
      for (final level in [DiagnosticLevel.info, DiagnosticLevel.off]) {
        final session = await LoggingSession.startForTesting(
          configuration: DiagnosticConfiguration(level: level),
          role: DiagnosticRole.transient,
        );
        addTearDown(session.close);
        for (var i = 0; i < 1000; i++) {
          session.registerProducer(DiagnosticProducerKind.setup);
        }
        expect(
          session.retainedProducerCount,
          lessThanOrEqualTo(LoggingSession.maximumProducers),
        );
        await session.close();
        for (var i = 0; i < 1000; i++) {
          session.registerProducer(DiagnosticProducerKind.setup);
        }
        expect(
          session.retainedProducerCount,
          lessThanOrEqualTo(LoggingSession.maximumProducers),
        );
      }
    },
  );
  test('all registered rate keys retain later new failure evidence', () async {
    final capture = SinkCapture();
    addTearDown(capture.dispose);
    final session = await LoggingSession.startForTesting(
      configuration: const DiagnosticConfiguration(
        level: DiagnosticLevel.trace,
      ),
      profilePath: 'selected-private-profile',
      sinkFactory: memorySink(capture.port.sendPort),
    );
    addTearDown(session.close);
    final elapsed = Stopwatch()..start();
    Future<void> send(
      DiagnosticEvent event,
      DiagnosticCategory category,
    ) async {
      while (!session.producer.emit(
        event,
        DiagnosticComponent.service,
        fields: () => {DiagnosticField.category: category},
      )) {
        if (elapsed.elapsed > const Duration(seconds: 10)) {
          fail('producer did not regain bounded credits');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(Duration.zero);
    }

    for (final event in DiagnosticEvent.values) {
      if (!event.fields.contains(DiagnosticField.category)) continue;
      for (final category in DiagnosticCategory.values) {
        if (event == DiagnosticEvent.nativeWorkerFailed &&
            category == DiagnosticCategory.process) {
          continue;
        }
        await send(event, category);
      }
    }
    await send(DiagnosticEvent.nativeWorkerFailed, DiagnosticCategory.process);
    await session.close();
    await capture.closed.future.timeout(const Duration(seconds: 2));
    expect(
      capture.records.any(
        (record) =>
            (record['event'] == DiagnosticEvent.nativeWorkerFailed.wire &&
                (record['fields'] as Map)['category'] ==
                    DiagnosticCategory.process.name) ||
            (record['event'] == DiagnosticEvent.recordsDropped.wire &&
                (record['fields'] as Map)['event'] ==
                    DiagnosticEvent.nativeWorkerFailed.wire &&
                (record['fields'] as Map)['category'] ==
                    DiagnosticCategory.process.name),
      ),
      isTrue,
    );
  });
  test(
    'healthy close finalizes missing ownership as unprotected unknown',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      session.expectOwnershipDecision();
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      final result = await session.close();
      expect(result.writerExited, isTrue);
      expect(result.flushed, isTrue);
      await capture.closed.future.timeout(const Duration(seconds: 2));
      expect(capture.records, hasLength(1));
      expect(
        capture.messages.whereType<Map>().any(
          (value) => value['classified'] == 'service',
        ),
        isFalse,
      );
    },
  );
}

void _worker(List<Object> arguments) async {
  final producer = (arguments[0] as DiagnosticProducerBootstrap).connect();
  await producer.ready;
  producer.emit(DiagnosticEvent.runtimeFailed, DiagnosticComponent.domain);
  (arguments[1] as SendPort).send('worker_done');
}
