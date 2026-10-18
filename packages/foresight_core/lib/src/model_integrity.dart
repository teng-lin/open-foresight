import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// The same digest contract is used at registration and every service startup.
Future<String> modelAssetDigest(String path) async {
  if (!await Directory(path).exists()) {
    return (await sha256.bind(File(path).openRead()).first).toString();
  }
  final files = await Directory(path)
      .list(recursive: true, followLinks: false)
      .where((entry) => entry is File)
      .cast<File>()
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) throw StateError('Empty model directory');
  final manifest = StringBuffer();
  for (final file in files) {
    manifest.writeln(
      '${file.path.substring(Directory(path).path.length)}:'
      '${await sha256.bind(file.openRead()).first}',
    );
  }
  return sha256.convert(utf8.encode(manifest.toString())).toString();
}
