import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/store.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/import_fixture.dart <file.pdf|file.rtf>',
    );
    exitCode = 64;
    return;
  }
  final parsed = await Parser(macOS: false).extract(args.single);
  stdout.writeln(jsonEncode({'text': parsed.$1, 'adapter': parsed.$2}));
}
