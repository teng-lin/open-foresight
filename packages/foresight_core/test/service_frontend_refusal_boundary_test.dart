import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service_client.dart'
    show isServiceTransportLost;
import 'package:foresight_test_support/hooked_service.dart' show ServiceGates;
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  for (final malformed in [
    'not-json\n',
    '{"id":"foreign"}\n',
    '[1,2]\n',
    'oversized',
  ]) {
    test(
      'draining frontend closes malformed peer ${jsonEncode(malformed)} without ending other refusals',
      () async {
        final root = createTestTempDirectorySync('frontend-boundary-');
        final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
        final saved = Map.of(runtimeConfiguration.environment);
        runtimeConfiguration.environment.removeWhere(
          (key, _) =>
              key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
        );
        final gates = await ServiceGates.create(root);
        gates.hold('close.before_frontend_release');
        runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
            gates.directory.path;
        IsolatedApplicationService? host;
        Future<void>? shutdown;
        final clients = <Socket>[];
        try {
          host = await IsolatedApplicationService.start(profile);
          final endpoint = serviceEndpoint(profile);
          shutdown = host.close();
          await gates.reached('close.before_frontend_release');
          final malformedPeer = await Socket.connect(
            InternetAddress(endpoint, type: InternetAddressType.unix),
            0,
          );
          clients.add(malformedPeer);
          final ended = malformedPeer
              .cast<List<int>>()
              .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk))
              .onError<SocketException>((_, _) => []);
          if (malformed == 'oversized') {
            malformedPeer.add(
              Uint8List(maxServiceMessage)..fillRange(0, maxServiceMessage, 32),
            );
          } else {
            malformedPeer.write(malformed);
          }
          try {
            await malformedPeer.flush();
          } on SocketException {
            if (malformed != 'oversized') rethrow;
          }
          expect(await ended.timeout(const Duration(seconds: 5)), isEmpty);

          final refused = await Socket.connect(
            InternetAddress(endpoint, type: InternetAddressType.unix),
            0,
          );
          clients.add(refused);
          final responses = StreamIterator(
            refused
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          );
          // Cancellation has no lease in the frontend. It must neither receive
          // an invented response nor prevent the next request's exact refusal.
          refused.write('{"cancel":7}\n{"id":8,"method":"status"}\n');
          await refused.flush();
          expect(
            await responses.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          final response = jsonDecode(responses.current) as Map;
          expect(response['id'], 8);
          expect(response['done'], isTrue);
          expect((response['error'] as Map)['code'], 'unavailable');
          expect((response['error'] as Map)['reason'], 'closing');
          gates.release('close.before_frontend_release');
          expect(
            await responses.moveNext().timeout(const Duration(seconds: 5)),
            isFalse,
          );
          await responses.cancel();
          await shutdown.timeout(const Duration(seconds: 10));
          await host.closed;
          expect(
            FileSystemEntity.typeSync(endpoint, followLinks: false),
            FileSystemEntityType.notFound,
          );
          expect(File('${profile.runtime}/worker.sock').existsSync(), isFalse);
        } finally {
          gates.releaseAll();
          for (final client in clients) {
            client.destroy();
          }
          if (shutdown != null) {
            await shutdown.timeout(const Duration(seconds: 10));
          }
          await host?.close();
          runtimeConfiguration.environment
            ..clear()
            ..addAll(saved);
        }
      },
    );
  }

  test(
    'a failed worker bridge closes only that peer and later clients recover',
    () async {
      final root = createTestTempDirectorySync('frontend-bridge-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      final saved = Map.of(runtimeConfiguration.environment);
      runtimeConfiguration.environment.removeWhere(
        (key, _) =>
            key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
      );
      IsolatedApplicationService? host;
      ServiceClient? broken, recovered;
      final worker = File('${profile.runtime}/worker.sock');
      final moved = File('${profile.runtime}/held-worker.sock');
      try {
        host = await IsolatedApplicationService.start(profile);
        worker.renameSync(moved.path);
        broken = await ServiceClient.connect(serviceEndpoint(profile));
        await expectLater(
          broken.call('status'),
          throwsA(
            isA<RpcError>()
                .having(
                  (error) => error.code,
                  'transport failure',
                  RpcErrorCode.unavailable,
                )
                .having(
                  isServiceTransportLost,
                  'local transport marker',
                  isTrue,
                ),
          ),
        );
        await broken.closed.timeout(const Duration(seconds: 5));
        expect(moved.existsSync(), isTrue);
        moved.renameSync(worker.path);
        recovered = await ServiceClient.connect(serviceEndpoint(profile));
        final status = await recovered.call('status') as Map;
        expect(status['profile_id'], profile.identity);
        expect(
          File('${profile.data}/.application-endpoint.json').existsSync(),
          isTrue,
        );
      } finally {
        if (moved.existsSync() && !worker.existsSync()) {
          moved.renameSync(worker.path);
        }
        await broken?.close();
        await recovered?.close();
        await host?.close();
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
  );
}
