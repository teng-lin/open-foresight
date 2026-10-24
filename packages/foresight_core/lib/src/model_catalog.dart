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

final gemmaModels = [
  modelFromPin('gemma-4-12B-it.litertlm'),
  modelFromPin('gemma-4-E4B-it.litertlm'),
  modelFromPin('gemma-4-E2B-it.litertlm'),
];

final embeddingGemmaModel = modelFromPin('embeddinggemma-2-740m.litertlm');
