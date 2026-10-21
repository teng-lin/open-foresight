import '../operations.dart';
import '../operation_argument_schema.dart';
import '../request_fingerprint.dart';

/// v1 envelope fields remain on the wire in args. Their raw fingerprint and
/// caller field presence survive typed normalization and service handoff.
class OperationRequestContext {
  OperationRequestContext._({
    required this.requestId,
    required this.conversation,
    required this.workspaceEpoch,
    required this.idempotencyKey,
    required this.rawArgumentsDigest,
    required this.rawArguments,
  });
  final String? requestId, conversation, workspaceEpoch, idempotencyKey;
  final String rawArgumentsDigest;
  final Map<String, dynamic> rawArguments;

  factory OperationRequestContext.decode(
    Operation operation,
    Map<String, dynamic> args,
  ) {
    for (final name in [
      'requestId',
      'conversation',
      'workspace_epoch',
      'idempotency_key',
    ]) {
      if (args[name] != null && args[name] is! String) {
        invalidArgument(name, 'must be a string');
      }
    }
    final key = args['idempotency_key'] as String?;
    if (key != null && !operation.descriptor.acceptsIdempotencyKey) {
      invalidArgument(
        'idempotency_key',
        'is not supported by ${operation.wire}',
      );
    }
    if (key != null && (key.isEmpty || key.length > 256)) {
      invalidArgument(
        'idempotency_key',
        'must be a string of 1 to 256 characters',
      );
    }
    final frozen = _freeze(args);
    return OperationRequestContext._(
      requestId: args['requestId'] as String?,
      conversation: args['conversation'] as String?,
      workspaceEpoch: args['workspace_epoch'] as String?,
      idempotencyKey: key,
      rawArgumentsDigest: requestArgumentsDigest(args),
      rawArguments: frozen as Map<String, dynamic>,
    );
  }
}

Object? _freeze(Object? value) {
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        invalidArgument('args', 'must have string object keys');
      }
      result[entry.key as String] = _freeze(entry.value);
    }
    return Map<String, dynamic>.unmodifiable(result);
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value is num && !value.isFinite) {
    invalidArgument('args', 'must contain finite JSON numbers');
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  invalidArgument('args', 'must contain JSON values');
}

abstract class OperationRequest {
  const OperationRequest(this.context);
  final OperationRequestContext context;
  Operation get operation;
  Map<String, dynamic> get rawArguments => context.rawArguments;
}
