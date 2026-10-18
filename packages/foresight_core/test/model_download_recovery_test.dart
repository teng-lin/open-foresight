import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:foresight_core/src/gemma_download.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late List<int> bytes;
  late GemmaModel model;
  late Uri uri;
  late HttpClient Function() client;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('model-recovery-');
    bytes = List.generate(4096, (i) => i % 251);
    model = GemmaModel(
      'Fixture',
      '',
      '',
      'fixture.bin',
      sha256.convert(bytes).toString(),
      bytes.length,
      1,
    );
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      '${root.path}/key.pem',
      '-out',
      '${root.path}/cert.pem',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
    ]);
    expect(result.exitCode, 0);
    final context = SecurityContext()
      ..useCertificateChain('${root.path}/cert.pem')
      ..usePrivateKey('${root.path}/key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    uri = Uri.parse('https://127.0.0.1:${server.port}/model');
    client = () =>
        HttpClient()
          ..badCertificateCallback = (cert, host, port) =>
              host == '127.0.0.1' && port == server.port;
  });
  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'socket interruption retains a partial and the next attempt resumes its exact range',
    () async {
      final ranges = <String?>[];
      server.listen((request) async {
        ranges.add(request.headers.value('range'));
        if (ranges.length == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n',
          );
          socket.add(bytes.sublist(0, 1234));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          socket.destroy();
        } else {
          expect(request.headers.value('range'), 'bytes=1234-4095');
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 1234-4095/4096');
          request.response.add(bytes.sublist(1234));
          await request.response.close();
        }
      });
      await expectLater(
        GemmaDownload(
          createClient: client,
          parallelism: 1,
        ).download(model, root, sourceForTesting: uri),
        throwsStateError,
      );
      final staging = File(
        '${root.path}/${model.directory}/.download/model.part',
      );
      expect(await staging.length(), 1234);
      final file = await GemmaDownload(
        createClient: client,
        parallelism: 1,
      ).download(model, root, sourceForTesting: uri);
      expect(await file.readAsBytes(), bytes);
      expect(ranges, [null, 'bytes=1234-4095']);
    },
  );

  test(
    'parallel retries retain completed ranges and resume a damaged connection',
    () async {
      var interrupted = false;
      final requested = <String>[];
      server.listen((request) async {
        final range = request.headers.value('range')!;
        requested.add(range);
        final endpoints = range.substring(6).split('-').map(int.parse).toList();
        final start = endpoints[0], end = endpoints[1];
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes $start-$end/4096');
        request.response.contentLength = end - start + 1;
        if (start == 1024 && !interrupted) {
          interrupted = true;
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 206 Partial Content\r\nContent-Length: 1024\r\nContent-Range: bytes $start-$end/4096\r\nConnection: close\r\n\r\n',
          );
          socket.add(bytes.sublist(start, start + 300));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          socket.destroy();
        } else {
          request.response.add(bytes.sublist(start, end + 1));
          await request.response.close();
        }
      });
      await expectLater(
        GemmaDownload(
          createClient: client,
          rangeThreshold: 0,
        ).download(model, root, sourceForTesting: uri),
        throwsStateError,
      );
      final initialCount = requested.length;
      final file = await GemmaDownload(
        createClient: client,
        rangeThreshold: 0,
      ).download(model, root, sourceForTesting: uri);
      expect(await file.readAsBytes(), bytes);
      expect(requested.skip(initialCount), ['bytes=1324-2047']);
    },
  );

  test(
    'same-size cache corruption is absent and is replaced only by verified bytes',
    () async {
      final destination =
          File('${root.path}/${model.directory}/${model.filename}')
            ..createSync(recursive: true)
            ..writeAsBytesSync(List.filled(bytes.length, 7));
      expect(await localModelFile(model, root), isNull);
      var badResponse = true;
      server.listen((request) async {
        request.response.add(
          badResponse ? List.filled(bytes.length, 8) : bytes,
        );
        await request.response.close();
      });
      await expectLater(
        GemmaDownload(
          createClient: client,
        ).download(model, root, sourceForTesting: uri),
        throwsStateError,
      );
      expect(await destination.readAsBytes(), List.filled(bytes.length, 7));
      badResponse = false;
      final file = await GemmaDownload(
        createClient: client,
      ).download(model, root, sourceForTesting: uri);
      expect(file.path, destination.path);
      expect(await localModelFile(model, root), isNotNull);
      expect(await file.readAsBytes(), bytes);
    },
  );

  test(
    'insufficient free disk space refuses before creating an HTTP client',
    () async {
      await expectLater(
        GemmaDownload(
          availableBytes: (_) async => 0,
          createClient: () => throw StateError('Must not open the network'),
        ).download(model, root, sourceForTesting: uri),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Not enough free disk space'),
          ),
        ),
      );
      expect(
        File('${root.path}/${model.directory}/${model.filename}').existsSync(),
        false,
      );
    },
  );

  test(
    'a server ignoring a resumed Range restarts and verifies the whole file',
    () async {
      final staging =
          File('${root.path}/${model.directory}/.download/model.part')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes.sublist(0, 100));
      server.listen((request) async {
        expect(request.headers.value('range'), 'bytes=100-4095');
        request.response.add(bytes);
        await request.response.close();
      });
      final file = await GemmaDownload(
        createClient: client,
        parallelism: 1,
      ).download(model, root, sourceForTesting: uri);
      expect(await file.readAsBytes(), bytes);
      expect(await staging.exists(), false);
    },
  );
  test(
    'a concurrent attempt cannot mutate the active downloader staging',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        started.complete();
        await release.future;
        request.response.add(bytes);
        await request.response.close();
      });
      final first = GemmaDownload(
        createClient: client,
      ).download(model, root, sourceForTesting: uri);
      await started.future;
      await expectLater(
        GemmaDownload(
          createClient: client,
        ).download(model, root, sourceForTesting: uri),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('already active'),
          ),
        ),
      );
      expect(requests, 1);
      release.complete();
      expect(await (await first).readAsBytes(), bytes);
    },
  );

  test(
    'complete but corrupt retained bytes are discarded rather than resumed forever',
    () async {
      final staging =
          File('${root.path}/${model.directory}/.download/model.part')
            ..createSync(recursive: true)
            ..writeAsBytesSync(List.filled(model.bytes, 0));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.add(bytes);
        await request.response.close();
      });
      await expectLater(
        GemmaDownload(
          createClient: client,
          parallelism: 1,
        ).download(model, root, sourceForTesting: uri),
        throwsStateError,
      );
      expect(requests, 0);
      expect(await staging.exists(), false);
      final file = await GemmaDownload(
        createClient: client,
        parallelism: 1,
      ).download(model, root, sourceForTesting: uri);
      expect(requests, 1);
      expect(await file.readAsBytes(), bytes);
    },
  );
}
