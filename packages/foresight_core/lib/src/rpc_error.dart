import 'package:grpc/grpc.dart';

/// Stable error codes shared by service, desktop and MCP clients.
enum RpcErrorCode {
  invalidArgument,
  notFound,
  busy,
  cancelled,
  unavailable,
  denied,
  internal,
}

/// Whether a failed request may have taken effect. Optional on the wire:
/// peers that predate it omit it, and old clients ignore it.
enum RpcErrorReason {
  /// The service refused the request before dispatching it, because it is
  /// closing. Retrying after the ownership handoff is safe.
  closing,

  /// The request was dispatched, or written to the socket, and no terminal
  /// frame arrived. It may have committed.
  outcomeUnknown,

  /// Client-local: the request never reached a live socket. Retrying is safe.
  notSent,
}

// Preserve existing StateError catches while giving callers a stable wire code.
// Its message is never serialized through StateError.toString().
class RpcError extends StateError {
  final RpcErrorCode code;
  final RpcErrorReason? reason;
  RpcError(this.code, String message, {this.reason}) : super(message);
  Map<String, Object?> toJson() => {
    'code': code.name,
    'message': message,
    if (reason != null) 'reason': reason!.name,
  };
  @override
  String toString() => message;

  factory RpcError.from(Object error) {
    if (error is RpcError) return error;
    if (error is Map) {
      return RpcError(
        RpcErrorCode.values.firstWhere(
          (code) => code.name == error['code'],
          orElse: () => RpcErrorCode.internal,
        ),
        error['message']?.toString() ?? 'Application service error',
        // A reason this client does not know says nothing it can act on.
        reason: RpcErrorReason.values
            .where((reason) => reason.name == error['reason'])
            .firstOrNull,
      );
    }
    if (error is GrpcError) {
      final code = switch (error.code) {
        StatusCode.cancelled => RpcErrorCode.cancelled,
        StatusCode.invalidArgument => RpcErrorCode.invalidArgument,
        StatusCode.notFound => RpcErrorCode.notFound,
        StatusCode.resourceExhausted => RpcErrorCode.busy,
        StatusCode.unavailable => RpcErrorCode.unavailable,
        StatusCode.permissionDenied => RpcErrorCode.denied,
        _ => RpcErrorCode.internal,
      };
      return RpcError(code, error.message ?? 'Helper error');
    }
    if (error is ArgumentError ||
        error is FormatException ||
        error is TypeError) {
      return RpcError(
        RpcErrorCode.invalidArgument,
        error is ArgumentError ? error.message.toString() : error.toString(),
      );
    }
    if (error is StateError) {
      return RpcError(RpcErrorCode.internal, error.message);
    }
    return RpcError(RpcErrorCode.internal, error.toString());
  }
}
