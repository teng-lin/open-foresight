import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/platform_services.dart'
    show runtimeConfiguration;
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'transport worker executable cannot escape an installed application',
    () async {
      final root = createTestTempDirectorySync('worker-installation-');
      final saved = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(saved),
      );
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = root.path;
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          Platform.resolvedExecutable;
      final downloader = ModelBlobDownloader(apiKey: 'private-fixture');
      addTearDown(downloader.close);
      await expectLater(
        downloader.download(blobId: 'fixture', size: 4),
        throwsA(
          isA<ModelTransportException>().having(
            (e) => e.failureType,
            'category',
            'worker_unavailable',
          ),
        ),
      );
    },
  );

  for (final phase in ['connect', 'headers', 'body']) {
    test('$phase stall aborts its socket and exhausts finite retries', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final closed = <Completer<void>>[];
      server.listen((socket) {
        if (phase == 'connect' && closed.isNotEmpty) {
          expect(
            closed.last.isCompleted,
            isTrue,
            reason: 'retry must follow actual TLS socket retirement',
          );
        }
        sockets.add(socket);
        final done = Completer<void>();
        closed.add(done);
        var answered = false;
        socket.listen(
          (bytes) {
            if (!answered && phase == 'body') {
              answered = true;
              socket.add(
                ascii.encode(
                  'HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n\r\n',
                ),
              );
              socket.add([1]);
            }
          },
          onDone: () {
            socket.destroy();
            done.complete();
          },
          onError: (Object _) {
            socket.destroy();
            if (!done.isCompleted) done.complete();
          },
        );
      });
      final downloader = ModelBlobDownloader(
        apiKey: 'must-not-escape',
        parallelCount: 1,
        origin: Uri.parse(
          '${phase == 'connect' ? 'https' : 'http'}://127.0.0.1:${server.port}',
        ),
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: 2,
          delay: (_) => Duration.zero,
        ),
        deadlines: const ModelTransportDeadlines(
          connect: Duration(milliseconds: 150),
          headers: Duration(milliseconds: 150),
          bodyIdle: Duration(milliseconds: 150),
          attempt: Duration(seconds: 1),
          total: Duration(seconds: 5),
        ),
      );
      addTearDown(() async {
        downloader.close();
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      });
      await expectLater(
        downloader.download(blobId: 'fixture', size: 4),
        throwsA(isA<ModelTransportException>()),
      ).timeout(const Duration(seconds: 7));
      expect(sockets, hasLength(2));
      await Future.wait(
        closed.map((done) => done.future),
      ).timeout(const Duration(seconds: 2));
    });
  }

  test(
    'close during a TLS handshake reaps the worker and closes its peer',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>(), ended = Completer<void>();
      Socket? active;
      server.listen((socket) {
        active = socket;
        entered.complete();
        socket.listen(
          (_) {},
          onDone: () {
            socket.destroy();
            ended.complete();
          },
          onError: (Object _) {
            socket.destroy();
            if (!ended.isCompleted) ended.complete();
          },
        );
      });
      final downloader = ModelBlobDownloader(
        apiKey: 'private-handshake-canary',
        parallelCount: 1,
        origin: Uri.parse('https://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        downloader.close();
        active?.destroy();
        await server.close();
      });
      final pending = downloader.download(blobId: 'fixture', size: 4);
      final failed = expectLater(pending, throwsStateError);
      await entered.future.timeout(const Duration(seconds: 5));
      downloader.close();
      await failed.timeout(const Duration(seconds: 3));
      await ended.future.timeout(const Duration(seconds: 2));
    },
  );

  test('attempt deadline closes a continuously progressing response', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final ended = Completer<void>();
    final timers = <Timer>[];
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      var replied = false;
      Timer? timer;
      socket.listen(
        (_) {
          if (replied) return;
          replied = true;
          socket.add(
            ascii.encode(
              'HTTP/1.1 206 Partial Content\r\nContent-Length: 10000\r\nConnection: close\r\n\r\n',
            ),
          );
          timer = Timer.periodic(
            const Duration(milliseconds: 30),
            (_) => socket.add([1]),
          );
          timers.add(timer!);
        },
        onDone: () {
          timer?.cancel();
          socket.destroy();
          ended.complete();
        },
        onError: (Object _) {
          timer?.cancel();
          socket.destroy();
          if (!ended.isCompleted) ended.complete();
        },
      );
    });
    final downloader = ModelBlobDownloader(
      apiKey: 'local',
      parallelCount: 1,
      origin: Uri.parse('http://127.0.0.1:${server.port}'),
      retryPolicy: ModelDownloadRetryPolicy(
        maxAttempts: 1,
        delay: (_) => Duration.zero,
      ),
      deadlines: const ModelTransportDeadlines(
        bodyIdle: Duration(seconds: 1),
        attempt: Duration(milliseconds: 250),
        total: Duration(seconds: 5),
      ),
    );
    addTearDown(() async {
      downloader.close();
      for (final t in timers) {
        t.cancel();
      }
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    await expectLater(
      downloader.download(blobId: 'fixture', size: 10000),
      throwsA(isA<ModelTransportException>()),
    ).timeout(const Duration(seconds: 7));
    expect(sockets, hasLength(1));
    await ended.future.timeout(const Duration(seconds: 2));
  });

  test(
    'total budget bounds retry delay after the failed request is aborted',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response.statusCode = 503;
        unawaited(request.response.close());
      });
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final downloader = ModelBlobDownloader(
        client: client,
        apiKey: 'local',
        parallelCount: 1,
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: 5,
          delay: (_) => const Duration(seconds: 30),
        ),
        deadlines: const ModelTransportDeadlines(
          total: Duration(milliseconds: 250),
        ),
      );
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
      });
      await expectLater(
        downloader.download(blobId: 'fixture', size: 4),
        throwsA(isA<ModelTransportException>()),
      ).timeout(const Duration(seconds: 3));
      expect(requests, 1);
    },
  );

  test(
    'invalid transport concurrency and retry budgets are refused before requests',
    () {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      expect(
        () => ModelBlobDownloader(
          apiKey: 'local',
          parallelCount: 0,
          client: client,
        ),
        throwsArgumentError,
      );
      expect(
        () => ModelBlobDownloader(
          apiKey: 'local',
          client: client,
          retryPolicy: ModelDownloadRetryPolicy(
            maxAttempts: 0,
            delay: (_) => Duration.zero,
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'stream progress uses received bytes and close cancels an active body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>(), release = Completer<void>();
      final remaining = Completer<void>(), handlerDone = Completer<void>();
      server.listen((request) async {
        Socket? socket;
        try {
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=0-3');
          expect(request.uri.queryParameters['key'], 'private-fixture-only');
          entered.complete();
          await release.future;
          socket = await request.response.detachSocket(writeHeaders: false);
          socket.add(
            ascii.encode(
              'HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n\r\n',
            ),
          );
          socket.add([1, 2]);
          await socket.flush();
          // The remainder cannot coalesce with this chunk: only the test's
          // observed-progress/cancellation barrier releases it.
          await remaining.future;
          socket.add([3, 4]);
          await socket.flush();
        } on IOException {
          // Cancellation owns this response; writing its tail may fail.
        } finally {
          socket?.destroy();
          handlerDone.complete();
        }
      });
      final downloader = ModelBlobDownloader(
        apiKey: 'private-fixture-only',
        parallelCount: 1,
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        downloader.close();
        if (!release.isCompleted) release.complete();
        if (!remaining.isCompleted) remaining.complete();
        await server.close(force: true);
        if (entered.isCompleted) await handlerDone.future;
      });
      final progress = <(int, int)>[];
      final observed = Completer<void>();
      final pending = downloader.download(
        blobId: '/fixture',
        size: 4,
        onProgress: (n, total) {
          progress.add((n, total));
          downloader.close();
          if (!observed.isCompleted) observed.complete();
        },
      );
      final rejected = expectLater(pending, throwsStateError);
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      release.complete();
      await observed.future;
      downloader.close();
      downloader.close();
      remaining.complete();
      await handlerDone.future;
      await server.close(force: true);
      await rejected;
      expect(progress, hasLength(1));
      expect(progress.single.$1, inInclusiveRange(1, 2));
      expect(progress.single.$2, 4);
      await expectLater(
        downloader.download(blobId: '/fixture', size: 4),
        throwsStateError,
      );
    },
  );
}
