import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
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
    root = await createTestTempDirectory('model-recovery-');
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
  setUp(() {
    addTearDown(() async {
      await server.close(force: true);
      await root.delete(recursive: true);
    });
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
          await eventually(
            () =>
                File(
                  '${root.path}/${model.directory}/.download/model.part',
                ).existsSync() &&
                File(
                      '${root.path}/${model.directory}/.download/model.part',
                    ).lengthSync() ==
                    1234,
          );
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
          await eventually(
            () =>
                File(
                  '${root.path}/${model.directory}/.download/range-1.part',
                ).existsSync() &&
                File(
                      '${root.path}/${model.directory}/.download/range-1.part',
                    ).lengthSync() ==
                    300,
          );
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

  for (final fault in [
    'range',
    'status',
    'length',
    'redirect-loop',
    'redirect-missing',
    'redirect-http',
  ]) {
    test(
      '$fault response preserves registration bytes and permits a verified retry',
      () async {
        final destination =
            File('${root.path}/${model.directory}/${model.filename}')
              ..createSync(recursive: true)
              ..writeAsStringSync('previous model');
        var broken = true;
        server.listen((request) async {
          if (!broken) {
            final range = request.headers.value('range');
            final start = range == null
                ? 0
                : int.parse(range.substring(6).split('-').first);
            final end = range == null
                ? bytes.length - 1
                : int.parse(range.split('-').last);
            if (range != null) {
              request.response.statusCode = 206;
              request.response.headers.set(
                'content-range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            request.response.add(bytes.sublist(start, end + 1));
          } else if (fault.startsWith('redirect')) {
            request.response.statusCode = 302;
            if (fault != 'redirect-missing') {
              request.response.headers.set(
                'location',
                fault == 'redirect-http' ? 'http://127.0.0.1/model' : '/model',
              );
            }
          } else if (fault == 'range') {
            request.response.statusCode = 206;
            request.response.headers.set('content-range', 'bytes 1-1024/4096');
            request.response.add(bytes.sublist(0, 1024));
          } else if (fault == 'length') {
            request.response.contentLength = 1;
            request.response.add([0]);
          } else {
            request.response.statusCode = 403;
          }
          await request.response.close();
        });
        final downloader = GemmaDownload(
          createClient: client,
          rangeThreshold: fault == 'range' ? 0 : 65536,
        );
        await expectLater(
          downloader.download(model, root, sourceForTesting: uri),
          throwsStateError,
        );
        expect(destination.readAsStringSync(), 'previous model');
        broken = false;
        final verified = await downloader.download(
          model,
          root,
          sourceForTesting: uri,
        );
        expect(await verified.readAsBytes(), bytes);
        expect(
          await verifyModelFile(verified, model.digest, model.bytes),
          isTrue,
        );
      },
    );
  }

  test('parallel transfer falls back when the server ignores ranges', () async {
    final requests = <String?>[];
    final phases = <ModelDownloadPhase>[];
    final progress = <int>[];
    server.listen((request) async {
      requests.add(request.headers.value('range'));
      request.response.add(bytes);
      await request.response.close();
    });
    final file =
        await GemmaDownload(
          createClient: client,
          rangeThreshold: 0,
          parallelism: 3,
        ).download(
          model,
          root,
          sourceForTesting: uri,
          phase: phases.add,
          progress: (received, _) => progress.add(received),
        );
    expect(requests, ['bytes=0-1365']);
    expect(await file.readAsBytes(), bytes);
    expect(progress.last, bytes.length);
    expect(phases.last, ModelDownloadPhase.verifyingDownload);
    expect(Directory('${file.parent.path}/.download').existsSync(), isFalse);
  });

  test(
    'incompatible staging identity and oversized parts cannot poison retries',
    () async {
      final stage = Directory('${root.path}/${model.directory}/.download')
        ..createSync(recursive: true);
      File('${stage.path}/identity.json').writeAsStringSync('{"digest":"old"}');
      File('${stage.path}/model.part').writeAsStringSync('old partial');
      File('${stage.path}/assembled.part').writeAsStringSync('old assembly');
      server.listen((request) async {
        request.response.add(bytes);
        await request.response.close();
      });
      final first = await GemmaDownload(
        createClient: client,
      ).download(model, root, sourceForTesting: uri);
      expect(await first.readAsBytes(), bytes);
      first.deleteSync();
      stage.createSync();
      final part = File('${stage.path}/model.part')
        ..writeAsBytesSync(List.filled(bytes.length + 1, 0));
      final next = await GemmaDownload(
        createClient: client,
      ).download(model, root, sourceForTesting: uri);
      expect(await next.readAsBytes(), bytes);
      expect(part.existsSync(), isFalse);
    },
  );

  test(
    'untrusted staging and destination entries fail before network access',
    () async {
      final destination = Directory(
        '${root.path}/${model.directory}/${model.filename}',
      )..createSync(recursive: true);
      await expectLater(
        GemmaDownload(
          createClient: () => throw StateError('network opened'),
        ).download(model, root),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'The model cache destination must be a regular file.',
          ),
        ),
      );
      destination.deleteSync();
      final stage = Directory(
        '${root.path}/${model.directory}/.download/model.part',
      )..createSync(recursive: true);
      await expectLater(
        GemmaDownload(
          createClient: () => throw StateError('network opened'),
        ).download(model, root),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Invalid download staging file.',
          ),
        ),
      );
      expect(stage.existsSync(), isTrue);
      for (final parallelism in [0, 9]) {
        await expectLater(
          GemmaDownload(parallelism: parallelism).download(model, root),
          throwsArgumentError,
        );
      }
      final invalid = GemmaModel(
        'Invalid',
        '',
        '',
        '../model.bin',
        model.digest,
        model.bytes,
        0,
      );
      await expectLater(
        GemmaDownload().download(invalid, root),
        throwsArgumentError,
      );
    },
  );
}
