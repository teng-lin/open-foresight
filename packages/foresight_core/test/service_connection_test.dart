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

/// An RpcError with [code], [message] and the wire reason [reason]. Reading
/// the reason through toJson keeps this file runnable against older clients.
Matcher rpcError(RpcErrorCode code, String message, String? reason) =>
    isA<RpcError>()
        .having((error) => error.code, 'code', code)
        .having((error) => error.message, 'message', message)
        .having((error) => error.toJson()['reason'], 'reason', reason);

Matcher disconnected(String reason) => rpcError(
  RpcErrorCode.unavailable,
  'Application service disconnected',
  reason,
);

const closingText =
    'Application service is shutting down; retry after it exits.';

/// A protocol error: requests already written may have taken effect.
Matcher invalidReply(String? reason) => rpcError(
  RpcErrorCode.internal,
  'Application service sent an invalid reply',
  reason,
);

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

  // An owner older than the reason field sent only one of two texts (13).
  for (final refusal in <Map<String, Object?>>[
    {'code': 'unavailable', 'message': closingText},
    {'code': 'unavailable', 'message': 'Application service is shutting down'},
    {'code': 'unavailable', 'message': closingText, 'reason': 'closing'},
  ]) {
    test('a closing refusal before any result is sent once more after the '
        'handoff (SL-9): $refusal', () async {
      final connection = ServiceConnection(f.profile);
      await connection.connect();
      final before = f.requests.length;
      var refusals = 1;
      f.handler = (socket, request) {
        if (refusals-- > 0) {
          socket.writeln(
            jsonEncode({'id': request['id'], 'error': refusal, 'done': true}),
          );
        } else {
          f.reply(socket, request, ['listed']);
        }
      };
      expect(await connection.stream('notes.list').toList(), [
        ['listed'],
      ]);
      // Refused, a new startup probe, then the same request once more.
      expect(f.requests.skip(before).map((r) => r['method']), [
        'notes.list',
        'status',
        'notes.list',
      ]);
      await connection.close();
    });
  }

  test('a closing refusal leaves the other requests on its connection to '
      'the owner\'s own answers: a refused one is sent once more, a '
      'dispatched one is outcomeUnknown (SL-9)', () async {
    const ownerUnknown =
        'Application service stopped before this request finished; it may '
        'or may not have completed.';
    final connection = ServiceConnection(f.profile);
    final previous = await connection.connect();
    final closing = f.sockets.last;
    final held = <Map<String, dynamic>>[];
    void answer(Map<String, dynamic> request, Map<String, Object?> error) =>
        closing.writeln(
          jsonEncode({'id': request['id'], 'error': error, 'done': true}),
        );
    const refusal = {
      'code': 'unavailable',
      'message': closingText,
      'reason': 'closing',
    };
    f.handler = (socket, request) {
      final method = request['method'] as String;
      if (!identical(socket, closing)) {
        f.reply(socket, request, 'next owner: $method');
        // The closing owner's other answers arrive only after the first
        // refused request reached the next owner.
        if (method == 'notes.list') {
          for (final request in held) {
            answer(
              request,
              request['method'] == 'meetings.list'
                  ? refusal
                  : {
                      'code': 'unavailable',
                      'message': ownerUnknown,
                      'reason': 'outcomeUnknown',
                    },
            );
          }
        }
        return;
      }
      if (method == 'notes.list') {
        answer(request, refusal);
      } else {
        held.add(request);
      }
    };
    final first = connection.stream('notes.list').toList();
    final second = connection.stream('meetings.list').toList();
    final dispatched = connection
        .stream('notes.save')
        .toList()
        .then<Object?>(
          (value) => fail('Expected a failure, got $value'),
          onError: (Object error) => error,
        );
    expect(await first, ['next owner: notes.list']);
    expect(await second, ['next owner: meetings.list']);
    expect(
      await dispatched,
      rpcError(RpcErrorCode.unavailable, ownerUnknown, 'outcomeUnknown'),
    );
    for (final (method, count) in [
      ('notes.list', 2),
      ('meetings.list', 2),
      ('notes.save', 1),
    ]) {
      expect(f.requests.where((r) => r['method'] == method), hasLength(count));
    }
    // With nothing left pending, the retired connection closed, and new
    // requests use the next owner's.
    expect(previous.isClosed, isTrue);
    expect(await connection.connect(), isNot(same(previous)));
    await connection.close();
  });

  test('a retired client sends nothing new and closes once its pending '
      'requests settle, or after its grace', () async {
    final client = await ServiceClient.connect(
      '${f.profile.runtime}/application.sock',
    );
    final answered = client.call('fixture.answered');
    final unanswered = client.call('fixture.unanswered');
    final failure = expectLater(
      unanswered,
      throwsA(disconnected('outcomeUnknown')),
    );
    await eventually(
      () => f.requests.any((r) => r['method'] == 'fixture.unanswered'),
    );
    client.retire(grace: const Duration(seconds: 3));
    expect(client.isClosed, isTrue);
    await expectLater(
      client.call('after.retire'),
      throwsA(disconnected('notSent')),
    );
    // The owner still answers a request written before the retirement.
    f.reply(
      f.sockets.last,
      f.requests.singleWhere((r) => r['method'] == 'fixture.answered'),
      'answered',
    );
    expect(await answered, 'answered');
    // One that is never answered fails at the grace.
    await failure;
    expect(f.requests.where((r) => r['method'] == 'after.retire'), isEmpty);
  });

  test('a request is resent at most once', () async {
    final connection = ServiceConnection(f.profile);
    f.handler = (socket, request) => socket.writeln(
      jsonEncode({
        'id': request['id'],
        'error': {
          'code': 'unavailable',
          'message': closingText,
          'reason': 'closing',
        },
        'done': true,
      }),
    );
    await expectLater(
      connection.stream('notes.list').toList(),
      throwsA(rpcError(RpcErrorCode.unavailable, closingText, 'closing')),
    );
    expect(f.requests.where((r) => r['method'] == 'notes.list'), hasLength(2));
    await connection.close();
  });

  test(
    'a request with an unknown outcome, or one that already had a result, is '
    'never resent',
    () async {
      final connection = ServiceConnection(f.profile);
      const unknown = {
        'code': 'unavailable',
        'message': 'stopped',
        'reason': 'outcomeUnknown',
      };
      f.handler = (socket, request) {
        if (request['method'] == 'notes.stream') {
          f.reply(socket, request, 'partial', done: false);
          socket.writeln(
            jsonEncode({
              'id': request['id'],
              'error': {
                'code': 'unavailable',
                'message': closingText,
                'reason': 'closing',
              },
              'done': true,
            }),
          );
        } else {
          socket.writeln(
            jsonEncode({'id': request['id'], 'error': unknown, 'done': true}),
          );
        }
      };
      await expectLater(
        connection.stream('notes.save').toList(),
        throwsA(
          rpcError(RpcErrorCode.unavailable, 'stopped', 'outcomeUnknown'),
        ),
      );
      final results = <Object?>[];
      await expectLater(
        connection.stream('notes.stream').forEach(results.add),
        throwsA(rpcError(RpcErrorCode.unavailable, closingText, 'closing')),
      );
      expect(results, ['partial']);
      for (final method in ['notes.save', 'notes.stream']) {
        expect(f.requests.where((r) => r['method'] == method), hasLength(1));
      }
      await connection.close();
    },
  );

  test('a peer cannot make a request resendable by claiming notSent', () async {
    final connection = ServiceConnection(f.profile);
    f.handler = (socket, request) => socket.writeln(
      jsonEncode({
        'id': request['id'],
        'error': {
          'code': 'unavailable',
          'message': 'stopped',
          'reason': 'notSent',
        },
        'done': true,
      }),
    );
    await expectLater(
      connection.stream('notes.save').toList(),
      throwsA(rpcError(RpcErrorCode.unavailable, 'stopped', null)),
    );
    expect(f.requests.where((r) => r['method'] == 'notes.save'), hasLength(1));
    await connection.close();
  });

  test('cancelling a stream cancels its request and never resends', () async {
    final connection = ServiceConnection(f.profile);
    f.handler = (socket, request) =>
        f.reply(socket, request, 'preview', done: false);
    final first = Completer<void>();
    final subscription = connection.stream('answer.stream').listen((_) {
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    final request = f.requests.lastWhere((r) => r['method'] == 'answer.stream');
    await subscription.cancel();
    await eventually(() => f.requests.any((r) => r['cancel'] == request['id']));
    expect(
      f.requests.where((r) => r['method'] == 'answer.stream'),
      hasLength(1),
    );
    await connection.close();
  });

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
                    'result': {'pid': pid, 'profile_id': profile.identity},
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

  // No /proc/locks or stat; or a holder outside this pid namespace (pid 0).
  for (final (recorded, holders) in <(bool, Set<int>?)>[
    (false, null),
    (true, null),
    (true, {0}),
  ]) {
    test('an older owner whose lock holder cannot be read fails startup at '
        'once and says so (record: $recorded, holders: $holders)', () async {
      // An owner released before profile identity holds this profile's
      // lock and answers status without profile_id.
      final profile = ProfilePaths(
        '${f.root.path}/older-data',
        '${f.root.path}/own-run',
      );
      final runtime = recorded ? '${f.root.path}/older-run' : profile.runtime;
      privateDirectory(profile.data);
      privateDirectory(runtime);
      final holder = await Process.start('python3', [
        '-c',
        'import fcntl,sys\nf=open(sys.argv[1],"a")\n'
            'fcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\n'
            'sys.stdin.read()',
        '${profile.data}/.application.lock',
      ]);
      addTearDown(() => holder.kill(ProcessSignal.sigkill));
      expect(
        await utf8.decoder
            .bind(holder.stdout)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      final server = await ServerSocket.bind(
        InternetAddress(
          '$runtime/application.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
      addTearDown(server.close);
      server.listen((socket) {
        unawaited(socket.done.catchError((Object _) {}));
        utf8.decoder.bind(socket).transform(const LineSplitter()).listen((
          line,
        ) {
          final request = jsonDecode(line) as Map;
          socket.writeln(
            jsonEncode({
              'id': request['id'],
              'result': {'pid': holder.pid, 'application_api_version': 1},
              'done': true,
            }),
          );
        }, onError: (Object _) {});
      });
      if (recorded) {
        // The record it wrote names its runtime.
        File('${profile.data}/.application-endpoint.json').writeAsStringSync(
          jsonEncode({'data': profile.data, 'runtime': runtime}),
        );
      }
      final reader = readPosixLockHolders;
      readPosixLockHolders = (_) => holders;
      addTearDown(() => readPosixLockHolders = reader);
      final startup = Stopwatch()..start();
      await expectLater(
        ensureService(profile, startupTimeout: const Duration(seconds: 60)),
        throwsA(
          isA<UnverifiableServiceOwner>().having(
            (error) => error.message,
            'message',
            'Cannot verify the running older Open Foresight service (pid '
                '${holder.pid}) for this profile; stop it with its own '
                '--stop, then retry.',
          ),
        ),
      );
      // Well before the startup deadline.
      expect(startup.elapsed, lessThan(const Duration(seconds: 20)));
      // Once nothing holds this profile's lock, a service without
      // profile_id is another profile's, as before.
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          '/missing/fixture-service';
      await expectLater(
        ensureService(profile, startupTimeout: const Duration(seconds: 5)),
        throwsA(isNot(isA<UnverifiableServiceOwner>())),
      );
    });
  }

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
      // The request was written; whether it took effect is unknown (SL-6).
      final failure = expectLater(
        pending,
        throwsA(disconnected('outcomeUnknown')),
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
            allOf(
              disconnected('notSent'),
              isA<RpcError>().having(
                (error) => error.runtimeType,
                'plain public type',
                RpcError,
              ),
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
      throwsA(disconnected('outcomeUnknown')),
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
    expect(cause, disconnected('notSent'));
    await client.close();
    await expectLater(client.call('after.close'), throwsA(same(cause)));
  });

  test(
    'a reply cut off by EOF is a lost connection, not a caller error (SL-6)',
    () async {
      final client = await ServiceClient.connect(
        '${f.profile.runtime}/application.sock',
      );
      final pending = client.call('fixture.pending');
      final failure = expectLater(
        pending,
        throwsA(disconnected('outcomeUnknown')),
      );
      await eventually(
        () => f.requests.any((r) => r['method'] == 'fixture.pending'),
      );
      final request = f.requests.last;
      // ignore: close_sinks
      final socket = f.sockets.last;
      socket.add(
        utf8.encode(
          jsonEncode({
            'id': request['id'],
            'result': 'complete',
            'done': true,
          }).substring(0, 12),
        ),
      );
      await socket.flush();
      await socket.close();
      await failure;
      await expectLater(
        client.stream('after.eof').toList(),
        throwsA(disconnected('notSent')),
      );
    },
  );

  test('reply frames are counted exactly, not per socket read', () async {
    const limit = 1024;
    final client = await ServiceClient.connect(
      '${f.profile.runtime}/application.sock',
      maxMessageBytes: limit,
    );
    try {
      final first = client.call('fixture.first');
      final second = client.call('fixture.second');
      await eventually(
        () => f.requests.any((r) => r['method'] == 'fixture.second'),
      );
      final ids = [
        for (final method in ['fixture.first', 'fixture.second'])
          f.requests.singleWhere((r) => r['method'] == method)['id'],
      ];
      // A frame at the limit (newline included), followed in the same write
      // by a second frame: together they exceed the limit, each fits it.
      String filling(Object? id, String char) =>
          char * (limit - 1 - '{"id":$id,"done":true,"result":""}'.length);
      List<int> frame(Object? id, String result) => utf8.encode(
        '${jsonEncode({'id': id, 'done': true, 'result': result})}\n',
      );
      final results = [filling(ids[0], 'a'), filling(ids[1], 'b')];
      final bytes = [
        ...frame(ids[0], results[0]),
        ...frame(ids[1], results[1]),
      ];
      expect(bytes.length, 2 * limit);
      f.sockets.last.add(bytes);
      expect(await first, results[0]);
      expect(await second, results[1]);
      expect(client.isClosed, isFalse);
    } finally {
      await client.close();
    }
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
        // An oversized frame loses the connection; a complete frame that is
        // not a JSON object is a protocol error for every caller.
        final failure = expectLater(
          pending,
          throwsA(
            malformed == 'oversized'
                ? disconnected('outcomeUnknown')
                : invalidReply('outcomeUnknown'),
          ),
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
          throwsA(
            malformed == 'oversized'
                ? disconnected('notSent')
                : invalidReply(null),
          ),
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

  test('endpoint records ignore stale data identities and symbolic links', () {
    final record = File('${f.profile.data}/.application-endpoint.json');
    void ignored(String reason) {
      expect(
        readEndpointRecord(f.profile),
        isA<EndpointInvalid>().having(
          (record) => record.reason,
          'reason',
          contains(reason),
        ),
      );
      // Record content never fails a client; it uses its own runtime instead.
      expect(
        serviceEndpoint(f.profile),
        '${f.profile.runtime}/application.sock',
      );
    }

    record.writeAsStringSync(
      jsonEncode({'data': '/other/profile', 'runtime': f.profile.runtime}),
    );
    ignored('names another profile (/other/profile)');
    record.writeAsStringSync(
      jsonEncode({'data': f.profile.data, 'runtime': 42}),
    );
    ignored('string data and runtime fields');
    record.writeAsStringSync(
      jsonEncode({'data': f.profile.data, 'runtime': 'relative-runtime'}),
    );
    ignored('not an absolute path');
    expect(Directory('relative-runtime').existsSync(), isFalse);
    record.writeAsStringSync(
      jsonEncode({'data': f.profile.data, 'runtime': f.profile.runtime}),
    );
    expect(
      readEndpointRecord(f.profile),
      isA<EndpointValid>().having(
        (record) => record.runtime,
        'runtime',
        f.profile.runtime,
      ),
    );
    record.deleteSync();
    expect(readEndpointRecord(f.profile), isA<EndpointAbsent>());
    final target = File('${f.root.path}/target')..writeAsStringSync('{}');
    Link(record.path).createSync(target.path);
    ignored('symbolic link');
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
