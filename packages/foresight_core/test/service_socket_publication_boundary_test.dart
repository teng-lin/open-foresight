import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/service_socket.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'unsafe endpoint directories are refused without modifying their contents',
    () async {
      final root = createTestTempDirectorySync('socket-boundary-');
      final endpoint = Directory('${root.path}/application.sock')..createSync();
      final marker = File('${endpoint.path}/ownership')
        ..writeAsStringSync('another owner');
      final refusal = await probeSocketPath(endpoint.path);
      expect(
        refusal,
        isA<SocketPathInUse>().having((error) => error.live, 'live', isFalse),
      );
      expect('$refusal', contains('not a socket'));
      await expectLater(
        clearStaleSocket(endpoint.path),
        throwsA(isA<SocketPathInUse>()),
      );
      expect(marker.readAsStringSync(), 'another owner');
      expect(endpoint.listSync().map((entry) => entry.path), [marker.path]);
    },
  );

  test(
    'invalid identity input is rejected without inspecting a truncated path',
    () {
      final root = createTestTempDirectorySync('identity-boundary-');
      final file = File('${root.path}/owned')..writeAsStringSync('unchanged');
      expect(
        () => fileIdentitySync('${file.path}\u0000suffix'),
        throwsArgumentError,
      );
      expect(file.readAsStringSync(), 'unchanged');
      expect(fileIdentitySync('${root.path}/missing'), isNull);
    },
  );

  test(
    'a lost private bind cannot publish and a fresh listener can recover',
    () async {
      final root = createTestTempDirectorySync('publish-boundary-');
      final path = '${root.path}/application.sock';
      final failed = await ServiceSocketBinding.bind(path);
      addTearDown(failed.close);
      var removed = false;
      await expectLater(
        failed.publish(
          (client) => client.destroy(),
          linkForTesting: (_, _) => false,
          beforeMoveForTesting: () {
            if (removed) return;
            removed = true;
            // Simulate the private entry disappearing before an unsupported
            // hard-link filesystem can move it to its public endpoint.
            File(failed.listener.address.address).deleteSync();
          },
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'safe failure',
            contains('without risking replacing'),
          ),
        ),
      );
      expect(failed.published, isFalse);
      expect(await failed.unpublish(), isFalse);
      await failed.close();
      expect(root.listSync(), isEmpty);
      final replacement = await ServiceSocketBinding.bind(path);
      addTearDown(replacement.close);
      await replacement.publish((client) async {
        client.write('fresh owner');
        await client.flush();
        client.destroy();
      });
      final client = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 5));
      addTearDown(client.destroy);
      expect(
        await client
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5)),
        'fresh owner',
      );
      expect(await replacement.unpublish(), isTrue);
      await replacement.close();
      expect(root.listSync(), isEmpty);
    },
  );
}
