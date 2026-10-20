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

/// What a closing owner refuses with. Clients released before
/// [RpcErrorReason] (v0.1.0-v0.1.2) match this text, so it must stay
/// byte-identical.
const serviceClosingMessage =
    'Application service is shutting down; retry after it exits.';
// Those owners also refused from _execute with this shorter text.
const _legacyExecuteClosingMessage = 'Application service is shutting down';

/// Whether [error] is a closing owner's refusal: the request was never
/// dispatched, so it is safe to send again once ownership is handed off.
/// Owners that predate [RpcErrorReason] are recognized by their message, but
/// only when their frame carried no reason at all.
bool isClosingRefusal(RpcError error) =>
    error.code == RpcErrorCode.unavailable &&
    (error.reason == RpcErrorReason.closing ||
        (!error._reasonOnWire &&
            error.reason == null &&
            (error.message == serviceClosingMessage ||
                error.message == _legacyExecuteClosingMessage)));

// Preserve existing StateError catches while giving callers a stable wire code.
// Its message is never serialized through StateError.toString().
class RpcError extends StateError {
  final RpcErrorCode code;
  final RpcErrorReason? reason;
  // Whether the peer's frame named a reason, even one dropped as unknown.
  final bool _reasonOnWire;
  RpcError(this.code, String message, {this.reason})
    : _reasonOnWire = false,
      super(message);
  RpcError._fromWire(this.code, String message, this.reason, this._reasonOnWire)
    : super(message);
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
      final reason = RpcErrorReason.values
          .where((reason) => reason.name == error['reason'])
          .firstOrNull;
      return RpcError._fromWire(
        RpcErrorCode.values.firstWhere(
          (code) => code.name == error['code'],
          orElse: () => RpcErrorCode.internal,
        ),
        error['message']?.toString() ?? 'Application service error',
        // A reason this client does not know says nothing it can act on, and
        // notSent is the client's own judgement, never a peer's.
        reason == RpcErrorReason.notSent ? null : reason,
        error.containsKey('reason'),
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
