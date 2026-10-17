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
      final root = Directory.systemTemp.createTempSync('rpc-errors-');
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
