part of 'session.dart';

/// Closed numeric inspection used by resource/lifecycle fixtures only.
final class DiagnosticProducerBudget {
  DiagnosticProducerBudget._(List value)
    : slot = value[0] as int,
      generation = value[1] as int,
      normalEpoch = value[2] as int,
      priorityEpoch = value[3] as int,
      normalBytes = value[4] as int,
      normalRecords = value[5] as int,
      priorityBytes = value[6] as int,
      priorityRecords = value[7] as int,
      quarantined = value[8] as bool;
  final int slot,
      generation,
      normalEpoch,
      priorityEpoch,
      normalBytes,
      normalRecords,
      priorityBytes,
      priorityRecords;
  final bool quarantined;
}

final class DiagnosticBudgetSnapshot {
  DiagnosticBudgetSnapshot._(List value)
    : normalBytes = value[0] as int,
      priorityBytes = value[1] as int,
      normalRecords = value[2] as int,
      priorityRecords = value[3] as int,
      queuedBytes = value[4] as int,
      queuedRecords = value[5] as int,
      producers = List.unmodifiable(
        (value[6] as List).map((p) => DiagnosticProducerBudget._(p as List)),
      );
  final int normalBytes,
      priorityBytes,
      normalRecords,
      priorityRecords,
      queuedBytes,
      queuedRecords;
  final List<DiagnosticProducerBudget> producers;
  int get producerBytes => normalBytes + priorityBytes;
  int get producerRecords => normalRecords + priorityRecords;
  int get scratchBytes => producers.length * 8 * 1024 + 16 * 1024;
  int get reservedTrafficBytes =>
      producerBytes +
      scratchBytes +
      LoggingSession.maximumIpcBytes +
      LoggingSession.maximumControlBytes;
}
