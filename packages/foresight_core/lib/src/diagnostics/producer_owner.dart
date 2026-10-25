part of 'session.dart';

final class _OwnedProducer {
  _OwnedProducer(this.bootstrap);
  final DiagnosticProducerBootstrap bootstrap;
  DiagnosticProducer? local;
  Completer<void>? completion;
  bool ownerExitSent = false;
  Future<void> get retired => (completion ??= Completer<void>()).future;
}

/// A reservation whose capability has not yet been made transferable.
/// Reading bootstrap irreversibly removes never-spawned cancellation authority.
final class DiagnosticProducerReservation {
  DiagnosticProducerReservation._(this._owner, this._slot);
  final LoggingSession _owner;
  final _OwnedProducer? _slot;
  bool _exposed = false, _cancelled = false;
  DiagnosticProducerBootstrap get bootstrap {
    if (_cancelled || _slot == null) return _owner._inactiveBootstrap;
    _exposed = true;
    return _slot.bootstrap;
  }

  Future<void> get retired =>
      _slot?.retired ?? _owner._inactiveBootstrap.connect().retired;
  Future<DiagnosticOwnedIsolate> spawn<T>(
    void Function((DiagnosticProducerBootstrap, T)) entrypoint,
    T message, {
    SendPort? onError,
    SendPort? onExit,
    bool errorsAreFatal = true,
    String? debugName,
  }) {
    final slot = !_exposed && !_cancelled ? _slot : null;
    _exposed = true;
    return _owner._spawnReserved(
      slot,
      entrypoint,
      message,
      onError: onError,
      onExit: onExit,
      errorsAreFatal: errorsAreFatal,
      debugName: debugName,
    );
  }

  bool cancelNeverSpawned() {
    if (_cancelled || _exposed || _slot == null) return false;
    _cancelled = true;
    _owner._cancelNeverExposed(_slot.bootstrap);
    return true;
  }
}

/// Actual worker ownership is separate from diagnostic credit retirement.
final class DiagnosticOwnedIsolate {
  DiagnosticOwnedIsolate._(this.isolate, this.bootstrap, this.retired);
  final Isolate isolate;
  final DiagnosticProducerBootstrap bootstrap;

  /// Diagnostic-only observation. Business completion must not await storage.
  final Future<void> retired;
}

extension _ProducerOwnership on LoggingSession {
  _OwnedProducer? _reserve(
    DiagnosticProducerKind kind, {
    SendPort? executingIsolate,
  }) {
    if (_closed || _writer == null) return null;
    for (var slot = 0; slot < LoggingSession.maximumProducers; slot++) {
      if (_slots[slot] != null || _generations[slot] == _maximumGeneration) {
        continue;
      }
      final generation = ++_generations[slot];
      final bootstrap = DiagnosticProducerBootstrap._(
        _writer,
        slot,
        generation,
        kind,
        configuration,
      );
      final owned = _OwnedProducer(bootstrap);
      _slots[slot] = owned;
      _writer.send([
        'reserve',
        slot,
        generation,
        0,
        kind.index,
        executingIsolate,
      ]);
      return owned;
    }
    health.producerRegistrationRefused = _sum(
      health.producerRegistrationRefused,
      1,
    );
    _registrationEdge();
    return null;
  }

  void _registrationEdge() {
    if (_registrationPending ||
        _closed ||
        _writer == null ||
        _registrationSent == health.producerRegistrationRefused) {
      return;
    }
    _registrationPending = true;
    _registrationSent = health.producerRegistrationRefused;
    _writer.send(['registration_refused', health.producerRegistrationRefused]);
  }

  bool _current(DiagnosticProducerBootstrap bootstrap) =>
      bootstrap._writer == _writer &&
      bootstrap.id >= 0 &&
      bootstrap.id < _slots.length &&
      _slots[bootstrap.id]?.bootstrap.generation == bootstrap.generation;
  void _cancelNeverExposed(DiagnosticProducerBootstrap bootstrap) {
    if (_current(bootstrap)) {
      _writer?.send(['never_spawned', bootstrap.id, bootstrap.generation, 0]);
    }
  }

  void _retired(int slot, int generation) {
    if (slot < 0 || slot >= _slots.length) return;
    final owned = _slots[slot];
    if (owned == null || owned.bootstrap.generation != generation) return;
    owned.local?._markRetired();
    final completion = owned.completion;
    if (completion != null && !completion.isCompleted) completion.complete();
    _slots[slot] = null;
  }
}
