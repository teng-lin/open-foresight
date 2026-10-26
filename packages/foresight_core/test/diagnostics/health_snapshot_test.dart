import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart'
    show DiagnosticSink, DiagnosticSinkFactory;
import 'package:test/test.dart';

import 'test_sinks.dart';

const _info = DiagnosticConfiguration();

Future<void> _until(
  bool Function() condition, {
  int milliseconds = 3000,
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsedMilliseconds > milliseconds) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void _spin(int milliseconds) {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsedMilliseconds < milliseconds) {}
}

Future<LoggingSession> _storedSession(SinkCapture capture) async {
  final session = await LoggingSession.startForTesting(
    configuration: _info,
    profilePath: 'private-profile',
    role: DiagnosticRole.desktop,
    sinkFactory: memorySink(capture.port.sendPort),
  );
  addTearDown(session.close);
  return session;
}

Future<void> _admitStorage(LoggingSession session) async {
  expect(
    session.producer.emit(
      DiagnosticEvent.runtimeFailed,
      DiagnosticComponent.domain,
    ),
    isTrue,
  );
  await _until(() => session.health.slot == 7);
}

/// Reports the first (pre-reply) and first authoritative snapshot from a VM
/// separate from the owner, as closed JSON only.
void _secondVm((DiagnosticProducerBootstrap, SendPort) message) async {
  final producer = message.$1.connect();
  await producer.ready;
  final initial = producer.healthSnapshot;
  final elapsed = Stopwatch()..start();
  var current = initial;
  while (!current.known && elapsed.elapsedMilliseconds < 3000) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    current = producer.healthSnapshot;
  }
  message.$2.send([
    jsonEncode(initial.toJson()),
    jsonEncode(current.toJson()),
    producer.healthRequestStateForTesting.$1,
  ]);
  producer.close();
}

/// Observes request state while the owner VM is synchronously held.
void _heldOwner((DiagnosticProducerBootstrap, SendPort) message) async {
  final producer = message.$1.connect();
  await producer.ready;
  final commands = ReceivePort();
  final elapsed = Stopwatch()..start();
  while (!producer.healthSnapshot.known && elapsed.elapsedMilliseconds < 3000) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final known = producer.healthRequestStateForTesting;
  message.$2.send(['hold', commands.sendPort]);
  await commands.first;
  // The owner now spins. Let the throttle expire, then read repeatedly.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final held = <List<int>>[];
  final reads = Stopwatch()..start();
  while (reads.elapsedMilliseconds < 800) {
    final snapshot = producer.healthSnapshot;
    final (nonce, pending) = producer.healthRequestStateForTesting;
    held.add([nonce, pending, snapshot.known ? 1 : 0]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final released = Stopwatch()..start();
  while (producer.healthRequestStateForTesting.$2 != 0 &&
      released.elapsedMilliseconds < 3000) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  message.$2.send([
    [known.$1, known.$2],
    held,
    [
      producer.healthRequestStateForTesting.$1,
      producer.healthRequestStateForTesting.$2,
    ],
  ]);
  producer.close();
}

void _foreignVm((DiagnosticProducerBootstrap, SendPort) message) {
  final producer = message.$1.connect();
  final first = producer.healthSnapshot;
  final second = producer.healthSnapshot;
  message.$2.send([
    jsonEncode(first.toJson()),
    jsonEncode(second.toJson()),
    producer.healthRequestStateForTesting.$1,
    DiagnosticProducer.localEndpointCount,
  ]);
}

void _forwardToForeignVm(
  (DiagnosticProducerBootstrap, SendPort) message,
) async {
  final child = ReceivePort();
  await Isolate.spawn(_foreignVm, (message.$1, child.sendPort));
  message.$2.send(await child.first);
  child.close();
}

DiagnosticSinkFactory _heldWriterSink(SendPort entered, SendPort finished) =>
    (_, __, ___) => _HeldWriterSink(entered, finished);

final class _HeldWriterSink implements DiagnosticSink {
  _HeldWriterSink(this.entered, this.finished);
  final SendPort entered, finished;
  bool _held = false;
  @override
  int get slot => 3;
  @override
  bool get failed => false;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) => true;
  @override
  bool append(Uint8List record) {
    // Holds the writer VM's event loop once, inside the real flush path.
    if (!_held) {
      _held = true;
      entered.send(null);
      _spin(1200);
      finished.send(null);
    }
    return true;
  }

  @override
  void close() {}
}

Map<String, Object?> _complete({
  Object? version = 1,
  Object? level = 'info',
  Object? storageConfigured = true,
  Object? known = true,
  Object? stale = false,
  Object? ageMs = 4,
  Object? state = 'starting',
  Object? reason = 'healthy',
  Object? slot,
}) => {
  'version': version,
  'level': level,
  'transportTrace': false,
  'invalidLevel': false,
  'storageConfigured': storageConfigured,
  'known': known,
  'stale': stale,
  'ageMs': ageMs,
  'state': state,
  'reason': reason,
  'nativeReason': 'unconfigured',
  'nativeDropsExact': true,
  'admittedRecords': 1,
  'droppedRecords': 2,
  'rejectedRecords': 3,
  'highWaterBytes': 4,
  'highWaterRecords': 5,
  'producerRegistrationRefused': 6,
  'quarantinedProducers': 7,
  'slot': slot,
};

void main() {
  test(
    'canonical off is known/off after enabled inactive use without resources',
    () async {
      final enabled = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
      );
      final capability = enabled.reserveProducer(DiagnosticProducerKind.domain);
      final active = capability.connect();
      await active.ready;
      final inactive = capability.connect();
      expect(inactive.active, isFalse);
      expect(inactive.healthSnapshot.level, DiagnosticLevel.info);
      active.close();
      await active.retired;
      await enabled.close();
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.off,
        ),
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final local = session.healthSnapshot;
      expect(local.known, isTrue);
      expect(local.state, DiagnosticHealthState.off);
      expect(local.reason, DiagnosticHealthReason.off);
      expect(local.ageMs, 0);
      expect(local.storageConfigured, isTrue);
      expect(local.transportEnabled, isFalse);
      expect(session.producer.healthSnapshot.toJson(), local.toJson());
      for (var i = 0; i < 64; i++) {
        final snapshot = session.producer.healthSnapshot;
        expect(snapshot.known, isTrue);
        expect(snapshot.storageConfigured, isTrue);
        expect(snapshot.level, DiagnosticLevel.off);
        expect(snapshot.state, DiagnosticHealthState.off);
        expect(snapshot.stale, isFalse);
      }
      expect(session.producer.healthRequestStateForTesting, (0, 0));
      expect(DiagnosticProducer.localEndpointCount, 0);
      expect(DiagnosticProducer.localRegistrationTimerCount, 0);
      expect(session.retainedSlotCount, 0);
      await session.close();
      expect(session.healthSnapshot.state, DiagnosticHealthState.off);
      expect(
        session.producer.healthSnapshot.toJson(),
        session.healthSnapshot.toJson(),
      );
      expect(session.producer.healthRequestStateForTesting, (0, 0));
    },
  );

  test('public model defaults to unknown and round-trips closed JSON', () {
    const fake = DiagnosticHealthSnapshot();
    expect(fake.known, isFalse);
    expect(fake.state, DiagnosticHealthState.unknown);
    expect(fake.ageMs, isNull);
    expect(fake.reason, isNot(DiagnosticHealthReason.healthy));
    expect(fake.nativeDropsExact, isFalse);

    final json = fake.toJson();
    expect(json.length, 20);
    expect(json['version'], 1);
    for (final value in json.values) {
      expect(
        value == null || value is bool || value is int || value is String,
        isTrue,
      );
    }
    // The only strings are closed enum names.
    expect(
      json.entries.where((e) => e.value is String).map((e) => e.key).toSet(),
      {'level', 'state', 'reason', 'nativeReason'},
    );
    final parsed = DiagnosticHealthSnapshot.tryParse(
      jsonDecode(jsonEncode(json)),
    )!;
    expect(parsed.toJson(), json);

    final complete = _complete(slot: 9, state: 'healthy');
    expect(DiagnosticHealthSnapshot.tryParse(complete)!.toJson(), complete);
    final transport = DiagnosticHealthSnapshot.tryParse(
      _complete()..['transportTrace'] = true,
    )!;
    expect(transport.transportTrace, isTrue);
    expect(transport.transportEnabled, isTrue);
    expect(
      DiagnosticHealthSnapshot.tryParse(
        _complete(level: 'trace'),
      )!.transportEnabled,
      isTrue,
    );
  });

  test(
    'stale closing and closed public snapshots preserve terminal priority',
    () {
      for (final state in ['closing', 'closed']) {
        final value = _complete(state: state, stale: true, ageMs: 2001);
        final parsed = DiagnosticHealthSnapshot.tryParse(value);
        expect(parsed, isNotNull);
        expect(parsed!.toJson(), value);
      }
    },
  );

  test('tryParse rejects malformed, extended and unknown versions', () {
    final malformed = <Object?>[
      null,
      'healthy',
      const [1],
      <String, Object?>{},
      _complete(version: 2),
      _complete(version: 1.0),
      _complete(version: '1'),
      _complete(level: 'verbose'),
      _complete(state: 'supported'),
      _complete(state: 'closing', stale: true, ageMs: 4),
      _complete(state: 'closed', stale: false, ageMs: 2001),
      _complete(state: 'closing', known: false, ageMs: null),
      _complete(level: 'off', state: 'closed'),
      _complete(state: 'starting', reason: 'sinkFailed'),
      _complete(state: 'starting', storageConfigured: false),
      _complete(state: 'unknown'),
      _complete(state: 'degraded', slot: 0),
      _complete(level: 'off', state: 'off', reason: 'healthy'),
      _complete(state: 'healthy', storageConfigured: false, slot: 0),
      _complete(state: 'healthy', slot: null),
      _complete(state: 'healthy', reason: 'sinkFailed', slot: 0),
      _complete(state: 'healthy', stale: true),
      _complete(reason: 'secret text'),
      _complete(slot: 10),
      _complete(slot: -1),
      _complete(ageMs: -1),
      _complete(ageMs: 0x80000000),
      _complete(known: 1),
      _complete(known: false),
      _complete(known: false, ageMs: null, state: 'healthy'),
      _complete(known: true, ageMs: null),
      _complete(level: 'off', state: 'healthy'),
      _complete(level: 'info', state: 'off'),
      _complete()..remove('slot'),
      _complete()..remove('ageMs'),
      _complete()..remove('quarantinedProducers'),
      _complete()..['path'] = '/home/user',
      _complete()
        ..remove('slot')
        ..['session'] = 'abc',
      _complete()..['admittedRecords'] = 0x80000000,
      _complete()..['droppedRecords'] = -1,
      _complete()..['highWaterBytes'] = 1.5,
      _complete()..['nativeReason'] = 'unknown',
      _complete()..['storageConfigured'] = 'true',
    ];
    for (final value in malformed) {
      expect(
        DiagnosticHealthSnapshot.tryParse(value),
        isNull,
        reason: '$value',
      );
    }
    expect(
      DiagnosticHealthSnapshot.tryParse(
        _complete(known: false, ageMs: null, state: 'unknown'),
      ),
      isNotNull,
    );
  });

  test(
    'local session derives configuration, starting, healthy and close',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await _storedSession(capture);
      final initial = session.healthSnapshot;
      expect(initial.known, isTrue);
      expect(initial.ageMs, 0);
      expect(initial.stale, isFalse);
      expect(initial.storageConfigured, isTrue);
      expect(initial.level, DiagnosticLevel.info);
      expect(initial.transportEnabled, isFalse);
      // Initial healthy reason alone never produces healthy.
      expect(initial.reason, DiagnosticHealthReason.healthy);
      expect(initial.slot, isNull);
      expect(initial.state, DiagnosticHealthState.starting);

      await _admitStorage(session);
      final admitted = session.healthSnapshot;
      expect(admitted.state, DiagnosticHealthState.healthy);
      expect(admitted.slot, 7);
      expect(admitted.admittedRecords, greaterThanOrEqualTo(1));
      expect(
        DiagnosticHealthSnapshot.tryParse(admitted.toJson())!.toJson(),
        admitted.toJson(),
      );

      final closing = session.close();
      expect(session.healthSnapshot.state, DiagnosticHealthState.closing);
      final result = await closing;
      expect(session.healthSnapshot.state, DiagnosticHealthState.closed);
      // Close results remain the separate writer-exit evidence.
      expect(result.writerExited, isTrue);
    },
  );

  test(
    'unconfigured storage, sink failure and transport trace semantics',
    () async {
      final plain = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(transportTrace: true),
        role: DiagnosticRole.transient,
      );
      addTearDown(plain.close);
      final unconfigured = plain.healthSnapshot;
      expect(unconfigured.storageConfigured, isFalse);
      expect(unconfigured.state, DiagnosticHealthState.degraded);
      expect(unconfigured.transportTrace, isTrue);
      expect(unconfigured.transportEnabled, isTrue);
      expect(unconfigured.level, DiagnosticLevel.info);
      await plain.close();

      final invalid = await LoggingSession.startForTesting(
        configuration: DiagnosticConfiguration.fromEnvironment(const {
          'FORESIGHT_LOG_LEVEL': 'loud',
        }),
        role: DiagnosticRole.transient,
      );
      addTearDown(invalid.close);
      expect(invalid.healthSnapshot.invalidLevel, isTrue);
      expect(invalid.healthSnapshot.level, DiagnosticLevel.info);
      await invalid.close();

      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final broken = await LoggingSession.startForTesting(
        configuration: _info,
        profilePath: 'private-profile',
        role: DiagnosticRole.desktop,
        sinkFactory: brokenSink(capture.port.sendPort),
      );
      addTearDown(broken.close);
      broken.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.domain,
      );
      await _until(
        () => broken.health.reason == DiagnosticHealthReason.sinkFailed,
      );
      expect(broken.healthSnapshot.storageConfigured, isTrue);
      expect(broken.healthSnapshot.state, DiagnosticHealthState.degraded);
    },
  );

  test(
    'an owned spawn in a second VM round-trips the owner snapshot',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await _storedSession(capture);
      await _admitStorage(session);
      final reports = ReceivePort();
      addTearDown(reports.close);
      final owned = await session.spawnProducer(
        DiagnosticProducerKind.domain,
        _secondVm,
        reports.sendPort,
      );
      final report =
          await reports.first.timeout(const Duration(seconds: 5)) as List;
      final initial = DiagnosticHealthSnapshot.tryParse(
        jsonDecode(report[0] as String),
      )!;
      expect(initial.known, isFalse);
      expect(initial.ageMs, isNull);
      expect(initial.state, DiagnosticHealthState.unknown);
      expect(initial.storageConfigured, isTrue);
      expect(initial.level, DiagnosticLevel.info);

      final remote = DiagnosticHealthSnapshot.tryParse(
        jsonDecode(report[1] as String),
      )!;
      final local = session.healthSnapshot;
      expect(remote.known, isTrue);
      expect(remote.stale, isFalse);
      expect(remote.ageMs, inInclusiveRange(0, 2000));
      expect(remote.state, DiagnosticHealthState.healthy);
      expect(remote.reason, local.reason);
      expect(remote.slot, 7);
      expect(remote.nativeReason, local.nativeReason);
      expect(remote.nativeDropsExact, local.nativeDropsExact);
      expect(remote.admittedRecords, local.admittedRecords);
      expect(
        remote.producerRegistrationRefused,
        local.producerRegistrationRefused,
      );
      expect(remote.quarantinedProducers, local.quarantinedProducers);
      // One authoritative round trip; polling did not replace or retry it.
      expect(report[2], 1);
      await owned.retired.timeout(const Duration(seconds: 2));
    },
  );

  test('refresh is throttled, single-pending, stale, and closed endpoints stay '
      'closed', () async {
    final capture = SinkCapture();
    addTearDown(capture.dispose);
    final session = await _storedSession(capture);
    await _admitStorage(session);
    final producer = session.registerProducer(DiagnosticProducerKind.domain);
    await producer.ready.timeout(const Duration(seconds: 2));
    expect(producer.active, isTrue);

    final before = producer.healthSnapshot;
    expect(before.known, isFalse);
    expect(before.state, DiagnosticHealthState.unknown);
    for (var i = 0; i < 1000; i++) {
      expect(producer.healthSnapshot.known, isFalse);
    }
    expect(producer.healthRequestStateForTesting, (1, 1));
    await _until(() => producer.healthRequestStateForTesting.$2 == 0);
    final fresh = producer.healthSnapshot;
    expect(fresh.known, isTrue);
    expect(fresh.state, DiagnosticHealthState.healthy);
    // Within the 250 ms window repeated reads send nothing new.
    for (var i = 0; i < 1000; i++) {
      producer.healthSnapshot;
    }
    expect(producer.healthRequestStateForTesting.$1, 1);

    // Without reads, the cached reply ages past 2000 monotonic ms.
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    final stale = producer.healthSnapshot;
    expect(stale.known, isTrue);
    expect(stale.stale, isTrue);
    expect(stale.ageMs, greaterThan(2000));
    expect(stale.state, DiagnosticHealthState.unknown);
    // A stale reply retains its last reason and counters.
    expect(stale.reason, fresh.reason);
    expect(stale.slot, fresh.slot);
    expect(stale.admittedRecords, fresh.admittedRecords);
    expect(producer.healthRequestStateForTesting, (2, 2));
    await _until(() => producer.healthRequestStateForTesting.$2 == 0);
    expect(producer.healthSnapshot.stale, isFalse);
    expect(producer.healthSnapshot.state, DiagnosticHealthState.healthy);

    producer.close();
    await producer.retired.timeout(const Duration(seconds: 2));
    final retired = producer.healthRequestStateForTesting;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 260));
      producer.healthSnapshot;
    }
    expect(producer.healthRequestStateForTesting, retired);
  });

  test(
    'a held owner leaves exactly one pending request under repeated reads',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await _storedSession(capture);
      final reports = ReceivePort();
      addTearDown(reports.close);
      final messages = StreamIterator(reports);
      addTearDown(messages.cancel);
      final owned = await session.spawnProducer(
        DiagnosticProducerKind.domain,
        _heldOwner,
        reports.sendPort,
      );
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      final hold = messages.current as List;
      expect(hold[0], 'hold');
      (hold[1] as SendPort).send(null);
      // The owner's event loop cannot answer while it spins.
      _spin(1500);
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      final report = messages.current as List;
      final known = (report[0] as List).cast<int>();
      expect(known, [1, 0]);
      final held = (report[1] as List).map((e) => (e as List).cast<int>());
      expect(held, isNotEmpty);
      // Every read during the hold observed the same single pending nonce.
      for (final [nonce, pending, isKnown] in held) {
        expect(nonce, 2);
        expect(pending, 2);
        expect(isKnown, 1);
      }
      // After release the one queued request was answered exactly once.
      expect((report[2] as List).cast<int>(), [2, 0]);
      await owned.retired.timeout(const Duration(seconds: 2));
    },
  );

  test('a held writer does not accumulate health traffic', () async {
    final entered = ReceivePort(), finished = ReceivePort();
    addTearDown(entered.close);
    addTearDown(finished.close);
    var writerFinished = false;
    finished.listen((_) => writerFinished = true);
    final enter = entered.first;
    final session = await LoggingSession.startForTesting(
      configuration: _info,
      profilePath: 'private-profile',
      role: DiagnosticRole.desktop,
      sinkFactory: _heldWriterSink(entered.sendPort, finished.sendPort),
    );
    addTearDown(session.close);
    // The entrypoint owns the initial pool; ready alone promises no credits.
    final producer = session.producer;
    await producer.ready.timeout(const Duration(seconds: 2));
    // The error record makes the writer's real flush call the held sink.
    expect(
      producer.emit(DiagnosticEvent.runtimeFailed, DiagnosticComponent.domain),
      isTrue,
    );
    await enter.timeout(const Duration(seconds: 2));
    expect(writerFinished, isFalse);
    final elapsed = Stopwatch()..start();
    var reads = 0, heldReads = 0, maximumPending = 0;
    while (elapsed.elapsedMilliseconds < 1000) {
      producer.healthSnapshot;
      session.healthSnapshot;
      reads++;
      if (!writerFinished) heldReads++;
      final (_, pending) = producer.healthRequestStateForTesting;
      if (pending > maximumPending) maximumPending = pending;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final (nonce, _) = producer.healthRequestStateForTesting;
    expect(reads, greaterThan(50));
    expect(heldReads, greaterThan(50));
    // Requests are bounded by the monotonic throttle, not by reads.
    expect(nonce, inInclusiveRange(1, elapsed.elapsedMilliseconds ~/ 250 + 1));
    expect(maximumPending, nonce);
    expect(producer.healthSnapshot.known, isTrue);
    producer.close();
    await producer.retired.timeout(const Duration(seconds: 3));
  });

  test(
    'a copied capability in a foreign VM never sends a health request',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await _storedSession(capture);
      final reports = ReceivePort();
      addTearDown(reports.close);
      final owned = await session.spawnProducer(
        DiagnosticProducerKind.domain,
        _forwardToForeignVm,
        reports.sendPort,
      );
      final report =
          await reports.first.timeout(const Duration(seconds: 5)) as List;
      for (final encoded in report.take(2)) {
        final snapshot = DiagnosticHealthSnapshot.tryParse(
          jsonDecode(encoded as String),
        )!;
        expect(snapshot.known, isFalse);
        expect(snapshot.state, DiagnosticHealthState.unknown);
      }
      expect(report[2], 0);
      expect(report[3], 0);
      await owned.retired.timeout(const Duration(seconds: 2));
    },
  );
}
