import 'dart:async';

import 'diagnostics/session.dart';
import 'persistence/read_schema_guard.dart';
import 'rpc_error.dart';

final _serviceProducerKey = Object();
final _serviceComponentKey = Object();
final _serviceOwnershipKey = Object();
final _serviceEmitterKey = Object();

/// Bind only the producer already owned by this application entrypoint/worker.
T runWithServiceDiagnostics<T>(
  DiagnosticProducer? producer,
  T Function() body, {
  DiagnosticComponent component = DiagnosticComponent.service,
  DiagnosticOwnershipReporter? ownership,
}) => producer == null
    ? body()
    : runZoned(
        body,
        zoneValues: {
          _serviceProducerKey: producer,
          _serviceComponentKey: component,
          _serviceOwnershipKey: ownership,
          _serviceEmitterKey: producer.configuration.enabled
              ? ServiceDiagnosticEmitter._(producer, component)
              : null,
        },
      );

/// A narrow immutable capability for callbacks that execute outside their
/// construction Zone. It retains only the existing producer and closed component.
final class ServiceDiagnosticEmitter {
  const ServiceDiagnosticEmitter._(this._producer, this._component);
  final DiagnosticProducer _producer;
  final DiagnosticComponent _component;
  bool get active => _producer.active;
  bool emit(
    DiagnosticEvent event, {
    Map<DiagnosticField, Object> Function()? fields,
    DiagnosticIdentity? connection,
    int? request,
    int? attempt,
    DiagnosticIdentity? job,
  }) => _producer.emit(
    event,
    _component,
    fields: fields,
    connection: connection,
    request: request,
    attempt: attempt,
    job: job,
  );
  void noteCorrelationRefused() =>
      _producer.noteDropped(DiagnosticDropReason.correlationCapacity);
  int? clockMicros() => active
      ? (_operationClock ??= Stopwatch()..start()).elapsedMicroseconds
      : null;
}

/// Select only the captured construction-owner emitter for an opener. A null
/// owner explicitly masks an inherited caller emitter; all other Zone values,
/// including producer/component/ownership bindings, remain with the caller.
T runWithServiceDiagnosticEmitter<T>(
  ServiceDiagnosticEmitter? emitter,
  T Function() body,
) => runZoned(body, zoneValues: {_serviceEmitterKey: emitter});

/// Repeated captures in one owner scope reuse one handle. Disabled or unbound
/// construction allocates no handle and cannot later borrow a caller's producer.
ServiceDiagnosticEmitter? captureServiceDiagnosticEmitter() {
  final emitter = Zone.current[_serviceEmitterKey] as ServiceDiagnosticEmitter?;
  return emitter?.active == true ? emitter : null;
}

/// A causal observation from the actual profile-lock guard, never authority.
void noteServiceOwnershipDecision(OwnershipDecision decision) {
  try {
    (Zone.current[_serviceOwnershipKey] as DiagnosticOwnershipReporter?)
        ?.report(decision);
  } catch (_) {
    // A diagnostic endpoint cannot alter lock admission or cleanup.
  }
}

/// Await registration without making logging an application ownership gate.
Future<void> waitForServiceDiagnostics(DiagnosticProducer? producer) async {
  if (producer == null || !producer.configuration.enabled) return;
  try {
    await producer.ready.timeout(const Duration(milliseconds: 100));
  } catch (_) {
    // Diagnostic registration failure never prevents application startup.
  }
}

/// Announce process startup from its entrypoint producer before other producers
/// share normal credits. Exactly one continuation survives a short cold wait.
Future<void> startServiceDiagnostics(
  DiagnosticProducer? producer, {
  DiagnosticComponent component = DiagnosticComponent.service,
}) async {
  if (producer == null || !producer.configuration.enabled) return;
  // One continuation per service worker, released by the existing registration
  // lifecycle. A cold logger may become ready after application startup proceeds.
  final announced = producer.ready.then((_) {
    producer.emit(
      component == DiagnosticComponent.mcp
          ? DiagnosticEvent.mcpStarting
          : DiagnosticEvent.serviceStarting,
      component,
    );
  });
  try {
    await announced.timeout(const Duration(milliseconds: 100));
  } catch (_) {
    // Held, failed and unavailable logging must not prevent service startup.
  }
}

DiagnosticProducer? get _producer =>
    Zone.current[_serviceProducerKey] as DiagnosticProducer?;
DiagnosticComponent get _component =>
    Zone.current[_serviceComponentKey] as DiagnosticComponent? ??
    DiagnosticComponent.service;

/// Nonawaiting public status projection; an unbound caller has unknown health.
DiagnosticHealthSnapshot serviceDiagnosticHealth() =>
    _producer?.healthSnapshot ?? const DiagnosticHealthSnapshot();

bool get serviceDiagnosticsEnabled => _producer?.active ?? false;

/// Typed client/service integration. Builders remain unevaluated when disabled.
bool emitServiceDiagnostic(
  DiagnosticEvent event, {
  Map<DiagnosticField, Object> Function()? fields,
  DiagnosticIdentity? connection,
  int? request,
  int? attempt,
  DiagnosticIdentity? job,
}) =>
    _producer?.emit(
      event,
      _component,
      fields: fields,
      connection: connection,
      request: request,
      attempt: attempt,
      job: job,
    ) ??
    false;

void noteServiceDiagnosticCorrelationRefused() =>
    _producer?.noteDropped(DiagnosticDropReason.correlationCapacity);

/// One monotonic clock per enabled VM, shared with completion observations.
int? serviceDiagnosticClockMicros() => serviceDiagnosticsEnabled
    ? (_operationClock ??= Stopwatch()..start()).elapsedMicroseconds
    : null;

const _maximumObservedOperations = 1;
int _observedOperations = 0;
int _observedOperationAdmissions = 0, _observedOperationRefusals = 0;
Stopwatch? _operationClock;

/// Process-local VM counters, separate from record admission/drop counters.
/// Other service/MCP VMs are not aggregated or represented by this projection.
Map<String, Object> serviceDiagnosticObservation() => {
  'version': 1,
  'processWide': false,
  'capacity': _maximumObservedOperations,
  'active': serviceDiagnosticsEnabled ? _observedOperations : 0,
  'admitted': serviceDiagnosticsEnabled ? _observedOperationAdmissions : 0,
  'refused': serviceDiagnosticsEnabled ? _observedOperationRefusals : 0,
};

/// Observe only settled non-stream handler results. The existing service owns
/// streams, subscriptions, cancellation and request admission; none move here.
FutureOr<Object?> observeServiceOperation(
  String wire,
  FutureOr<Object?> Function() invoke,
) {
  final producer = _producer;
  if (producer == null || !producer.active) return invoke();
  final operation = DiagnosticOperation.parse(wire);
  if (operation == null) return invoke();
  if (_observedOperations >= _maximumObservedOperations) {
    _observedOperationRefusals = (_observedOperationRefusals + 1).clamp(
      0,
      0x7fffffff,
    );
    producer.noteDropped(DiagnosticDropReason.correlationCapacity);
    return invoke();
  }
  _observedOperations++;
  _observedOperationAdmissions = (_observedOperationAdmissions + 1).clamp(
    0,
    0x7fffffff,
  );
  final clock = _operationClock ??= Stopwatch()..start();
  final started = clock.elapsedMicroseconds;
  final component = _component;
  int duration() => (clock.elapsedMicroseconds - started).clamp(0, 0x7fffffff);
  void completed(Object? value) {
    if (value is Stream) return;
    producer.emit(
      DiagnosticEvent.rpcCompleted,
      component,
      fields: () => {
        DiagnosticField.operation: operation,
        DiagnosticField.outcome: DiagnosticOutcome.completed,
        DiagnosticField.durationUs: duration(),
      },
    );
  }

  void failed(Object error) {
    final category = error is RpcError
        ? switch (error.code) {
            RpcErrorCode.cancelled => DiagnosticCategory.cancelled,
            RpcErrorCode.denied => DiagnosticCategory.permission,
            RpcErrorCode.invalidArgument ||
            RpcErrorCode.notFound => DiagnosticCategory.validation,
            RpcErrorCode.busy ||
            RpcErrorCode.unavailable => DiagnosticCategory.unavailable,
            RpcErrorCode.internal => DiagnosticCategory.internal,
          }
        : DiagnosticCategory.internal;
    producer.emit(
      DiagnosticEvent.rpcFailed,
      component,
      fields: () => {
        DiagnosticField.operation: operation,
        DiagnosticField.category: category,
        DiagnosticField.durationUs: duration(),
        DiagnosticField.outcome: category == DiagnosticCategory.cancelled
            ? DiagnosticOutcome.cancelled
            : DiagnosticOutcome.failed,
      },
    );
  }

  var asynchronous = false;
  try {
    final result = invoke();
    if (result is Future<Object?>) {
      final observed = result.then<Object?>(
        (value) {
          try {
            completed(value);
            return value;
          } finally {
            _observedOperations--;
          }
        },
        onError: (Object error, StackTrace stack) {
          try {
            failed(error);
            Error.throwWithStackTrace(error, stack);
          } finally {
            _observedOperations--;
          }
        },
      );
      asynchronous = true;
      return observed;
    }
    completed(result);
    return result;
  } catch (error) {
    failed(error);
    rethrow;
  } finally {
    if (!asynchronous) _observedOperations--;
  }
}

/// Compatibility for callers whose original message can contain private data.
/// It is intentionally never evaluated, even at trace level.
void traceServiceTransport(String Function() _) {
  _producer?.emit(DiagnosticEvent.transportActivity, _component);
}

RpcError requestFailure(Object error, StackTrace stack) {
  final failure = error is IncompatibleReadSchema
      ? error.rpcError
      : RpcError.from(error);
  if (failure.code == RpcErrorCode.internal) {
    _producer?.emit(
      DiagnosticEvent.rpcFailed,
      _component,
      fields: () => {
        DiagnosticField.category: DiagnosticCategory.internal,
        DiagnosticField.outcome: DiagnosticOutcome.failed,
      },
    );
  }
  return failure;
}
