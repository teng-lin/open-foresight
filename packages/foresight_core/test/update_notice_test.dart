import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/update_notice.dart';
import 'package:test/test.dart';

Map<String, Object?> release({String tag = 'v0.2.0'}) => {
  'id': 123,
  'tag_name': tag,
  'html_url': 'https://github.com/teng-lin/open-foresight/releases/tag/$tag',
  'url': 'https://api.github.com/repos/teng-lin/open-foresight/releases/123',
  'draft': false,
  'prerelease': false,
};

Matcher problem(UpdateNoticeProblem value) => isA<UpdateNoticeException>()
    .having((error) => error.problem, 'problem', value);

UpdateNoticeClient metadata(Object? value) => UpdateNoticeClient(
  transport: (_, _) async => utf8.encode(jsonEncode(value)),
);

// Route the HTTP implementation to a local plaintext fixture, without claiming
// TLS acceptance for these tests. The separate secure-socket test below really
// performs a failing TLS handshake. Production uses the default secure factory.
Future<UpdateNoticeClient> httpFixture(
  Future<void> Function(HttpRequest) respond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final listener = server.listen((request) async {
    try {
      await respond(request);
    } on IOException {
      // A refusal/deadline closes the client while a fixture is still writing.
    }
  });
  final client = UpdateNoticeClient(
    timeout: timeout,
    createClient: () {
      final client = HttpClient();
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (_, _, _) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
      return client;
    },
  );
  addTearDown(() async {
    client.close();
    await listener.cancel();
    await server.close(force: true);
  });
  return client;
}

void main() {
  test('construction and opt-out never allocate a network client', () async {
    var clients = 0;
    final client = UpdateNoticeClient(
      createClient: () {
        clients++;
        throw StateError('must not open a connection');
      },
    );
    addTearDown(client.close);
    expect(clients, 0);
    final result = await client.check(enabled: false, currentVersion: '0.1.3');
    expect(result.enabled, isFalse);
    expect(result.hasUpdate, isFalse);
    expect(clients, 0);
  });

  test(
    'uses only the fixed public endpoint and notices a newer stable version',
    () async {
      Uri? requested;
      Duration? deadline;
      final client = UpdateNoticeClient(
        transport: (uri, timeout) async {
          requested = uri;
          deadline = timeout;
          return utf8.encode(jsonEncode(release()));
        },
      );
      addTearDown(client.close);
      final result = await client.check(
        enabled: true,
        currentVersion: '0.1.3+4',
      );
      expect(
        requested.toString(),
        'https://api.github.com/repos/teng-lin/open-foresight/releases/latest',
      );
      expect(deadline, const Duration(seconds: 5));
      expect(result.version, '0.2.0');
      expect(
        result.releasePage.toString(),
        'https://github.com/teng-lin/open-foresight/releases/tag/v0.2.0',
      );
    },
  );

  for (final tag in ['v0.1.3', 'v0.1.2']) {
    test('$tag never offers the current version or a downgrade', () async {
      final client = metadata(release(tag: tag));
      addTearDown(client.close);
      final result = await client.check(enabled: true, currentVersion: '0.1.3');
      expect(result.hasUpdate, isFalse);
      expect(result.releasePage, isNull);
    });
  }

  test('compares numeric version components', () async {
    final client = metadata(release(tag: 'v0.10.0'));
    addTearDown(client.close);
    expect(
      (await client.check(enabled: true, currentVersion: '0.9.9')).hasUpdate,
      isTrue,
    );
  });

  test('HTTP request has no profile payload or authorization', () async {
    String? method, path, body;
    List<String>? authorization, cookies;
    final client = await httpFixture((request) async {
      method = request.method;
      path = request.uri.toString();
      authorization = request.headers[HttpHeaders.authorizationHeader];
      cookies = request.headers[HttpHeaders.cookieHeader];
      body = await utf8.decoder.bind(request).join();
      request.response.write(jsonEncode(release()));
      await request.response.close();
    });
    expect(
      (await client.check(enabled: true, currentVersion: '0.1.3')).hasUpdate,
      isTrue,
    );
    expect(method, 'GET');
    expect(path, '/repos/teng-lin/open-foresight/releases/latest');
    expect(body, isEmpty);
    expect(authorization, isNull);
    expect(cookies, isNull);
  });

  for (final status in [301, 302, 403, 404, 500]) {
    test('HTTP $status is refused without following a redirect', () async {
      var requests = 0;
      final client = await httpFixture((request) async {
        requests++;
        request.response.statusCode = status;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'https://github.com/other/project',
        );
        await request.response.close();
      });
      await expectLater(
        client.check(enabled: true, currentVersion: '0.1.3'),
        throwsA(problem(UpdateNoticeProblem.unavailable)),
      );
      expect(requests, 1);
    });
  }

  test('HTTP metadata stream is bounded before decoding', () async {
    final client = await httpFixture((request) async {
      request.response.add(
        List<int>.filled(UpdateNoticeClient.maximumMetadataBytes + 1, 32),
      );
      await request.response.close();
    });
    await expectLater(
      client.check(enabled: true, currentVersion: '0.1.3'),
      throwsA(problem(UpdateNoticeProblem.invalidMetadata)),
    );
  });

  test('HTTP response that never ends has a finite total deadline', () async {
    final client = await httpFixture((request) async {
      request.response.write('{');
      await request.response.flush();
      // Intentionally no response.close(): client deadline must settle the call.
    }, timeout: const Duration(milliseconds: 100));
    await expectLater(
      client.check(enabled: true, currentVersion: '0.1.3'),
      throwsA(problem(UpdateNoticeProblem.timedOut)),
    );
  });

  for (final entry in {
    'draft': {...release(), 'draft': true},
    'prerelease': {...release(), 'prerelease': true},
    'missing channel': {...release()}..remove('prerelease'),
  }.entries) {
    test('rejects ${entry.key} metadata', () async {
      final client = metadata(entry.value);
      addTearDown(client.close);
      await expectLater(
        client.check(enabled: true, currentVersion: '0.1.3'),
        throwsA(problem(UpdateNoticeProblem.wrongChannel)),
      );
    });
  }

  test('unsupported requested channel refuses before networking', () async {
    var called = false;
    final client = UpdateNoticeClient(
      transport: (_, _) async {
        called = true;
        return [];
      },
    );
    addTearDown(client.close);
    await expectLater(
      client.check(enabled: true, currentVersion: '0.1.3', channel: 'beta'),
      throwsA(problem(UpdateNoticeProblem.wrongChannel)),
    );
    expect(called, isFalse);
  });

  for (final entry in {
    'foreign repository': {
      ...release(),
      'html_url': 'https://github.com/other/project/releases/tag/v0.2.0',
    },
    'foreign API identity': {
      ...release(),
      'url': 'https://api.github.com/repos/other/project/releases/123',
    },
    'HTTP release page': {
      ...release(),
      'html_url':
          'http://github.com/teng-lin/open-foresight/releases/tag/v0.2.0',
    },
    'different release id': {...release(), 'id': 124},
    'query or fragment': {
      ...release(),
      'html_url': '${release()['html_url']}?redirect=elsewhere',
    },
  }.entries) {
    test('rejects ${entry.key}', () async {
      final client = metadata(entry.value);
      addTearDown(client.close);
      await expectLater(
        client.check(enabled: true, currentVersion: '0.1.3'),
        throwsA(problem(UpdateNoticeProblem.untrustedMetadata)),
      );
    });
  }

  for (final value in <Object?>[
    null,
    [],
    'not metadata',
    {...release(), 'id': -1},
    {...release(), 'id': '123'},
    release(tag: '0.2.0'),
    release(tag: 'v00.2.0'),
    release(tag: 'v0.2.0-beta'),
    release(tag: 'v0.2'),
  ]) {
    test('refuses malformed release ${jsonEncode(value)}', () async {
      final client = metadata(value);
      addTearDown(client.close);
      await expectLater(
        client.check(enabled: true, currentVersion: '0.1.3'),
        throwsA(problem(UpdateNoticeProblem.invalidMetadata)),
      );
    });
  }

  test('invalid local version refuses before networking', () async {
    var called = false;
    final client = UpdateNoticeClient(
      transport: (_, _) async {
        called = true;
        return [];
      },
    );
    addTearDown(client.close);
    await expectLater(
      client.check(enabled: true, currentVersion: 'development'),
      throwsA(problem(UpdateNoticeProblem.invalidMetadata)),
    );
    expect(called, isFalse);
  });

  for (final bytes in [
    [0xff],
    utf8.encode('{'),
    List<int>.filled(UpdateNoticeClient.maximumMetadataBytes + 1, 32),
  ]) {
    test('refuses malformed or oversized bytes (${bytes.length})', () async {
      final client = UpdateNoticeClient(transport: (_, _) async => bytes);
      addTearDown(client.close);
      await expectLater(
        client.check(enabled: true, currentVersion: '0.1.3'),
        throwsA(problem(UpdateNoticeProblem.invalidMetadata)),
      );
    });
  }

  test(
    'reports offline failure without exposing raw exception content',
    () async {
      final client = UpdateNoticeClient(
        transport: (_, _) async =>
            throw const SocketException('fixture offline'),
      );
      addTearDown(client.close);
      await expectLater(
        client.check(enabled: true, currentVersion: '0.1.3'),
        throwsA(problem(UpdateNoticeProblem.unavailable)),
      );
    },
  );

  test('a stalled metadata request has a finite total deadline', () async {
    final held = Completer<List<int>>();
    final client = UpdateNoticeClient(
      timeout: const Duration(milliseconds: 20),
      transport: (_, _) => held.future,
    );
    addTearDown(client.close);
    await expectLater(
      client.check(enabled: true, currentVersion: '0.1.3'),
      throwsA(problem(UpdateNoticeProblem.timedOut)),
    );
    held.complete(utf8.encode(jsonEncode(release())));
  });

  test(
    'disabling or disposing rejects an otherwise valid late response',
    () async {
      for (final dispose in [false, true]) {
        final held = Completer<List<int>>();
        final client = UpdateNoticeClient(transport: (_, _) => held.future);
        final result = client.check(enabled: true, currentVersion: '0.1.3');
        if (dispose) {
          client.close();
        } else {
          client.cancelPending();
        }
        held.complete(utf8.encode(jsonEncode(release())));
        await expectLater(
          result,
          throwsA(problem(UpdateNoticeProblem.cancelled)),
        );
        client.close();
      }
    },
  );

  test('real TLS handshake rejects a plaintext endpoint', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final listener = server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {}, onError: (_) {});
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\n\r\nnot TLS'));
      unawaited(socket.flush());
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await listener.cancel();
      await server.close();
    });
    final client = UpdateNoticeClient(
      createClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'DIRECT';
        client.connectionFactory = (_, _, _) => SecureSocket.startConnect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        return client;
      },
    );
    addTearDown(client.close);
    await expectLater(
      client.check(enabled: true, currentVersion: '0.1.3'),
      throwsA(problem(UpdateNoticeProblem.untrustedMetadata)),
    );
  });
}
