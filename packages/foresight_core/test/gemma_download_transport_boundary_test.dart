import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/gemma_download.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late Future<void> Function(HttpRequest) respond;
  late Uri uri;
  late HttpClient Function() client;
  setUp(() async {
    root = createTestTempDirectorySync('gemma-transport-boundaries-');
    final certificate = '${root.path}/certificate.pem',
        key = '${root.path}/key.pem';
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      certificate,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(key),
    );
    uri = Uri.parse('https://127.0.0.1:${server.port}/model');
    client = () =>
        HttpClient()
          ..badCertificateCallback = (_, host, port) =>
              host == '127.0.0.1' && port == server.port;
    server.listen((request) => respond(request));
    addTearDown(() async {
      await server.close(force: true);
      root.deleteSync(recursive: true);
    });
  });
  GemmaModel model(List<int> bytes) => GemmaModel(
    'local fixture',
    'fixture/repository',
    'pinned',
    'fixture.bin',
    sha256.convert(bytes).toString(),
    bytes.length,
    0,
  );

  test(
    'large verified transfer flushes staging and cached reuse reports completed progress',
    () async {
      final bytes = List.generate(1024 * 1024 + 31, (i) => i % 251);
      final fixture = model(bytes);
      var requests = 0;
      respond = (request) async {
        requests++;
        expect(
          request.headers.value(HttpHeaders.acceptEncodingHeader),
          'identity',
        );
        expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      };
      final cache = Directory('${root.path}/cache');
      final progress = <(int, int)>[], phases = <ModelDownloadPhase>[];
      final download = GemmaDownload(createClient: client);
      final file = await download.download(
        fixture,
        cache,
        sourceForTesting: uri,
        progress: (received, total) => progress.add((received, total)),
        phase: phases.add,
      );
      expect(await file.readAsBytes(), bytes);
      expect(progress.first, (0, bytes.length));
      expect(progress.last, (bytes.length, bytes.length));
      expect(phases, [
        ModelDownloadPhase.checkingCache,
        ModelDownloadPhase.downloading,
        ModelDownloadPhase.verifyingDownload,
      ]);
      expect(Directory('${file.parent.path}/.download').existsSync(), isFalse);
      progress.clear();
      final reused = await download.download(
        fixture,
        cache,
        progress: (received, total) => progress.add((received, total)),
      );
      expect(reused.path, file.path);
      expect(progress, [(bytes.length, bytes.length)]);
      expect(requests, 1);
    },
  );

  test(
    'server ignoring resume cannot overwrite retained partial when restart space is insufficient',
    () async {
      final bytes = [1, 2, 3, 4, 5, 6], fixture = model([1, 2, 3, 4, 5, 6]);
      final cache = Directory('${root.path}/cache');
      final stage = Directory('${cache.path}/${fixture.directory}/.download')
        ..createSync(recursive: true);
      File('${stage.path}/identity.json').writeAsStringSync(
        jsonEncode({
          'digest': fixture.digest,
          'bytes': fixture.bytes,
          'parallelism': 4,
          'rangeThreshold': 64 * 1024 * 1024,
        }),
      );
      final partial = File('${stage.path}/model.part')
        ..writeAsBytesSync(bytes.take(3).toList());
      respond = (request) async {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=3-5');
        request.response.add(bytes);
        await request.response.close();
      };
      final downloader = GemmaDownload(
        createClient: client,
        availableBytes: (_) async => bytes.length + 16 * 1024 * 1024 - 1,
      );
      await expectLater(
        downloader.download(fixture, cache, sourceForTesting: uri),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('restart'),
          ),
        ),
      );
      expect(partial.readAsBytesSync(), [1, 2, 3]);
      expect(
        File('${stage.parent.path}/${fixture.filename}').existsSync(),
        isFalse,
      );
      // The failed attempt released its lock; a subsequent owner can safely restart.
      final resumed = await GemmaDownload(
        createClient: client,
      ).download(fixture, cache, sourceForTesting: uri);
      expect(resumed.readAsBytesSync(), bytes);
      expect(stage.existsSync(), isFalse);
    },
  );
}
