import 'dart:io';

import 'agent_access.dart' show ImportPolicy;
import 'rpc_error.dart';

/// Native asynchronous directory/stat operations yield between bounded entries;
/// no recursive listSync or source body reads run on the capture isolate.
Future<List<File>> enumerateImportFiles(
  String path, {
  bool Function()? current,
}) async {
  final files = <File>[];
  var entries = 0;
  var bytes = 0;
  final supported = RegExp(r'\.(txt|md|pdf|rtf)$', caseSensitive: false);
  void checkCurrent() {
    if (!(current?.call() ?? true)) {
      throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
    }
  }

  checkCurrent();
  await for (final entry in Directory(
    path,
  ).list(recursive: true, followLinks: false)) {
    checkCurrent();
    if (++entries > ImportPolicy.maxDirectoryEntries) {
      throw StateError('Directory entry limit exceeded');
    }
    if (entry is! File || !supported.hasMatch(entry.path)) continue;
    final stat = await entry.stat();
    checkCurrent();
    if (stat.type != FileSystemEntityType.file ||
        stat.size > ImportPolicy.maxFileBytes) {
      throw StateError('Import requires a regular file no larger than 10 MiB');
    }
    bytes += stat.size;
    if (bytes > 100 * 1024 * 1024 ||
        files.length >= ImportPolicy.maxDirectoryFiles) {
      throw StateError('Directory import limit exceeded');
    }
    files.add(entry);
  }
  checkCurrent();
  return files;
}
