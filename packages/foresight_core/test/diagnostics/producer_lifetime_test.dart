import '../sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/sqlite_read_worker.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

import 'test_sinks.dart';

void _exitBeforeRegistration((DiagnosticProducerBootstrap, int) message) {
  Isolate.exit();
}

void _naturalProducer((DiagnosticProducerBootstrap, SendPort) message) async {
  final producer = message.$1.connect();
  await producer.ready;
  final admitted = producer.emit(
    DiagnosticEvent.runtimeFailed,
    DiagnosticComponent.domain,
  );
  message.$2.send(admitted);
  // No cooperative close: only the direct VM exit can retire this slot.
}

void _heldProducer((DiagnosticProducerBootstrap, SendPort) message) async {
  final producer = message.$1.connect();
  await producer.ready;
  final commands = ReceivePort();
  message.$2.send((commands.sendPort, producer.active));
  commands.listen((_) {
    producer.close();
    commands.close();
  });
}

void _copyBootstraps((DiagnosticProducerBootstrap, SendPort) message) {
  for (var i = 0; i < 32; i++) {
    message.$2.send(message.$1);
  }
}

void _unobservedExit(DiagnosticProducerBootstrap _) => Isolate.exit();

void _foreignConnection((DiagnosticProducerBootstrap, SendPort) message) async {
  final producer = message.$1.connect();
  await producer.ready;
  var built = false;
  final admitted = producer.emit(
    DiagnosticEvent.runtimeFailed,
    DiagnosticComponent.domain,
    fields: () {
      built = true;
      return {};
    },
  );
  message.$2.send((
    producer.active,
    admitted,
    built,
    DiagnosticProducer.localEndpointCount,
    DiagnosticProducer.localRegistrationTimerCount,
    DiagnosticProducer.retainedConnectionCount,
    DiagnosticProducer.localRegistryAllocatedForTesting,
  ));
}

void _forwardedCapability(
  (DiagnosticProducerBootstrap, SendPort) message,
) async {
  final child = ReceivePort();
  await Isolate.spawn(_foreignConnection, (message.$1, child.sendPort));
  message.$2.send(await child.first);
  child.close();
}

void _unreachable((DiagnosticProducerBootstrap, RawReceivePort) message) {
  throw StateError('unsendable spawn must never execute its entrypoint');
}

void _limits(DiagnosticBudgetSnapshot state) {
  expect(state.producers.length, lessThanOrEqualTo(16));
  expect(state.normalBytes, inInclusiveRange(0, 64 * 1024));
  expect(state.priorityBytes, inInclusiveRange(0, 128 * 1024));
  expect(state.normalRecords, inInclusiveRange(0, 160));
  expect(state.priorityRecords, inInclusiveRange(0, 64));
  expect(state.producerBytes, lessThanOrEqualTo(192 * 1024));
  expect(state.producerRecords, lessThanOrEqualTo(224));
  expect(state.scratchBytes, lessThanOrEqualTo(144 * 1024));
  expect(state.reservedTrafficBytes, lessThanOrEqualTo(512 * 1024));
}

Future<LoggingSession> _session() => LoggingSession.startForTesting(
  configuration: const DiagnosticConfiguration(level: DiagnosticLevel.trace),
  role: DiagnosticRole.transient,
);

void main() {
  bootstrapSqlSupportFixture();
  test(
    'legacy and exposed reservations reject foreign VM before registry setup',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final reserved = session.reserveProducerForSpawn(
        DiagnosticProducerKind.domain,
      );
      final exposed = reserved.bootstrap;
      for (var i = 0; i < 10000; i++) {
        expect(identical(reserved.bootstrap, exposed), isTrue);
      }
      for (final bootstrap in [
        session.reserveProducer(DiagnosticProducerKind.setup),
        exposed,
      ]) {
        final observation = ReceivePort();
        final exited = ReceivePort();
        try {
          await Isolate.spawn(_foreignConnection, (
            bootstrap,
            observation.sendPort,
          ), onExit: exited.sendPort);
          expect(await observation.first.timeout(const Duration(seconds: 2)), (
            false,
            false,
            false,
            0,
            0,
            0,
            false,
          ));
          await exited.first.timeout(const Duration(seconds: 2));
        } finally {
          observation.close();
          exited.close();
        }
        final local = bootstrap.connect();
        await local.ready;
        expect(local.active, isTrue);
        local.close();
        await local.retired;
      }
    },
  );

  test(
    'getter during paused owned spawn never steals the worker binding',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final reservation = session.reserveProducerForSpawn(
        DiagnosticProducerKind.domain,
      );
      final observations = ReceivePort();
      addTearDown(observations.close);
      final spawning = reservation.spawn(_heldProducer, observations.sendPort);
      final premature = reservation.bootstrap.connect();
      expect(premature.active, isFalse);
      final owned = await spawning;
      final observation =
          await observations.first.timeout(const Duration(seconds: 2))
              as (SendPort, bool);
      expect(observation.$2, isTrue);
      expect(reservation.bootstrap.connect().active, isFalse);
      observation.$1.send(null);
      await owned.retired.timeout(const Duration(seconds: 2));
      expect(session.retainedSlotCount, 1);
    },
  );

  test(
    'catalog-small cold100 admits before five seconds using only normal credits',
    () async {
      final elapsed = Stopwatch()..start();
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'private-profile',
        role: DiagnosticRole.desktop,
        sinkFactory: memorySink(capture.port.sendPort),
      );
      addTearDown(session.close);
      final categories = DiagnosticCategory.values
          .where((c) => c != DiagnosticCategory.cancelled)
          .toList();
      var totalEncoded = 0, totalCharge = 0;
      for (var i = 0; i < 100; i++) {
        final event = i < 88
            ? DiagnosticEvent.rpcCompleted
            : i < 96
            ? DiagnosticEvent.serviceReady
            : DiagnosticEvent.serviceStarting;
        final fields = <DiagnosticField, Object>{
          if (i < 88)
            DiagnosticField.category: categories[i % categories.length],
        };
        final length = utf8
            .encode(
              jsonEncode(
                DiagnosticRecord(
                  event,
                  DiagnosticComponent.service,
                  fields: fields,
                ).toWire(),
              ),
            )
            .length;
        totalEncoded += length;
        totalCharge += length * 4 + 256;
        expect(
          session.producer.emit(
            event,
            DiagnosticComponent.service,
            fields: () => fields,
          ),
          isTrue,
        );
      }
      expect(totalEncoded, lessThanOrEqualTo(9984));
      expect(totalCharge, lessThanOrEqualTo(64 * 1024));
      await eventually(
        () => capture.records.length == 100,
        timeout: const Duration(seconds: 5),
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
      expect(capture.records.every((r) => r['level'] == 'info'), isTrue);
      expect(
        capture.records.any((r) => r['event'] == 'logging.records_dropped'),
        isFalse,
      );
      await session.close();
      expect(session.health.admitted, 100);
      expect(session.health.dropped, 0);
      print(
        'cold100 producer UTF8=$totalEncoded; charged=$totalCharge; '
        'elapsed_us=${elapsed.elapsedMicroseconds}',
      );
    },
  );

  test('exhausted positive63bit generations refuse without wrapping', () async {
    const maximum = 0x7fffffffffffffff;
    final session = await LoggingSession.startForTesting(
      configuration: const DiagnosticConfiguration(),
      role: DiagnosticRole.transient,
      generationSeed: maximum - 1,
    );
    addTearDown(session.close);
    expect(session.producer.generation, maximum);
    session.producer.close();
    await session.producer.retired.timeout(const Duration(seconds: 2));
    for (var slot = 1; slot < 16; slot++) {
      final producer = session.registerProducer(DiagnosticProducerKind.domain);
      await producer.ready;
      expect(producer.active, isTrue);
      expect(producer.slot, slot);
      expect(producer.generation, maximum);
      producer.close();
      await producer.retired.timeout(const Duration(seconds: 2));
    }
    final refused = session.registerProducer(DiagnosticProducerKind.domain);
    expect(refused.active, isFalse);
    expect(session.retainedSlotCount, 0);
    expect(session.health.producerRegistrationRefused, 1);
    _limits(await session.inspectBudgetForTesting());
  });

  test(
    'an external exit observer never invents a bound writer barrier',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final bootstrap = session.reserveProducer(DiagnosticProducerKind.domain);
      final exited = ReceivePort();
      addTearDown(exited.close);
      final isolate = await Isolate.spawn(
        _unobservedExit,
        bootstrap,
        onExit: exited.sendPort,
      );
      await exited.first.timeout(const Duration(seconds: 2));
      expect(isolate.controlPort, isNotNull);
      session.producerExited(bootstrap);
      final state = await session.inspectBudgetForTesting();
      expect(
        state.producers
            .singleWhere((p) => p.slot == bootstrap.slot)
            .quarantined,
        isTrue,
      );
      expect(session.retainedSlotCount, 2);
      _limits(state);
    },
  );

  test(
    'ten thousand duplicate and copied connects allocate one endpoint',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final baselinePorts = DiagnosticProducer.localEndpointCount;
      final bootstrap = session.reserveProducer(DiagnosticProducerKind.domain);
      final accepted = bootstrap.connect();
      final inactive = bootstrap.connect();
      for (var i = 0; i < 10000; i++) {
        expect(identical(bootstrap.connect(), inactive), isTrue);
      }
      expect(DiagnosticProducer.localEndpointCount, baselinePorts + 1);
      expect(DiagnosticProducer.localRegistrationTimerCount, 1);
      await accepted.ready;
      expect(accepted.active, isTrue);
      final echo = ReceivePort();
      addTearDown(echo.close);
      await Isolate.spawn(_copyBootstraps, (bootstrap, echo.sendPort));
      final copies = await echo.take(32).toList();
      expect(copies, hasLength(32));
      for (var i = 1; i < copies.length; i++) {
        expect(identical(copies[i - 1], copies[i]), isFalse);
      }
      for (final copied in copies.cast<DiagnosticProducerBootstrap>()) {
        expect(identical(copied, bootstrap), isFalse);
        expect(identical(copied.connect(), inactive), isTrue);
      }
      inactive.close();
      expect(accepted.active, isTrue);
      expect(DiagnosticProducer.localEndpointCount, baselinePorts + 1);
      expect(DiagnosticProducer.localRegistrationTimerCount, 0);
      accepted.close();
      await accepted.retired.timeout(const Duration(seconds: 2));
      for (var i = 0; i < 10000; i++) {
        expect(identical(bootstrap.connect(), inactive), isTrue);
      }
      expect(DiagnosticProducer.localEndpointCount, baselinePorts);
      expect(DiagnosticProducer.retainedConnectionCount, lessThanOrEqualTo(16));
      expect(session.retainedSlotCount, 1);
    },
  );

  test(
    'writer context replacement refuses old capabilities and active peers',
    () async {
      final first = await _session();
      addTearDown(first.close);
      final old = first.reserveProducer(DiagnosticProducerKind.domain);
      final live = old.connect();
      await live.ready;
      final count = DiagnosticProducer.localEndpointCount;
      final concurrent = await _session();
      addTearDown(concurrent.close);
      expect(concurrent.health.reason, DiagnosticHealthReason.writerFailed);
      expect(concurrent.producer.active, isFalse);
      expect(DiagnosticProducer.localEndpointCount, count);
      expect(live.active, isTrue);
      live.close();
      await live.retired;
      await first.close();
      final replacement = await _session();
      addTearDown(replacement.close);
      final now = DiagnosticProducer.localEndpointCount;
      expect(old.connect().active, isFalse);
      expect(DiagnosticProducer.localEndpointCount, now);
      expect(replacement.producer.active, isTrue);
    },
  );

  test('retirement remains completed for late reservation observers', () async {
    final session = await _session();
    addTearDown(session.close);
    final cancelled = session.reserveProducerForSpawn(
      DiagnosticProducerKind.domain,
    );
    expect(cancelled.cancelNeverSpawned(), isTrue);
    await eventually(() => session.retainedSlotCount == 1);
    await cancelled.retired.timeout(const Duration(milliseconds: 100));
    final exposed = session.reserveProducerForSpawn(
      DiagnosticProducerKind.domain,
    );
    final producer = exposed.bootstrap.connect();
    await producer.ready;
    producer.close();
    await eventually(() => session.retainedSlotCount == 1);
    await exposed.retired.timeout(const Duration(milliseconds: 100));
    final spawned = session.reserveProducerForSpawn(
      DiagnosticProducerKind.domain,
    );
    await spawned.spawn(_exitBeforeRegistration, 0);
    await eventually(() => session.retainedSlotCount == 1);
    await spawned.retired.timeout(const Duration(milliseconds: 100));
  });

  for (final priority in [false, true]) {
    test(
      'close after revoke ACK before replacement grant priority=$priority',
      () async {
        final session = await _session();
        addTearDown(session.close);
        final producer = session.registerProducer(
          DiagnosticProducerKind.domain,
        );
        await producer.ready;
        await eventually(() async {
          final state = await session.inspectBudgetForTesting();
          final own = state.producers.singleWhere(
            (p) => p.slot == producer.slot,
          );
          return own.normalBytes > 0 && producer.receivedGrantsForTesting.$2;
        });
        final event = priority
            ? DiagnosticEvent.runtimeFailed
            : DiagnosticEvent.serviceStarting;
        var admitted = 0;
        while (producer.emit(event, DiagnosticComponent.domain)) {
          admitted++;
          expect(admitted, lessThanOrEqualTo(224));
        }
        expect(admitted, greaterThan(0));
        // pressure then inspect are ordered to the same writer. Its revoke is
        // dispatched before inspectReply, whose continuation closes before the
        // replacement grant queued by the revoke ACK can be dispatched here.
        final before = await session.inspectBudgetForTesting();
        final previous = before.producers.singleWhere(
          (p) => p.slot == producer.slot,
        );
        final received = producer.receivedGrantsForTesting;
        expect(
          priority ? received.$4 : received.$2,
          isFalse,
          reason: 'closure must observe an ACKed but unreceived replacement',
        );
        expect(
          priority ? received.$3 : received.$1,
          (priority ? previous.priorityEpoch : previous.normalEpoch) + 1,
        );
        producer.close();
        await producer.retired.timeout(const Duration(seconds: 2));
        expect(session.retainedSlotCount, 1);
        expect(
          (await session.inspectBudgetForTesting()).producers.any(
            (p) => p.quarantined,
          ),
          isFalse,
        );
        final replacement = session.registerProducer(
          DiagnosticProducerKind.domain,
        );
        await replacement.ready;
        expect(replacement.slot, producer.slot);
        expect(replacement.generation, producer.generation + 1);
        replacement.close();
        await replacement.retired.timeout(const Duration(seconds: 2));
      },
    );
  }

  test(
    'registration deadline withdraws only its own never-enabled endpoint',
    () async {
      final blocked = ReceivePort();
      final output = blocked.sendPort;
      addTearDown(blocked.close);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        role: DiagnosticRole.desktop,
        sinkFactory: (path, id, role) {
          output.send(true);
          sleep(const Duration(milliseconds: 650));
          return MemorySink(output);
        },
      );
      addTearDown(session.close);
      final acceptedBootstrap = session.reserveProducer(
        DiagnosticProducerKind.domain,
      );
      final accepted = acceptedBootstrap.connect();
      await accepted.ready;
      session.selectProfile('private-profile');
      expect(
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.domain,
        ),
        isTrue,
      );
      await blocked.first.timeout(const Duration(seconds: 2));
      final duplicate = ReceivePort();
      addTearDown(duplicate.close);
      await Isolate.spawn(_foreignConnection, (
        acceptedBootstrap,
        duplicate.sendPort,
      ));
      final bootstrap = session.reserveProducer(DiagnosticProducerKind.domain);
      final producer = bootstrap.connect();
      await producer.ready;
      expect(producer.active, isFalse);
      expect(DiagnosticProducer.localRegistrationTimerCount, 0);
      var built = false;
      expect(
        producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.domain,
          fields: () {
            built = true;
            return {};
          },
        ),
        isFalse,
      );
      expect(built, isFalse);
      await eventually(
        () => session.retainedSlotCount == 2,
        timeout: const Duration(seconds: 2),
      );
      final state = await session.inspectBudgetForTesting();
      expect(state.producers.any((p) => p.quarantined), isFalse);
      expect(bootstrap.connect().active, isFalse);
      expect(await duplicate.first.timeout(const Duration(seconds: 2)), (
        false,
        false,
        false,
        0,
        0,
        0,
        false,
      ));
      expect(accepted.active, isTrue);
      accepted.close();
      await accepted.retired.timeout(const Duration(seconds: 2));
      expect(session.retainedSlotCount, 1);
    },
  );

  test(
    'closing before registration grants cannot retain a local slot',
    () async {
      final session = await _session();
      addTearDown(session.close);
      for (var i = 0; i < 32; i++) {
        final producer = session.registerProducer(
          DiagnosticProducerKind.domain,
        );
        producer.close();
        await producer.retired.timeout(const Duration(seconds: 2));
        expect(producer.active, isFalse);
        expect(session.retainedSlotCount, 1);
      }
    },
  );

  test(
    'an idle zero normal grant advances epoch before funding its replacement',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final producer = session.registerProducer(DiagnosticProducerKind.domain);
      await producer.ready;
      // Do not emit/drop: idle rebalancing alone must settle the zero lease.
      await eventually(() async {
        final state = await session.inspectBudgetForTesting();
        final current = state.producers.singleWhere(
          (p) => p.slot == producer.slot,
        );
        _limits(state);
        return current.normalEpoch > 1 && current.normalBytes > 0;
      }, timeout: const Duration(seconds: 2));
      expect(
        producer.emit(
          DiagnosticEvent.serviceStarting,
          DiagnosticComponent.domain,
        ),
        isTrue,
      );
      final state = await session.inspectBudgetForTesting();
      expect(
        state.producers.singleWhere((p) => p.slot == producer.slot).quarantined,
        isFalse,
      );
    },
  );

  test('the owned helper preserves the application exit observer', () async {
    final session = await _session();
    addTearDown(session.close);
    final business = ReceivePort();
    addTearDown(business.close);
    final owned = await session.spawnProducer(
      DiagnosticProducerKind.domain,
      _exitBeforeRegistration,
      0,
      onExit: business.sendPort,
    );
    expect(await business.first.timeout(const Duration(seconds: 2)), isNull);
    await owned.retired.timeout(const Duration(seconds: 2));
    expect(session.retainedSlotCount, 1);
  });

  test(
    'a copied capability in a foreign VM never receives encoder authority',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final observations = ReceivePort();
      addTearDown(observations.close);
      final owned = await session.spawnProducer(
        DiagnosticProducerKind.domain,
        _forwardedCapability,
        observations.sendPort,
      );
      expect(await observations.first.timeout(const Duration(seconds: 2)), (
        false,
        false,
        false,
        0,
        0,
        0,
        false,
      ));
      await owned.retired.timeout(const Duration(seconds: 2));
      expect(session.retainedSlotCount, 1);
      _limits(await session.inspectBudgetForTesting());
    },
  );

  test(
    'a preflight reservation spawns only through its bound owner helper',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final reservation = session.reserveProducerForSpawn(
        DiagnosticProducerKind.domain,
      );
      final spawning = reservation.spawn(_exitBeforeRegistration, 0);
      expect(reservation.cancelNeverSpawned(), isFalse);
      final owned = await spawning;
      await owned.retired.timeout(const Duration(seconds: 2));
      await reservation.retired.timeout(const Duration(seconds: 2));
      expect(session.retainedSlotCount, 1);
    },
  );

  test('owner notification alone quarantines an exposed reservation', () async {
    final session = await _session();
    addTearDown(session.close);
    final exposed = session.reserveProducer(DiagnosticProducerKind.domain);
    session.producerExited(exposed);
    session.producerExited(exposed); // A duplicate cannot create another edge.
    final state = await session.inspectBudgetForTesting();
    expect(
      state.producers.singleWhere((p) => p.slot == exposed.slot).quarantined,
      isTrue,
    );
    expect(session.retainedSlotCount, 2);
    final late = exposed.connect();
    await late.ready;
    var built = false;
    expect(
      late.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.domain,
        fields: () {
          built = true;
          return {};
        },
      ),
      isFalse,
    );
    expect(built, isFalse);
    expect(session.retainedSlotCount, 2);
    _limits(await session.inspectBudgetForTesting());
  });

  test(
    '120 cooperative replacements plateau at one current local handle',
    () async {
      final session = await _session();
      addTearDown(session.close);
      var generation = 0;
      for (var i = 0; i < 120; i++) {
        final producer = session.registerProducer(
          DiagnosticProducerKind.domain,
        );
        await producer.ready;
        expect(producer.active, isTrue);
        expect(producer.slot, 1);
        expect(producer.generation, greaterThan(generation));
        generation = producer.generation;
        producer.close();
        await producer.retired.timeout(const Duration(seconds: 2));
        expect(session.retainedProducerCount, 1);
        expect(session.retainedSlotCount, 1);
        _limits(await session.inspectBudgetForTesting());
      }
      expect(session.health.producerRegistrationRefused, 0);
    },
  );

  test('120 actual VM exits recycle without an owner-forwarded exit', () async {
    final session = await _session();
    addTearDown(session.close);
    final done = ReceivePort();
    addTearDown(done.close);
    final observations = StreamIterator(done);
    addTearDown(observations.cancel);
    var generation = 0;
    for (var i = 0; i < 120; i++) {
      final owned = await session.spawnProducer(
        DiagnosticProducerKind.domain,
        _naturalProducer,
        done.sendPort,
      );
      expect(
        await observations.moveNext().timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(observations.current, isTrue);
      await owned.retired.timeout(const Duration(seconds: 2));
      expect(owned.bootstrap.slot, 1);
      expect(owned.bootstrap.generation, greaterThan(generation));
      generation = owned.bootstrap.generation;
      expect(session.retainedSlotCount, 1);
      _limits(await session.inspectBudgetForTesting());
    }
  });

  test(
    'pre-registration exit and old bootstrap replay cannot attach after reuse',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final old = <DiagnosticProducerBootstrap>[];
      for (var i = 0; i < 32; i++) {
        final owned = await session.spawnProducer(
          DiagnosticProducerKind.domain,
          _exitBeforeRegistration,
          i,
        );
        await owned.retired.timeout(const Duration(seconds: 2));
        old.add(owned.bootstrap);
        expect(session.retainedSlotCount, 1);
      }
      final current = session.registerProducer(DiagnosticProducerKind.setup);
      await current.ready;
      expect(current.active, isTrue);
      var fields = 0;
      for (final bootstrap in old) {
        session.producerExited(bootstrap); // Stale owner hints never enqueue.
        final late = bootstrap.connect();
        await late.ready;
        expect(late.active, isFalse);
        expect(
          late.emit(
            DiagnosticEvent.runtimeFailed,
            DiagnosticComponent.domain,
            fields: () {
              fields++;
              return {};
            },
          ),
          isFalse,
        );
        late.close();
      }
      expect(fields, 0);
      expect(current.active, isTrue);
      expect(session.retainedSlotCount, 2);
      _limits(await session.inspectBudgetForTesting());
    },
  );

  test(
    'never-spawned cancellation is lost irrevocably on capability exposure',
    () async {
      final session = await _session();
      addTearDown(session.close);
      for (var i = 0; i < 32; i++) {
        final reservation = session.reserveProducerForSpawn(
          DiagnosticProducerKind.domain,
        );
        expect(reservation.cancelNeverSpawned(), isTrue);
        await reservation.retired.timeout(const Duration(seconds: 2));
        expect(reservation.bootstrap.connect().active, isFalse);
        expect(session.retainedSlotCount, 1);
      }
      final exposed = session.reserveProducerForSpawn(
        DiagnosticProducerKind.domain,
      );
      final bootstrap = exposed.bootstrap;
      expect(exposed.cancelNeverSpawned(), isFalse);
      final producer = bootstrap.connect();
      await producer.ready;
      expect(producer.active, isTrue);
      expect(session.retainedSlotCount, 2);
      producer.close();
      await exposed.retired.timeout(const Duration(seconds: 2));
      expect(session.retainedSlotCount, 1);
    },
  );

  test(
    '32 failed paused spawns never execute an encoder or retain a slot',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final unsendable = RawReceivePort();
      addTearDown(unsendable.close);
      for (var i = 0; i < 32; i++) {
        await expectLater(
          session.spawnProducer(
            DiagnosticProducerKind.domain,
            _unreachable,
            unsendable,
          ),
          throwsA(isA<ArgumentError>()),
        );
        _limits(await session.inspectBudgetForTesting());
        expect(session.retainedSlotCount, 1);
      }
      expect(session.health.producerRegistrationRefused, 0);
    },
  );

  test(
    '17 live owners refuse diagnostics only and keep a fixed refusal edge',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final done = ReceivePort();
      addTearDown(done.close);
      final observations = StreamIterator(done);
      addTearDown(observations.cancel);
      final owners = <DiagnosticOwnedIsolate>[], commands = <SendPort>[];
      addTearDown(() async {
        for (final command in commands) {
          command.send(null);
        }
        await Future.wait(
          owners.map((owner) => owner.retired),
        ).timeout(const Duration(seconds: 2));
      });
      for (var i = 0; i < 16; i++) {
        final owned = await session.spawnProducer(
          DiagnosticProducerKind.domain,
          _heldProducer,
          done.sendPort,
        );
        owners.add(owned);
        expect(
          await observations.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        final (command, active) = observations.current as (SendPort, bool);
        commands.add(command);
        expect(active, i < 15); // Entrypoint +15 workers; the17th still runs.
      }
      expect(session.retainedSlotCount, 16);
      expect(session.health.producerRegistrationRefused, 1);
      DiagnosticProducer? previous;
      var fields = 0;
      for (var i = 0; i < 10000; i++) {
        final refused = session.registerProducer(DiagnosticProducerKind.domain);
        if (previous != null) expect(identical(refused, previous), isTrue);
        previous = refused;
        expect(
          refused.emit(
            DiagnosticEvent.runtimeFailed,
            DiagnosticComponent.domain,
            fields: () {
              fields++;
              return {};
            },
          ),
          isFalse,
        );
      }
      expect(fields, 0);
      expect(session.health.producerRegistrationRefused, 10001);
      _limits(await session.inspectBudgetForTesting());
      expect(session.retainedProducerCount, 1);
    },
  );

  test(
    'close from a builder cannot retire scratch before that builder returns',
    () async {
      final session = await _session();
      addTearDown(session.close);
      final producer = session.registerProducer(DiagnosticProducerKind.domain);
      await producer.ready;
      var unwound = false;
      final retired = producer.retired.then((_) => expect(unwound, isTrue));
      expect(
        producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.domain,
          fields: () {
            producer.close();
            expect(session.retainedSlotCount, 2);
            expect(producer.active, isFalse);
            return {};
          },
        ),
        isFalse,
      );
      unwound = true;
      await retired.timeout(const Duration(seconds: 2));
      final reused = session.registerProducer(DiagnosticProducerKind.setup);
      await reused.ready;
      expect(reused.slot, producer.slot);
      expect(reused.generation, greaterThan(producer.generation));
      _limits(await session.inspectBudgetForTesting());
    },
  );

  test(
    'queued attribution and credit settlement survive kind/generation reuse',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'private-profile',
        role: DiagnosticRole.desktop,
        sinkFactory: memorySink(capture.port.sendPort),
      );
      addTearDown(session.close);
      final producer = session.registerProducer(DiagnosticProducerKind.domain);
      await producer.ready;
      final deadline = Stopwatch()..start();
      while (!producer.emit(
        DiagnosticEvent.serviceStarting,
        DiagnosticComponent.domain,
      )) {
        expect(deadline.elapsed, lessThan(const Duration(seconds: 2)));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      producer.close();
      await producer.retired.timeout(const Duration(seconds: 2));
      final replacement = session.registerProducer(
        DiagnosticProducerKind.setup,
      );
      await replacement.ready;
      expect(replacement.slot, producer.slot);
      expect(replacement.generation, greaterThan(producer.generation));
      final before = await session.inspectBudgetForTesting();
      expect(before.queuedRecords, 1);
      final beforeNew = before.producers.singleWhere(
        (p) => p.slot == replacement.slot,
      );
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      );
      await eventually(
        () => capture.records.any((r) => r['event'] == 'service.starting'),
      );
      final after = await session.inspectBudgetForTesting();
      final afterNew = after.producers.singleWhere(
        (p) => p.slot == replacement.slot,
      );
      expect(
        (
          afterNew.normalBytes,
          afterNew.normalRecords,
          afterNew.priorityBytes,
          afterNew.priorityRecords,
          afterNew.normalEpoch,
          afterNew.priorityEpoch,
        ),
        (
          beforeNew.normalBytes,
          beforeNew.normalRecords,
          beforeNew.priorityBytes,
          beforeNew.priorityRecords,
          beforeNew.normalEpoch,
          beforeNew.priorityEpoch,
        ),
      );
      _limits(after);
      await session.close();
      await capture.closed.future.timeout(const Duration(seconds: 2));
      final old = capture.records.singleWhere(
        (r) => r['event'] == 'service.starting',
      );
      expect(old['producer'], 'domain:${producer.slot}');
      expect(old['schema'], 1); // No fabricated schema2 build identity.
      expect(old.containsKey('build_id'), isFalse);
      expect(session.health.highWaterBytes, lessThanOrEqualTo(192 * 1024));
      expect(session.health.highWaterRecords, lessThanOrEqualTo(224));
    },
  );

  test(
    'unadopted SQL reader compatibility retains only its explicit owner producer',
    () async {
      final root = createTestTempDirectorySync('diagnostic-readers-');
      final store = Store('${root.path}/profile.db');
      addTearDown(store.close);
      store.setPreference('fixture', 'kept');
      final session = await _session();
      addTearDown(session.close);
      final workers = <SqliteReadWorker>[];
      addTearDown(() => Future.wait(workers.map((w) => w.close())));
      ReadWorkerRequest request(int sequence) => ReadWorkerRequest(
        projection: 'preference',
        arguments: {'key': 'fixture'},
        sequence: sequence,
        identity: ReadIdentity(
          owner: 'owner',
          profile: 'profile',
          connection: 'reader-$sequence',
          epoch: store.workspaceEpoch,
          revision: 'tag',
        ),
      );
      for (var i = 0; i < 20; i++) {
        final reader = SqliteReadWorker(store.path);
        workers.add(reader);
        expect((await reader.read(request(i))).value, 'kept');
        expect(session.retainedSlotCount, 1);
      }
      for (var i = 0; i < 32; i++) {
        final reader = SqliteReadWorker('${root.path}/missing-$i.db');
        try {
          await expectLater(
            reader.read(request(i)),
            throwsA(
              isA<RpcError>().having(
                (e) => e.code,
                'startup code',
                RpcErrorCode.internal,
              ),
            ),
          );
        } finally {
          await reader.close();
        }
        expect(session.retainedSlotCount, 1);
      }
      expect(session.health.producerRegistrationRefused, 0);
      _limits(await session.inspectBudgetForTesting());
    },
  );
}
