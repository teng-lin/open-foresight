import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Map<String, Object> entry(String kind, {String host = '127.0.0.1'}) => {
  'name': 'Fixture $kind (not a model)',
  'filename': 'fixture-$kind.litertlm',
  'sha256': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  'bytes': 32,
  'url': 'http://$host:34567/$kind',
};
Map<String, Object> catalog({String host = '127.0.0.1'}) => {
  'schema': 1,
  'generation': [entry('generation', host: host)],
  'embedding': [entry('embedding', host: host)],
};
Future<ProcessResult> probe(
  Map<String, Object> metadata, {
  bool hooks = true,
  List<String> arguments = const [],
}) => Process.run(Platform.resolvedExecutable, [
  '--packages=${Directory.current.path}/.dart_tool/package_config.json',
  '-DFORESIGHT_ENABLE_TEST_HOOKS=$hooks',
  '-DFORESIGHT_MODEL_CATALOG_TEST_BASE64=${base64Encode(utf8.encode(jsonEncode(metadata)))}',
  'test/fixtures/model_catalog_probe.dart',
  ...arguments,
]);
void main() {
  test(
    'only explicitly compiled test-hook catalog replaces public pins',
    () async {
      final fixture = await probe(catalog());
      expect(fixture.exitCode, 0, reason: '${fixture.stderr}');
      final result = jsonDecode(fixture.stdout as String) as Map;
      expect(result['generation'], 'Fixture generation (not a model)');
      expect(result['embedding_bytes'], 32);
      expect(result['source'], 'http://127.0.0.1:34567/generation');
      expect(result['loopback_allowed'], true);
      expect(result['escape_allowed'], false);
      final production = await probe(
        catalog(host: 'example.com'),
        hooks: false,
      );
      expect(production.exitCode, 0, reason: '${production.stderr}');
      final ordinary = jsonDecode(production.stdout as String) as Map;
      expect(ordinary['generation_bytes'] as int, greaterThan(65536));
      expect(ordinary['source'], isNull);
      expect(ordinary['loopback_allowed'], false);
    },
  );
  for (final host in ['localhost', 'example.com', '127.0.0.2']) {
    test('compiled catalog rejects nonliteral loopback $host', () async {
      final result = await probe(catalog(host: host));
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('tiny pinned loopback'));
    });
  }
  test('compiled catalog rejects invalid checksum metadata', () async {
    final metadata = catalog();
    (metadata['generation'] as List).first['sha256'] = 'unverified';
    final result = await probe(metadata);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('tiny pinned loopback'));
  });
  for (final destination in ['unlisted', 'foreign']) {
    test(
      'actual downloader refuses $destination redirect from compiled loopback asset',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final seen = <String>[];
        server.listen((request) async {
          seen.add(request.uri.path);
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            destination == 'unlisted'
                ? 'http://127.0.0.1:${server.port}/unlisted'
                : 'https://example.invalid/foreign',
          );
          await request.response.close();
        });
        final metadata = catalog();
        (metadata['generation'] as List).first['url'] =
            'http://127.0.0.1:${server.port}/generation';
        final directory = createTestTempDirectorySync('catalog-redirect-');
        final result = await probe(metadata, arguments: [directory.path]);
        expect(result.exitCode, isNot(0));
        expect(seen, ['/generation']);
        expect(
          directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.litertlm')),
          isEmpty,
        );
      },
    );
  }
  test(
    'actual downloader verifies and publishes exact compiled loopback bytes',
    () async {
      final payload = List<int>.generate(32, (index) => index);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      final metadata = catalog();
      final generation = (metadata['generation'] as List).first;
      generation['url'] = 'http://127.0.0.1:${server.port}/generation';
      generation['sha256'] = sha256.convert(payload).toString();
      final directory = createTestTempDirectorySync('catalog-download-');
      final result = await probe(metadata, arguments: [directory.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(jsonDecode(result.stdout as String)['downloaded'], payload.length);
      final published = directory
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((file) => file.path.endsWith('.litertlm'));
      expect(published.readAsBytesSync(), payload);
    },
  );
  test(
    'AOT compiler preserves full immutable catalog with comma-safe encoding',
    () async {
      final directory = createTestTempDirectorySync('catalog-aot-');
      final executable = '${directory.path}/catalog-probe';
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '-DFORESIGHT_ENABLE_TEST_HOOKS=true',
        '-DFORESIGHT_MODEL_CATALOG_TEST_BASE64=${base64Encode(utf8.encode(jsonEncode(catalog())))}',
        'test/fixtures/model_catalog_probe.dart',
        '-o',
        executable,
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout} ${compiled.stderr}',
      );
      final result = await Process.run(executable, const []);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final metadata = jsonDecode(result.stdout as String) as Map;
      expect(metadata['generation'], 'Fixture generation (not a model)');
      expect(metadata['embedding_bytes'], 32);
      expect(metadata['source'], 'http://127.0.0.1:34567/generation');
    },
  );
}
