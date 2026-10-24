import 'dart:io';
import 'package:crypto/crypto.dart';
import 'model_catalog.dart';

/// Every availability decision authenticates bytes, including equal-size files.
Future<bool> verifyModelFile(File file, String digest, int bytes) async {
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.lengthSync() != bytes) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() == digest;
  } on FileSystemException {
    return false;
  }
}

Future<File?> localModelFile(
  GemmaModel model,
  Directory root, {
  Map<String, Object?>? registration,
}) async {
  final candidates = [
    if (registration?['digest'] == model.digest)
      File(registration!['path'] as String),
    File('${root.path}/${model.directory}/${model.filename}'),
  ];
  for (final file in candidates) {
    if (await verifyModelFile(file, model.digest, model.bytes)) return file;
  }
  return null;
}
