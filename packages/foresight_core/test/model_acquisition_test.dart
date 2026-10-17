import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/generated/web_content.pbgrpc.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class ConfigFixture extends ForesightServiceBase {
  GetSharedConfigRequest? request;
  String? key;
  Completer<ForesightSharedConfig>? pending;
  Completer<void>? started;
  @override
  Future<ForesightSharedConfig> getSharedConfig(
    ServiceCall call,
    GetSharedConfigRequest request,
  ) async {
    this.request = request;
    key = call.clientMetadata?['x-goog-api-key'];
    if (pending != null) {
      started?.complete();
      return pending!.future;
    }
    return ForesightSharedConfig(
      onDeviceModelMetadatas: [
        OnDeviceModelMetadata(
          modelType: 4,
          name: 'detector',
          version: 'fixture',
          blobId: '/fixture/model',
          size: Int64(179437568),
        ),
      ],
    );
  }

  @override
  Future<FetchExternalWebsiteResponse> fetchExternalWebsite(
    ServiceCall call,
    FetchExternalWebsiteRequest request,
  ) async => throw GrpcError.unimplemented();
}

class FailingUriClient implements HttpClient {
  var attempts = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    attempts++;
    throw HttpException('Failed URL: $url', uri: url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixedRandom implements Random {
  FixedRandom(this.value);
  final double value;
  var calls = 0;
  @override
  double nextDouble() {
    calls++;
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TrackedChannel extends ClientChannel {
  TrackedChannel(int port)
    : super(
        '127.0.0.1',
        port: port,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
  var shutdowns = 0;
  @override
  Future<void> shutdown() {
    shutdowns++;
    return super.shutdown();
  }
}

void main() {
  test(
    'metadata close cancels its active RPC without closing an injected channel',
    () async {
      final fixture = ConfigFixture()
        ..pending = Completer()
        ..started = Completer();
      final server = Server.create(services: [fixture]);
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final channel = TrackedChannel(server.port!);
      final service = ModelConfigService(apiKey: 'fixture', channel: channel);
      try {
        final pending = service.fetch(appVersion: '1.0.0');
        final cancelled = expectLater(
          pending,
          throwsA(
            isA<GrpcError>().having(
              (e) => e.code,
              'code',
              StatusCode.cancelled,
            ),
          ),
        );
        await fixture.started!.future;
        await service.close();
        await cancelled;
        expect(channel.shutdowns, 0);
      } finally {
        await channel.shutdown();
        await server.shutdown();
      }
    },
  );
  test(
    'original parallelism uses the 800 MiB ceiling with one-to-eight clamp',
    () {
      const slot = 838860800;
      expect(referenceModelDownloadParallelCount(1), 1);
      expect(referenceModelDownloadParallelCount(slot), 1);
      expect(referenceModelDownloadParallelCount(slot + 1), 2);
      expect(referenceModelDownloadParallelCount(7 * slot), 7);
      expect(referenceModelDownloadParallelCount(8 * slot), 8);
      expect(referenceModelDownloadParallelCount(9 * slot), 8);
      expect(referenceModelDownloadParallelCount(179437568), 1);
    },
  );

  test(
    'download plan uses last duplicate and basename without version ordering',
    () {
      final first = OnDeviceModelMetadata(
        modelType: 4,
        version: '9',
        blobId: '/old/model.bin',
      );
      final other = OnDeviceModelMetadata(modelType: 2, blobId: '/other.bin');
      final last = OnDeviceModelMetadata(
        modelType: 4,
        version: '1',
        blobId: '/remote/version/detector.bin/',
      );
      final plan = referenceModelDownloadPlan([first, other, last], 4)!;
      expect(plan.metadata, same(last));
      expect(plan.blobName, 'detector.bin');
      expect(referenceModelDownloadPlan([first, other], 99), isNull);
    },
  );

  test(
    'original retry durations preserve attempt limit, jitter, rounding and cap',
    () {
      final source = FixedRandom(0);
      final lower = ModelDownloadRetryPolicy.reference(random: source);
      expect(lower.maxAttempts, 5);
      expect(lower.delay(0), Duration.zero);
      expect(lower.delay(-1), Duration.zero);
      expect(source.calls, 0);
      expect(lower.delay(1), const Duration(milliseconds: 750));
      expect(lower.delay(4), const Duration(seconds: 6));
      final middle = ModelDownloadRetryPolicy.reference(
        random: FixedRandom(.5),
      );
      expect(middle.delay(1), const Duration(seconds: 1));
      expect(middle.delay(4), const Duration(seconds: 8));
      expect(middle.delay(31), const Duration(seconds: 10));
      expect(middle.delay(1000), const Duration(seconds: 10));
      final rounded = ModelDownloadRetryPolicy.reference(
        random: FixedRandom(.1234567),
      );
      expect(rounded.delay(1), const Duration(microseconds: 811728));
      expect(rounded.delay(2), const Duration(microseconds: 1623457));
      final upper = ModelDownloadRetryPolicy.reference(
        random: FixedRandom(.999998),
      );
      expect(upper.delay(1), const Duration(microseconds: 1249999));
      expect(upper.delay(5), const Duration(seconds: 10));
    },
  );
  test('OdmlService normalization removes exactly one leading blob slash', () {
    final downloader = ModelBlobDownloader(
      apiKey: 'fixture',
      parallelCount: 1,
      retryPolicy: ModelDownloadRetryPolicy(
        maxAttempts: 1,
        delay: (_) => Duration.zero,
      ),
    );
    try {
      expect(
        downloader.downloadUri('/fixture/model').path,
        '/v1/medias/foresight/fixture/model:download',
      );
      expect(
        downloader.downloadUri('//fixture/model').path,
        '/v1/medias/foresight//fixture/model:download',
      );
    } finally {
      downloader.close();
    }
  });
  test(
    'final transport errors omit authenticated URI after retry classification',
    () async {
      final client = FailingUriClient();
      final downloader = ModelBlobDownloader(
        apiKey: 'private fixture&秘密',
        parallelCount: 1,
        client: client,
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: 3,
          delay: (_) => Duration.zero,
        ),
        sleep: (_) async {},
      );
      try {
        await downloader.download(blobId: '/fixture/model', size: 1);
        fail('Expected transport failure');
      } on ModelTransportException catch (error) {
        expect(client.attempts, 3);
        expect(error.failureType, 'HttpException');
        expect(error.toString(), isNot(contains('private')));
        expect(error.toString(), isNot(contains('key=')));
        expect(error.toString(), isNot(contains('odml.pa.googleapis.com')));
        expect(error.toString(), isNot(contains('%')));
      } finally {
        downloader.close();
      }
    },
  );

  test('public metadata tags decode independently constructed wire bytes', () {
    final metadata = OnDeviceModelMetadata.fromBuffer([
      8,
      4,
      18,
      1,
      110,
      26,
      1,
      118,
      50,
      1,
      98,
      64,
      128,
      128,
      128,
      128,
      16,
    ]);
    expect(metadata.modelType, referenceQueryDetectorModelType);
    expect(metadata.name, 'n');
    expect(metadata.version, 'v');
    expect(metadata.blobId, 'b');
    expect(metadata.size, Int64(4294967296));
    expect(
      GetSharedConfigRequest(
        appVersion: '1',
        platform: 'macos',
        fallbackMode: 1,
      ).writeToBuffer(),
      [10, 1, 49, 18, 5, 109, 97, 99, 111, 115, 24, 1],
    );
  });

  test(
    'loopback RPC sends shared distribution credential and exact platform',
    () async {
      final fixture = ConfigFixture();
      final server = Server.create(services: [fixture]);
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final channel = ClientChannel(
        '127.0.0.1',
        port: server.port!,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      final service = ModelConfigService(
        apiKey: 'distribution-fixture',
        channel: channel,
      );
      try {
        final config = await service.fetch(appVersion: '1.0.0');
        expect(fixture.request!.appVersion, '1.0.0');
        expect(fixture.request!.platform, 'macos');
        expect(fixture.request!.fallbackMode, 1);
        expect(fixture.key, 'distribution-fixture');
        expect(config.onDeviceModelMetadatas.single.modelType, 4);
        await service.close();
        expect(() => service.fetch(appVersion: '1.0.0'), throwsStateError);
        // Injected channel remains owned by its caller.
        expect(
          (await ForesightServiceClient(
            channel,
          ).getSharedConfig(GetSharedConfigRequest())).onDeviceModelMetadatas,
          hasLength(1),
        );
      } finally {
        await service.close();
        await channel.terminate();
        await server.shutdown();
      }
    },
  );

  group('loopback range transport', () {
    late HttpServer server;
    late ModelBlobDownloader downloader;
    late List<String> ranges;
    late List<Duration> waits;
    late Future<void> Function(HttpRequest) respond;
    setUp(() async {
      ranges = [];
      waits = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader)!);
        expect(request.uri.path, '/v1/medias/foresight/fixture/model:download');
        expect(request.uri.queryParameters, {
          'alt': 'media',
          'key': 'distribution-fixture',
        });
        await respond(request);
      });
      downloader = ModelBlobDownloader(
        apiKey: 'distribution-fixture',
        parallelCount: 3,
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: 3,
          delay: (attempt) => Duration(milliseconds: attempt),
        ),
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        sleep: (duration) async {
          waits.add(duration);
        },
      );
    });
    tearDown(() async {
      downloader.close();
      await server.close(force: true);
    });

    test(
      'inclusive partitions start concurrently and preserve byte ordering',
      () async {
        final allStarted = Completer<void>();
        respond = (request) async {
          if (ranges.length == 3) allStarted.complete();
          await allStarted.future;
          final parts = request.headers
              .value(HttpHeaders.rangeHeader)!
              .substring(6)
              .split('-')
              .map(int.parse)
              .toList();
          request.response.statusCode = 206;
          request.response.add([for (var i = parts[0]; i <= parts[1]; i++) i]);
          await request.response.close();
        };
        expect(await downloader.download(blobId: '/fixture/model', size: 8), [
          0,
          1,
          2,
          3,
          4,
          5,
          6,
          7,
        ]);
        expect(ranges.toSet(), {'bytes=0-2', 'bytes=3-5', 'bytes=6-7'});
        expect(waits, isEmpty);
      },
    );

    test(
      'retryable status retries same cursor and skips surplus partitions',
      () async {
        respond = (request) async {
          if (ranges.length == 1) {
            request.response.statusCode = 503;
          } else {
            request.response.statusCode = 206;
            request.response.add([42]);
          }
          await request.response.close();
        };
        expect(await downloader.download(blobId: '/fixture/model', size: 1), [
          42,
        ]);
        expect(ranges, ['bytes=0-0', 'bytes=0-0']);
        expect(waits, [const Duration(milliseconds: 1)]);
      },
    );

    test('nonretryable HTTP status propagates without retry', () async {
      respond = (request) async {
        request.response.statusCode = 404;
        await request.response.close();
      };
      await expectLater(
        downloader.download(blobId: '/fixture/model', size: 1),
        throwsA(isA<NonRetryableModelDownloadException>()),
      );
      expect(ranges, hasLength(1));
      expect(waits, isEmpty);
    });

    test(
      '200 is rejected for split ranges even when server sends full object',
      () async {
        respond = (request) async {
          request.response.add([1, 2, 3]);
          await request.response.close();
        };
        await expectLater(
          downloader.download(blobId: '/fixture/model', size: 3),
          throwsA(isA<NonRetryableModelDownloadException>()),
        );
        expect(waits, isEmpty);
      },
    );

    test(
      'full-object 200 and observed short EOF preserve original semantics',
      () async {
        respond = (request) async {
          request.response.add([7]);
          await request.response.close();
        };
        expect(await downloader.download(blobId: '/fixture/model', size: 1), [
          7,
        ]);
        downloader.close();
        downloader = ModelBlobDownloader(
          apiKey: 'distribution-fixture',
          retryPolicy: ModelDownloadRetryPolicy(
            maxAttempts: 1,
            delay: (_) => Duration.zero,
          ),
          origin: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        expect(await downloader.download(blobId: '/fixture/model', size: 3), [
          7,
          0,
          0,
        ]);
        expect(ranges.last, 'bytes=0-2');
      },
    );

    test('interrupted body resumes at the successfully written cursor', () async {
      downloader.close();
      downloader = ModelBlobDownloader(
        apiKey: 'distribution-fixture',
        parallelCount: 1,
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: 3,
          delay: (_) => Duration.zero,
        ),
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      respond = (request) async {
        request.response.statusCode = 206;
        if (ranges.length == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.add(
            'HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nConnection: close\r\n\r\n'
                .codeUnits,
          );
          socket.add([0]);
          await socket.flush();
          socket.destroy();
        } else {
          request.response.add([1, 2]);
          await request.response.close();
        }
      };
      expect(await downloader.download(blobId: '/fixture/model', size: 3), [
        0,
        1,
        2,
      ]);
      expect(ranges, ['bytes=0-2', 'bytes=1-2']);
    });

    test(
      'close aborts its request while preserving an injected client',
      () async {
        downloader.close();
        final client = HttpClient();
        downloader = ModelBlobDownloader(
          apiKey: 'distribution-fixture',
          parallelCount: 1,
          retryPolicy: ModelDownloadRetryPolicy(
            maxAttempts: 3,
            delay: (_) => Duration.zero,
          ),
          client: client,
          origin: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final started = Completer<void>();
        respond = (request) async {
          started.complete();
        };
        final pending = downloader.download(blobId: '/fixture/model', size: 1);
        final failed = expectLater(pending, throwsA(anything));
        await started.future;
        downloader.close();
        await failed.timeout(const Duration(seconds: 2));
        respond = (request) async {
          request.response.add([42]);
          await request.response.close();
        };
        final request = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/v1/medias/foresight/fixture/model:download?alt=media&key=distribution-fixture',
          ),
        );
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        expect(
          await (await request.close()).expand((bytes) => bytes).toList(),
          [42],
        );
        client.close(force: true);
      },
    );

    test(
      'empty inputs never start transport and close rejects further downloads',
      () async {
        expect(await downloader.download(blobId: '', size: 2), isEmpty);
        expect(
          await downloader.download(blobId: 'fixture/model', size: 0),
          isEmpty,
        );
        expect(ranges, isEmpty);
        downloader.close();
        await expectLater(
          downloader.download(blobId: 'fixture/model', size: 1),
          throwsStateError,
        );
      },
    );
  });
}
