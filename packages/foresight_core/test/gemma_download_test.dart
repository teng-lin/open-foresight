import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:foresight_core/src/gemma_download.dart';

void main() {
  test(
    'registered asset outside the cache is verified and reused without network access',
    () async {
      final root = Directory.systemTemp.createTempSync('existing-model-');
      final bytes = List.generate(1024, (i) => i % 251);
      final model = GemmaModel(
        'fixture',
        '',
        '',
        'fixture.bin',
        sha256.convert(bytes).toString(),
        bytes.length,
        0,
      );
      final file = File('${root.path}/custom/model.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final cache = Directory('${root.path}/new-cache');
      final registration = <String, Object?>{
        'digest': model.digest,
        'path': file.path,
        'runtime': '/missing/runner',
      };
      final phases = <ModelDownloadPhase>[];
      try {
        expect(
          (await localModelFile(
            model,
            cache,
            registration: registration,
          ))?.path,
          file.path,
        );
        final reused = await GemmaDownload(
          createClient: () => throw StateError('Network must not be used'),
        ).download(model, cache, existingFile: file, phase: phases.add);
        expect(reused.path, file.path);
        expect(phases, [
          ModelDownloadPhase.checkingCache,
          ModelDownloadPhase.verifyingCache,
        ]);
        expect(cache.existsSync(), false);
        // Same-length corruption must not bypass the digest check or trigger a download.
        file.writeAsBytesSync(List.filled(bytes.length, 0));
        await expectLater(
          GemmaDownload(
            createClient: () => throw StateError('Network must not be used'),
          ).download(model, cache, existingFile: file),
          throwsStateError,
        );
        expect(file.readAsBytesSync(), List.filled(bytes.length, 0));
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'range download verifies bytes, reuse and preserves invalid existing files',
    () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final model = GemmaModel(
        'fixture',
        '',
        '',
        'fixture.litertlm',
        sha256.convert(bytes).toString(),
        bytes.length,
        1,
      );
      final root = Directory.systemTemp.createTempSync('gemma-download-');
      final certificate = '${root.path}/certificate.pem';
      final key = '${root.path}/key.pem';
      final result = Process.runSync('openssl', [
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
      expect(result.exitCode, 0);
      final context = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(key);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      HttpClient client() =>
          HttpClient()
            ..badCertificateCallback = (cert, host, port) =>
                host == '127.0.0.1' && port == server.port;
      var requests = 0;
      server.listen((request) async {
        requests++;
        final range = request.headers.value('range');
        if (range != null) {
          final endpoints = range
              .substring(6)
              .split('-')
              .map(int.parse)
              .toList();
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes ${endpoints[0]}-${endpoints[1]}/${bytes.length}',
          );
          request.response.add(bytes.sublist(endpoints[0], endpoints[1] + 1));
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      try {
        final uri = Uri.parse('https://127.0.0.1:${server.port}/fixture');
        final file = await GemmaDownload(
          rangeThreshold: 0,
          createClient: client,
        ).download(model, root, sourceForTesting: uri);
        expect(await file.readAsBytes(), bytes);
        expect(requests, 4);
        final phases = <ModelDownloadPhase>[];
        await GemmaDownload().download(
          model,
          root,
          sourceForTesting: uri,
          phase: phases.add,
        );
        expect(phases, [
          ModelDownloadPhase.checkingCache,
          ModelDownloadPhase.verifyingCache,
        ]);
        expect(requests, 4);
        await file.writeAsBytes([1, 2, 3]);
        await expectLater(
          GemmaDownload().download(model, root, sourceForTesting: uri),
          throwsStateError,
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
      } finally {
        await server.close(force: true);
        root.deleteSync(recursive: true);
      }
    },
  );
  test('cancelled downloader never replaces a completed asset', () async {
    final root = Directory.systemTemp.createTempSync('gemma-cancel-');
    final bytes = [1, 2, 3];
    final model = GemmaModel(
      'fixture',
      '',
      '',
      'fixture.litertlm',
      sha256.convert(bytes).toString(),
      3,
      1,
    );
    final directory = Directory('${root.path}/${model.directory}')
      ..createSync();
    final file = File('${directory.path}/${model.filename}')
      ..writeAsBytesSync(bytes);
    try {
      final downloader = GemmaDownload()..cancel();
      await expectLater(downloader.download(model, root), throwsStateError);
      expect(file.readAsBytesSync(), bytes);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
