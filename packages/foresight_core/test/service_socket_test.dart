import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:foresight_core/src/service_socket.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'closing a retired listener preserves its replacement endpoint',
    () async {
      final directory = shortTestTempRoot.createTempSync('of-socket-');
      final path = '${directory.path}/application.sock';
      ServiceSocketBinding? old;
      ServiceSocketBinding? replacement;
      Socket? client;
      try {
        old = await ServiceSocketBinding.bind(path);
        expect(File(path).existsSync(), isFalse);
        old.publish((socket) => socket.destroy());
        expect(FileStat.statSync(path).mode & 0x1ff, 0x180);
        // A new owner has removed the predecessor's stale published endpoint.
        File(path).deleteSync();
        replacement = await ServiceSocketBinding.bind(path);
        replacement.publish((socket) async {
          socket.write('replacement');
          await socket.flush();
          socket.destroy();
        });
        await old.close();
        expect(File(path).existsSync(), isTrue);
        client = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        expect(
          await client.cast<List<int>>().transform(utf8.decoder).join(),
          'replacement',
        );
        await replacement.close();
        // Only the explicit ownership-protected cleanup removes publication.
        expect(File(path).existsSync(), isTrue);
        File(path).deleteSync();
        expect(directory.listSync(), isEmpty);
      } finally {
        client?.destroy();
        await old?.close();
        await replacement?.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'cancelled publication cannot replace a newer owner after a pause',
    () async {
      final directory = shortTestTempRoot.createTempSync('of-socket-');
      final path = '${directory.path}/application.sock';
      final pause = Completer<void>();
      final old = await ServiceSocketBinding.bind(path);
      ServiceSocketBinding? replacement;
      try {
        final publication = pause.future.then(
          (_) => old.publish((socket) => socket.destroy()),
        );
        final rejected = expectLater(publication, throwsStateError);
        await old.close();
        replacement = await ServiceSocketBinding.bind(path);
        replacement.publish((socket) => socket.destroy());
        pause.complete();
        await rejected;
        expect(File(path).existsSync(), isTrue);
        final client = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        client.destroy();
      } finally {
        if (!pause.isCompleted) pause.complete();
        await old.close();
        await replacement?.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('an unpublished listener closes without disturbing the owner', () async {
    final directory = shortTestTempRoot.createTempSync('of-socket-');
    final path = '${directory.path}/worker.sock';
    ServiceSocketBinding? owner;
    ServiceSocketBinding? candidate;
    try {
      owner = await ServiceSocketBinding.bind(path);
      owner.publish((socket) => socket.destroy());
      candidate = await ServiceSocketBinding.bind(path);
      await candidate.close();
      expect(File(path).existsSync(), isTrue);
      expect(FileStat.statSync(path).mode & 0x1ff, 0x180);
      await owner.close();
      File(path).deleteSync();
      expect(directory.listSync(), isEmpty);
    } finally {
      await owner?.close();
      await candidate?.close();
      directory.deleteSync(recursive: true);
    }
  });
}
