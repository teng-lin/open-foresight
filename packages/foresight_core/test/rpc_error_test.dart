import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  test(
    'every stable error survives the service wire without message prefixes',
    () async {
      final root = createTestTempDirectorySync('rpc-errors-');
      final path = '${root.path}/service.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final sockets = <Socket>[];
      listener.listen((socket) {
        sockets.add(socket);
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final request = jsonDecode(line) as Map;
              socket.writeln(
                jsonEncode({
                  'id': request['id'],
                  'done': true,
                  'error': {
                    'code': request['args']['code'],
                    'message': 'Readable failure',
                  },
                }),
              );
            });
      });
      final client = await ServiceClient.connect(path);
      try {
        for (final code in RpcErrorCode.values) {
          await expectLater(
            client.call('status', {'code': code.name}),
            throwsA(
              isA<RpcError>()
                  .having((error) => error.code, 'code', code)
                  .having(
                    (error) => error.toString(),
                    'message',
                    'Readable failure',
                  ),
            ),
          );
        }
      } finally {
        await client.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.close();
        root.deleteSync(recursive: true);
      }
    },
  );

  test('reasons travel on the wire and stay optional for old peers', () {
    for (final reason in RpcErrorReason.values) {
      final error = RpcError(
        RpcErrorCode.unavailable,
        'Readable failure',
        reason: reason,
      );
      final wire = jsonDecode(jsonEncode(error.toJson())) as Map;
      expect(wire, {
        'code': 'unavailable',
        'message': 'Readable failure',
        'reason': reason.name,
      });
      expect(RpcError.from(wire).reason, reason);
    }
    // Errors without a reason serialize exactly as before the field existed.
    expect(RpcError(RpcErrorCode.notFound, 'Missing').toJson(), {
      'code': 'notFound',
      'message': 'Missing',
    });
    // A peer's unknown reason or code carries nothing this client can act on.
    final unknown = RpcError.from({
      'code': 'futureCode',
      'message': 'From a newer peer',
      'reason': 'futureReason',
    });
    expect(unknown.code, RpcErrorCode.internal);
    expect(unknown.reason, isNull);
    expect(unknown.message, 'From a newer peer');
  });

  test('closing refusals are recognized with or without a reason (L2)', () {
    const closing =
        'Application service is shutting down; retry after it exits.';
    // v0.1.x owners sent both texts without a reason.
    for (final message in [closing, 'Application service is shutting down']) {
      expect(
        isClosingRefusal(RpcError(RpcErrorCode.unavailable, message)),
        isTrue,
        reason: message,
      );
    }
    expect(
      isClosingRefusal(
        RpcError(
          RpcErrorCode.unavailable,
          'Any text',
          reason: RpcErrorReason.closing,
        ),
      ),
      isTrue,
    );
    for (final error in [
      // A reason other than closing wins over a matching legacy text.
      RpcError(
        RpcErrorCode.unavailable,
        closing,
        reason: RpcErrorReason.outcomeUnknown,
      ),
      RpcError(
        RpcErrorCode.unavailable,
        closing,
        reason: RpcErrorReason.notSent,
      ),
      RpcError(RpcErrorCode.internal, closing),
      RpcError(RpcErrorCode.busy, 'x', reason: RpcErrorReason.closing),
      RpcError(RpcErrorCode.unavailable, 'Application service disconnected'),
      RpcError(RpcErrorCode.unavailable, '$closing '),
    ]) {
      expect(isClosingRefusal(error), isFalse, reason: '${error.toJson()}');
    }
  });

  test('helper status codes map to stable application errors', () {
    expect(
      RpcError.from(const GrpcError.cancelled('Cancelled')).code,
      RpcErrorCode.cancelled,
    );
    expect(
      RpcError.from(const GrpcError.notFound('Missing')).code,
      RpcErrorCode.notFound,
    );
    expect(RpcError.from(StateError('Failure')).toString(), 'Failure');
  });
}
