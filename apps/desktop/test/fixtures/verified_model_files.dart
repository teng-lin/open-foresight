import 'dart:io';
import 'package:foresight_core/src/gemma_download.dart';

// UI-only fixtures replace the byte verifier; downloader tests authenticate real
// small assets. These sparse files must never be hashed as multi-GB models.
Future<File?> verifiedFixtureModelFile(
  GemmaModel model,
  Directory root, {
  Map<String, Object?>? registration,
}) async {
  final file = registration?['digest'] == model.digest
      ? File(registration!['path'] as String)
      : File('${root.path}/${model.directory}/${model.filename}');
  return file.existsSync() && file.lengthSync() == model.bytes ? file : null;
}
