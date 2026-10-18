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

// Preserve existing StateError catches while giving callers a stable wire code.
// Its message is never serialized through StateError.toString().
class RpcError extends StateError {
  final RpcErrorCode code;
  RpcError(this.code, String message) : super(message);
  Map<String, Object?> toJson() => {'code': code.name, 'message': message};
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
