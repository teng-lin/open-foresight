part of 'session.dart';

enum NativeDiagnosticHealth {
  unconfigured,
  healthy,
  unsupported,
  capacity,
  protocolFailed,
  unsettled,
}

void _nativeConfigurationUnavailable() {
  for (final producer in DiagnosticProducer._connections) {
    if (producer != null && producer.active) {
      producer._writer!.send([
        'native_unsupported',
        producer.slot,
        producer.generation,
        0,
      ]);
      return;
    }
  }
}

void _nativeImageLoaded(NativeLibrary loaded) {
  if (DiagnosticProducer._nativeAnnounced) return;
  for (final producer in DiagnosticProducer._connections) {
    if (producer == null ||
        producer._closed ||
        producer._writer == null ||
        !producer.configuration.enabled)
      continue;
    DiagnosticProducer._nativeAnnounced = true;
    try {
      final functions = NativeDiagnosticQueueFunctions.fromLoaded(loaded);
      if (functions != null &&
          functions.pin() &&
          functions.configureLevel(producer.configuration.level.name)) {
        NativeLibrary.diagnosticConfigurationAccepted = true;
        producer._writer!.send([
          'native_attach',
          producer.slot,
          producer.generation,
          0,
          functions.codeAddresses,
        ]);
        return;
      }
    } catch (_) {
      // The business runtime retains its independent required ABI checks.
    }
    producer._writer!.send([
      'native_unsupported',
      producer.slot,
      producer.generation,
      0,
    ]);
    return;
  }
}

extension _NativeDrainReservation on LoggingSession {
  void _reserveNativeDrain(List<int> capabilities) {
    if (_closed || _nativeDrainSlot != null || _isolate == null) return;
    _pendingNativeCapabilities = capabilities;
    final slot = _reserve(
      DiagnosticProducerKind.nativeDrain,
      executingIsolate: _isolate.controlPort,
    );
    if (slot == null) {
      _writer?.send(['native_capacity']);
      return;
    }
    _nativeDrainSlot = slot;
    _pendingNativeCapabilities = null;
    _writer!.send(['native_bind', slot.bootstrap, capabilities]);
  }
}

extension _NativeWriterControl on _Writer {
  void _nativeStatus(NativeDiagnosticHealth next) {
    if (_nativeReason == next) return;
    _nativeReason = next;
    _nativeHealthPending = true;
  }

  void _publishNativeHealth() {
    if (!_nativeHealthPending) return;
    _nativeHealthPending = false;
    owner.send(['native_health', _nativeReason.index, _nativeDropsExact]);
  }

  void _nativePrecisionLost() {
    if (!_nativeDropsExact) return;
    _nativeDropsExact = false;
    _nativePrecisionPending = _nativeHealthPending = true;
  }

  bool _nativeControl(List value) {
    switch (value.first) {
      case 'native_attach':
      case 'native_unsupported':
        final source = ledger.matching(value);
        if (closing ||
            source == null ||
            source.port == null ||
            source.quarantined ||
            value[3] != 0)
          return true;
        if (value.first == 'native_unsupported') {
          _nativeQueue?.disabled = true;
          _nativeStatus(NativeDiagnosticHealth.unsupported);
        } else if (!_nativeRequested && value.length == 5) {
          _nativeRequested = true;
          final functions =
              NativeDiagnosticQueueFunctions.fromPinnedCodeAddresses(
                value[4] as List<int>,
              );
          owner.send(['native_reserve', functions.codeAddresses]);
        }
        return true;
      case 'native_capacity':
        _nativeStatus(NativeDiagnosticHealth.capacity);
        return true;
      case 'native_bind':
        if (closing || _nativeQueue != null || value.length != 3) return true;
        final bootstrap = value[1] as DiagnosticProducerBootstrap;
        if (bootstrap.kind != DiagnosticProducerKind.nativeDrain ||
            bootstrap._executionVm != Isolate.current.controlPort)
          return true;
        final functions =
            NativeDiagnosticQueueFunctions.fromPinnedCodeAddresses(
              value[2] as List<int>,
            );
        final producer = bootstrap.connect();
        _nativeQueue = _NativeQueueAdapter(this, producer, functions);
        return true;
    }
    return false;
  }

  void _nativeTick() {
    if (!_nativeClosing && !closing && !_finished) _nativeQueue?.tick();
  }

  bool _finishNative() {
    final adapter = _nativeQueue;
    if (adapter == null) return true;
    _nativeClosing = _nativeFinishing = true;
    if (!adapter.close()) {
      _nativeStatus(NativeDiagnosticHealth.unsettled);
      return false;
    }
    if (adapter.pending && _nativeReason == NativeDiagnosticHealth.healthy) {
      _nativeStatus(NativeDiagnosticHealth.capacity);
    }
    adapter.producer.close();
    final slot = adapter.producer.slot;
    if (slot >= 0 &&
        ledger.slots[slot]?.snapshot.generation == adapter.producer.generation)
      return false;
    adapter.producer._markRetired();
    _nativeFinishing = false;
    return true;
  }
}

/// Uses an ordinary nativeDrain producer slot; its leases are already charged
/// in the shared ledger before any FFI record is removed. No additional timer,
/// unbounded batch or separate producer/writer traffic allowance is added.
final class _NativeQueueAdapter {
  _NativeQueueAdapter(this.writer, this.producer, this.functions);
  final _Writer writer;
  final DiagnosticProducer producer;
  final NativeDiagnosticQueueFunctions functions;
  NativeDiagnosticQueue? queue;
  bool disabled = false, pending = true;

  // No identities/stacks/strings cross this bridge. All closed enum spellings
  // and maximal fixed numeric fields fit this producer envelope (tested).
  static const maximumWireBytes =
      LoggingSession.maximumNativeProducerEventBytes;
  static const maximumCharge = maximumWireBytes * 4 + 256;

  void tick() {
    if (disabled || !producer.active) return;
    queue ??= NativeDiagnosticQueue.tryOpenPinned(functions);
    final current = queue;
    if (current == null) {
      writer._nativeStatus(NativeDiagnosticHealth.unsettled);
      pending = true;
      return;
    }
    var remaining = NativeDiagnosticQueue.maximumRecords;
    pending = true;
    while (remaining > 0) {
      final normal = producer._revokeNormal == null
          ? (producer._bytes ~/ maximumCharge).clamp(0, producer._records)
          : 0;
      final priority = producer._revokePriority == null
          ? (producer._priority ~/ maximumCharge).clamp(
              0,
              producer._priorityCount,
            )
          : 0;
      final priorityOnly = normal == 0;
      final permits = priorityOnly ? priority : normal;
      if (permits == 0) {
        producer._pressure(false);
        writer._nativeStatus(NativeDiagnosticHealth.capacity);
        return;
      }
      final capacity = permits.clamp(1, remaining);
      final batch = current.poll(
        capacity: capacity,
        priorityOnly: priorityOnly,
        onRecord: _emit,
      );
      if (batch == null) {
        writer._nativeStatus(
          current.invalid
              ? NativeDiagnosticHealth.protocolFailed
              : NativeDiagnosticHealth.unsettled,
        );
        if (current.invalid) disabled = true;
        return;
      }
      writer._producerCounters(
        batch.droppedGeneral + batch.droppedPriority + batch.deliveryDropped,
        0,
      );
      if ((batch.precisionLost || batch.counterSaturated) &&
          writer._nativeDropsExact) {
        writer._nativePrecisionLost();
      }
      writer._nativeStatus(NativeDiagnosticHealth.healthy);
      remaining -= batch.count;
      if (batch.count < capacity) {
        pending = priorityOnly;
        if (priorityOnly) producer._pressure(false);
        if (priorityOnly) writer._nativeStatus(NativeDiagnosticHealth.capacity);
        return;
      }
    }
  }

  bool _emit(NativeDiagnosticRecord record) {
    final category = DiagnosticCategory.values[record.category];
    final event = record.priority
        ? DiagnosticEvent.nativeWorkerFailed
        : DiagnosticEvent.captureStateChanged;
    final severity = category == DiagnosticCategory.cancelled
        ? DiagnosticLevel.debug
        : category == DiagnosticCategory.closing
        ? DiagnosticLevel.info
        : event.severity;
    if (!writer.configuration.permits(severity)) return true;
    var precisionLost = false;
    int counter(int value) {
      if (value > _maximumCounter) precisionLost = true;
      return value.clamp(0, _maximumCounter);
    }

    final status = record.status >= -_maximumCounter ? record.status : null;
    final signal = record.signal >= -_maximumCounter ? record.signal : null;
    final bytes = counter(record.bytes), dropped = counter(record.dropped);
    final queued = counter(record.queued),
        duration = counter(record.durationUs);
    precisionLost |= status == null || signal == null;
    if (precisionLost) writer._nativePrecisionLost();
    return producer.emit(
      event,
      record.priority
          ? DiagnosticComponent.native
          : DiagnosticComponent.capture,
      fields: () => {
        DiagnosticField.category: category,
        DiagnosticField.outcome: DiagnosticOutcome.values[record.outcome],
        if (record.priority) ...{
          if (status != null) DiagnosticField.status: status,
          if (signal != null) DiagnosticField.signal: signal,
          DiagnosticField.bytes: bytes,
          DiagnosticField.dropped: dropped,
        } else ...{
          DiagnosticField.queued: queued,
          DiagnosticField.active: record.active,
          DiagnosticField.durationUs: duration,
        },
        if (precisionLost) DiagnosticField.precisionLost: true,
      },
    );
  }

  bool close() {
    try {
      return queue?.close() ?? true;
    } catch (_) {
      return false;
    }
  }
}
