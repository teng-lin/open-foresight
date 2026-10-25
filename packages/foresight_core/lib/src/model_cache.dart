import 'dart:io';
import 'package:crypto/crypto.dart';
import 'model_catalog.dart';
import 'model_download_contract.dart';

/// Every availability decision authenticates bytes, including equal-size files.
Future<bool> verifyModelFile(
  File file,
  String digest,
  int bytes, {
  bool Function()? current,
}) async {
  void check() {
    if (!(current?.call() ?? true)) throw const ModelDownloadCancelled();
  }

  check();
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.lengthSync() != bytes) {
      return false;
    }
    final digestValue = await sha256
        .bind(
          file.openRead().map((chunk) {
            check();
            return chunk;
          }),
        )
        .first;
    check();
    return digestValue.toString() == digest;
  } on FileSystemException {
    return false;
  }
}

Future<File?> localModelFile(
  GemmaModel model,
  Directory root, {
  Map<String, Object?>? registration,
  bool Function()? current,
}) async {
  final candidates = [
    if (registration?['digest'] == model.digest)
      File(registration!['path'] as String),
    File('${root.path}/${model.directory}/${model.filename}'),
  ];
  for (final file in candidates) {
    if (await verifyModelFile(
      file,
      model.digest,
      model.bytes,
      current: current,
    )) {
      return file;
    }
  }
  return null;
}
