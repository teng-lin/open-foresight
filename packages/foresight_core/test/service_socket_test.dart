import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:foresight_core/src/service_socket.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Publish [binding]; written so it also runs against a synchronous publish.
Future<void> publish(
  ServiceSocketBinding binding,
  void Function(Socket) onClient,
) async => binding.publish(onClient);

/// A listener that answers every connection with [name].
void Function(Socket) answer(String name) => (socket) async {
  socket.write(name);
  await socket.flush();
  socket.destroy();
};

/// What the listener at [path] answers.
Future<String> answerAt(String path) async {
  final client = await Socket.connect(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  try {
    return await client.cast<List<int>>().transform(utf8.decoder).join();
  } finally {
    client.destroy();
  }
}

void main() {
  test('publishing never replaces a live socket, but takes over one nobody '
      'listens on (S2)', () async {
    final directory = createTestTempDirectorySync('of-socket-');
    final path = '${directory.path}/application.sock';
    final first = await ServiceSocketBinding.bind(path);
    final second = await ServiceSocketBinding.bind(path);
    try {
      await publish(first, answer('first'));
      expect(first.linkedForTesting, isTrue);
      // Two owners sharing a runtime start together: the later one must not
      // take the earlier one's live socket.
      await expectLater(
        publish(second, answer('second')),
        throwsA(
          isA<SocketPathInUse>().having((error) => error.live, 'live', isTrue),
        ),
      );
      expect(await answerAt(path), 'first');
      // Once nobody listens there, a new listener takes the path over.
      await first.close();
      final third = await ServiceSocketBinding.bind(path);
      try {
        await publish(third, answer('third'));
        expect(third.linkedForTesting, isTrue);
        expect(await answerAt(path), 'third');
      } finally {
        await third.close();
      }
    } finally {
      await first.close();
      await second.close();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'closing a retired listener preserves its replacement endpoint',
    () async {
      final directory = createTestTempDirectorySync('of-socket-');
      final path = '${directory.path}/application.sock';
      ServiceSocketBinding? old;
      ServiceSocketBinding? replacement;
      Socket? client;
      try {
        old = await ServiceSocketBinding.bind(path);
        expect(File(path).existsSync(), isFalse);
        await publish(old, (socket) => socket.destroy());
        expect(FileStat.statSync(path).mode & 0x1ff, 0x180);
        // A new owner has removed the predecessor's stale published endpoint.
        File(path).deleteSync();
        replacement = await ServiceSocketBinding.bind(path);
        await publish(replacement, (socket) async {
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
      final directory = createTestTempDirectorySync('of-socket-');
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
        await publish(replacement, (socket) => socket.destroy());
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
    final directory = createTestTempDirectorySync('of-socket-');
    final path = '${directory.path}/worker.sock';
    ServiceSocketBinding? owner;
    ServiceSocketBinding? candidate;
    try {
      owner = await ServiceSocketBinding.bind(path);
      await publish(owner, (socket) => socket.destroy());
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

  test('a socket keeps its identity through link, rename and chmod, and a '
      'replacement that reuses its inode number gets a new one', () async {
    final directory = createTestTempDirectorySync('of-identity-');
    final path = '${directory.path}/application.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    try {
      final bound = await fileIdentity(path);
      expect(bound, isNotNull);
      // What publishing and protecting a socket do to it.
      expect(Process.runSync('/bin/chmod', ['600', path]).exitCode, 0);
      expect(Process.runSync('/bin/ln', [path, '$path.2']).exitCode, 0);
      File('$path.2').deleteSync();
      File(path).renameSync('$path.aside');
      File('$path.aside').renameSync(path);
      expect(await fileIdentity(path), bound);
      if (Platform.isLinux) {
        // ext4 and overlay filesystems give a freed inode number to the next
        // file at once. A replacement differs in its bind time even then;
        // the same inode with a different modification time stands in for it.
        File(path).setLastModifiedSync(DateTime(2001));
        expect(await fileIdentity(path), isNot(bound));
      }
    } finally {
      await server.close();
    }
  });
}
