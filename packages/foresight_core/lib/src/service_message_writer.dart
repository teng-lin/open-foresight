import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'agent_access.dart';
import 'rpc_error.dart';
import 'service_diagnostics.dart';
import 'service_framing.dart';

/// Bounded JSON replies and events share one encoding and refusal policy.
class ServiceMessageWriter {
  ServiceMessageWriter(this.cancelUnsendable);
  final void Function(Socket client, int id) cancelUnsendable;

  /// Writes [message] to [client] and says whether it got there. A reply that
  /// is too large or cannot be encoded is replaced by an error; such an event
  /// is dropped. A failed write closes the connection.
  EventDelivery send(Socket client, Map<String, Object?> message) {
    try {
      traceServiceTransport(
        () =>
            'worker send peer=${identityHashCode(client)} id=${message['id']} '
            'event=${message['event']} done=${message['done']}',
      );
      Uint8List? frame;
      String? failure;
      var delivery = EventDelivery.sent;
      try {
        frame = utf8.encode(jsonEncode(message));
        // A client drops its whole connection on a frame over the limit, and
        // losing the desktop's connection stops its recording. Fail only the
        // request instead.
        if (frame.length + 1 > maxServiceFrame) {
          delivery = EventDelivery.tooLarge;
          failure =
              'Reply exceeds ${maxServiceFrame ~/ (1024 * 1024)} MiB; '
              'request fewer items.';
        }
      } on JsonUnsupportedObjectError {
        delivery = EventDelivery.unencodable;
        failure =
            'Reply contains a value JSON cannot represent, such as NaN or '
            'Infinity.';
      }
      if (failure != null) {
        final id = message['id'];
        traceServiceTransport(
          () =>
              'worker unsendable peer=${identityHashCode(client)} id=$id '
              'event=${message['event']} bytes=${frame?.length} $failure',
        );
        // A dropped snapshot is superseded by the next one. The approval gate
        // fails its request instead of waiting for a decision.
        if (id == null) return delivery;
        // No later frame may follow this request's terminal error.
        if (id is int) cancelUnsendable(client, id);
        frame = utf8.encode(
          jsonEncode({
            'id': id,
            'error': RpcError(RpcErrorCode.internal, failure).toJson(),
            'done': true,
          }),
        );
      }
      client
        ..add(frame!)
        ..add(const [10]);
      return delivery;
    } catch (_) {
      client.destroy();
      return EventDelivery.writeFailed;
    }
  }
}
