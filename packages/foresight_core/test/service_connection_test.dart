import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';

import 'package:foresight_test_support/remote_service.dart';

void main() {
  test(
    'partial fixture startup removes its private directory and can close twice',
    () async {
      final partial = RemoteFixture(
        openStore: (_) => throw StateError('fixture store failure'),
      );
      await expectLater(
        partial.start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'fixture store failure',
          ),
        ),
      );
      expect(partial.root.existsSync(), isFalse);
      await partial.close();
      await partial.close();
    },
  );

  late RemoteFixture f;
  late Map<String, String> environment;
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    f = RemoteFixture();
    await f.start();
  });
  tearDown(() async {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(environment);
    await f.close();
  });

  test(
    'connection coalesces concurrent opens and reconnects without replaying uncertain writes',
    () async {
      final connection = ServiceConnection(f.profile);
      final clients = await Future.wait([
        connection.connect(),
        connection.connect(),
      ]);
      expect(identical(clients[0], clients[1]), isTrue);
      final pending = connection.stream('notes.save', {
        'title': 'uncertain',
      }).toList();
      final failed = expectLater(pending, throwsStateError);
      await eventually(
        () => f.requests.any((r) => r['method'] == 'notes.save'),
      );
      f.sockets.last.destroy();
      await failed;
      f.handler = (socket, request) =>
          f.reply(socket, request, {'reconnected': true});
      expect(await connection.stream('notes.list').single, {
        'reconnected': true,
      });
      expect(
        f.requests.where((r) => r['method'] == 'notes.save'),
        hasLength(1),
      );
      await connection.close();
      await expectLater(connection.connect(), throwsStateError);
    },
  );

  test('launcher waits for model verification beyond ten seconds', () async {
    runtimeConfiguration.environment.removeWhere(
      (key, _) => key.startsWith('FORESIGHT_'),
    );
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = '/usr/bin/true';
    final profile = ProfilePaths(
      '${f.root.path}/slow-data',
      '${f.root.path}/slow-run',
    );
    ServerSocket? server;
    final peers = <Socket>[];
    final listening = Future<void>.delayed(
      const Duration(seconds: 11),
      () async {
        server = await ServerSocket.bind(
          InternetAddress(
            '${profile.runtime}/application.sock',
            type: InternetAddressType.unix,
          ),
          0,
        );
        server!.listen((socket) {
          peers.add(socket);
          unawaited(socket.done.catchError((Object _) {}));
          socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                final request = jsonDecode(line) as Map;
                socket.writeln(
                  jsonEncode({
                    'id': request['id'],
                    'result': {'pid': pid},
                    'done': true,
                  }),
                );
              });
        });
      },
    );
    ServiceClient? client;
    try {
      client = await ensureService(profile);
      expect((await client.call('status') as Map)['pid'], pid);
    } finally {
      await listening;
      await client?.close();
      for (final socket in peers) {
        socket.destroy();
      }
      await server?.close();
    }
  });

  test(
    'closing during connect rejects the late connection and leaves no usable client',
    () async {
      final connection = ServiceConnection(f.profile);
      final pending = connection.connect();
      final failure = expectLater(pending, throwsStateError);
      await connection.close();
      await failure;
      await expectLater(connection.stream('status').toList(), throwsStateError);
    },
  );

  test(
    'packaged compatibility is checked before handing out a service connection',
    () async {
      runtimeConfiguration.environment['FORESIGHT_RUNTIME_REVISION'] =
          'fixture-revision';
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] =
          f.profile.data;
      f.status = {
        ...f.status,
        'application_api_version': 1,
        'installation_root': f.profile.data,
        'runtime_revision': 'wrong',
      };
      final connection = ServiceConnection(f.profile);
      await expectLater(connection.connect(), throwsStateError);
      f.status['runtime_revision'] = 'fixture-revision';
      final client = await connection.connect();
      expect(
        (await client.call('status') as Map)['runtime_revision'],
        'fixture-revision',
      );
      await connection.close();
    },
  );

  test(
    'local close preserves pending errors and the public disconnect contract',
    () async {
      final client = await ServiceClient.connect(
        '${f.profile.runtime}/application.sock',
      );
      final pending = client.call('fixture.pending');
      final failure = expectLater(
        pending,
        throwsA(
          allOf(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Client closed',
            ),
            isNot(isA<RpcError>()),
          ),
        ),
      );
      await eventually(
        () => f.requests.any((r) => r['method'] == 'fixture.pending'),
      );
      await client.close();
      await failure;
      await client.close();
      for (final request in [
        () => client.call('after.close'),
        () => client.stream('after.close').toList(),
      ]) {
        await expectLater(
          request(),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.unavailable)
                .having(
                  (error) => error.message,
                  'message',
                  'Application service disconnected',
                )
                .having(
                  (error) => error.runtimeType,
                  'plain public type',
                  RpcError,
                ),
          ),
        );
      }
      expect(f.requests.where((r) => r['method'] == 'after.close'), isEmpty);
    },
  );

  test('local close cannot replace an earlier EOF failure', () async {
    final client = await ServiceClient.connect(
      '${f.profile.runtime}/application.sock',
    );
    final pending = client.call('fixture.pending');
    final failure = expectLater(
      pending,
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.unavailable,
        ),
      ),
    );
    await eventually(
      () => f.requests.any((r) => r['method'] == 'fixture.pending'),
    );
    f.sockets.last.destroy();
    await failure;
    final cause = await client
        .call('after.eof')
        .then<Object?>(
          (_) => fail('Expected EOF'),
          onError: (Object error) => error,
        );
    expect(
      cause,
      isA<RpcError>().having(
        (error) => error.message,
        'message',
        'Application service disconnected',
      ),
    );
    await client.close();
    await expectLater(client.call('after.close'), throwsA(same(cause)));
  });

  for (final malformed in ['json', 'utf8', 'oversized']) {
    test(
      '$malformed service frames fail pending operations and close the client',
      () async {
        final client = await ServiceClient.connect(
          '${f.profile.runtime}/application.sock',
          maxMessageBytes: 1024,
        );
        final pending = client.call('fixture.pending');
        final failure = expectLater(
          pending,
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        await eventually(
          () => f.requests.any((r) => r['method'] == 'fixture.pending'),
        );
        // Ownership transfers to the transport or test teardown.
        // ignore: close_sinks
        final socket = f.sockets.last;
        if (malformed == 'json') {
          socket.writeln('{broken');
        } else if (malformed == 'utf8') {
          socket.add([255, 10]);
        } else {
          socket.add(Uint8List(1025)..fillRange(0, 1025, 65));
          unawaited(socket.flush().catchError((Object _) {}));
        }
        await failure;
        expect(client.isClosed, isTrue);
        await expectLater(
          client.stream('after.close').toList(),
          throwsStateError,
        );
        final cause = await client
            .call('before.local.close')
            .then<Object?>(
              (_) => fail('Expected the original frame failure'),
              onError: (Object error) => error,
            );
        expect(cause, isA<RpcError>());
        await client.close();
        await expectLater(
          client.call('after.local.close'),
          throwsA(same(cause)),
        );
      },
    );
  }

  test('endpoint records reject stale data identities and symbolic links', () {
    final record = File('${f.profile.data}/.application-endpoint.json');
    record.writeAsStringSync(
      jsonEncode({'data': '/other/profile', 'runtime': f.profile.runtime}),
    );
    expect(() => serviceEndpoint(f.profile), throwsStateError);
    record.writeAsStringSync(
      jsonEncode({'data': f.profile.data, 'runtime': 42}),
    );
    expect(() => serviceEndpoint(f.profile), throwsStateError);
    record.deleteSync();
    final target = File('${f.root.path}/target')..writeAsStringSync('{}');
    Link(record.path).createSync(target.path);
    expect(() => serviceEndpoint(f.profile), throwsStateError);
    expect(target.readAsStringSync(), '{}');
  });
  test(
    'invalid reply limits fail before attempting a socket connection',
    () async {
      for (final limit in [0, -1]) {
        await expectLater(
          ServiceClient.connect('/missing', maxMessageBytes: limit),
          throwsArgumentError,
        );
      }
    },
  );
}
