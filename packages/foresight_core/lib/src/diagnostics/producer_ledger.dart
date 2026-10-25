part of 'session.dart';

const _maximumGeneration = 0x7fffffffffffffff;
const _normalPoolBytes = 64 * 1024, _priorityPoolBytes = 128 * 1024;
const _normalPoolRecords = 160, _priorityPoolRecords = 64;

final class _WriterProducer {
  _WriterProducer(this.snapshot);
  final DiagnosticProducerSnapshot snapshot;
  SendPort? port, expectedIsolate;
  bool vmExitBound = false;
  int normalEpoch = 1, priorityEpoch = 1, sequence = 0;
  int bytes = 0, records = 0, priority = 0, priorityCount = 0;
  int? revokeNormal, revokePriority;
  bool quarantined = false, wantsNormal = false, wantsPriority = false;
  bool normalIssued = false, priorityIssued = false;
}

/// Credits never leave this ledger until a causal terminal/revoke/VM barrier.
/// Queued charges are independent of occupants; completions cannot refund a
/// slot that has since acquired a different generation.
final class _ProducerLedger {
  _ProducerLedger(this.owner, this.counters);
  final SendPort owner;
  final void Function(int, int) counters;
  final slots = List<_WriterProducer?>.filled(
    LoggingSession.maximumProducers,
    null,
  );
  final generations = Uint64List(LoggingSession.maximumProducers);
  int normalUsed = 0, priorityUsed = 0, normalTickets = 0, priorityTickets = 0;
  int registrationRefused = 0, cursor = 0;
  bool closing = false;
  int get quarantined => slots.where((p) => p?.quarantined ?? false).length;
  int get usedBytes => normalUsed + priorityUsed;
  int get usedRecords => normalTickets + priorityTickets;

  _WriterProducer? matching(List value) {
    if (value.length < 4 ||
        value[1] is! int ||
        value[2] is! int ||
        value[3] is! int) {
      return null;
    }
    final slot = value[1] as int;
    if (slot < 0 || slot >= slots.length) return null;
    final producer = slots[slot];
    return producer?.snapshot.generation == value[2] ? producer : null;
  }

  bool handle(List value) {
    switch (value.first) {
      case 'reserve':
        final slot = value[1] as int, generation = value[2] as int;
        if (closing ||
            value[3] != 0 ||
            slot < 0 ||
            slot >= slots.length ||
            generation <= 0 ||
            generation > _maximumGeneration ||
            slots[slot] != null ||
            generation <= generations[slot]) {
          return true;
        }
        generations[slot] = generation;
        slots[slot] = _WriterProducer(
          DiagnosticProducerSnapshot(
            DiagnosticProducerKind.values[value[4] as int],
            slot,
            generation,
          ),
        );
        slots[slot]!.expectedIsolate = value[5] as SendPort?;
        return true;
      case 'registration_refused':
        registrationRefused = (value[1] as int).clamp(
          registrationRefused,
          _maximumCounter,
        );
        owner.send(['registration_refused_ack', registrationRefused]);
        return true;
      case 'bind_vm':
        final producer = matching(value);
        if (producer != null &&
            value[3] == 0 &&
            producer.port == null &&
            producer.expectedIsolate == null &&
            !producer.vmExitBound) {
          producer.expectedIsolate = value[4] as SendPort;
          producer.vmExitBound = true;
        }
        return true;
      case 'register':
        final port = value[4] as SendPort, producer = matching(value);
        if (closing ||
            value[3] != 0 ||
            producer == null ||
            producer.port != null ||
            producer.quarantined ||
            (producer.expectedIsolate != null &&
                producer.expectedIsolate != value[5])) {
          port.send(['stop', value[1], value[2], 0]);
          return true;
        }
        producer.port = port;
        producer.expectedIsolate ??= value[5] as SendPort;
        producer.wantsNormal = producer.wantsPriority = true;
        _grant(producer, false, initial: true);
        _grant(producer, true, initial: true);
        _rebalanceNormal(producer);
        return true;
      case 'owner_exit':
        final producer = matching(value);
        if (producer != null && value[3] == 0) _quarantine(producer);
        return true;
      case 'actual_exit':
        final producer = matching(value);
        if (producer != null && producer.vmExitBound && value[3] == 0) {
          _retire(producer);
        }
        return true;
      case 'never_spawned':
        final producer = matching(value);
        if (producer != null && value[3] == 0) {
          if (producer.port == null) {
            _retire(producer);
          } else {
            _quarantine(producer);
          }
        }
        return true;
      case 'pressure':
        final producer = matching(value);
        if (producer == null || producer.quarantined) return true;
        final priority = value[4] as bool;
        if (value[3] !=
            (priority ? producer.priorityEpoch : producer.normalEpoch)) {
          return true;
        }
        counters(value[5] as int, value[6] as int);
        if (priority) {
          producer.wantsPriority = true;
        } else {
          producer.wantsNormal = true;
        }
        _revoke(producer, priority);
        return true;
      case 'terminal':
        final producer = matching(value);
        if (producer == null || value.length != 12) return true;
        // Terminal carries both credit epochs and the final sent sequence.
        if (value[3] != producer.normalEpoch ||
            value[4] != producer.priorityEpoch ||
            value[5] != producer.sequence ||
            value[6] != producer.bytes ||
            value[7] != producer.records ||
            value[8] != producer.priority ||
            value[9] != producer.priorityCount) {
          _quarantine(producer);
          return true;
        }
        counters(value[10] as int, value[11] as int);
        _retire(producer);
        return true;
      case 'revoke_ack':
        final producer = matching(value);
        if (producer == null || producer.quarantined || value.length != 10) {
          return true;
        }
        final priority = value[4] as bool, epoch = value[3] as int;
        final expected = priority
            ? producer.revokePriority
            : producer.revokeNormal;
        if (epoch !=
                (priority ? producer.priorityEpoch : producer.normalEpoch) ||
            value[5] != producer.sequence ||
            expected == null ||
            value[9] != expected ||
            value[6] != (priority ? producer.priority : producer.bytes) ||
            value[7] !=
                (priority ? producer.priorityCount : producer.records)) {
          _quarantine(producer);
          return true;
        }
        final counts = value[8] as List;
        counters(counts[0] as int, counts[1] as int);
        _releaseUnused(producer, priority);
        if (priority) {
          producer.priorityEpoch = expected;
          producer.priorityIssued = false;
          producer.revokePriority = null;
        } else {
          producer.normalEpoch = expected;
          producer.normalIssued = false;
          producer.revokeNormal = null;
        }
        _grant(producer, priority);
        return true;
    }
    return false;
  }

  DiagnosticProducerSnapshot? consume(List value, int cost, bool priority) {
    final producer = matching(value);
    if (closing ||
        producer == null ||
        producer.quarantined ||
        producer.port == null ||
        value[3] !=
            (priority ? producer.priorityEpoch : producer.normalEpoch) ||
        value[4] != producer.sequence + 1 ||
        cost < 256 ||
        cost > (priority ? producer.priority : producer.bytes) ||
        (priority ? producer.priorityCount : producer.records) < 1) {
      return null;
    }
    producer.sequence++;
    if (priority) {
      producer.priority -= cost;
      producer.priorityCount--;
    } else {
      producer.bytes -= cost;
      producer.records--;
    }
    // Global used totals deliberately do not change: lease -> queued record.
    return producer.snapshot;
  }

  void completed(int cost, bool priority) {
    if (priority) {
      priorityUsed -= cost;
      priorityTickets--;
    } else {
      normalUsed -= cost;
      normalTickets--;
    }
    // No lookup of the old record's slot, kind or later generation occurs.
  }

  void _quarantine(_WriterProducer producer) {
    if (producer.quarantined) return;
    producer.quarantined = true;
    producer.port?.send([
      'stop',
      producer.snapshot.slot,
      producer.snapshot.generation,
      0,
    ]);
  }

  void _releaseUnused(_WriterProducer producer, bool priority) {
    if (priority) {
      priorityUsed -= producer.priority;
      priorityTickets -= producer.priorityCount;
      producer.priority = producer.priorityCount = 0;
    } else {
      normalUsed -= producer.bytes;
      normalTickets -= producer.records;
      producer.bytes = producer.records = 0;
    }
  }

  void _retire(_WriterProducer producer) {
    _releaseUnused(producer, false);
    _releaseUnused(producer, true);
    final identity = producer.snapshot;
    slots[identity.slot] = null;
    owner.send(['retired', identity.slot, identity.generation, 0]);
    producer.port?.send(['retired', identity.slot, identity.generation, 0]);
    rebalance();
  }

  void _grant(_WriterProducer producer, bool priority, {bool initial = false}) {
    if (closing ||
        producer.quarantined ||
        producer.port == null ||
        (priority ? producer.revokePriority : producer.revokeNormal) != null) {
      return;
    }
    if (priority ? producer.priorityIssued : producer.normalIssued) {
      _revoke(producer, priority);
      return;
    }
    final freeBytes = priority
        ? _priorityPoolBytes - priorityUsed
        : _normalPoolBytes - normalUsed;
    final freeRecords = priority
        ? _priorityPoolRecords - priorityTickets
        : _normalPoolRecords - normalTickets;
    // Sole normal producer may fill the catalog-small cold100 envelope. Once
    // peers need credits, unused leases are reclaimed by ordered revoke ACKs.
    final active = slots
        .where((p) => p?.port != null && !p!.quarantined)
        .length;
    final targetBytes = priority
        ? _priorityBytes
        : active == 1
        ? _normalPoolBytes
        : _normalBytes;
    final targetRecords = priority
        ? _priorityRecords
        : active == 1
        ? _normalPoolRecords
        : _normalRecords;
    final currentBytes = priority ? producer.priority : producer.bytes;
    final currentRecords = priority ? producer.priorityCount : producer.records;
    final bytes = (targetBytes - currentBytes).clamp(0, freeBytes);
    final records = (targetRecords - currentRecords).clamp(0, freeRecords);
    if (!initial && (bytes < _cost(2) || records == 0)) return;
    if (priority) {
      producer.priority += bytes;
      producer.priorityCount += records;
      priorityUsed += bytes;
      priorityTickets += records;
      producer.wantsPriority = false;
      producer.priorityIssued = true;
    } else {
      producer.bytes += bytes;
      producer.records += records;
      normalUsed += bytes;
      normalTickets += records;
      producer.wantsNormal = records == 0 || bytes < _cost(2);
      producer.normalIssued = true;
    }
    producer.port!.send([
      'credits',
      producer.snapshot.slot,
      producer.snapshot.generation,
      priority ? producer.priorityEpoch : producer.normalEpoch,
      priority,
      bytes,
      records,
    ]);
  }

  void _revoke(_WriterProducer producer, bool priority) {
    if (producer.quarantined ||
        producer.port == null ||
        closing ||
        (priority ? producer.revokePriority : producer.revokeNormal) != null) {
      return;
    }
    final epoch = priority ? producer.priorityEpoch : producer.normalEpoch;
    if (epoch == _maximumGeneration) {
      _quarantine(producer);
      return;
    }
    if (priority) {
      producer.revokePriority = epoch + 1;
    } else {
      producer.revokeNormal = epoch + 1;
    }
    producer.port!.send([
      'revoke',
      producer.snapshot.slot,
      producer.snapshot.generation,
      epoch,
      priority,
      epoch + 1,
    ]);
  }

  void _rebalanceNormal(_WriterProducer receiver) {
    if (!receiver.wantsNormal) return;
    for (var step = 0; step < slots.length; step++) {
      final index = cursor, candidate = slots[index];
      cursor = (cursor + 1) % slots.length;
      if (candidate != null &&
          !identical(candidate, receiver) &&
          candidate.bytes > _normalBytes &&
          candidate.revokeNormal == null) {
        _revoke(candidate, false);
        break;
      }
    }
  }

  void rebalance() {
    if (closing) return;
    for (var step = 0; step < slots.length; step++) {
      final producer = slots[(cursor + step) % slots.length];
      if (producer == null || producer.quarantined || producer.port == null) {
        continue;
      }
      if (producer.wantsNormal) {
        _grant(producer, false);
        _rebalanceNormal(producer);
      }
      if (producer.wantsPriority) _grant(producer, true);
      // Replenishment is epoch based. The old local lease must settle first.
      if (producer.records == 0 || producer.bytes < _cost(100)) {
        producer.wantsNormal = true;
        _revoke(producer, false);
      }
      if (producer.priorityCount == 0 || producer.priority < _cost(100)) {
        producer.wantsPriority = true;
        _revoke(producer, true);
      }
    }
    cursor = (cursor + 1) % slots.length;
  }

  void close() {
    closing = true;
    for (final producer in slots) {
      producer?.port?.send([
        'stop',
        producer.snapshot.slot,
        producer.snapshot.generation,
        0,
      ]);
    }
  }
}
