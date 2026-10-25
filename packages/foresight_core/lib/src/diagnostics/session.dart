import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'events.dart';
import 'storage.dart';
import 'storage_worker.dart';
import 'storage_worker_native.dart';
import 'storage_worker_protocol.dart';

export 'configuration.dart';
export 'events.dart';
export 'storage_worker.dart';
export 'storage.dart'
    show DiagnosticRole, OwnershipDecision, DiagnosticHealthReason;

part 'producer.dart';
part 'producer_owner.dart';
part 'producer_ledger.dart';
part 'producer_budget.dart';

const _normalBytes = 4 * 1024, _priorityBytes = 8 * 1024;
// 224 producer tickets plus32 sequential writer/internal tickets.
const _normalRecords = 10, _priorityRecords = 4;
const _maximumCounter = 0x7fffffff;
int _sum(int a, int b) => (a + b).clamp(0, _maximumCounter);
int _cost(int length) => length * 4 + 256;

/// Health contains only closed reasons, bounded counters and slot number.
final class DiagnosticHealth {
  DiagnosticHealthReason reason = DiagnosticHealthReason.healthy;
  int admitted = 0,
      dropped = 0,
      rejected = 0,
      highWaterBytes = 0,
      highWaterRecords = 0;
  int producerRegistrationRefused = 0, quarantinedProducers = 0;
  int? slot;
  bool closed = false;
  Map<String, Object?> toJson() => {
    'reason': reason.name,
    'closed': closed,
    'admitted': admitted,
    'dropped': dropped,
    'rejected': rejected,
    'high_water_bytes': highWaterBytes,
    'high_water_records': highWaterRecords,
    'slot': slot,
    'producer_registration_refused': producerRegistrationRefused,
    'producer_quarantined': quarantinedProducers,
  };
}

final class LoggingCloseResult {
  const LoggingCloseResult({
    required this.writerExited,
    required this.flushed,
    this.ownerSettled = true,
  });
  final bool writerExited, flushed, ownerSettled;
  bool get requiresExplicitExit => !writerExited || !ownerSettled;
}

DiagnosticLevel _severity(Map value) {
  final category = (value['fields'] as Map)['category'];
  if (category == DiagnosticCategory.cancelled.name) {
    return DiagnosticLevel.debug;
  }
  if (category == DiagnosticCategory.closing.name) return DiagnosticLevel.info;
  return DiagnosticEvent.values
      .firstWhere((event) => event.wire == value['event'])
      .severity;
}

/// Session-owned control metadata is independent of producer credits and
/// unregister. Pass one reporter to the actual acquisition guard; the worker
/// sends its decision before its completion barrier on this same control path.
final class DiagnosticOwnershipReporter {
  DiagnosticOwnershipReporter._(this._writer);
  final SendPort? _writer;
  bool _sent = false;
  void report(OwnershipDecision decision) {
    if (_sent) return;
    _sent = true;
    _writer?.send(['ownership', decision.index]);
  }

  void terminalUnknown() => report(OwnershipDecision.unknown);
}

/// The entrypoint owns this registry/session once per process and passes only
/// producer bootstraps to isolates. Feature code cannot obtain a close handle
/// through a producer. Repeated start/Retry returns this same process session.
final class LoggingSession {
  LoggingSession._(
    this.configuration,
    this.identity,
    this._writer,
    this._isolate,
    this._status,
    this._errors,
    this._exited,
    this.health,
  );
  static Future<LoggingSession>? _processSession;
  static const maximumProducers = 16;
  static const maximumOutstandingBytes = 512 * 1024;
  static const maximumOutstandingRecords = 256;
  static const maximumProducerEventBytes =
      _normalPoolBytes + _priorityPoolBytes;
  static const maximumProducerEventRecords =
      _normalPoolRecords + _priorityPoolRecords;
  static const maximumEncodingScratchBytes = 144 * 1024;
  static const maximumIpcBytes = 160 * 1024;
  static const maximumControlBytes = 16 * 1024;
  static const closeDeadline = Duration(milliseconds: 500);
  final DiagnosticConfiguration configuration;
  final DiagnosticIdentity identity;
  final SendPort? _writer;
  final Isolate? _isolate;
  final RawReceivePort? _status, _errors;
  final Completer<void> _exited;
  final DiagnosticHealth health;
  late final DiagnosticProducer producer;
  final _slots = List<_OwnedProducer?>.filled(maximumProducers, null);
  final _generations = Uint64List(maximumProducers);
  late final _inactiveBootstrap = DiagnosticProducerBootstrap._(
    null,
    -1,
    0,
    DiagnosticProducerKind.entrypoint,
    configuration,
  );
  late final _inactiveReservation = DiagnosticProducerReservation._(this, null);
  bool _registrationPending = false;
  int _registrationSent = 0;
  @visibleForTesting
  int get retainedProducerCount => _slots.where((s) => s?.local != null).length;
  @visibleForTesting
  int get retainedSlotCount => _slots.where((s) => s != null).length;
  bool _ownershipExpected = false,
      _closed = false,
      _flushed = false,
      _closeAcknowledged = false;
  Future<LoggingCloseResult>? _close;
  _DiagnosticCoordinator? _coordinator;

  static Future<LoggingSession> start({
    required DiagnosticConfiguration configuration,
    String? profilePath,
    DiagnosticRole role = DiagnosticRole.candidate,
    String version = 'unknown',
    String revision = 'unknown',
    DiagnosticWorkerFactory? workerFactory,
  }) => _processSession ??= _start(
    configuration,
    profilePath,
    role == DiagnosticRole.service ? DiagnosticRole.candidate : role,
    version,
    revision,
    workerFactory: workerFactory,
  );
  @visibleForTesting
  static Future<LoggingSession> startForTesting({
    required DiagnosticConfiguration configuration,
    String? profilePath,
    DiagnosticRole role = DiagnosticRole.candidate,
    DiagnosticSinkFactory? sinkFactory,
    DiagnosticWorkerFactory? workerFactory,
    DateTime Function()? clock,
    int generationSeed = 0,
  }) => _start(
    configuration,
    profilePath,
    role,
    'unknown',
    'unknown',
    sinkFactory: sinkFactory,
    workerFactory: workerFactory,
    clock: clock,
    generationSeed: generationSeed,
  );

  static Future<LoggingSession> _start(
    DiagnosticConfiguration configuration,
    String? profile,
    DiagnosticRole role,
    String version,
    String revision, {
    DiagnosticSinkFactory? sinkFactory,
    DiagnosticWorkerFactory? workerFactory,
    DateTime Function()? clock,
    int generationSeed = 0,
  }) async {
    if (sinkFactory != null && workerFactory != null) {
      throw ArgumentError('Select one explicit diagnostic test sink or worker');
    }
    if (generationSeed < 0 || generationSeed >= _maximumGeneration) {
      throw ArgumentError.value(generationSeed, 'generationSeed');
    }
    final identity = DiagnosticIdentity.random();
    final health = DiagnosticHealth();
    if (!configuration.enabled) {
      health.reason = DiagnosticHealthReason.off;
      final session = LoggingSession._(
        configuration,
        identity,
        null,
        null,
        null,
        null,
        Completer<void>()..complete(),
        health,
      );
      session.producer = session
          .reserveProducer(DiagnosticProducerKind.entrypoint)
          .connect();
      return session;
    }
    // Build identities never come through as arbitrary environment text.
    if (!RegExp(
          r'^(unknown|[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.]{1,20})?)$',
        ).hasMatch(version) ||
        version.length > 48) {
      version = 'unknown';
    }
    if (!RegExp(r'^(unknown|[a-f0-9]{40})$').hasMatch(revision)) {
      revision = 'unknown';
    }
    final bootstrap = ReceivePort();
    final exited = Completer<void>();
    late LoggingSession session;
    LoggingSession? currentSession;
    final errors = RawReceivePort((dynamic _) {})..keepIsolateAlive = false;
    final status = RawReceivePort((dynamic value) {
      if (value == null) {
        if (!exited.isCompleted) exited.complete();
        currentSession?._coordinator?.writerDidExit();
        final active = currentSession;
        if (active == null || !active._closed || !active._closeAcknowledged) {
          health.reason = DiagnosticHealthReason.writerFailed;
        }
        if (active != null) {
          for (final slot in active._slots) {
            slot?.local?._shutdown();
          }
        }
        return;
      }
      if (value is! List || value.isEmpty) return;
      if (value.first == 'worker_probe' && value.length == 1) {
        currentSession?._coordinator?.probe();
        return;
      }
      if (value.first == 'worker_request' && value.length == 4) {
        currentSession?._coordinator?.request(value);
        return;
      }
      if (value.first == 'retired' && value.length == 4 && value[3] == 0) {
        currentSession?._retired(value[1] as int, value[2] as int);
        return;
      }
      if (value.first == 'registration_refused_ack' && value.length == 2) {
        final active = currentSession;
        if (active != null && value[1] == active._registrationSent) {
          active._registrationPending = false;
          if (health.producerRegistrationRefused > (value[1] as int)) {
            active._registrationEdge();
          }
        }
        return;
      }
      if (value.first == 'closed' && value.length == 10) {
        session._closeAcknowledged = true;
        session._flushed = value[1] as bool;
        health.reason = DiagnosticHealthReason.values[value[8] as int];
        health.quarantinedProducers = value[9] as int;
        health.admitted = value[2] as int;
        health.dropped = value[3] as int;
        health.rejected = value[4] as int;
        health.highWaterBytes = value[5] as int;
        health.highWaterRecords = value[6] as int;
        health.slot = value[7] as int?;
        return;
      }
      if (value.first == 'health' && value.length == 9) {
        health.reason = DiagnosticHealthReason.values[value[1] as int];
        health.admitted = value[2] as int;
        health.dropped = value[3] as int;
        health.rejected = value[4] as int;
        health.highWaterBytes = value[5] as int;
        health.highWaterRecords = value[6] as int;
        health.slot = value[7] as int?;
        health.quarantinedProducers = value[8] as int;
        session._writer?.send(['health_ack']);
      }
      // onError carries arbitrary exception text/stack. Ignore it entirely;
      // onExit supplies the constant writerFailed health classification.
    })..keepIsolateAlive = false;
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _writerMain,
        [
          bootstrap.sendPort,
          status.sendPort,
          configuration,
          identity.value,
          profile,
          role.index,
          version,
          revision,
          sinkFactory,
          clock,
        ],
        onExit: status.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
        debugName: 'diagnostic-writer',
      );
      final port = await bootstrap.first.timeout(closeDeadline) as SendPort;
      session = LoggingSession._(
        configuration,
        identity,
        port,
        isolate,
        status,
        errors,
        exited,
        health,
      );
      if (!DiagnosticProducer._selectWriter(port)) {
        throw StateError('Diagnostic writer context is already active');
      }
      currentSession = session;
      session._coordinator = _DiagnosticCoordinator(
        factory: workerFactory,
        writer: port,
        configuration: configuration,
        identity: identity,
        version: version,
        revision: revision,
        writerExited: exited.future,
      );
      session._generations.fillRange(0, maximumProducers, generationSeed);
      session.producer = session
          .reserveProducer(DiagnosticProducerKind.entrypoint)
          .connect();
      session._slots[session.producer.slot]!.local = session.producer;
      await session.producer.ready.timeout(closeDeadline);
      if (configuration.invalidLevel) {
        session.producer.emit(
          DiagnosticEvent.invalidConfiguration,
          DiagnosticComponent.logging,
        );
      }
      return session;
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      // Once a VM was created, a kill request is not its exit barrier. Retain
      // the non-keepalive observer and actual handle for final bounded close.
      if (isolate == null || exited.isCompleted) {
        status.close();
        errors.close();
      }
      if (isolate == null && !exited.isCompleted) exited.complete();
      health.reason = DiagnosticHealthReason.writerFailed;
      session = LoggingSession._(
        configuration,
        identity,
        null,
        isolate,
        isolate == null ? null : status,
        isolate == null ? null : errors,
        exited,
        health,
      );
      currentSession = session;
      session.producer = session
          .reserveProducer(DiagnosticProducerKind.entrypoint)
          .connect();
      return session;
    } finally {
      bootstrap.close();
    }
  }

  DiagnosticProducerBootstrap reserveProducer(DiagnosticProducerKind kind) =>
      _reserve(kind)?.bootstrap ?? _inactiveBootstrap;

  DiagnosticProducerReservation reserveProducerForSpawn(
    DiagnosticProducerKind kind,
  ) {
    final slot = _reserve(kind);
    return slot == null
        ? _inactiveReservation
        : DiagnosticProducerReservation._(this, slot);
  }

  /// Legacy owner observation is deliberately not a VM exit/unwind barrier.
  void producerExited(DiagnosticProducerBootstrap bootstrap) {
    if (_closed || !_current(bootstrap)) return;
    final slot = _slots[bootstrap.id]!;
    if (slot.ownerExitSent) return;
    slot.ownerExitSent = true;
    DiagnosticProducer._denyConnection(
      _writer,
      bootstrap.slot,
      bootstrap.generation,
    );
    _writer?.send(['owner_exit', bootstrap.id, bootstrap.generation, 0]);
  }

  DiagnosticProducer registerProducer(DiagnosticProducerKind kind) {
    final bootstrap =
        _reserve(
          kind,
          executingIsolate: Isolate.current.controlPort,
        )?.bootstrap ??
        _inactiveBootstrap;
    final producer = bootstrap.connect();
    if (_current(bootstrap)) _slots[bootstrap.id]!.local = producer;
    return producer;
  }

  /// The entrypoint is paused until its direct writer exit listener is installed.
  /// Diagnostics refusal never prevents application worker startup.
  Future<DiagnosticOwnedIsolate> spawnProducer<T>(
    DiagnosticProducerKind kind,
    void Function((DiagnosticProducerBootstrap, T)) entrypoint,
    T message, {
    SendPort? onError,
    SendPort? onExit,
    bool errorsAreFatal = true,
    String? debugName,
  }) async {
    return _spawnReserved(
      _reserve(kind),
      entrypoint,
      message,
      onError: onError,
      onExit: onExit,
      errorsAreFatal: errorsAreFatal,
      debugName: debugName,
    );
  }

  Future<DiagnosticOwnedIsolate> _spawnReserved<T>(
    _OwnedProducer? slot,
    void Function((DiagnosticProducerBootstrap, T)) entrypoint,
    T message, {
    SendPort? onError,
    SendPort? onExit,
    bool errorsAreFatal = true,
    String? debugName,
  }) async {
    if (_closed || (slot != null && !_current(slot.bootstrap))) slot = null;
    final bootstrap = slot?.bootstrap ?? _inactiveBootstrap;
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _activateProducer<T>,
        (bootstrap, entrypoint, message),
        paused: true,
        onError: onError,
        onExit: onExit,
        errorsAreFatal: errorsAreFatal,
        debugName: debugName,
      );
      bootstrap._executionVm = isolate.controlPort;
      if (_current(bootstrap)) {
        _writer?.send([
          'bind_vm',
          bootstrap.slot,
          bootstrap.generation,
          0,
          isolate.controlPort,
        ]);
      }
      if (!bootstrap._observeExit(isolate)) producerExited(bootstrap);
      isolate.resume(isolate.pauseCapability!);
      return DiagnosticOwnedIsolate._(
        isolate,
        bootstrap,
        slot?.retired ?? _inactiveBootstrap.connect().retired,
      );
    } catch (_) {
      if (isolate == null) {
        // Paused spawn never exposed the capability to executing Dart code.
        _cancelNeverExposed(bootstrap);
      } else {
        // Once a VM exists, only its ordered exit or terminal may refund.
        isolate.kill(priority: Isolate.immediate);
        producerExited(bootstrap);
      }
      rethrow;
    }
  }

  @visibleForTesting
  Future<DiagnosticBudgetSnapshot> inspectBudgetForTesting() async {
    if (_writer == null) {
      return DiagnosticBudgetSnapshot._([0, 0, 0, 0, 0, 0, const []]);
    }
    if (_closed) throw StateError('Diagnostic budget unavailable during close');
    final reply = ReceivePort();
    try {
      _writer.send(['inspect_budget', reply.sendPort]);
      return DiagnosticBudgetSnapshot._(
        await reply.first.timeout(closeDeadline) as List,
      );
    } finally {
      reply.close();
    }
  }

  void selectProfile(String canonicalProfile) {
    if (!_closed) _writer?.send(['profile', canonicalProfile]);
  }

  DiagnosticOwnershipReporter expectOwnershipDecision() {
    if (_ownershipExpected) return DiagnosticOwnershipReporter._(null);
    if (!_closed && !_ownershipExpected) {
      _ownershipExpected = true;
      _writer?.send(['expect_ownership']);
    }
    return DiagnosticOwnershipReporter._(_closed ? null : _writer);
  }

  void ownershipWorkerTerminated() {
    // Completion may follow close. This session control path remains alive
    // independently of producer ports until the external close deadline.
    _writer?.send(['ownership', OwnershipDecision.unknown.index]);
  }

  /// Call only after application/client/child cleanup and intentional output
  /// disposition. The result tells standalone entrypoints whether they must
  /// perform their same-code exit fallback; this library never exits an app.
  Future<LoggingCloseResult> close() => _close ??= _finishClose();
  Future<LoggingCloseResult> _finishClose() async {
    _closed = true;
    if (!configuration.enabled) {
      health.closed = true;
      return const LoggingCloseResult(writerExited: true, flushed: true);
    }
    final elapsed = Stopwatch()..start();
    _coordinator?.beginClose(elapsed);
    for (final slot in _slots) {
      slot?.local?.close();
    }
    // Local terminal microtasks must run after any synchronous encoder unwinds.
    await Future<void>.delayed(Duration.zero);
    _writer?.send(['close']);
    var writerExited = _exited.isCompleted;
    try {
      await _exited.future.timeout(
        Duration(
          microseconds:
              (closeDeadline.inMicroseconds - elapsed.elapsedMicroseconds)
                  .clamp(0, closeDeadline.inMicroseconds),
        ),
      );
      writerExited = true;
    } on TimeoutException {
      health.reason = DiagnosticHealthReason.writerFailed;
      _isolate?.kill(priority: Isolate.immediate);
    }
    DiagnosticWorkerCloseResult? ownerResult;
    final coordinator = _coordinator;
    if (coordinator != null) {
      try {
        ownerResult = await coordinator.finish().timeout(
          Duration(
            microseconds:
                (closeDeadline.inMicroseconds - elapsed.elapsedMicroseconds)
                    .clamp(0, closeDeadline.inMicroseconds),
          ),
        );
      } on TimeoutException {
        coordinator.force();
      }
      if (ownerResult != null &&
          coordinator.ownerCreated &&
          !ownerResult.retired &&
          health.reason == DiagnosticHealthReason.healthy) {
        health.reason = ownerResult.reason;
      }
    }
    if (_exited.isCompleted) {
      _status?.close();
      _errors?.close();
    } else {
      // Retain the non-keepalive exit observation through a late native return;
      // a kill request or the external deadline is not an actual VM exit.
      unawaited(
        _exited.future.then((_) {
          _status?.close();
          _errors?.close();
        }),
      );
    }
    health.closed = true;
    if (health.reason == DiagnosticHealthReason.healthy) {
      health.reason = DiagnosticHealthReason.closed;
    }
    return LoggingCloseResult(
      writerExited: writerExited,
      flushed:
          (_flushed || _writer == null) &&
          (coordinator?.ownerCreated != true || ownerResult?.retired == true),
      ownerSettled:
          ownerResult?.ownerSettled ?? coordinator?.ownerSettled ?? true,
    );
  }

  @visibleForTesting
  static Future<void> resetForTesting() async {
    final session = _processSession;
    if (session != null) await (await session).close();
    _processSession = null;
  }
}

/// The application coordinator never blocks in file/prepare/spawn FFI. Its
/// ports do not keep the VM alive; the native owner observes actual parent work
/// separately from child-only unknown health.
final class _DiagnosticCoordinator {
  _DiagnosticCoordinator({
    required this.factory,
    required this.writer,
    required this.configuration,
    required this.identity,
    required this.version,
    required this.revision,
    required this.writerExited,
  });
  final DiagnosticWorkerFactory? factory;
  final SendPort writer;
  final DiagnosticConfiguration configuration;
  final DiagnosticIdentity identity;
  final String version, revision;
  final Future<void> writerExited;
  DiagnosticWorkerOwner? _owner;
  bool _attempted = false, _forced = false, _writerGone = false;
  int? _pending;
  bool _notified = false;
  Stopwatch? _closing;
  Timer? _forceDeadline;
  Future<DiagnosticWorkerCloseResult>? _finish;
  DiagnosticHealthReason _failure =
      DiagnosticHealthReason.storageWorkerUnconfigured;
  bool get ownerCreated => _owner != null;
  DiagnosticWorkerSnapshot get _snapshot {
    try {
      return _owner?.snapshot ?? const DiagnosticWorkerSnapshot();
    } catch (_) {
      return const DiagnosticWorkerSnapshot(
        parentSettled: false,
        reason: DiagnosticHealthReason.storageWorkerUnknown,
      );
    }
  }

  bool get ownerSettled => _snapshot.parentSettled;

  Future<int> _prepare(List<int> addresses, int generation) async {
    final done = Completer<int>();
    final port = RawReceivePort((dynamic result) {
      if (!done.isCompleted) {
        if (result is int) {
          done.complete(result);
        } else {
          done.completeError(
            const DiagnosticWorkerFailure(
              DiagnosticHealthReason.storageWorkerProtocolFailed,
            ),
          );
        }
      }
    })..keepIsolateAlive = false;
    // One attempt only; this single exit listener is bounded for the process.
    unawaited(
      writerExited.then((_) {
        if (!done.isCompleted) {
          done.completeError(
            const DiagnosticWorkerFailure(
              DiagnosticHealthReason.writerFailed,
              disposed: true,
            ),
          );
        }
      }),
    );
    try {
      if (_writerGone || _forced) {
        throw const DiagnosticWorkerFailure(
          DiagnosticHealthReason.writerFailed,
          disposed: true,
        );
      }
      writer.send(['native_prepare', addresses, generation, port.sendPort]);
      return await done.future;
    } finally {
      port.close();
    }
  }

  void request(List message) {
    final id = message[1] as int;
    if (_forced || _pending != null) {
      writer.send([
        'worker_failure',
        id,
        DiagnosticHealthReason.storageWorkerUnknown.index,
        _owner == null || _snapshot.childNotLive,
      ]);
      return;
    }
    if (!_attempted) {
      _attempted = true;
      try {
        _owner = factory?.call(
          DiagnosticStorageLaunchContext(
            configuration: configuration,
            session: identity,
            applicationPid: pid,
            version: version,
            revision: revision,
            prepare: _prepare,
            writerExited: writerExited,
          ),
        );
      } on DiagnosticWorkerFailure catch (error) {
        _failure = error.reason;
      } catch (_) {
        _failure = DiagnosticHealthReason.storageWorkerLaunchFailed;
      }
    }
    final owner = _owner;
    if (owner == null) {
      writer.send(['worker_failure', id, _failure.index, true]);
      return;
    }
    _pending = id;
    _notified = false;
    Future<void> run() async {
      try {
        final reply = await owner.request(
          DiagnosticWorkerRequest(message[2] as int, message[3] as Uint8List),
        );
        if (!_notified && !_writerGone) {
          final encoded = reply.encode();
          final buildId = _snapshot.buildId;
          _notified = true;
          writer.send(['worker_reply', id, encoded, buildId]);
        }
      } catch (error) {
        final failure = error is DiagnosticWorkerFailure
            ? error
            : const DiagnosticWorkerFailure(
                DiagnosticHealthReason.storageWorkerUnknown,
              );
        if (!_notified && !_writerGone) {
          _notified = true;
          writer.send([
            'worker_failure',
            id,
            failure.reason.index,
            failure.disposed || _snapshot.childNotLive,
          ]);
        }
      } finally {
        if (_pending == id) _pending = null;
      }
    }

    unawaited(run());
  }

  void probe() {
    final state = _snapshot;
    if (_writerGone) return;
    if (!state.childNotLive &&
        state.reason == DiagnosticHealthReason.storageWorkerUnknown &&
        !_forced) {
      force();
    }
    writer.send(['worker_probe_reply', state.childNotLive, state.reason.index]);
  }

  void beginClose(Stopwatch elapsed) {
    if (_closing != null) return;
    _closing = elapsed;
    _forceDeadline = Timer(const Duration(milliseconds: 300), force);
  }

  void force() {
    _forced = true;
    try {
      _owner?.force();
    } catch (_) {
      _failure = DiagnosticHealthReason.storageWorkerUnknown;
    }
    final id = _pending;
    if (id != null && !_notified && !_writerGone) {
      _notified = true;
      writer.send([
        'worker_failure',
        id,
        DiagnosticHealthReason.storageWorkerUnknown.index,
        _owner == null || _snapshot.childNotLive,
      ]);
    }
  }

  void writerDidExit() {
    _writerGone = true;
    if (_closing == null) force();
  }

  Future<DiagnosticWorkerCloseResult> finish() => _finish ??= _finishOwner();
  Future<DiagnosticWorkerCloseResult> _finishOwner() async {
    final owner = _owner;
    if (owner == null) {
      _forceDeadline?.cancel();
      return const DiagnosticWorkerCloseResult();
    }
    final elapsed = _closing?.elapsed ?? const Duration(milliseconds: 300);
    final normal = Duration(
      microseconds: (300000 - elapsed.inMicroseconds).clamp(0, 300000),
    );
    final total = Duration(
      microseconds: (500000 - elapsed.inMicroseconds).clamp(0, 500000),
    );
    try {
      return await owner.close(normalBudget: normal, totalBudget: total);
    } catch (_) {
      force();
      return DiagnosticWorkerCloseResult(
        ownerSettled: _snapshot.parentSettled,
        childNotLive: _snapshot.childNotLive,
        reaped: _snapshot.reaped,
        reason: DiagnosticHealthReason.storageWorkerUnknown,
      );
    } finally {
      _forceDeadline?.cancel();
    }
  }
}

// Dense closed-schema state: no per-key objects, allocation or eviction. Summary
// coordinates already saturate at the public numeric bound; windows remain 64-bit.
final class _RateState {
  _RateState._(this.offsets, this.windows, this.values);
  factory _RateState() {
    final offsets = Uint16List(DiagnosticEvent.values.length + 1);
    for (final event in DiagnosticEvent.values) {
      offsets[event.index + 1] =
          offsets[event.index] +
          (event.fields.contains(DiagnosticField.category)
              ? DiagnosticCategory.values.length
              : 1);
    }
    final keys = offsets.last;
    // Include conservative typed-array/object headers in the control envelope.
    if (offsets.lengthInBytes + keys * 24 + 256 > 4096) {
      throw StateError('Diagnostic rate metadata exceeds its fixed budget');
    }
    return _RateState._(offsets, Uint64List(keys), Uint32List(keys * 4));
  }
  final Uint16List offsets;
  final Uint64List windows;
  final Uint32List values;

  int key(DiagnosticEvent event, DiagnosticCategory category) =>
      offsets[event.index] +
      (offsets[event.index + 1] - offsets[event.index] == 1
          ? 0
          : category.index);
  bool admit(DiagnosticEvent event, DiagnosticCategory category, int now) {
    final index = key(event, category), at = index * 4, window = now ~/ 1000;
    if (windows[index] != window) {
      windows[index] = window;
      values[at] = 0;
    }
    values[at] = _sum(values[at], 1);
    if (values[at] <= 8) return true;
    final bounded = now.clamp(0, _maximumCounter);
    if (values[at + 1] == 0) values[at + 2] = bounded;
    values[at + 3] = bounded;
    values[at + 1] = _sum(values[at + 1], 1);
    return false;
  }

  bool get pending {
    for (var at = 1; at < values.length; at += 4) {
      if (values[at] != 0) return true;
    }
    return false;
  }
}

final class _QueuedRecord {
  _QueuedRecord(this.encoded, this.producer, this.charge, this.priority);
  final String encoded;
  final DiagnosticProducerSnapshot producer;
  final int charge;
  final bool priority;
}

void _writerMain(List<Object?> arguments) {
  final receive = ReceivePort();
  (arguments[0] as SendPort).send(receive.sendPort);
  final state = _Writer(
    receive,
    arguments[1] as SendPort,
    arguments[2] as DiagnosticConfiguration,
    arguments[3] as String,
    arguments[4] as String?,
    DiagnosticRole.values[arguments[5] as int],
    arguments[6] as String,
    arguments[7] as String,
    arguments[8] as DiagnosticSinkFactory?,
    arguments[9] as DateTime Function()?,
  );
  receive.listen(state.handle);
  state.creditTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    state.ledger.rebalance();
    state.probe();
  });
  state.timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
    state.heartbeat();
    state.flush();
  });
}

final class _Writer {
  _Writer(
    this.receive,
    this.owner,
    this.configuration,
    this.session,
    this.profile,
    this.role,
    this.version,
    this.revision,
    this.sinkFactory,
    DateTime Function()? clock,
  ) : clock = clock ?? DateTime.now;
  final ReceivePort receive;
  final SendPort owner;
  final DiagnosticConfiguration configuration;
  final String session, version, revision;
  final DiagnosticSinkFactory? sinkFactory;
  final DateTime Function() clock;
  String? profile;
  DiagnosticRole role;
  late final ledger = _ProducerLedger(owner, _producerCounters);
  final records = <_QueuedRecord>[];
  final started = Stopwatch()..start();
  final rate = _RateState();
  int pendingDrops = 0, pendingRejected = 0, firstDrop = 0, lastDrop = 0;
  Timer? timer, creditTimer, ownershipCloseDeadline;
  DiagnosticSink? storage;
  DiagnosticHealthReason reason = DiagnosticHealthReason.healthy;
  int dropped = 0,
      rejected = 0,
      admitted = 0,
      sequence = 0,
      charge = 0,
      highBytes = 0,
      highRecords = 0,
      attempts = 0,
      nextAttempt = 0;
  bool healthPending = false,
      closing = false,
      decisionExpected = false,
      decisionReceived = false,
      hadFailure = false,
      hadPriority = false;

  void handle(dynamic value) {
    if (value is! List || value.isEmpty) return;
    if (workerControl(value)) return;
    if (ledger.handle(value)) {
      _captureLedgerHighWater();
      return;
    }
    switch (value.first) {
      case 'inspect_budget':
        _captureLedgerHighWater();
        (value[1] as SendPort).send([
          ledger.normalUsed,
          ledger.priorityUsed,
          ledger.normalTickets,
          ledger.priorityTickets,
          charge,
          records.length,
          [
            for (final p in ledger.slots)
              if (p != null)
                [
                  p.snapshot.slot,
                  p.snapshot.generation,
                  p.normalEpoch,
                  p.priorityEpoch,
                  p.bytes,
                  p.records,
                  p.priority,
                  p.priorityCount,
                  p.quarantined,
                ],
          ],
        ]);
      case 'record':
        if (closing) return;
        final encoded = value[5] as String, cost = value[6] as int;
        final priority = value[7] as bool;
        final producer = ledger.consume(value, cost, priority);
        if (producer == null) return;
        final length = utf8.encode(encoded).length;
        if (length > DiagnosticRecord.maximumProducerRecordBytes ||
            _cost(length) != cost) {
          _producerCounters(0, 1);
          ledger.completed(cost, priority);
          return;
        }
        final map = jsonDecode(encoded);
        _producerCounters(value[8] as int, value[9] as int);
        if (!DiagnosticRecord.validWire(map)) {
          _producerCounters(0, 1);
          ledger.completed(cost, priority);
          return;
        }
        final wire = map as Map<String, dynamic>;
        final severity = _severity(wire);
        final event = DiagnosticEvent.values.firstWhere(
          (event) => event.wire == wire['event'],
        );
        if (!configuration.permits(
          severity,
          transport: event == DiagnosticEvent.transportActivity,
        )) {
          ledger.completed(cost, priority);
          return;
        }
        if (!_admitRate(event, wire) ||
            records.length >= _normalPoolRecords + _priorityPoolRecords ||
            charge + cost > _normalPoolBytes + _priorityPoolBytes) {
          dropped = _sum(dropped, 1);
          ledger.completed(cost, priority);
          return;
        }
        records.add(_QueuedRecord(encoded, producer, cost, priority));
        charge += cost;
        highBytes = highBytes < charge ? charge : highBytes;
        highRecords = highRecords < records.length
            ? records.length
            : highRecords;
        admitted = _sum(admitted, 1);
        if (storage == null &&
            !_admitted &&
            reason == DiagnosticHealthReason.healthy) {
          reason = DiagnosticHealthReason.bootstrapOnly;
        }
        if (severity.index <= DiagnosticLevel.warn.index) hadPriority = true;
        if (severity == DiagnosticLevel.error) hadFailure = true;
        if (severity == DiagnosticLevel.error) scheduleMicrotask(flush);
      // Keep session-owned ownership metadata even after producer completion.
      case 'profile':
        profile ??= value[1] as String;
      case 'expect_ownership':
        if (!decisionReceived) decisionExpected = true;
      case 'ownership':
        if (!decisionReceived) {
          ownershipCloseDeadline?.cancel();
          ownershipCloseDeadline = null;
          decisionReceived = true;
          if (OwnershipDecision.values[value[1] as int] ==
              OwnershipDecision.acquired) {
            role = DiagnosticRole.service;
          }
          flush();
        }
      case 'health_ack':
        healthPending = false;
      case 'close':
        closing = true;
        ledger.close();
        if (decisionExpected && !decisionReceived) {
          ownershipCloseDeadline ??= Timer(
            const Duration(milliseconds: 100),
            () {
              if (decisionReceived) return;
              decisionReceived = true;
              if (role == DiagnosticRole.service) {
                role = DiagnosticRole.candidate;
              }
              flush();
            },
          );
        }
        flush();
    }
  }

  bool _admitRate(DiagnosticEvent event, Map<String, dynamic> value) {
    final category =
        DiagnosticCategory.values
            .where(
              (category) =>
                  category.name == (value['fields'] as Map)['category'],
            )
            .firstOrNull ??
        DiagnosticCategory.unknown;
    return rate.admit(event, category, started.elapsedMilliseconds);
  }

  void _producerCounters(int drops, int rejects) {
    dropped = _sum(dropped, drops);
    rejected = _sum(rejected, rejects);
    if (pendingDrops + pendingRejected == 0 && drops + rejects > 0) {
      firstDrop = started.elapsedMilliseconds;
    }
    if (drops + rejects > 0) lastDrop = started.elapsedMilliseconds;
    pendingDrops = _sum(pendingDrops, drops);
    pendingRejected = _sum(pendingRejected, rejects);
  }

  bool get _hasSummaries =>
      configuration.permits(DiagnosticLevel.warn) &&
      (pendingDrops + pendingRejected > 0 || rate.pending);

  Iterable<_QueuedRecord> _summaries() sync* {
    if (!configuration.permits(DiagnosticLevel.warn)) return;
    _QueuedRecord summary(
      DiagnosticEvent event,
      int count,
      int first,
      int last, {
      DiagnosticEvent? original,
      DiagnosticCategory? category,
    }) => _QueuedRecord(
      jsonEncode(
        DiagnosticRecord(
          event,
          DiagnosticComponent.logging,
          fields: {
            DiagnosticField.count: count,
            DiagnosticField.firstMs: first.clamp(0, _maximumCounter),
            DiagnosticField.lastMs: last.clamp(0, _maximumCounter),
            if (original != null) DiagnosticField.event: original,
            if (category != null) DiagnosticField.category: category,
          },
        ).toWire()!,
      ),
      const DiagnosticProducerSnapshot.writer(),
      0,
      false,
    );
    if (pendingDrops > 0) {
      final count = pendingDrops;
      pendingDrops = 0;
      yield summary(DiagnosticEvent.recordsDropped, count, firstDrop, lastDrop);
    }
    if (pendingRejected > 0) {
      final count = pendingRejected;
      pendingRejected = 0;
      yield summary(DiagnosticEvent.recordRejected, count, firstDrop, lastDrop);
    }
    for (final event in DiagnosticEvent.values) {
      final count = rate.offsets[event.index + 1] - rate.offsets[event.index];
      for (var category = 0; category < count; category++) {
        final at = (rate.offsets[event.index] + category) * 4;
        final suppressed = rate.values[at + 1];
        if (suppressed == 0) continue;
        rate.values[at + 1] = 0;
        yield summary(
          DiagnosticEvent.recordsDropped,
          suppressed,
          rate.values[at + 2],
          rate.values[at + 3],
          original: event,
          category: count == 1
              ? DiagnosticCategory.unknown
              : DiagnosticCategory.values[category],
        );
      }
    }
  }

  void _captureLedgerHighWater() {
    if (ledger.normalUsed < 0 ||
        ledger.normalUsed > _normalPoolBytes ||
        ledger.priorityUsed < 0 ||
        ledger.priorityUsed > _priorityPoolBytes ||
        ledger.normalTickets < 0 ||
        ledger.normalTickets > _normalPoolRecords ||
        ledger.priorityTickets < 0 ||
        ledger.priorityTickets > _priorityPoolRecords) {
      throw StateError('Diagnostic credit ledger invariant failed');
    }
    if (ledger.usedBytes > highBytes) highBytes = ledger.usedBytes;
    if (ledger.usedRecords > highRecords) highRecords = ledger.usedRecords;
  }

  void _health() {
    _captureLedgerHighWater();
    if (healthPending || closing) return;
    healthPending = true;
    owner.send([
      'health',
      reason.index,
      admitted,
      dropped,
      rejected,
      highBytes,
      highRecords,
      storage?.slot ?? _remoteSlot,
      ledger.quarantined,
    ]);
  }

  Uint8List _encode(_QueuedRecord record) {
    if (sequence >= 0x7fffffffffffffff) {
      throw StateError('Diagnostic sequence exhausted');
    }
    final value = jsonDecode(record.encoded) as Map<String, dynamic>;
    final producer = record.producer;
    final severity = _severity(value);
    return Uint8List.fromList(
      utf8.encode(
        '${jsonEncode({'schema': sinkFactory == null ? 2 : 1, 'timestamp': clock().toUtc().toIso8601String(), 'sequence': ++sequence, 'level': severity.name, 'version': version, 'revision': revision, 'session': session, 'pid': pid, 'producer': sinkFactory == null ? '${producer.kind.name}:${producer.slot}:${producer.generation}' : '${producer.kind.name}:${producer.slot}', if (sinkFactory == null) 'build_id': _buildId, ...value})}\n',
      ),
    );
  }

  DiagnosticNativeFunctions? _nativeFunctions;
  int _nativeGeneration = 0;
  int _workerRequestId = 0;
  Completer<DiagnosticWorkerReply>? _reply;
  String? _buildId;
  int? _remoteSlot;
  bool _flushing = false,
      _finished = false,
      _initialized = false,
      _admitted = false,
      _remoteDisabled = false,
      _unknown = false;
  _QueuedRecord? _inFlight, _pendingSummary;
  bool _probePending = false, _disposed = false;
  (DiagnosticRole, bool, bool)? _classification;

  void heartbeat() {
    // Only the existing writer tick supplies the native child lease. The
    // coordinator/spawn owners never keep an idle writer alive for it.
    if (_nativeGeneration != 0) _nativeFunctions?.heartbeat(_nativeGeneration);
  }

  void probe() {
    if (_initialized && !_finished && !_probePending) {
      _probePending = true;
      owner.send(['worker_probe']);
    }
  }

  void _disposalHealth() {
    if (reason == DiagnosticHealthReason.healthy ||
        reason == DiagnosticHealthReason.bootstrapOnly ||
        reason == DiagnosticHealthReason.storageWorkerUnknown) {
      reason = DiagnosticHealthReason.storageWorkerExited;
    }
  }

  void _disposeConfirmed() {
    // Let an active native request consume a matching final ACK first. Actual
    // native requests settle promptly after observed exit; an earlier unknown
    // request has no pending Future and can be disposed immediately.
    if (!_disposed || _reply != null || _inFlight != null) return;
    _unknown = false;
    dropped = _sum(dropped, records.length);
    _discard();
    _pendingSummary = null;
    _disposalHealth();
  }

  bool workerControl(List value) {
    switch (value.first) {
      case 'worker_probe_reply':
        if (value.length == 3 && _probePending) {
          _probePending = false;
          final observed = DiagnosticHealthReason.values[value[2] as int];
          if (value[1] == true) {
            _disposed = true;
            _remoteDisabled = true;
            // An earlier failed APPEND is now authoritatively disposed.
            if (_reply == null) _inFlight = null;
            _disposeConfirmed();
            _health();
          } else if (observed == DiagnosticHealthReason.storageWorkerUnknown) {
            _remoteDisabled = true;
            if (reason == DiagnosticHealthReason.healthy ||
                reason == DiagnosticHealthReason.bootstrapOnly) {
              reason = observed;
            }
            _health();
          }
        }
        return true;
      case 'native_prepare':
        final functions = DiagnosticNativeFunctions.fromCodeAddresses(
          (value[1] as List).cast<int>(),
        );
        final generation = value[2] as int;
        var result = DiagnosticNativeFunctions.error;
        try {
          // Synchronous/blocking preparation is isolated from the application
          // coordinator, which already owns this native context and can FORCE.
          result = functions.prepare(generation);
          if (result == DiagnosticNativeFunctions.prepared) {
            _nativeFunctions = functions;
            _nativeGeneration = generation;
          }
        } catch (_) {
          // No arbitrary exception or native text crosses the control channel.
        } finally {
          (value[3] as SendPort).send(result);
        }
        return true;
      case 'worker_reply':
        if (value.length == 4 &&
            value[1] == _workerRequestId &&
            _reply?.isCompleted == false) {
          try {
            final reply = DiagnosticWorkerReply.decode(value[2] as Uint8List);
            final build = value[3];
            if (build != null) {
              if (build is! String ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(build) ||
                  (_buildId != null && build != _buildId)) {
                throw const DiagnosticWorkerFailure(
                  DiagnosticHealthReason.storageWorkerProtocolFailed,
                );
              }
              _buildId = build;
            }
            _reply!.complete(reply);
          } catch (_) {
            _reply!.completeError(
              const DiagnosticWorkerFailure(
                DiagnosticHealthReason.storageWorkerProtocolFailed,
              ),
            );
          }
        }
        return true;
      case 'worker_failure':
        if (value.length == 4 &&
            value[1] == _workerRequestId &&
            _reply?.isCompleted == false) {
          _reply!.completeError(
            DiagnosticWorkerFailure(
              DiagnosticHealthReason.values[value[2] as int],
              disposed: value[3] as bool,
            ),
          );
        }
        return true;
      default:
        return false;
    }
  }

  Future<DiagnosticWorkerReply> _request(int type, Uint8List payload) async {
    if (_reply != null) {
      throw StateError('Overlapping diagnostic writer request');
    }
    final reply = _reply = Completer<DiagnosticWorkerReply>();
    final id = ++_workerRequestId;
    owner.send(['worker_request', id, type, payload]);
    try {
      // No Future timeout releases a request/ticket. Only a matching reply or
      // an owner-observed physical disposal can do so.
      return await reply.future;
    } finally {
      if (identical(_reply, reply)) _reply = null;
    }
  }

  bool _accepted(DiagnosticWorkerReply reply) {
    _remoteSlot = reply.slot ?? _remoteSlot;
    reason =
        reply.result == DiagnosticWorkerResult.retry &&
            (reply.reason == DiagnosticHealthReason.healthy ||
                reply.reason == DiagnosticHealthReason.bootstrapOnly)
        ? DiagnosticHealthReason.storageUnavailable
        : reply.reason;
    if (reply.result == DiagnosticWorkerResult.disabled) _remoteDisabled = true;
    return reply.result == DiagnosticWorkerResult.ok;
  }

  void flush() {
    if (sinkFactory != null) {
      _flushSynchronousForTesting();
    } else if (!_flushing && !_finished) {
      _flushing = true;
      unawaited(_flushAsync().whenComplete(() => _flushing = false));
    }
  }

  Future<void> _flushAsync() async {
    try {
      if (decisionExpected && !decisionReceived) {
        _health();
        return;
      }
      if (role == DiagnosticRole.transient) {
        _discard();
        if (closing) _finish();
        return;
      }
      final eligible =
          hadPriority ||
          _hasSummaries ||
          records.length >= 100 ||
          started.elapsedMilliseconds >= 5000;
      if (!eligible || profile == null || _remoteDisabled) {
        if (closing) {
          _discardUnsent();
          _finish();
        } else {
          _health();
        }
        return;
      }
      if (!_initialized) {
        final reply = await _request(
          DiagnosticWorkerFrame.init,
          DiagnosticWorkerInit(
            profile: profile!,
            session: DiagnosticIdentity.parse(session)!,
            role: role,
          ).encode(),
        );
        if (!_accepted(reply)) {
          _finishOrHealth();
          return;
        }
        if (_buildId == null) {
          throw const DiagnosticWorkerFailure(
            DiagnosticHealthReason.storageWorkerProtocolFailed,
          );
        }
        _initialized = true;
      }
      if (decisionExpected && !decisionReceived) {
        _health();
        return;
      }
      if (!_admitted) {
        if (attempts >= 5 || started.elapsedMilliseconds < nextAttempt) {
          _finishOrHealth();
          return;
        }
        attempts++;
        nextAttempt =
            started.elapsedMilliseconds +
            [100, 500, 2000, 5000, 5000][attempts - 1];
        if (!_accepted(
          await _request(DiagnosticWorkerFrame.admit, Uint8List(0)),
        )) {
          _finishOrHealth();
          return;
        }
        _admitted = true;
      }
      // Data and counters can arrive during summary/classification RPCs.
      // Re-enter the whole drain before acknowledging close; closing revokes
      // new admission, so its admitted suffix is finite.
      do {
        while (records.isNotEmpty) {
          if (_disposed) {
            _finishOrHealth();
            return;
          }
          if (decisionExpected && !decisionReceived) {
            _health();
            return;
          }
          if (!await _classify()) {
            _finishOrHealth();
            return;
          }
          if (_disposed) {
            _finishOrHealth();
            return;
          }
          final record = records.first;
          final bytes = _encode(record);
          if (bytes.length > 4096) {
            _complete(record, droppedRecord: true);
            reason = DiagnosticHealthReason.sinkFailed;
            continue;
          }
          _inFlight = record;
          final reply = await _request(DiagnosticWorkerFrame.append, bytes);
          _inFlight = null;
          if (!_accepted(reply)) {
            if (reply.result == DiagnosticWorkerResult.disabled) {
              // This matching ACK definitively disposed of this failed append.
              // Return exactly its charge; newer unsent records stay queued.
              _complete(record, droppedRecord: true);
            }
            _finishOrHealth();
            return;
          }
          _complete(record);
        }
        if (_disposed) {
          _finishOrHealth();
          return;
        }
        while (_pendingSummary != null || _hasSummaries) {
          final summary = _pendingSummary ??= _summaries().firstOrNull;
          if (summary == null) break;
          if (!await _classify(priority: true)) {
            _finishOrHealth();
            return;
          }
          final reply = await _request(
            DiagnosticWorkerFrame.append,
            _encode(summary),
          );
          if (!_accepted(reply)) {
            _finishOrHealth();
            return;
          }
          _pendingSummary = null;
          if (_disposed) {
            _finishOrHealth();
            return;
          }
        }
        // Ownership may change during the last APPEND, or after an earlier
        // flush emptied the queue. Publish its protection even without new data;
        // _classify also retains a pending decision's close deadline.
        if (!await _classify()) {
          _finishOrHealth();
          return;
        }
      } while (records.isNotEmpty || _pendingSummary != null || _hasSummaries);
      _health();
      if (closing) _finish();
    } on DiagnosticWorkerFailure catch (error) {
      reason = error.reason;
      _remoteDisabled = true;
      if (error.disposed) {
        _inFlight = null;
        dropped = _sum(dropped, records.length);
        _discard();
      } else {
        // Never refund an unknown APPEND or replay it under a new request ID.
        // Later records remain a bounded in-memory suffix. Close can discard
        // that unsent suffix, but the unknown prefix lives until writer exit.
        _unknown = _inFlight != null;
      }
      _finishOrHealth();
    } catch (_) {
      reason = DiagnosticHealthReason.sinkFailed;
      _remoteDisabled = true;
      _unknown = _inFlight != null;
      _finishOrHealth();
    }
  }

  Future<bool> _classify({bool priority = false}) async {
    while (true) {
      if (_disposed || (decisionExpected && !decisionReceived)) return false;
      final state = (role, hadPriority || priority, hadFailure);
      if (_classification == state) return true;
      final reply = await _request(
        DiagnosticWorkerFrame.classify,
        DiagnosticWorkerClassification(
          state.$1,
          error: state.$2,
          genuineFailure: state.$3,
        ).encode(),
      );
      if (!_accepted(reply)) return false;
      _classification = state;
      if (decisionExpected && !decisionReceived) return false;
      // A promotion or newer failure can arrive while the old classification
      // is in flight. Publish the newest protection before any following data.
      if (_classification == (role, hadPriority || priority, hadFailure)) {
        return true;
      }
    }
  }

  void _complete(_QueuedRecord record, {bool droppedRecord = false}) {
    if (!identical(records.firstOrNull, record)) {
      throw StateError('Diagnostic ACK prefix changed');
    }
    records.removeAt(0);
    charge -= record.charge;
    ledger.completed(record.charge, record.priority);
    if (droppedRecord) dropped = _sum(dropped, 1);
    ledger.rebalance();
  }

  void _discardUnsent() {
    final keep = _unknown ? _inFlight : null;
    for (var i = records.length - 1; i >= 0; i--) {
      final record = records[i];
      if (identical(record, keep)) continue;
      records.removeAt(i);
      charge -= record.charge;
      ledger.completed(record.charge, record.priority);
      dropped = _sum(dropped, 1);
    }
    ledger.rebalance();
  }

  void _finishOrHealth() {
    _disposeConfirmed();
    if (decisionExpected && !decisionReceived) {
      // A late ownership expectation can arrive during CLASSIFY. Its existing
      // close deadline still owns the decision; a deferred classification is
      // not a failed sink and cannot discard protected failure data early.
      _health();
      return;
    }
    if (closing) {
      _discardUnsent();
      _finish();
    } else {
      _health();
    }
  }

  void _flushSynchronousForTesting() {
    if (decisionExpected && !decisionReceived) {
      _health();
      return;
    }
    if (role == DiagnosticRole.transient) {
      _discard();
      if (closing) _finish();
      return;
    }
    final lazyReady =
        hadPriority ||
        _hasSummaries ||
        records.length >= 100 ||
        started.elapsedMilliseconds >= 5000;
    if (!lazyReady || profile == null) {
      if (closing) {
        dropped = _sum(dropped, records.length);
        _discard();
        _finish();
      } else {
        _health();
      }
      return;
    }
    if (storage == null &&
        attempts < 5 &&
        started.elapsedMilliseconds >= nextAttempt) {
      attempts++;
      nextAttempt =
          started.elapsedMilliseconds +
          [100, 500, 2000, 5000, 5000][attempts - 1];
      try {
        storage = sinkFactory!(
          profile!,
          DiagnosticIdentity.parse(session)!,
          role,
        );
        reason = storage == null
            ? DiagnosticHealthReason.storageUnavailable
            : DiagnosticHealthReason.healthy;
      } on DiagnosticStorageUnavailable catch (error) {
        reason = error.reason;
      } catch (_) {
        reason = DiagnosticHealthReason.storageUnavailable;
      }
    }
    var written = 0;
    try {
      if (storage != null) {
        if (!storage!.classify(
          role,
          error: hadPriority,
          genuineFailure: hadFailure,
        )) {
          if (!storage!.failed) {
            if (closing) {
              // Admission contention is not a broken file sink. Do not append
              // unclassified failure data or hold the final phase indefinitely.
              reason = DiagnosticHealthReason.storageUnavailable;
              _discard();
              _finish();
            } else {
              _health();
            }
            return;
          }
          reason = DiagnosticHealthReason.sinkFailed;
        } else {
          for (final record in records) {
            final bytes = _encode(record);
            if (bytes.length > DiagnosticRecord.maximumRecordBytes ||
                !storage!.append(bytes)) {
              reason = DiagnosticHealthReason.sinkFailed;
              break;
            }
            written++;
          }
          if (written == records.length &&
              reason != DiagnosticHealthReason.sinkFailed) {
            for (final summary in _summaries()) {
              if (!storage!.append(_encode(summary))) {
                reason = DiagnosticHealthReason.sinkFailed;
                break;
              }
            }
          }
        }
      }
    } catch (_) {
      reason = DiagnosticHealthReason.sinkFailed;
    }
    dropped = _sum(dropped, records.length - written);
    _discard();
    _health();
    if (closing) _finish();
  }

  void _discard() {
    for (final record in records) {
      ledger.completed(record.charge, record.priority);
    }
    records.clear();
    charge = 0;
    ledger.rebalance();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _captureLedgerHighWater();
    timer?.cancel();
    timer = null;
    creditTimer?.cancel();
    creditTimer = null;
    ownershipCloseDeadline?.cancel();
    ownershipCloseDeadline = null;
    final slot = storage?.slot ?? _remoteSlot;
    try {
      storage?.close();
    } catch (_) {
      reason = DiagnosticHealthReason.sinkFailed;
    }
    storage = null;
    owner.send([
      'closed',
      reason == DiagnosticHealthReason.healthy,
      admitted,
      dropped,
      rejected,
      highBytes,
      highRecords,
      slot,
      reason.index,
      ledger.quarantined,
    ]);
    receive.close();
  }
}
