import 'dart:async';
import 'dart:io';
import 'package:foresight_core/src/generated/web_content.pbgrpc.dart';
import 'package:foresight_core/src/web_content.dart';
import 'package:foresight_core/src/web_search.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

List<int> hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

class Fixture extends ForesightServiceBase {
  final requests = <FetchExternalWebsiteRequest>[];
  final credentials = <String?>[];
  late Future<FetchExternalWebsiteResponse> Function(
    FetchExternalWebsiteRequest,
  )
  respond;
  @override
  Future<FetchExternalWebsiteResponse> fetchExternalWebsite(
    ServiceCall call,
    FetchExternalWebsiteRequest request,
  ) {
    requests.add(request);
    credentials.add(call.clientMetadata?['x-goog-api-key']);
    return respond(request);
  }
}

void main() {
  test(
    'recovered tags, signed int32, defaults and explicit false match fixed wire bytes',
    () {
      final request = FetchExternalWebsiteRequest(
        url: 'u',
        useTrawler: false,
        summarizeContent: true,
        maxSummarizationWords: 100,
        modelId: 'm',
        summaryTimeoutMillis: -1,
        maxInputTokens: 131072,
      );
      expect(
        request.writeToBuffer(),
        hex('0a017510002001286432016d40ffffffffffffffffff0148808008'),
      );
      final defaults = FetchExternalWebsiteRequest();
      expect(defaults.maxSummarizationWords, 100);
      expect(defaults.hasMaxSummarizationWords(), isFalse);
      expect(defaults.writeToBuffer(), isEmpty);
      final response = FetchExternalWebsiteResponse.fromBuffer(
        hex('1201741a01632a016d3a017341000000000000e83f'),
      );
      expect(response.title, 't');
      expect(response.content, 'c');
      expect(response.mimeType, 'm');
      expect(response.summary, 's');
      expect(response.summaryConfidenceScore, .75);
    },
  );

  group('loopback gRPC', () {
    late Fixture fixture;
    late Server server;
    late ClientChannel channel;
    late WebContentService service;
    setUp(() async {
      fixture = Fixture();
      server = Server.create(services: [fixture]);
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      channel = ClientChannel(
        '127.0.0.1',
        port: server.port!,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      service = WebContentService(apiKey: 'release-fixture', channel: channel);
    });
    tearDown(() async {
      await service.close();
      await channel.terminate();
      await server.shutdown();
    });

    test(
      'default sends one 100-word request with recovered model and limits',
      () async {
        fixture.respond = (_) async => FetchExternalWebsiteResponse(
          title: 'Title',
          summary: '摘要 café',
          content: 'raw\t中文 café',
          mimeType: 'application/json',
          summaryConfidenceScore: .8,
        );
        final result = await service.summarizeWebContent(
          'https://example.org',
          100,
        );
        expect(fixture.requests, hasLength(1));
        final request = fixture.requests.single;
        expect(request.url, 'https://example.org');
        expect(request.useTrawler, isFalse);
        expect(request.hasUseTrawler(), isTrue);
        expect(request.summarizeContent, isTrue);
        expect(request.maxSummarizationWords, 100);
        expect(request.modelId, 'models/odml-gemini-v4p1xs-supernova-one-shot');
        expect(request.summaryTimeoutMillis, -1);
        expect(request.maxInputTokens, 131072);
        expect(fixture.credentials, ['release-fixture']);
        expect(result.title, 'Title');
        expect(result.summary, '摘要 café');
        expect(result.content, 'raw caf');
      },
    );

    test(
      'ASCII content, HTML MIME and first-60-character title fallback',
      () async {
        fixture.respond = (_) async => FetchExternalWebsiteResponse(
          content: '${'x' * 65}中文',
          summary: 'Summary',
        );
        final response = await service.fetchWebContent(
          'url',
          maxWords: 42,
          summaryTimeoutMillis: 123,
        );
        expect(response!.mimeType, 'text/html');
        expect(response.content, 'x' * 65);
        expect(response.title, 'x' * 60);
        expect(fixture.requests.single.maxSummarizationWords, 42);
        expect(fixture.requests.single.summaryTimeoutMillis, 123);
        fixture.respond = (_) async =>
            FetchExternalWebsiteResponse(content: 'short');
        expect((await service.fetchWebContent('url'))!.title, 'short');
      },
    );

    test('empty URL makes no request and yields empty summary', () async {
      expect(await service.fetchWebContent(''), isNull);
      final result = await service.summarizeWebContent('', 100);
      expect(result.summary, '');
      expect(result.title, '');
      expect(result.content, '');
      expect(fixture.requests, isEmpty);
    });

    test(
      'ranking runs concurrently and resolves equal scores by input order',
      () async {
        final pending = <Completer<FetchExternalWebsiteResponse>>[];
        final started = Completer<void>();
        fixture.respond = (_) {
          final c = Completer<FetchExternalWebsiteResponse>();
          pending.add(c);
          if (pending.length == 3) started.complete();
          return c.future;
        };
        final result = service.summarizeWebContent(
          'url',
          100,
          enableCandidateRanking: true,
        );
        await started.future;
        pending[2].complete(
          FetchExternalWebsiteResponse(
            summary: 'last-ranked',
            summaryConfidenceScore: .9,
          ),
        );
        pending[1].complete(
          FetchExternalWebsiteResponse(
            summary: 'lower',
            summaryConfidenceScore: .5,
          ),
        );
        pending[0].complete(
          FetchExternalWebsiteResponse(
            summary: 'first-ranked',
            summaryConfidenceScore: .9,
          ),
        );
        expect((await result).summary, 'last-ranked');
        expect(fixture.requests, hasLength(3));
      },
    );

    test(
      'fetch failure propagates directly but becomes snippet fallback through summary',
      () async {
        fixture.respond = (_) async => throw GrpcError.unavailable('offline');
        await expectLater(
          service.fetchWebContent('url'),
          throwsA(isA<GrpcError>()),
        );
        final callbacks = SearchCallbacks(
          search: (_) async => [
            const WebSearchItem(
              title: 'Title',
              link: 'url',
              snippet: 'Snippet',
            ),
          ],
          summarize: service.summarizeSearchPage,
        );
        final result = await callbacks.handleGoogleSearch({'query': 'q'});
        expect(result.results, ['title: Title\nsnippet: Snippet']);
        expect(
          formatSearchToolResult(result),
          '[Source:1] title: Title\nsnippet: Snippet\n\n',
        );
      },
    );

    test('ranking skips failed fetch and score below minus one', () async {
      var index = 0;
      fixture.respond = (_) async {
        switch (index++) {
          case 0:
            throw GrpcError.unavailable('offline');
          case 1:
            return FetchExternalWebsiteResponse(
              summary: 'invalid',
              summaryConfidenceScore: -2,
            );
          default:
            return FetchExternalWebsiteResponse(
              summary: 'boundary',
              summaryConfidenceScore: -1,
            );
        }
      };
      expect(
        (await service.summarizeWebContent(
          'url',
          100,
          enableCandidateRanking: true,
        )).summary,
        'boundary',
      );
    });

    test(
      'close rejects new operations without closing injected channel',
      () async {
        fixture.respond = (_) async =>
            FetchExternalWebsiteResponse(summary: 'open');
        await service.close();
        await service.close();
        await expectLater(service.fetchWebContent('url'), throwsStateError);
        await expectLater(
          service.summarizeWebContent('url', 100),
          throwsStateError,
        );
        expect(
          (await ForesightServiceClient(channel).fetchExternalWebsite(
            FetchExternalWebsiteRequest(url: 'url'),
          )).summary,
          'open',
        );
      },
    );
  });
}
