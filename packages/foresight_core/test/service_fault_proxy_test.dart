import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart' show ServiceClient;
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// A minimal newline-framed peer that answers every request with its method.
class EchoService {
  EchoService._(this.directory, this.server);
  final Directory directory;
  final ServerSocket server;
  final requests = <Map<String, dynamic>>[];
  final peers = <Socket>[];
  final _disconnected = StreamController<void>.broadcast();

  /// Completes when the next peer reaches EOF.
  Future<void> get disconnected => _disconnected.stream.first;

  String get path => '${directory.path}/application.sock';

  static Future<EchoService> start() async {
    final directory = await createPrivateTempDirectory(
      shortTestTempRoot,
      'of-echo-',
    );
    final server = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/application.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final service = EchoService._(directory, server);
    server.listen((socket) {
      service.peers.add(socket);
      unawaited(socket.done.catchError((Object _) {}));
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final request = jsonDecode(line) as Map<String, dynamic>;
              service.requests.add(request);
              socket.writeln(
                jsonEncode({
                  'id': request['id'],
                  'result': {'method': request['method']},
                  'done': true,
                }),
              );
            },
            onError: (Object _) {},
            onDone: () {
              service._disconnected.add(null);
              socket.destroy();
            },
          );
    });
    return service;
  }

  Future<void> close() async {
    for (final peer in peers) {
      peer.destroy();
    }
    await server.close();
    await _disconnected.close();
    directory.deleteSync(recursive: true);
  }
}

void main() {
  late EchoService service;
  late ServiceFaultProxy proxy;
  setUp(() async {
    service = await EchoService.start();
    proxy = ServiceFaultProxy();
  });
  tearDown(() async {
    await proxy.close();
    await service.close();
  });

  test('relays both directions and labels replies with their method', () async {
    final request = proxy.seen(ProxyDirection.toService, method: 'notes.list');
    final reply = proxy.seen(ProxyDirection.toClient, method: 'notes.list');
    final client = await proxy.run(() => ServiceClient.connect(service.path));
    try {
      expect(await client.call('notes.list'), {'method': 'notes.list'});
      expect((await request).id, (await reply).id);
      expect((await reply).done, isTrue);
      expect(proxy.connections.single.endpoint, service.path);
      expect(proxy.attempts.single.refused, isFalse);
      expect(
        proxy.frames.map((frame) => '${frame.direction.name} ${frame.method}'),
        ['toService notes.list', 'toClient notes.list'],
      );
    } finally {
      await client.close();
    }
  });

  test(
    'a held reply waits for release and keeps later frames behind it',
    () async {
      final held = proxy.hold(ProxyDirection.toClient, method: 'status');
      final later = proxy.seen(ProxyDirection.toClient, method: 'notes.list');
      final client = await proxy.run(() => ServiceClient.connect(service.path));
      try {
        var statusDone = false;
        final status = client
            .call('status')
            .whenComplete(() => statusDone = true);
        final list = client.call('notes.list');
        final frame = await held.reached;
        expect(frame.method, 'status');
        // The service answers both; the later reply queues behind the held one.
        await eventually(
          () => proxy.frames.any(
            (frame) =>
                frame.direction == ProxyDirection.toClient &&
                frame.method == 'notes.list',
          ),
        );
        expect(statusDone, isFalse);
        held.release();
        expect(await status, {'method': 'status'});
        expect(await list, {'method': 'notes.list'});
        expect((await later).method, 'notes.list');
      } finally {
        await client.close();
      }
    },
  );

  test('truncate delivers a partial frame and then EOF', () async {
    final cut = proxy.truncate(
      ProxyDirection.toClient,
      method: 'status',
      keepBytes: 5,
    );
    final socket = await proxy.run(
      () => Socket.connect(
        InternetAddress(service.path, type: InternetAddressType.unix),
        0,
      ),
    );
    try {
      socket.writeln(jsonEncode({'id': 1, 'method': 'status', 'args': {}}));
      final received = await socket.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      final frame = await cut;
      expect(utf8.decode(received), frame.text.substring(0, 5));
      expect(received, isNot(contains(10)));
    } finally {
      socket.destroy();
    }
  });

  test('drop discards a request and destroys its connection', () async {
    final dropped = proxy.drop(ProxyDirection.toService, method: 'notes.save');
    final client = await proxy.run(() => ServiceClient.connect(service.path));
    try {
      expect(await client.call('status'), {'method': 'status'});
      await expectLater(
        client.call('notes.save', {'title': 'Lost'}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.message,
            'message',
            'Application service disconnected',
          ),
        ),
      );
      expect((await dropped).method, 'notes.save');
      await proxy.connections.single.closed;
      expect(service.requests.map((request) => request['method']), ['status']);
    } finally {
      await client.close();
    }
  });

  test('inject writes frames, including malformed ones, on demand', () async {
    final client = await proxy.run(() => ServiceClient.connect(service.path));
    try {
      final event = client.events.stream.first;
      proxy.inject(ProxyDirection.toClient, {
        'event': 'changed',
        'revision': 7,
      });
      expect((await event)['revision'], 7);
      final held = proxy.hold(ProxyDirection.toClient, method: 'status');
      final status = client.call('status');
      await held.reached;
      proxy.inject(ProxyDirection.toClient, 'not-json');
      held.release();
      await expectLater(status, throwsA(isA<FormatException>()));
      expect(client.isClosed, isTrue);
    } finally {
      await client.close();
    }
  });

  test('a peer EOF reaches the client as EOF', () async {
    final client = await proxy.run(() => ServiceClient.connect(service.path));
    try {
      expect(await client.call('status'), {'method': 'status'});
      final closed = client.events.stream.drain<void>();
      service.peers.single.destroy();
      await closed;
      expect(client.isClosed, isTrue);
      await proxy.connections.single.closed;
    } finally {
      await client.close();
    }
  });

  test('a client close reaches the service as EOF', () async {
    final client = await proxy.run(() => ServiceClient.connect(service.path));
    expect(await client.call('status'), {'method': 'status'});
    final disconnected = service.disconnected;
    await client.close();
    await proxy.connections.single.ended(ProxyDirection.toService);
    await disconnected;
    await proxy.connections.single.closed;
  });

  test('a refused connect is recorded and surfaces unchanged', () async {
    final refused = proxy.attempt(refused: true);
    final missing = '${service.directory.path}/missing/application.sock';
    await expectLater(
      proxy.run(() => ServiceClient.connect(missing)),
      throwsA(isA<SocketException>()),
    );
    expect((await refused).endpoint, missing);
    expect(proxy.connections, isEmpty);
  });

  test('counted observers skip earlier matches', () async {
    final second = proxy.seen(
      ProxyDirection.toService,
      method: 'status',
      count: 2,
    );
    final refusals = proxy.attempt(refused: true, count: 2);
    final client = await proxy.run(() => ServiceClient.connect(service.path));
    try {
      await client.call('status');
      await client.call('notes.list');
      var counted = false;
      unawaited(second.then((_) => counted = true));
      // Only one status request has been sent so far.
      expect(counted, isFalse);
      await client.call('status');
      expect((await second).id, 3);
      final missing = '${service.directory.path}/missing/application.sock';
      for (var i = 0; i < 2; i++) {
        await expectLater(
          proxy.run(() => ServiceClient.connect(missing)),
          throwsA(isA<SocketException>()),
        );
      }
      expect(await refusals, same(proxy.attempts.last));
    } finally {
      await client.close();
    }
  });

  test('other Unix sockets and a predicate select what is relayed', () async {
    final other = await ServerSocket.bind(
      InternetAddress(
        '${service.directory.path}/helper.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final accepted = other.first;
    try {
      final socket = await proxy.run(
        () => Socket.connect(
          InternetAddress(
            other.address.address,
            type: InternetAddressType.unix,
          ),
          0,
        ),
      );
      socket.destroy();
      (await accepted).destroy();
      expect(proxy.attempts, isEmpty);
      final second = proxy.hold(
        ProxyDirection.toService,
        where: (frame) => frame.id == 2 && frame.json?['args'] is Map,
      );
      final client = await proxy.run(() => ServiceClient.connect(service.path));
      try {
        expect(await client.call('status'), {'method': 'status'});
        final pending = client.call('notes.list');
        expect((await second.reached).method, 'notes.list');
        expect(service.requests, hasLength(1));
        second.release();
        expect(await pending, {'method': 'notes.list'});
      } finally {
        await client.close();
      }
    } finally {
      await other.close();
    }
  });
}
