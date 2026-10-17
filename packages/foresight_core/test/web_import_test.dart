import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/web_import.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:test/test.dart';

final privateAddresses = [
  '0.0.0.0',
  '0.1.2.3',
  '10.0.0.1',
  '100.64.0.1',
  '100.100.100.200',
  '127.0.0.1',
  '169.254.169.254',
  '172.16.0.1',
  '172.31.255.255',
  '192.0.0.1',
  '192.0.2.1',
  '192.88.99.1',
  '192.168.1.1',
  '198.18.0.1',
  '198.19.255.255',
  '198.51.100.1',
  '203.0.113.1',
  '224.0.0.1',
  '240.0.0.1',
  '255.255.255.255',
  '168.63.129.16',
  '::',
  '::1',
  '::127.0.0.1',
  '::ffff:127.0.0.1',
  '::ffff:192.168.1.1',
  'fc00::1',
  'fd12::1',
  'fe80::1',
  'ff02::1',
  '64:ff9b::a00:1',
  '2001::1',
  '2001:2::1',
  '2001:db8::1',
  '2002:7f00:1::1',
  '3fff::1',
];

void main() {
  test(
    'global-address policy rejects private, metadata, mapped and special ranges',
    () {
      for (final address in privateAddresses) {
        expect(
          isGlobalWebAddress(InternetAddress(address)),
          false,
          reason: address,
        );
      }
      for (final address in [
        '8.8.8.8',
        '1.1.1.1',
        '172.32.0.1',
        '192.0.1.1',
        '2001:4860:4860::8888',
        '2606:4700:4700::1111',
        '::ffff:8.8.8.8',
      ]) {
        expect(
          isGlobalWebAddress(InternetAddress(address)),
          true,
          reason: address,
        );
      }
    },
  );

  test(
    'untrusted DNS and literal private addresses never open a socket',
    () async {
      var connections = 0;
      for (final address in privateAddresses) {
        final importer = WebPageImporter(
          lookup: (_) async => [InternetAddress(address)],
          connect: (ip, port) async {
            connections++;
            throw StateError('Unexpected connection');
          },
        );
        await expectLater(
          importer.fetch(Uri.parse('http://private.test/')),
          throwsStateError,
        );
      }
      final importer = WebPageImporter(
        connect: (ip, port) async {
          connections++;
          throw StateError('Unexpected connection');
        },
      );
      for (final url in [
        'http://127.0.0.1/',
        'http://[::1]/',
        'http://169.254.169.254/latest/meta-data/',
        'http://[::ffff:127.0.0.1]/',
      ]) {
        await expectLater(importer.fetch(Uri.parse(url)), throwsStateError);
      }
      expect(connections, 0);
    },
  );

  test('mixed public/private DNS results fail closed', () async {
    final importer = WebPageImporter(
      lookup: (_) async => [
        InternetAddress('8.8.8.8'),
        InternetAddress('127.0.0.1'),
      ],
      connect: (_, _) => throw StateError('Unexpected connection'),
    );
    await expectLater(
      importer.fetch(Uri.parse('http://mixed.test/')),
      throwsStateError,
    );
  });

  test('DNS deadline prevents a late lookup from opening a socket', () async {
    final lookup = Completer<List<InternetAddress>>();
    var connected = false;
    final importer = WebPageImporter(
      timeout: const Duration(milliseconds: 25),
      lookup: (_) => lookup.future,
      connect: (_, _) async {
        connected = true;
        throw StateError('Unexpected late connection');
      },
    );
    await expectLater(
      importer.fetch(Uri.parse('http://slow-dns.test/')),
      throwsStateError,
    );
    lookup.complete([InternetAddress('8.8.8.8')]);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(connected, false);
  });

  test('private network imports require explicit opt-in', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.html;
      request.response.write('<p>Allowed local page</p>');
      await request.response.close();
    });
    final importer = WebPageImporter();
    final url = Uri.parse('http://127.0.0.1:${server.port}/');
    await expectLater(importer.fetch(url), throwsStateError);
    expect(requests, 0);
    expect(
      await importer.fetch(url, allowPrivateNetwork: true),
      'Allowed local page',
    );
    expect(requests, 1);
  });

  test(
    'connections use the validated IP once without a second DNS lookup',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(
          request.headers.value(HttpHeaders.hostHeader),
          'public.test:${server.port}',
        );
        request.response.headers.contentType = ContentType.text;
        request.response.write('Pinned socket');
        await request.response.close();
      });
      var lookups = 0;
      final connected = <String>[];
      final importer = WebPageImporter(
        lookup: (_) async {
          lookups++;
          return [InternetAddress(lookups == 1 ? '8.8.8.8' : '127.0.0.1')];
        },
        connect: (ip, port) {
          connected.add(ip.address);
          return Socket.startConnect(InternetAddress.loopbackIPv4, port);
        },
      );
      expect(
        await importer.fetch(Uri.parse('http://public.test:${server.port}/')),
        'Pinned socket',
      );
      expect(lookups, 1);
      expect(connected, ['8.8.8.8']);
    },
  );

  test(
    'each redirect revalidates literal and DNS destinations before connecting',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var location = 'http://169.254.169.254/latest/meta-data/';
      server.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set('location', location);
        await request.response.close();
      });
      for (final target in [
        'http://127.0.0.1/',
        'http://169.254.169.254/latest/meta-data/',
        'http://10.0.0.1/',
        'http://[::1]/',
        'http://rebind.test:${server.port}/',
        'file:///etc/passwd',
      ]) {
        location = target;
        var connections = 0;
        final importer = WebPageImporter(
          lookup: (host) async => [
            InternetAddress(host == 'public.test' ? '8.8.8.8' : '127.0.0.1'),
          ],
          connect: (ip, port) {
            connections++;
            return Socket.startConnect(InternetAddress.loopbackIPv4, port);
          },
        );
        await expectLater(
          importer.fetch(Uri.parse('http://public.test:${server.port}/')),
          throwsStateError,
          reason: target,
        );
        expect(connections, 1, reason: target);
      }
    },
  );

  test(
    'another validated DNS address is tried if the first cannot connect',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('Reachable');
        await request.response.close();
      });
      final attempted = <String>[];
      final importer = WebPageImporter(
        lookup: (_) async => [
          InternetAddress('2001:4860:4860::8888'),
          InternetAddress('8.8.8.8'),
        ],
        connect: (address, port) async {
          attempted.add(address.address);
          if (address.type == InternetAddressType.IPv6)
            throw const SocketException('IPv6 unavailable');
          return Socket.startConnect(InternetAddress.loopbackIPv4, port);
        },
      );
      expect(
        await importer.fetch(Uri.parse('http://public.test:${server.port}/')),
        'Reachable',
      );
      expect(attempted, ['2001:4860:4860::8888', '8.8.8.8']);
    },
  );

  test('same-host DNS rebinding at a redirect is blocked', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', '/next');
      await request.response.close();
    });
    var lookups = 0, connections = 0;
    final importer = WebPageImporter(
      lookup: (_) async => [
        InternetAddress(++lookups == 1 ? '8.8.8.8' : '127.0.0.1'),
      ],
      connect: (ip, port) {
        connections++;
        return Socket.startConnect(InternetAddress.loopbackIPv4, port);
      },
    );
    await expectLater(
      importer.fetch(Uri.parse('http://public.test:${server.port}/')),
      throwsStateError,
    );
    expect(lookups, 2);
    expect(connections, 1);
  });

  test(
    'relative redirect opt-in is retained and redirect loops are bounded',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (request.uri.path == '/page') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('Redirected');
        } else {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            request.uri.path == '/loop' ? '/loop' : '/page',
          );
        }
        await request.response.close();
      });
      final importer = WebPageImporter();
      expect(
        await importer.fetch(
          Uri.parse('http://127.0.0.1:${server.port}/start'),
          allowPrivateNetwork: true,
        ),
        'Redirected',
      );
      expect(requests, 2);
      await expectLater(
        importer.fetch(
          Uri.parse('http://127.0.0.1:${server.port}/loop'),
          allowPrivateNetwork: true,
        ),
        throwsStateError,
      );
      expect(requests, 8);
    },
  );

  test(
    'TLS validates the URL hostname on the pinned socket and refuses downgrade',
    () async {
      final serverContext = SecurityContext()
        ..useCertificateChain('test/fixtures/web_import/cert.pem')
        ..usePrivateKey('test/fixtures/web_import/key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (request.uri.path == '/downgrade') {
          request.response.statusCode = 302;
          request.response.headers.set('location', 'http://public.test/');
        } else {
          request.response.headers.contentType = ContentType.text;
          request.response.write('Secure public page');
        }
        await request.response.close();
      });
      final importer = WebPageImporter(
        securityContext: SecurityContext()
          ..setTrustedCertificates('test/fixtures/web_import/cert.pem'),
        lookup: (_) async => [InternetAddress('8.8.8.8')],
        connect: (_, port) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, port),
      );
      expect(
        await importer.fetch(
          Uri.parse('https://web-import.test:${server.port}/'),
        ),
        'Secure public page',
      );
      await expectLater(
        importer.fetch(
          Uri.parse('https://web-import.test:${server.port}/downgrade'),
        ),
        throwsStateError,
      );
      await expectLater(
        importer.fetch(Uri.parse('https://wrong-host.test:${server.port}/')),
        throwsA(isA<HandshakeException>()),
      );
      expect(requests, 2);
    },
  );

  test(
    'response charsets decode GBK, Big5 and Shift_JIS with full HTML entities',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final fixtures = {
        'gbk': ([0xd6, 0xd0, 0xce, 0xc4], '中文'),
        'big5': ([0xa4, 0xa4, 0xa4, 0xe5], '中文'),
        'shift_jis': ([0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea], '日本語'),
      };
      server.listen((request) async {
        final charset = request.uri.path.substring(1);
        request.response.headers.contentType = ContentType(
          'text',
          'html',
          charset: charset,
        );
        request.response.add([
          ...ascii.encode('<p>'),
          ...fixtures[charset]!.$1,
          ...ascii.encode(' &copy; &#x1F600; &eacute; &quot;ok&quot;</p>'),
        ]);
        await request.response.close();
      });
      for (final entry in fixtures.entries) {
        expect(
          await WebPageImporter().fetch(
            Uri.parse('http://127.0.0.1:${server.port}/${entry.key}'),
            allowPrivateNetwork: true,
          ),
          '${entry.value.$2} © 😀 é "ok"',
        );
      }
    },
  );

  test(
    'parser removes hidden content, preserves boundaries and rejects invalid encodings',
    () async {
      expect(
        await parseWebPage(
          Uint8List.fromList(
            utf8.encode(
              '<head><title>hidden</title></head><p>Hello<b>world</b>end</p><script>secret</script><style>private</style><template>hidden</template>',
            ),
          ),
          mimeType: 'text/html',
        ),
        'Hello world end',
      );
      await expectLater(
        parseWebPage(Uint8List.fromList([255]), mimeType: 'text/plain'),
        throwsStateError,
      );
      await expectLater(
        parseWebPage(
          Uint8List.fromList([1]),
          mimeType: 'text/plain',
          charset: 'unsupported',
        ),
        throwsStateError,
      );
      await expectLater(
        parseWebPage(Uint8List(maxWebPageBytes + 1), mimeType: 'text/plain'),
        throwsStateError,
      );
      await expectLater(
        parseWebPage(
          Uint8List.fromList(ascii.encode('<b>' * 100001)),
          mimeType: 'text/html',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'hostile HTML parser has a killable deadline while service timers keep running',
    () async {
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      final elapsed = Stopwatch()..start();
      try {
        await expectLater(
          parseWebPage(
            Uint8List.fromList(ascii.encode('<b>' * 60000)),
            mimeType: 'text/html',
            timeout: const Duration(milliseconds: 50),
          ),
          throwsStateError,
        );
        expect(ticks, greaterThan(0));
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          await parseWebPage(
            Uint8List.fromList(ascii.encode('<p>Next request</p>')),
            mimeType: 'text/html',
          ),
          'Next request',
        );
      } finally {
        timer.cancel();
      }
    },
  );

  test(
    'whole-download deadline stops a continuously active slow body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        try {
          for (var i = 0; i < 40; i++) {
            request.response.write('tick');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await request.response.close();
        } catch (_) {}
      });
      final elapsed = Stopwatch()..start();
      await expectLater(
        WebPageImporter(timeout: const Duration(milliseconds: 100)).fetch(
          Uri.parse('http://127.0.0.1:${server.port}/'),
          allowPrivateNetwork: true,
        ),
        throwsStateError,
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );

  test(
    'hostile page import cannot stall another application-service RPC',
    () async {
      final root = Directory.systemTemp.createTempSync('web-import-service-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      final service = await ApplicationService.start(profile);
      final client = await ServiceClient.connect(
        '${profile.runtime}/application.sock',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sent = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<b>' * 60000);
        await request.response.close();
        sent.complete();
      });
      try {
        final pending = client.call('sources.import_url', {
          'url': 'http://127.0.0.1:${server.port}/',
          'allow_private_network': true,
        });
        final rejected = expectLater(pending, throwsStateError);
        await sent.future;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final elapsed = Stopwatch()..start();
        final status = await client
            .call('status')
            .timeout(const Duration(milliseconds: 500));
        expect(status, isA<Map>());
        expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
        await rejected;
        expect(service.domain.store.sources, isEmpty);
      } finally {
        await client.close();
        await service.close();
        await server.close(force: true);
        root.deleteSync(recursive: true);
      }
    },
  );
}
