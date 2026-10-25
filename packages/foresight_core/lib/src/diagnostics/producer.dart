part of 'session.dart';

/// Immutable attribution survives slot retirement and reuse. Schema1's stored
/// grammar remains kind:slot; later formatters can use generation explicitly.
final class DiagnosticProducerSnapshot {
  const DiagnosticProducerSnapshot(this.kind, this.slot, this.generation);
  const DiagnosticProducerSnapshot.writer()
    : kind = DiagnosticProducerKind.writer,
      slot = 0,
      generation = 0;
  final DiagnosticProducerKind kind;
  final int slot, generation;
}

/// A sendable producer capability, never application/session-close authority.
final class DiagnosticProducerBootstrap {
  DiagnosticProducerBootstrap._(
    this._writer,
    this.id,
    this.generation,
    this.kind,
    this.configuration,
  );
  final SendPort? _writer;
  final int id, generation;
  int get slot => id;
  final DiagnosticProducerKind kind;
  final DiagnosticConfiguration configuration;
  SendPort? _executionVm;
  DiagnosticProducer connect() {
    if (_writer == null ||
        (_executionVm != null && _executionVm != Isolate.current.controlPort)) {
      return DiagnosticProducer._inactive(configuration);
    }
    return DiagnosticProducer._connect(this);
  }

  // Only the owned paused-spawn helper wires this after binding the exact VM.
  // A transferable producer bootstrap does not convey retirement authority.
  bool _observeExit(Isolate isolate) {
    final writer = _writer;
    if (writer != null && Platform.version.startsWith('3.9.2 ')) {
      // Epoch0 identifies the lifetime barrier, covering all credit epochs.
      isolate.addOnExitListener(
        writer,
        response: ['actual_exit', id, generation, 0],
      );
      return true;
    }
    return false;
  }
}

enum DiagnosticDropReason { correlationCapacity }

final class DiagnosticProducer {
  // One logging owner per VM. A bootstrap cannot change that selection. The
  // owner/private entry wrapper may replace an entirely unwound test context.
  static SendPort? _connectionWriter;
  static final _connections = List<DiagnosticProducer?>.filled(16, null);
  static final _latestGenerations = Uint64List(16);
  static bool _selectWriter(SendPort writer) {
    if (_connectionWriter == writer) return true;
    for (final old in _connections) {
      if (old != null &&
          (!old._closed || old._emitting || old._credits != null)) {
        return false;
      }
    }
    _connectionWriter = writer;
    _connections.fillRange(0, 16, null);
    _latestGenerations.fillRange(0, 16, 0);
    return true;
  }

  static DiagnosticProducer _connect(DiagnosticProducerBootstrap bootstrap) {
    final writer = bootstrap._writer!, slot = bootstrap.slot;
    // Legacy unbound callers can select their first context. Subsequent writer
    // selection belongs to the owner, never to a copied/stale capability.
    _connectionWriter ??= writer;
    if (_connectionWriter != writer ||
        slot < 0 ||
        slot >= 16 ||
        bootstrap.generation <= _latestGenerations[slot]) {
      return _inactive(bootstrap.configuration);
    }
    final old = _connections[slot];
    if (old != null &&
        (!old._closed || old._emitting || old._credits != null)) {
      return _inactive(bootstrap.configuration);
    }
    _latestGenerations[slot] = bootstrap.generation;
    return _connections[slot] = DiagnosticProducer._(bootstrap);
  }

  static void _denyConnection(
    SendPort? writer,
    int slot,
    int generation, {
    bool retired = false,
  }) {
    if (writer != _connectionWriter ||
        slot < 0 ||
        slot >= 16 ||
        generation < _latestGenerations[slot]) {
      return;
    }
    final old = _connections[slot];
    if (generation == _latestGenerations[slot]) {
      if (retired) old?._markRetired();
    } else if (old == null ||
        (old._closed && !old._emitting && old._credits == null)) {
      _latestGenerations[slot] = generation;
      _connections[slot] = null;
    }
  }

  @visibleForTesting
  static int get localEndpointCount =>
      _connections.where((p) => p?._credits != null).length;
  @visibleForTesting
  static int get localRegistrationTimerCount =>
      _connections.where((p) => p?._registrationDeadline != null).length;
  @visibleForTesting
  static int get retainedConnectionCount =>
      _latestGenerations.where((generation) => generation != 0).length;
  static DiagnosticProducer? _inactiveProducer;
  static DiagnosticProducer _inactive(DiagnosticConfiguration configuration) =>
      _inactiveProducer ??= DiagnosticProducer._off(configuration);
  DiagnosticProducer._off(this.configuration)
    : _writer = null,
      _slot = -1,
      generation = 0 {
    _closed = true;
    _ready.complete();
    _retired.complete();
  }
  DiagnosticProducer._(DiagnosticProducerBootstrap bootstrap)
    : _writer = bootstrap._writer,
      _slot = bootstrap.id,
      generation = bootstrap.generation,
      configuration = bootstrap.configuration {
    _credits = RawReceivePort(_receive);
    _registrationDeadline = Timer(
      LoggingSession.closeDeadline,
      _registrationExpired,
    );
    _writer!.send([
      'register',
      _slot,
      generation,
      0,
      _credits!.sendPort,
      Isolate.current.controlPort,
    ]);
  }
  final SendPort? _writer;
  final int _slot, generation;
  int get slot => _slot;
  final DiagnosticConfiguration configuration;
  final _ready = Completer<void>(), _retired = Completer<void>();
  Future<void> get ready => _ready.future;
  Future<void> get retired => _retired.future;
  RawReceivePort? _credits;
  Timer? _registrationDeadline;
  int _normalEpoch = 0, _priorityEpoch = 0, _sequence = 0;
  int _bytes = 0, _records = 0, _priority = 0, _priorityCount = 0;
  int _dropped = 0, _rejected = 0, _correlationRefused = 0, _totalDropped = 0;
  int? _revokeNormal, _revokePriority;
  bool _normalGranted = false, _priorityGranted = false, _hadAuthority = false;
  bool _closed = false,
      _accepted = false,
      _emitting = false,
      _terminalSent = false,
      _controlScheduled = false,
      _pressureSent = false,
      _pressurePriority = false;
  bool get active => !_closed && _accepted && configuration.enabled;
  int get dropped => _totalDropped;
  int get rejected => _rejected;
  int get correlationRefused => _correlationRefused;
  @visibleForTesting
  (int, bool, int, bool) get receivedGrantsForTesting =>
      (_normalEpoch, _normalGranted, _priorityEpoch, _priorityGranted);

  void noteDropped(DiagnosticDropReason reason) {
    if (!active) return;
    switch (reason) {
      case DiagnosticDropReason.correlationCapacity:
        _correlationRefused = _sum(_correlationRefused, 1);
    }
    _drop();
  }

  void _drop({bool priority = false}) {
    _dropped = _sum(_dropped, 1);
    _totalDropped = _sum(_totalDropped, 1);
    _pressure(priority);
  }

  void _pressure(bool priority) {
    if (!active || _pressureSent) return;
    _pressureSent = true;
    _pressurePriority = priority;
    _writer!.send([
      'pressure',
      _slot,
      generation,
      priority ? _priorityEpoch : _normalEpoch,
      priority,
      _dropped,
      _rejected,
    ]);
    _dropped = _rejected = 0;
  }

  void _receive(dynamic value) {
    if (value is! List ||
        value.length < 4 ||
        value[1] != _slot ||
        value[2] != generation) {
      return;
    }
    final epoch = value[3] as int;
    if (value.first == 'retired' && epoch == 0) {
      _markRetired();
      return;
    }
    if (_closed && _terminalSent) return;
    if (value.first == 'stop') {
      if (_normalEpoch == 0 || _priorityEpoch == 0) {
        _shutdown();
        return;
      }
      close();
      return;
    }
    if (value.first == 'revoke' && value.length == 6) {
      final priority = value[4] as bool;
      if (epoch != (priority ? _priorityEpoch : _normalEpoch)) return;
      if (priority) {
        _revokePriority = value[5] as int;
      } else {
        _revokeNormal = value[5] as int;
      }
      _scheduleControl();
      return;
    }
    if (value.first == 'credits' && value.length == 7 && !_terminalSent) {
      final priority = value[4] as bool;
      final current = priority ? _priorityEpoch : _normalEpoch;
      if (epoch <= 0 ||
          (epoch != current && current != 0) ||
          (priority ? _priorityGranted : _normalGranted)) {
        return;
      }
      if (_pressureSent && _pressurePriority == priority) _pressureSent = false;
      if (priority) {
        _priorityEpoch = epoch;
        _priorityGranted = true;
        _priority += value[5] as int;
        _priorityCount += value[6] as int;
      } else {
        _normalEpoch = epoch;
        _normalGranted = true;
        _bytes += value[5] as int;
        _records += value[6] as int;
      }
      if (_normalEpoch != 0 && _priorityEpoch != 0) {
        _registrationDeadline?.cancel();
        _registrationDeadline = null;
        _accepted = !_closed;
        if (_accepted) _hadAuthority = true;
        _credits?.keepIsolateAlive = false;
        if (!_ready.isCompleted) _ready.complete();
        if (_closed) _scheduleControl();
      }
    }
  }

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
    if (!active ||
        !configuration.permits(
          event.severity,
          transport: event == DiagnosticEvent.transportActivity,
        )) {
      return false;
    }
    if (_emitting) {
      _drop();
      return false;
    }
    if (stack != null && stackBuilder != null) {
      _rejected = _sum(_rejected, 1);
      return false;
    }
    if (_sequence == _maximumGeneration) {
      _drop();
      return false;
    }
    // All catalog spellings are ASCII. Even empty fields must fit before a
    // caller builder can receive authority; no JSON allocation is needed here.
    const envelope = '{"event":"","component":"","fields":{}}';
    final minimum = _cost(
      envelope.length + event.wire.length + component.name.length,
    );
    final warning = event.severity.index <= DiagnosticLevel.warn.index;
    var priority =
        warning &&
        _revokePriority == null &&
        _priorityCount > 0 &&
        _priority >= minimum &&
        (_revokeNormal != null || _records == 0 || _priority > _bytes);
    final normalAvailable =
        _revokeNormal == null && _records > 0 && _bytes >= minimum;
    if (!priority && !normalAvailable) {
      if (warning &&
          _revokePriority == null &&
          _priorityCount > 0 &&
          _priority >= minimum) {
        priority = true;
      } else {
        _drop(priority: warning);
        return false;
      }
    }
    final reservation = priority ? _priority : _bytes;
    if (priority) {
      _priority = 0;
      _priorityCount--;
    } else {
      _bytes = 0;
      _records--;
    }
    // The complete finite byte envelope and this slot's scratch are owned
    // before caller code. No encode can borrow another producer's permit.
    final ceiling = ((reservation - 256) ~/ 4).clamp(
      0,
      DiagnosticRecord.maximumProducerRecordBytes,
    );
    var sent = false, charge = 0;
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
      if (_closed || (priority ? _revokePriority : _revokeNormal) != null) {
        return false;
      }
      final value = record.toWire();
      if (value == null) {
        _rejected = _sum(_rejected, 1);
        return false;
      }
      if (!configuration.permits(
        _severity(value),
        transport: event == DiagnosticEvent.transportActivity,
      )) {
        return false;
      }
      final encoded = jsonEncode(value);
      final length = utf8.encode(encoded).length;
      if (length > ceiling) {
        _rejected = _sum(_rejected, 1);
        _pressure(priority);
        return false;
      }
      charge = _cost(length);
      _writer!.send([
        'record',
        _slot,
        generation,
        priority ? _priorityEpoch : _normalEpoch,
        ++_sequence,
        encoded,
        charge,
        priority,
        _dropped,
        _rejected,
      ]);
      sent = true;
      _dropped = _rejected = 0;
      return true;
    } catch (_) {
      _rejected = _sum(_rejected, 1);
      return false;
    } finally {
      if (priority) {
        _priority += reservation - (sent ? charge : 0);
        if (!sent) _priorityCount++;
      } else {
        _bytes += reservation - (sent ? charge : 0);
        if (!sent) _records++;
      }
      _emitting = false;
      if (_closed || _revokeNormal != null || _revokePriority != null) {
        _scheduleControl();
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _accepted = false;
    _scheduleControl();
  }

  void _scheduleControl() {
    if (_controlScheduled || _emitting || _terminalSent) return;
    _controlScheduled = true;
    // A builder calling close/revoke cannot declare its own stack unwound.
    scheduleMicrotask(() {
      _controlScheduled = false;
      if (_emitting || _terminalSent) return;
      if (_closed) {
        if (_normalEpoch == 0 || _priorityEpoch == 0) return;
        _writer?.send([
          'terminal',
          _slot,
          generation,
          _normalEpoch,
          _priorityEpoch,
          _sequence,
          _bytes,
          _records,
          _priority,
          _priorityCount,
          _dropped,
          _rejected,
          _normalGranted,
          _priorityGranted,
        ]);
        _bytes = _records = _priority = _priorityCount = 0;
        _dropped = _rejected = 0;
        _terminalSent = true;
        _credits?.keepIsolateAlive = false;
        _registrationDeadline?.cancel();
        return;
      }
      for (final priority in [false, true]) {
        final next = priority ? _revokePriority : _revokeNormal;
        if (next == null) continue;
        _writer?.send([
          'revoke_ack',
          _slot,
          generation,
          priority ? _priorityEpoch : _normalEpoch,
          priority,
          _sequence,
          priority ? _priority : _bytes,
          priority ? _priorityCount : _records,
          [_dropped, _rejected],
          next,
        ]);
        _dropped = _rejected = 0;
        if (priority) {
          _priority = _priorityCount = 0;
          _priorityEpoch = next;
          _priorityGranted = false;
          _revokePriority = null;
        } else {
          _bytes = _records = 0;
          _normalEpoch = next;
          _normalGranted = false;
          _revokeNormal = null;
        }
      }
    });
  }

  void _registrationExpired() {
    if (_hadAuthority || _terminalSent) return;
    final reply = _credits?.sendPort;
    if (reply != null) {
      _writer?.send(['withdraw', _slot, generation, 0, reply]);
    }
    // No encoder ever ran. The exact endpoint's withdrawal precedes any later
    // reuse acknowledgement; closing locally does not refund writer leases.
    _shutdown();
  }

  void _markRetired() {
    _shutdown();
    if (!_retired.isCompleted) _retired.complete();
  }

  void _shutdown() {
    _closed = true;
    _accepted = false;
    _registrationDeadline?.cancel();
    _registrationDeadline = null;
    _credits?.close();
    _credits = null;
    _bytes = _records = _priority = _priorityCount = 0;
    if (!_ready.isCompleted) _ready.complete();
  }
}
