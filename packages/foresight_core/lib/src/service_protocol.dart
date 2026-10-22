import 'dart:io';
import 'rpc_error.dart';

// The whole flush of closing connections, not each one.
const serviceClosingFlushBound = Duration(seconds: 2);
Future<void> flushServiceSocketQuietly(Socket socket) async {
  try {
    await socket.flush();
  } catch (_) {
    // The peer has gone; nothing is left to deliver.
  }
}

/// The refusal a closing owner sends for a request it did not dispatch.
RpcError serviceClosingRefusal() => RpcError(
  RpcErrorCode.unavailable,
  serviceClosingMessage,
  reason: RpcErrorReason.closing,
);
