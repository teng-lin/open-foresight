import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/web_content.dart';
import 'package:foresight_core/src/web_search.dart';
import 'package:foresight_core/src/generated/web_content.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import '../tool/verify_cloud_services.dart';

class CloudPeer extends ForesightServiceBase {
  bool failSummary = false;
  int advertisedSize = dedicatedQueryModelBytes;
  int metadataCalls = 0;
  @override
  Future<ForesightSharedConfig> getSharedConfig(
    ServiceCall call,
    GetSharedConfigRequest request,
  ) async {
    metadataCalls++;
    expect(call.clientMetadata?['x-goog-api-key'], 'fixture-private');
    expect(request.appVersion, '1.0.0');
    expect(request.platform, 'macos');
    expect(request.fallbackMode, referenceClosestLowerFallback);
    return ForesightSharedConfig(
      onDeviceModelMetadatas: [
        OnDeviceModelMetadata(
          modelType: referenceQueryDetectorModelType,
          blobId: 'folder/query.bin',
          size: Int64(advertisedSize),
        ),
      ],
    );
  }

  @override
  Future<FetchExternalWebsiteResponse> fetchExternalWebsite(
    ServiceCall call,
    FetchExternalWebsiteRequest request,
  ) async {
    expect(call.clientMetadata?['x-goog-api-key'], 'fixture-private');
    expect(request.url, 'https://example.com/');
    expect(request.modelId, referenceWebSummaryModel);
    expect(request.maxSummarizationWords, 100);
    if (failSummary) throw GrpcError.unavailable('fixture-private');
    return FetchExternalWebsiteResponse(summary: 'Synthetic public summary');
  }
}

void main() {
  test(
    'missing distribution configuration blocks before creating clients',
    () async {
      Never unexpected(String _) =>
          throw StateError('must not create a client');
      final result = await verifyCloudServices(
        endpointMode: 'controlled',
        downloadQuery: true,
        configuration: {},
        searchFactory: unexpected,
        webFactory: unexpected,
        configFactory: unexpected,
        blobFactory: unexpected,
      );
      expect(result.code, 2);
      expect(result.report['status'], 'blocked');
      expect((result.report['query_blob'] as Map)['status'], 'blocked');
    },
  );

  test(
    'CLI redacts malformed runtime configuration and rejects unknown flags',
    () async {
      final resources = createTestTempDirectorySync('of-cloud-config-');
      final environment = Map<String, String>.from(Platform.environment)
        ..remove('FORESIGHT_SEARCH_API_KEY')
        ..remove('FORESIGHT_WEB_CONTENT_API_KEY')
        ..['FORESIGHT_RESOURCES'] = resources.path;
      try {
        File('${resources.path}/runtime.json').writeAsStringSync(
          '{"FORESIGHT_SEARCH_API_KEY":"fixture-private", "broken":',
        );
        final malformed = await Process.run(Platform.resolvedExecutable, [
          'run',
          'tool/verify_cloud_services.dart',
        ], environment: environment);
        expect(malformed.exitCode, 1);
        expect(
          jsonDecode(malformed.stdout.toString())['error_type'],
          'FormatException',
        );
        expect(
          '${malformed.stdout}${malformed.stderr}',
          isNot(contains('fixture-private')),
        );
        final invalid = await Process.run(Platform.resolvedExecutable, [
          'run',
          'tool/verify_cloud_services.dart',
          '--unknown',
        ], environment: environment);
        expect(invalid.exitCode, 64);
        expect(invalid.stdout, isEmpty);
      } finally {
        resources.deleteSync(recursive: true);
      }
    },
  );

  group('controlled transport acceptance', () {
    late CloudPeer peer;
    late Server grpc;
    late ClientChannel channel;
    late HttpServer http;
    var failSearch = false;
    setUp(() async {
      peer = CloudPeer();
      grpc = Server.create(services: [peer]);
      await grpc.serve(address: InternetAddress.loopbackIPv4, port: 0);
      channel = ClientChannel(
        '127.0.0.1',
        port: grpc.port!,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      failSearch = false;
      http.listen((request) async {
        expect(request.uri.queryParameters['key'], 'fixture-private');
        expect(request.uri.queryParameters['q'], 'IANA example domains');
        if (failSearch) {
          request.response.statusCode = 403;
          request.response.write('fixture-private');
        } else {
          request.response.write(
            jsonEncode({
              'items': [
                {'title': 'fixture-private', 'link': 'https://example.com/'},
              ],
            }),
          );
        }
        await request.response.close();
      });
    });
    setUp(() {
      addTearDown(() async {
        await channel.shutdown();
        await grpc.shutdown();
        await http.close(force: true);
      });
    });
    Future<({Map<String, Object?> report, int code})> run({
      bool download = false,
    }) => verifyCloudServices(
      endpointMode: 'controlled',
      downloadQuery: download,
      configuration: {
        'FORESIGHT_SEARCH_API_KEY': 'fixture-private',
        'FORESIGHT_WEB_CONTENT_API_KEY': 'fixture-private',
      },
      searchFactory: (key) => SearchService(
        apiKey: key,
        endpoint: Uri.parse('http://127.0.0.1:${http.port}/search'),
      ),
      webFactory: (key) => WebContentService(apiKey: key, channel: channel),
      configFactory: (key) => ModelConfigService(apiKey: key, channel: channel),
      blobFactory: (_) =>
          throw StateError('must not download an incompatible model'),
    );
    test(
      'search, summary and metadata pass using actual controlled clients',
      () async {
        final result = await run();
        expect(result.code, 0);
        expect(result.report['status'], 'passed');
        expect((result.report['search'] as Map)['result_count'], 1);
        expect((result.report['query_blob'] as Map)['status'], 'not_requested');
        expect(jsonEncode(result.report), isNot(contains('fixture-private')));
      },
    );
    test(
      'reports safe classifications and continues after independent failures',
      () async {
        failSearch = true;
        peer.failSummary = true;
        final result = await run();
        expect(result.code, 1);
        expect((result.report['search'] as Map)['http_status'], 403);
        expect(
          (result.report['website_summary'] as Map)['grpc_code'],
          StatusCode.unavailable,
        );
        expect((result.report['model_metadata'] as Map)['status'], 'passed');
        expect(peer.metadataCalls, 1);
        expect(jsonEncode(result.report), isNot(contains('fixture-private')));
      },
    );
    test(
      'incompatible advertised size blocks blob allocation and transport',
      () async {
        peer.advertisedSize = 1;
        final result = await run(download: true);
        expect(result.code, 1);
        expect((result.report['model_metadata'] as Map)['status'], 'failed');
        expect((result.report['query_blob'] as Map)['status'], 'blocked');
      },
    );
  });
}
