import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/web_import.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

void main() {
  test(
    'late connection completion after deadline cancels the socket and cannot issue HTTP',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      server.listen(peers.add);
      final raw = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final release = Completer<ConnectionTask<Socket>>();
      final entered = Completer<void>();
      var cancellations = 0;
      final importer = WebPageImporter(
        timeout: const Duration(seconds: 1),
        lookup: (_) async => [InternetAddress('8.8.8.8')],
        connect: (_, _) {
          entered.complete();
          return release.future;
        },
      );
      addTearDown(() async {
        raw.destroy();
        for (final peer in peers) {
          peer.destroy();
        }
        await server.close();
      });
      final rejected = expectLater(
        importer.fetch(Uri.parse('http://public.fixture/')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('time limit'),
          ),
        ),
      );
      await entered.future;
      await rejected;
      release.complete(
        ConnectionTask.fromSocket(Future.value(raw), () {
          cancellations++;
          raw.destroy();
        }),
      );
      await eventually(() => cancellations > 0);
      expect(cancellations, 1);
    },
  );

  test(
    'response refusal closes each transport and a later request remains usable',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requested = <String>[];
      server.listen((request) async {
        requested.add(request.uri.path);
        switch (request.uri.path) {
          case '/status':
            request.response.statusCode = 503;
          case '/binary':
            request.response.headers.contentType = ContentType.binary;
          case '/redirect':
            request.response.statusCode = 302;
          case '/large':
            request.response.headers.contentType = ContentType.text;
            request.response.add(List.filled(maxWebPageBytes + 1, 120));
          default:
            request.response.headers.contentType = ContentType.text;
            request.response.write('next request is independent');
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final importer = WebPageImporter();
      for (final path in ['status', 'binary', 'redirect', 'large']) {
        await expectLater(
          importer.fetch(base.resolve(path), allowPrivateNetwork: true),
          throwsStateError,
        );
        expect(
          await importer.fetch(
            base.resolve('valid'),
            allowPrivateNetwork: true,
          ),
          'next request is independent',
        );
      }
      expect(requested.where((path) => path == '/valid'), hasLength(4));
    },
  );
}
