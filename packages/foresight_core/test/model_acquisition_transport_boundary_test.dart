import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/model_acquisition.dart';
import 'package:test/test.dart';

void main() {
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
