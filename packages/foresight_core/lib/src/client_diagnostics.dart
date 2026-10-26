import 'dart:io';

import 'diagnostics/session.dart';
import 'rpc_error.dart';
import 'service_diagnostics.dart';

// These slots retain only generated identities, closed operations and scalars.
// They never retain sockets, arguments, results, errors, Zones or callbacks.
// The runtime budget owner measures this cap before any increase.
const _capacity = 1;
int _connections = 0, _connectionRefusals = 0, _callRefusals = 0;
int _connectionAdmissions = 0, _callAdmissions = 0;
int _now() => serviceDiagnosticClockMicros() ?? 0;
int _duration(int started) => (_now() - started).clamp(0, 0x7fffffff);
int _increment(int value) => (value + 1).clamp(0, 0x7fffffff);

void _refuse({required bool connection}) {
  if (!serviceDiagnosticsEnabled) return;
  if (connection) {
    _connectionRefusals = _increment(_connectionRefusals);
  } else {
    _callRefusals = _increment(_callRefusals);
  }
  noteServiceDiagnosticCorrelationRefused();
}

Map<String, int> clientDiagnosticObservation() => {
  'version': 1,
  'callCapacity': _capacity,
  'connectionCapacity': _capacity,
  'connections': _connections,
  'calls': ClientDiagnosticCall._active == null ? 0 : 1,
  'connectionAdmissions': _connectionAdmissions,
  'callAdmissions': _callAdmissions,
  'connectionRefusals': _connectionRefusals,
  'callRefusals': _callRefusals,
};

/// A bounded diagnostic socket identity; it conveys no connection authority.
final class ClientDiagnosticConnection {
  ClientDiagnosticConnection._()
    : _identity = DiagnosticIdentity.random(),
      _started = _now();
  DiagnosticIdentity? _identity;
  DiagnosticIdentity? get identity => _identity;
  int _started;

  static ClientDiagnosticConnection? begin() {
    if (!serviceDiagnosticsEnabled) return null;
    if (_connections >= _capacity) {
      _refuse(connection: true);
      return null;
    }
    _connections++;
    try {
      final value = ClientDiagnosticConnection._();
      _connectionAdmissions = _increment(_connectionAdmissions);
      value.record(DiagnosticOutcome.started);
      return value;
    } catch (_) {
      _connections--;
      return null;
    }
  }

  void record(
    DiagnosticOutcome outcome, {
    DiagnosticCategory? category,
    int? count,
  }) {
    if (identity == null) return;
    emitServiceDiagnostic(
      DiagnosticEvent.rpcConnectionChanged,
      connection: identity,
      fields: () => {
        DiagnosticField.outcome: outcome,
        DiagnosticField.durationUs: _duration(_started),
        if (category != null) DiagnosticField.category: category,
        if (count != null) DiagnosticField.count: count.clamp(0, 0x7fffffff),
      },
    );
  }

  void close(DiagnosticOutcome outcome, DiagnosticCategory category) {
    if (identity == null) return;
    try {
      record(outcome, category: category);
    } finally {
      _identity = null;
      _started = 0;
      _connections--;
    }
  }
}

/// One live local call span, shared only across the transport's existing retry.
/// The call ID is local. Only wire ID plus connection evidence joins a service
/// record; no client identity is sent over the socket.
final class ClientDiagnosticCall {
  ClientDiagnosticCall._(this._operation, this._ownsLifetime)
    : _identity = DiagnosticIdentity.random(),
      _started = _now();
  static ClientDiagnosticCall? _active;
  DiagnosticIdentity? _identity, _connection;
  DiagnosticOperation? _operation;
  int? _wire;
  int _attempt = 0, _started;
  final bool _ownsLifetime;
  bool _settled = false;

  static ClientDiagnosticCall? begin(String wire, {bool ownsLifetime = false}) {
    if (!serviceDiagnosticsEnabled || wire.length > 96) return null;
    final operation = DiagnosticOperation.parse(wire);
    if (operation == null) return null;
    if (_active != null) {
      _refuse(connection: false);
      return null;
    }
    try {
      final call = _active = ClientDiagnosticCall._(operation, ownsLifetime);
      _callAdmissions = _increment(_callAdmissions);
      return call;
    } catch (_) {
      return null;
    }
  }

  void attach(DiagnosticIdentity? connection, int wire, int attempt) {
    if (_identity == null) return;
    if (connection == null) {
      _refuse(connection: false);
      release();
      return;
    }
    _connection = connection;
    _wire = wire;
    _attempt = attempt;
    _settled = false;
  }

  static ClientDiagnosticCall? forWire(DiagnosticIdentity? connection, int id) {
    final call = _active;
    return connection != null &&
            call?._connection == connection &&
            call?._wire == id
        ? call
        : null;
  }

  static ClientDiagnosticCall? forConnection(DiagnosticIdentity? connection) {
    final call = _active;
    return connection != null && call?._connection == connection ? call : null;
  }

  void settle([Object? error]) {
    if (_identity == null || _settled) return;
    _settled = true;
    final (category, outcome) = _classify(error);
    final identity = _identity!, operation = _operation!;
    emitServiceDiagnostic(
      error == null ? DiagnosticEvent.rpcCompleted : DiagnosticEvent.rpcFailed,
      connection: _connection,
      request: _wire,
      attempt: _attempt,
      fields: () => {
        DiagnosticField.call: identity,
        DiagnosticField.operation: operation,
        DiagnosticField.outcome: outcome,
        DiagnosticField.durationUs: _duration(_started),
        if (category != null) DiagnosticField.category: category,
      },
    );
    if (_ownsLifetime) release();
  }

  void unwritten(Object error, int attempt) {
    _connection = null;
    _wire = null;
    _attempt = attempt;
    _settled = false;
    settle(error);
  }

  void cancel() {
    settle(RpcError(RpcErrorCode.cancelled, 'Client cancelled'));
    release();
  }

  void release() {
    if (_identity == null) return;
    _identity = null;
    _connection = null;
    _operation = null;
    _wire = null;
    _attempt = _started = 0;
    if (identical(_active, this)) _active = null;
  }
}

(DiagnosticCategory?, DiagnosticOutcome) _classify(Object? error) {
  if (error == null) return (null, DiagnosticOutcome.completed);
  if (error is RpcError) {
    if (error.reason == RpcErrorReason.outcomeUnknown) {
      return (DiagnosticCategory.transport, DiagnosticOutcome.unknown);
    }
    if (isClosingRefusal(error)) {
      return (DiagnosticCategory.closing, DiagnosticOutcome.refused);
    }
    if (error.reason == RpcErrorReason.notSent) {
      return (DiagnosticCategory.transport, DiagnosticOutcome.refused);
    }
    return switch (error.code) {
      RpcErrorCode.cancelled => (
        DiagnosticCategory.cancelled,
        DiagnosticOutcome.cancelled,
      ),
      RpcErrorCode.denied => (
        DiagnosticCategory.permission,
        DiagnosticOutcome.failed,
      ),
      RpcErrorCode.invalidArgument || RpcErrorCode.notFound => (
        DiagnosticCategory.validation,
        DiagnosticOutcome.failed,
      ),
      RpcErrorCode.busy || RpcErrorCode.unavailable => (
        DiagnosticCategory.unavailable,
        DiagnosticOutcome.failed,
      ),
      RpcErrorCode.internal => (
        DiagnosticCategory.internal,
        DiagnosticOutcome.failed,
      ),
    };
  }
  return (
    error is SocketException
        ? DiagnosticCategory.transport
        : DiagnosticCategory.internal,
    DiagnosticOutcome.refused,
  );
}
