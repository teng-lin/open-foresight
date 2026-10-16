import 'dart:io';
import 'package:test/test.dart';
import 'package:grpc/grpc.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';

class PingService extends RagServiceBase {
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(success: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('concurrent helper shutdown shares one transport termination', () async {
    final directory = Directory.systemTemp.createTempSync('fc-close-');
    final socket = '${directory.path}/socket';
    final server = Server.create(services: [PingService()]);
    final helper = Helper(socket, directory.path, manageProcess: false);
    try {
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      expect((await helper.client.ping(PingRequest())).success, true);
      final first = helper.close();
      expect(identical(first, helper.close()), true);
      await first.timeout(const Duration(seconds: 5));
      await helper.close();
    } finally {
      await helper.close();
      await server.shutdown();
      directory.deleteSync(recursive: true);
    }
  });
}
