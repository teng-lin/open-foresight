import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'events.dart';
import 'storage.dart';

export 'configuration.dart';
export 'events.dart';
export 'storage.dart'
    show DiagnosticRole, OwnershipDecision, DiagnosticHealthReason;

const _normalBytes = 12 * 1024, _priorityBytes = 4 * 1024;
// Keep sixteen record positions for sequential writer summaries/control. The
// remaining240 producer records still reserve more than one quarter for priority.
const _normalRecords = 11, _priorityRecords = 4;
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
  };
}

final class LoggingCloseResult {
  const LoggingCloseResult({required this.writerExited, required this.flushed});
  final bool writerExited, flushed;
  bool get requiresExplicitExit => !writerExited;
}

/// Pass this through isolate bootstrap explicitly. Connecting registers at most
/// once; duplicate copies do not receive a second grant. It conveys no profile,
/// file descriptor, application ownership or session-close capability.
final class DiagnosticProducerBootstrap {
  DiagnosticProducerBootstrap._(
    this._writer,
    this.id,
    this.kind,
    this.configuration,
  );
  final SendPort? _writer;
  final int id;
  final DiagnosticProducerKind kind;
  final DiagnosticConfiguration configuration;
  DiagnosticProducer connect() => DiagnosticProducer._(this);
}

/// Closed producer-side loss causes, never arbitrary caller error text.
enum DiagnosticDropReason { correlationCapacity }

final class DiagnosticProducer {
  DiagnosticProducer._(DiagnosticProducerBootstrap bootstrap)
    : _writer = bootstrap._writer,
      _id = bootstrap.id,
      configuration = bootstrap.configuration {
    if (_writer == null) {
      _ready.complete();
      return;
    }
    final port = RawReceivePort(_receive);
    _registrationDeadline = Timer(LoggingSession.closeDeadline, _shutdown);
    _credits = port;
    _writer.send(['register', _id, bootstrap.kind.index, port.sendPort]);
  }
  final SendPort? _writer;
  final int _id;
  final DiagnosticConfiguration configuration;
  final _ready = Completer<void>();
  Future<void> get ready => _ready.future;
  RawReceivePort? _credits;
  Timer? _registrationDeadline;
  int _bytes = 0, _records = 0, _priority = 0, _priorityCount = 0;
  int _dropped = 0, _rejected = 0, _correlationRefused = 0;
  bool _closed = false, _accepted = false, _emitting = false;

  /// Registration/lifetime availability; transient credit exhaustion is separate.
  bool get active => !_closed && _accepted && configuration.enabled;
  int get dropped => _dropped;
  int get rejected => _rejected;
  int get correlationRefused => _correlationRefused;

  /// Report bounded diagnostic work refused before encoding. Counters travel
  /// only with existing grant/record/completion messages, never per refusal.
  void noteDropped(DiagnosticDropReason reason) {
    if (!active) return;
    switch (reason) {
      case DiagnosticDropReason.correlationCapacity:
        _correlationRefused = _sum(_correlationRefused, 1);
    }
    _dropped = _sum(_dropped, 1);
  }

  void _receive(dynamic value) {
    if (_closed || value is! List || value.isEmpty) return;
    if (value.first == 'stop') {
      _shutdown();
      return;
    }
    if (value.first == 'credits' && value.length == 5) {
      _registrationDeadline?.cancel();
      _registrationDeadline = null;
      _accepted = true;
      _credits?.keepIsolateAlive = false;
      _bytes = (_bytes + (value[1] as int)).clamp(0, _normalBytes);
      _records = (_records + (value[2] as int)).clamp(0, _normalRecords);
      _priority = (_priority + (value[3] as int)).clamp(0, _priorityBytes);
      _priorityCount = (_priorityCount + (value[4] as int)).clamp(
        0,
        _priorityRecords,
      );
      if (!_ready.isCompleted) _ready.complete();
      if (_dropped + _rejected > 0) {
        _writer?.send(['producer_counters', _id, _dropped, _rejected]);
        _dropped = 0;
        _rejected = 0;
      }
    }
  }

  /// Allocation of caller fields follows level filtering. Logging never throws,
  /// awaits, retries a business operation, writes fd2 or waits on file locks.
  bool emit(
    DiagnosticEvent event,
    DiagnosticComponent component, {
    Map<DiagnosticField, Object> Function()? fields,
    DiagnosticIdentity? connection,
    int? request,
    int? attempt,
    DiagnosticIdentity? job,
    SafeDiagnosticStack? stack,
    SafeDiagnosticStack Function()? stackBuilder,
  }) {
    if (_closed ||
        _writer == null ||
        !configuration.permits(
          event.severity,
          transport: event == DiagnosticEvent.transportActivity,
        )) {
      return false;
    }
    if (_emitting) {
      _dropped = _sum(_dropped, 1);
      return false;
    }
    if (stack != null && stackBuilder != null) {
      _rejected = _sum(_rejected, 1);
      return false;
    }
    // Reserve a record and byte credit before any caller-controlled builder.
    // Full encoded cost is settled before send; the reentrancy guard ensures
    // only one bounded encoder can use this producer's scratch at a time.
    const reservation = 256;
    var priority = false;
    if (_records > 0 && _bytes >= reservation) {
      _records--;
      _bytes -= reservation;
    } else if (event.severity.index <= DiagnosticLevel.warn.index &&
        _priorityCount > 0 &&
        _priority >= reservation) {
      priority = true;
      _priorityCount--;
      _priority -= reservation;
    } else {
      _dropped = _sum(_dropped, 1);
      return false;
    }
    var sent = false;
    var reservedCharge = reservation;
    _emitting = true;
    try {
      final record = DiagnosticRecord(
        event,
        component,
        fields: fields?.call() ?? const {},
        connection: connection,
        request: request,
        attempt: attempt,
        job: job,
        stack: stack ?? stackBuilder?.call(),
      );
      final value = record.toWire();
      if (value == null) {
        _rejected = _sum(_rejected, 1);
        return false;
      }
      final severity = _severity(value);
      if (!configuration.permits(
        severity,
        transport: event == DiagnosticEvent.transportActivity,
      )) {
        return false;
      }
      final encoded = jsonEncode(value);
      final length = utf8.encode(encoded).length;
      if (length > DiagnosticRecord.maximumProducerRecordBytes) {
        _rejected = _sum(_rejected, 1);
        return false;
      }
      final charge = _cost(length);
      final remaining = charge - reservation;
      if (priority ? _priority >= remaining : _bytes >= remaining) {
        if (priority) {
          _priority -= remaining;
        } else {
          _bytes -= remaining;
        }
      } else if (!priority &&
          severity.index <= DiagnosticLevel.warn.index &&
          _priorityCount > 0 &&
          _priority >= charge) {
        _bytes += reservation;
        _records++;
        priority = true;
        _priorityCount--;
        _priority -= charge;
      } else {
        _dropped = _sum(_dropped, 1);
        return false;
      }
      reservedCharge = charge;
      _writer.send([
        'record',
        _id,
        encoded,
        charge,
        priority,
        _dropped,
        _rejected,
      ]);
      sent = true;
      _dropped = 0;
      _rejected = 0;
      return true;
    } catch (_) {
      _rejected = _sum(_rejected, 1);
      return false;
    } finally {
      _emitting = false;
      if (!sent && !_closed) {
        if (priority) {
          _priority += reservedCharge;
          _priorityCount++;
        } else {
          _bytes += reservedCharge;
          _records++;
        }
      }
    }
  }

  void close() {
    if (_closed) return;
    _writer?.send(['producer_done', _id, _dropped, _rejected]);
    _shutdown();
  }

  void _shutdown() {
    _closed = true;
    _registrationDeadline?.cancel();
    _registrationDeadline = null;
    _bytes = 0;
    _priority = 0;
    _records = 0;
    _priorityCount = 0;
    _credits?.close();
    _credits = null;
    if (!_ready.isCompleted) _ready.complete();
  }
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
  static const closeDeadline = Duration(milliseconds: 500);
  final DiagnosticConfiguration configuration;
  final DiagnosticIdentity identity;
  final SendPort? _writer;
  final Isolate? _isolate;
  final RawReceivePort? _status, _errors;
  final Completer<void> _exited;
  final DiagnosticHealth health;
  late final DiagnosticProducer producer;
  final List<DiagnosticProducer> _localProducers = [];
  DiagnosticProducer? _noOpProducer;
  @visibleForTesting
  int get retainedProducerCount => _localProducers.length;
  int _nextProducer = 0;
  bool _ownershipExpected = false,
      _closed = false,
      _flushed = false,
      _closeAcknowledged = false;
  Future<LoggingCloseResult>? _close;

  static Future<LoggingSession> start({
    required DiagnosticConfiguration configuration,
    String? profilePath,
    DiagnosticRole role = DiagnosticRole.candidate,
    String version = 'unknown',
    String revision = 'unknown',
  }) => _processSession ??= _start(
    configuration,
    profilePath,
    role == DiagnosticRole.service ? DiagnosticRole.candidate : role,
    version,
    revision,
  );
  @visibleForTesting
  static Future<LoggingSession> startForTesting({
    required DiagnosticConfiguration configuration,
    String? profilePath,
    DiagnosticRole role = DiagnosticRole.candidate,
    DiagnosticSinkFactory? sinkFactory,
    DateTime Function()? clock,
  }) => _start(
    configuration,
    profilePath,
    role,
    'unknown',
    'unknown',
    sinkFactory: sinkFactory,
    clock: clock,
  );

  static Future<LoggingSession> _start(
    DiagnosticConfiguration configuration,
    String? profile,
    DiagnosticRole role,
    String version,
    String revision, {
    DiagnosticSinkFactory? sinkFactory,
    DateTime Function()? clock,
  }) async {
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
        final active = currentSession;
        if (active == null || !active._closed || !active._closeAcknowledged) {
          health.reason = DiagnosticHealthReason.writerFailed;
        }
        if (active != null) {
          for (final producer in active._localProducers) {
            producer._shutdown();
          }
        }
        return;
      }
      if (value is! List || value.isEmpty) return;
      if (value.first == 'closed' && value.length == 9) {
        session._closeAcknowledged = true;
        session._flushed = value[1] as bool;
        health.reason = DiagnosticHealthReason.values[value[8] as int];
        health.admitted = value[2] as int;
        health.dropped = value[3] as int;
        health.rejected = value[4] as int;
        health.highWaterBytes = value[5] as int;
        health.highWaterRecords = value[6] as int;
        health.slot = value[7] as int?;
        return;
      }
      if (value.first == 'health' && value.length == 8) {
        health.reason = DiagnosticHealthReason.values[value[1] as int];
        health.admitted = value[2] as int;
        health.dropped = value[3] as int;
        health.rejected = value[4] as int;
        health.highWaterBytes = value[5] as int;
        health.highWaterRecords = value[6] as int;
        health.slot = value[7] as int?;
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
      currentSession = session;
      session.producer = session
          .reserveProducer(DiagnosticProducerKind.entrypoint)
          .connect();
      session._localProducers.add(session.producer);
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
      status.close();
      errors.close();
      if (!exited.isCompleted) exited.complete();
      health.reason = DiagnosticHealthReason.writerFailed;
      session = LoggingSession._(
        configuration,
        identity,
        null,
        null,
        null,
        null,
        exited,
        health,
      );
      session.producer = session
          .reserveProducer(DiagnosticProducerKind.entrypoint)
          .connect();
      return session;
    } finally {
      bootstrap.close();
    }
  }

  DiagnosticProducerBootstrap reserveProducer(DiagnosticProducerKind kind) {
    if (_closed || _writer == null || _nextProducer >= maximumProducers) {
      return DiagnosticProducerBootstrap._(null, -1, kind, configuration);
    }
    return DiagnosticProducerBootstrap._(
      _writer,
      _nextProducer++,
      kind,
      configuration,
    );
  }

  /// The isolate owner calls this from its onExit observer. Outstanding records
  /// still flush, but no further grants target the dead endpoint. Tickets are
  /// never reused, so stale bootstrap copies cannot create another budget.
  void producerExited(DiagnosticProducerBootstrap bootstrap) {
    if (!_closed && bootstrap._writer == _writer) {
      _writer?.send(['producer_done', bootstrap.id, 0, 0]);
    }
  }

  DiagnosticProducer registerProducer(DiagnosticProducerKind kind) {
    final bootstrap = reserveProducer(kind);
    if (bootstrap._writer == null) return _noOpProducer ??= bootstrap.connect();
    final producer = bootstrap.connect();
    _localProducers.add(producer);
    return producer;
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
    for (final producer in _localProducers) {
      producer.close();
    }
    _writer?.send(['close']);
    var writerExited = _exited.isCompleted;
    try {
      await _exited.future.timeout(closeDeadline);
      writerExited = true;
    } on TimeoutException {
      health.reason = DiagnosticHealthReason.writerFailed;
      _isolate?.kill(priority: Isolate.immediate);
    }
    _status?.close();
    _errors?.close();
    health.closed = true;
    if (health.reason == DiagnosticHealthReason.healthy) {
      health.reason = DiagnosticHealthReason.closed;
    }
    return LoggingCloseResult(
      writerExited: writerExited,
      flushed: _flushed || _writer == null,
    );
  }

  @visibleForTesting
  static Future<void> resetForTesting() async {
    final session = _processSession;
    if (session != null) await (await session).close();
    _processSession = null;
  }
}

final class _WriterProducer {
  _WriterProducer(this.kind, this.port);
  final DiagnosticProducerKind kind;
  final SendPort port;
  int bytes = 0, records = 0, priority = 0, priorityCount = 0;
  bool active = true;
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
  _QueuedRecord(this.value, this.producer, this.charge, this.priority);
  final Map<String, dynamic> value;
  final int producer, charge;
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
  state.timer = Timer.periodic(
    const Duration(milliseconds: 250),
    (_) => state.flush(),
  );
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
  final producers = <int, _WriterProducer>{};
  final exitedTickets = <int>{};
  final records = <_QueuedRecord>[];
  final started = Stopwatch()..start();
  final rate = _RateState();
  int pendingDrops = 0, pendingRejected = 0, firstDrop = 0, lastDrop = 0;
  Timer? timer, ownershipCloseDeadline;
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
    switch (value.first) {
      case 'register':
        final id = value[1] as int;
        final port = value[3] as SendPort;
        if (closing ||
            id < 0 ||
            id >= LoggingSession.maximumProducers ||
            producers.containsKey(id) ||
            exitedTickets.contains(id)) {
          port.send(['stop']);
          return;
        }
        producers[id] = _WriterProducer(
          DiagnosticProducerKind.values[value[2] as int],
          port,
        );
        port.send([
          'credits',
          _normalBytes,
          _normalRecords,
          _priorityBytes,
          _priorityRecords,
        ]);
      case 'record':
        if (closing) return;
        final id = value[1] as int,
            encoded = value[2] as String,
            cost = value[3] as int;
        final producer = producers[id];
        if (producer == null) return;
        final length = utf8.encode(encoded).length;
        if (length > DiagnosticRecord.maximumProducerRecordBytes ||
            _cost(length) != cost) {
          _producerCounters(0, 1);
          return;
        }
        final map = jsonDecode(encoded);
        final priority = value[4] as bool;
        _producerCounters(value[5] as int, value[6] as int);
        if (!DiagnosticRecord.validWire(map)) {
          _producerCounters(0, 1);
          _credit(id, cost, priority);
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
          _credit(id, cost, priority);
          return;
        }
        if (!_admitRate(event, wire) ||
            records.length >= LoggingSession.maximumOutstandingRecords ||
            charge + cost > 256 * 1024) {
          dropped = _sum(dropped, 1);
          _credit(id, cost, priority);
          return;
        }
        records.add(_QueuedRecord(wire, id, cost, priority));
        charge += cost;
        highBytes = highBytes < charge ? charge : highBytes;
        highRecords = highRecords < records.length
            ? records.length
            : highRecords;
        admitted = _sum(admitted, 1);
        if (storage == null && reason == DiagnosticHealthReason.healthy) {
          reason = DiagnosticHealthReason.bootstrapOnly;
        }
        if (severity.index <= DiagnosticLevel.warn.index) hadPriority = true;
        if (severity == DiagnosticLevel.error) hadFailure = true;
        if (severity == DiagnosticLevel.error) scheduleMicrotask(flush);
      case 'producer_counters':
        _producerCounters(value[2] as int, value[3] as int);
      case 'producer_done':
        final id = value[1] as int;
        if (id < 0 || id >= LoggingSession.maximumProducers) return;
        exitedTickets.add(id);
        _producerCounters(value[2] as int, value[3] as int);
        final producer = producers[id];
        if (producer != null) {
          producer.port.send(['stop']);
          producer.active = false;
          producer.bytes = 0;
          producer.records = 0;
          producer.priority = 0;
          producer.priorityCount = 0;
        }
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
      Map<String, dynamic>.from(
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
      -1,
      0,
      false,
    );
    if (pendingDrops > 0) {
      yield summary(
        DiagnosticEvent.recordsDropped,
        pendingDrops,
        firstDrop,
        lastDrop,
      );
      pendingDrops = 0;
    }
    if (pendingRejected > 0) {
      yield summary(
        DiagnosticEvent.recordRejected,
        pendingRejected,
        firstDrop,
        lastDrop,
      );
      pendingRejected = 0;
    }
    for (final event in DiagnosticEvent.values) {
      final count = rate.offsets[event.index + 1] - rate.offsets[event.index];
      for (var category = 0; category < count; category++) {
        final at = (rate.offsets[event.index] + category) * 4;
        final suppressed = rate.values[at + 1];
        if (suppressed == 0) continue;
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
        rate.values[at + 1] = 0;
      }
    }
  }

  void _credit(int id, int cost, bool priority) {
    final producer = producers[id];
    if (producer == null || !producer.active) return;
    if (priority) {
      producer.priority += cost;
      producer.priorityCount++;
    } else {
      producer.bytes += cost;
      producer.records++;
    }
  }

  void _returnCredits() {
    for (final producer in producers.values) {
      if (!producer.active) continue;
      if (closing) {
        producer.port.send(['stop']);
        continue;
      }
      if (producer.records + producer.priorityCount == 0) continue;
      producer.port.send([
        'credits',
        producer.bytes,
        producer.records,
        producer.priority,
        producer.priorityCount,
      ]);
      producer.bytes = 0;
      producer.records = 0;
      producer.priority = 0;
      producer.priorityCount = 0;
    }
  }

  void _health() {
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
      storage?.slot,
    ]);
  }

  Uint8List _encode(_QueuedRecord record) {
    final producer = producers[record.producer];
    final severity = _severity(record.value);
    return Uint8List.fromList(
      utf8.encode(
        '${jsonEncode({'schema': 1, 'timestamp': clock().toUtc().toIso8601String(), 'sequence': ++sequence, 'level': severity.name, 'version': version, 'revision': revision, 'session': session, 'pid': pid, 'producer': '${producer?.kind.name ?? DiagnosticProducerKind.writer.name}:${record.producer < 0 ? 0 : record.producer}', ...record.value})}\n',
      ),
    );
  }

  void flush() {
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
        storage = sinkFactory == null
            ? DiagnosticStorage.admit(
                profile!,
                DiagnosticIdentity.parse(session)!,
                role,
                clock: clock,
              )
            : sinkFactory!(profile!, DiagnosticIdentity.parse(session)!, role);
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
      _credit(record.producer, record.charge, record.priority);
    }
    records.clear();
    charge = 0;
    _returnCredits();
  }

  void _finish() {
    timer?.cancel();
    timer = null;
    ownershipCloseDeadline?.cancel();
    ownershipCloseDeadline = null;
    final slot = storage?.slot;
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
    ]);
    receive.close();
  }
}
