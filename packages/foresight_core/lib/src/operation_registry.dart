import 'dart:async';

import 'operation_descriptor.dart';
import 'operation_requests.dart';
import 'operations.dart';
import 'rpc_error.dart';

typedef OperationCallback<T extends OperationRequest> =
    FutureOr<Object?> Function(T request, {bool Function()? current});

/// Dispatch ownership only. Admission, activity and resource lifetime belong to
/// the caller's service/application wrapper, never to this table.
abstract interface class OperationHandler {
  Operation get operation;
  FutureOr<Object?> invoke(
    OperationRequest request, {
    bool Function()? current,
  });
}

/// The single checked type-erasure point between an exhaustive heterogeneous
/// table and concrete feature handlers. A mismatched registration is a program
/// error, not a malformed caller argument.
final class TypedOperationHandler<T extends OperationRequest>
    implements OperationHandler {
  const TypedOperationHandler(this.operation, this.callback);

  @override
  final Operation operation;
  final OperationCallback<T> callback;

  @override
  FutureOr<Object?> invoke(
    OperationRequest request, {
    bool Function()? current,
  }) {
    if (request.operation != operation || request is! T) {
      throw RpcError(
        RpcErrorCode.internal,
        'Request type does not match the ${operation.wire} handler',
      );
    }
    return callback(request, current: current);
  }
}

final class OperationRegistry {
  OperationRegistry(this.scope, Iterable<OperationHandler> handlers) {
    final entries = <Operation, OperationHandler>{};
    for (final handler in handlers) {
      if (handler.operation.descriptor.scope != scope) {
        throw ArgumentError(
          '${handler.operation.wire} belongs to '
          '${handler.operation.descriptor.scope.name} dispatch, not ${scope.name}',
        );
      }
      if (entries.containsKey(handler.operation)) {
        throw ArgumentError('Duplicate handler for ${handler.operation.wire}');
      }
      entries[handler.operation] = handler;
    }
    final missing = Operation.values.where(
      (operation) =>
          operation.descriptor.scope == scope &&
          !entries.containsKey(operation),
    );
    if (missing.isNotEmpty) {
      throw ArgumentError(
        'Missing ${scope.name} handlers: '
        '${missing.map((operation) => operation.wire).join(', ')}',
      );
    }
    _handlers = Map.unmodifiable(entries);
  }

  final OperationScope scope;
  late final Map<Operation, OperationHandler> _handlers;
  Set<Operation> get operations => Set.unmodifiable(_handlers.keys);

  /// A stream-shaped handler returns its Stream as the result; the service
  /// wrapper owns subscription, cancellation and settlement of that stream.
  Future<Object?> dispatch(
    OperationRequest request, {
    bool Function()? current,
  }) => Future.sync(() => invoke(request, current: current));

  /// Synchronous handlers keep their admission effects in the current turn.
  /// This matters for desktop attachment and its subsequent socket requests.
  FutureOr<Object?> invoke(
    OperationRequest request, {
    bool Function()? current,
  }) {
    final handler = _handlers[request.operation];
    if (handler == null) {
      throw RpcError(
        RpcErrorCode.invalidArgument,
        scope == OperationScope.application
            ? 'Operation requires service dispatch: ${request.operation.wire}'
            : 'Operation requires application dispatch: ${request.operation.wire}',
      );
    }
    return handler.invoke(request, current: current);
  }
}
