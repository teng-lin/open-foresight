import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/gemma_download.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/platform_services.dart'
    show runtimeConfiguration;
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/capture_process.dart';
import 'package:test/test.dart';

// A peer deliberately aborting a progressing response may fail the output sink
// as well as end the input stream. Observe only that expected network failure;
// programming errors still fail the fixture rather than becoming stray futures.
void _observeSocketOutput(Socket socket) {
  unawaited(
    socket.done.then<void>(
      (_) {},
      onError: (Object error) {
        expect(error, isA<SocketException>());
      },
    ),
  );
}

// Hold the caller after the real response future exists, before its deadline
// wrapper can install an observer. This models a descheduled isolate without
// depending on a loopback connection happening inside a narrow wall budget.
class _PreparedRequestClient implements HttpClient {
  _PreparedRequestClient(this.inner, {this.closeStall = Duration.zero});
  final HttpClient inner;
  final Duration closeStall;
  HttpClientRequest? _prepared;
  var closeCalls = 0;

  Future<void> prepare(Uri uri) async => _prepared = await inner.getUrl(uri);

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    final request = _prepared;
    if (request == null || request.uri != url) {
      throw StateError('Expected the one pre-established fixture request');
    }
    _prepared = null;
    return Future.value(
      _HeldCloseRequest(request, closeStall, () => closeCalls++),
    );
  }

  @override
  void close({bool force = false}) {
    // A request not transferred to the downloader still belongs to this owner.
    _prepared?.abort();
    _prepared?.close().ignore();
    _prepared = null;
    inner.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _HeldCloseRequest implements HttpClientRequest {
  _HeldCloseRequest(this.inner, this.closeStall, this.onClose);
  final HttpClientRequest inner;
  final Duration closeStall;
  final void Function() onClose;

  @override
  HttpHeaders get headers => inner.headers;
  @override
  Future<HttpClientResponse> close() {
    final response = inner.close();
    onClose();
    if (closeStall > Duration.zero) sleep(closeStall);
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      inner.abort(exception, stackTrace);
  @override
  Future<HttpClientResponse> get done => inner.done;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late String transportService;
  setUpAll(() async {
    final compiled = createTestTempDirectorySync('transport-deadline-aot-');
    transportService = '${compiled.path}/service';
    final result = await runCaptureProcess(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/service.dart',
      '-o',
      transportService,
    ], timeout: const Duration(seconds: 90));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  setUp(() {
    final saved = Map.of(runtimeConfiguration.environment);
    addTearDown(
      () => runtimeConfiguration.environment
        ..clear()
        ..addAll(saved),
    );
    // Exercise the real production early worker. Compilation belongs to fixture
    // setup; the unchanged transport budgets still include OS process startup.
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = transportService;
  });
  test(
    'public file worker returns a verified cache path without buffering the asset',
    () async {
      final root = createTestTempDirectorySync('public-model-worker-');
      final bytes = List<int>.generate(1024 * 1024, (i) => i % 251);
      final existing = File('${root.path}/registered.bin')
        ..writeAsBytesSync(bytes);
      final model = GemmaModel(
        'fixture',
        'fixture/model',
        'revision',
        'fixture.bin',
        sha256.convert(bytes).toString(),
        bytes.length,
        0,
      );
      final phases = <ModelDownloadPhase>[];
      final progress = <(int, int)>[];
      final downloader = PublicModelFileDownloader();
      addTearDown(downloader.cancel);
      final result = await downloader.download(
        model,
        Directory('${root.path}/cache'),
        existingFile: existing,
        phase: phases.add,
        progress: (n, total) => progress.add((n, total)),
      );
      expect(result.path, existing.path);
      expect(result.readAsBytesSync(), bytes);
      expect(phases, [
        ModelDownloadPhase.checkingCache,
        ModelDownloadPhase.verifyingCache,
      ]);
      expect(progress.last, (bytes.length, bytes.length));
      expect(Directory('${root.path}/cache').existsSync(), isFalse);
    },
  );

  test('public file cancellation reaps a stalled TLS producer', () async {
    final root = createTestTempDirectorySync('public-model-cancel-');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>(), closed = Completer<void>();
    Socket? peer;
    final subscription = server.listen((socket) {
      peer = socket;
      socket.listen(
        (_) {},
        onDone: () {
          socket.destroy();
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          socket.destroy();
          if (!closed.isCompleted) closed.complete();
        },
      );
      if (!accepted.isCompleted) accepted.complete();
    });
    final downloader = PublicModelFileDownloader();
    addTearDown(() async {
      downloader.cancel();
      peer?.destroy();
      await subscription.cancel();
      await server.close();
    });
    final model = GemmaModel(
      'fixture',
      'fixture/model',
      'revision',
      'fixture.bin',
      sha256.convert([1, 2, 3, 4]).toString(),
      4,
      0,
    );
    final work = downloader.download(
      model,
      root,
      sourceForTesting: Uri.parse('https://127.0.0.1:${server.port}/fixture'),
    );
    final rejected = expectLater(work, throwsA(isA<ModelDownloadCancelled>()));
    await accepted.future.timeout(const Duration(seconds: 5));
    downloader.cancel();
    await rejected.timeout(const Duration(seconds: 3));
    await closed.future.timeout(const Duration(seconds: 2));
    expect(
      File('${root.path}/${model.directory}/${model.filename}').existsSync(),
      isFalse,
    );
  });

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
        _observeSocketOutput(socket);
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
            if (!done.isCompleted) done.complete();
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
        throwsA(
          phase == 'connect'
              ? isA<ModelTransportException>().having(
                  (error) => error.failureType,
                  'connect retries exhausted',
                  'connect_timeout',
                )
              : isA<ModelTransportException>(),
        ),
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
      // Keep actual source/JIT fallback coverage as well as the compiled worker.
      runtimeConfiguration.environment.remove('FORESIGHT_SERVICE');
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>(), ended = Completer<void>();
      Socket? active;
      server.listen((socket) {
        active = socket;
        _observeSocketOutput(socket);
        entered.complete();
        socket.listen(
          (_) {},
          onDone: () {
            socket.destroy();
            if (!ended.isCompleted) ended.complete();
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
      _observeSocketOutput(socket);
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
          if (!ended.isCompleted) ended.complete();
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
    'source worker total budget includes JIT startup and retires every accepted peer',
    () async {
      runtimeConfiguration.environment.remove('FORESIGHT_SERVICE');
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final closed = <Completer<void>>[];
      server.listen((socket) {
        sockets.add(socket);
        _observeSocketOutput(socket);
        final done = Completer<void>();
        closed.add(done);
        void finish() {
          socket.destroy();
          if (!done.isCompleted) done.complete();
        }

        socket.listen((_) {}, onDone: finish, onError: (Object _) => finish());
      });
      final downloader = ModelBlobDownloader(
        apiKey: 'source-budget-canary',
        parallelCount: 1,
        origin: Uri.parse('https://127.0.0.1:${server.port}'),
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: 2,
          delay: (_) => Duration.zero,
        ),
        deadlines: const ModelTransportDeadlines(
          connect: Duration(milliseconds: 150),
          attempt: Duration(seconds: 1),
          total: Duration(milliseconds: 250),
        ),
      );
      addTearDown(() async {
        downloader.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      await expectLater(
        downloader.download(blobId: 'fixture', size: 4),
        throwsA(
          isA<ModelTransportException>().having(
            (error) => error.failureType,
            'finite source/JIT total',
            'total_timeout',
          ),
        ),
      ).timeout(const Duration(seconds: 3));
      await Future.wait(
        closed.map((done) => done.future),
      ).timeout(const Duration(seconds: 2));
      final retiredCount = sockets.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        sockets,
        hasLength(retiredCount),
        reason: 'a reaped source worker cannot connect later',
      );
    },
  );

  test(
    'expired deadline observes the response future before aborting its request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.statusCode = 503;
        // Client cancellation can also fail the server's response sink. Its
        // expected network error must not masquerade as the client-side leak.
        unawaited(
          request.response.close().then<void>(
            (_) {},
            onError: (Object error) {
              expect(
                error,
                anyOf(isA<HttpException>(), isA<SocketException>()),
              );
            },
          ),
        );
      });
      final client = _PreparedRequestClient(
        HttpClient(),
        closeStall: const Duration(milliseconds: 300),
      );
      final downloader = ModelBlobDownloader(
        client: client,
        apiKey: 'local',
        parallelCount: 1,
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        deadlines: const ModelTransportDeadlines(
          total: Duration(milliseconds: 250),
        ),
      );
      addTearDown(() async {
        downloader.close();
        client.close(force: true);
        await server.close(force: true);
      });
      final settled = Completer<Object?>();
      final unhandled = <Object>[];
      unawaited(
        runZonedGuarded(() async {
          try {
            await client
                .prepare(downloader.downloadUri('fixture'))
                .timeout(const Duration(seconds: 3));
            await downloader.download(blobId: 'fixture', size: 4);
            settled.complete(null);
          } catch (error) {
            settled.complete(error);
          }
        }, (error, _) => unhandled.add(error)),
      );
      expect(
        await settled.future.timeout(const Duration(seconds: 3)),
        isA<ModelTransportException>(),
      );
      expect(client.closeCalls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(unhandled, isEmpty);
    },
  );
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
