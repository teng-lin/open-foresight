import 'dart:convert';

import 'model_pins.dart';

class GemmaModel {
  final String name, repository, revision, filename, digest;
  final int bytes, minimumMemoryGb;
  const GemmaModel(
    this.name,
    this.repository,
    this.revision,
    this.filename,
    this.digest,
    this.bytes,
    this.minimumMemoryGb,
  );
  Uri get url =>
      Uri.https('huggingface.co', '/$repository/resolve/$revision/$filename');
  String get directory =>
      '${filename.replaceAll('.litertlm', '')}-${digest.substring(0, 12)}';
}

// Pinned public artifact metadata, independently verified 2026-10-13. These
// are not assumed identical to Foresight's encrypted Mac service artifacts.
GemmaModel modelFromPin(String filename) {
  final pin = modelPin(filename);
  return GemmaModel(
    pin['name'] as String,
    pin['repository'] as String,
    pin['revision'] as String,
    pin['filename'] as String,
    pin['sha256'] as String,
    pin['bytes'] as int,
    pin['minimumMemoryGb'] as int,
  );
}

final gemmaModels =
    _compiledFixtureModels('generation') ??
    [
      modelFromPin('gemma-4-12B-it.litertlm'),
      modelFromPin('gemma-4-E4B-it.litertlm'),
      modelFromPin('gemma-4-E2B-it.litertlm'),
    ];

final embeddingGemmaModel =
    _compiledFixtureModels('embedding')?.single ??
    modelFromPin('embeddinggemma-2-740m.litertlm');

// Only explicitly compiled test-hook applications can substitute this catalog.
// There is no environment/config selector in an ordinary product. The test
// build still uses the real downloader, consent, hash validation and service.
const _fixtureHooks = bool.fromEnvironment('FORESIGHT_ENABLE_TEST_HOOKS');
const _fixtureEncoded = String.fromEnvironment(
  'FORESIGHT_MODEL_CATALOG_TEST_BASE64',
);
final Map<String, List<GemmaModel>>? _fixtureCatalog = _readFixtureCatalog();

Map<String, List<GemmaModel>>? _readFixtureCatalog() {
  if (!_fixtureHooks || _fixtureEncoded.isEmpty) return null;
  final decoded = jsonDecode(utf8.decode(base64Decode(_fixtureEncoded)));
  if (decoded is! Map ||
      decoded['schema'] != 1 ||
      decoded.keys.toSet().difference({
        'schema',
        'generation',
        'embedding',
      }).isNotEmpty) {
    throw const FormatException('Invalid compiled fixture model catalog');
  }
  final result = <String, List<GemmaModel>>{};
  for (final kind in ['generation', 'embedding']) {
    final entries = decoded[kind];
    if (entries is! List ||
        entries.isEmpty ||
        (kind == 'embedding' && entries.length != 1)) {
      throw const FormatException('Missing compiled fixture model kind');
    }
    result[kind] = List.unmodifiable(
      entries.map((entry) {
        if (entry is! Map ||
            entry['name'] is! String ||
            entry['filename'] is! String ||
            entry['sha256'] is! String ||
            entry['bytes'] is! int ||
            entry['url'] is! String) {
          throw const FormatException(
            'Invalid compiled fixture model metadata',
          );
        }
        final filename = entry['filename'] as String,
            digest = entry['sha256'] as String,
            bytes = entry['bytes'] as int;
        final source = Uri.parse(entry['url'] as String);
        if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(filename) ||
            filename == '.' ||
            filename == '..' ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
            bytes < 1 ||
            bytes > 65536 ||
            source.scheme != 'http' ||
            !['127.0.0.1', '::1'].contains(source.host) ||
            !source.hasPort ||
            source.port < 1 ||
            source.userInfo.isNotEmpty ||
            source.hasFragment ||
            source.hasQuery) {
          throw const FormatException(
            'Fixture models require tiny pinned loopback assets',
          );
        }
        return _LoopbackFixtureModel(
          kind,
          entry['name'] as String,
          filename,
          digest,
          bytes,
          source,
        );
      }),
    );
  }
  return Map.unmodifiable(result);
}

List<GemmaModel>? _compiledFixtureModels(String kind) => _fixtureCatalog?[kind];

final class _LoopbackFixtureModel extends GemmaModel {
  _LoopbackFixtureModel(
    String kind,
    String name,
    String filename,
    String digest,
    int bytes,
    this.source,
  ) : super(
        name,
        'fixture/loopback-$kind',
        'acceptance-v1',
        filename,
        digest,
        bytes,
        0,
      );
  final Uri source;
  @override
  Uri get url => source;
}

/// Compile-only acceptance source; ordinary products always return null.
Uri? compiledFixtureModelSource(GemmaModel model) {
  for (final candidate
      in _fixtureCatalog?.values.expand((models) => models) ?? <GemmaModel>[]) {
    if (candidate.digest == model.digest &&
        candidate.filename == model.filename &&
        candidate.bytes == model.bytes &&
        candidate.repository == model.repository &&
        candidate.revision == model.revision) {
      return candidate.url;
    }
  }
  return null;
}

/// A fixture redirect may never escape its exact compiled loopback assets.
bool isCompiledFixtureModelSource(Uri source) =>
    _fixtureCatalog?.values
        .expand((models) => models)
        .any((model) => model.url == source) ??
    false;
