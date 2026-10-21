import 'dart:io';

import 'platform_services.dart';
import 'persistence/read_schema_guard.dart';
import 'rpc_error.dart';

void traceServiceTransport(String Function() message) {
  if (runtimeConfiguration['FORESIGHT_SERVICE_TRACE'] == '1') {
    final text = message();
    final bounded = text.length > 16384 ? text.substring(0, 16384) : text;
    stderr.writeln(
      'Service transport $pid ${DateTime.now().toIso8601String()} $bounded',
    );
  }
}

// Keep programming diagnostics in service logs, never in a wire stack field.
RpcError requestFailure(Object error, StackTrace stack) {
  final failure = error is IncompatibleReadSchema
      ? error.rpcError
      : RpcError.from(error);
  if (failure.code == RpcErrorCode.internal) {
    stderr.writeln('Application service request failed: $error\n$stack');
  }
  return failure;
}
