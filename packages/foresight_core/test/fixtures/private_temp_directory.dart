import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';

// Invoked in a separate process so the test can set umask without affecting
// other concurrently running tests.
Future<void> main(List<String> arguments) async {
  final parent = Directory(arguments.single);
  final before = parent.statSync().mode;
  final public = Directory('${parent.path}/public')..createSync();
  final alias = Link('${parent.path}/alias')..createSync(public.path);
  var publicRejected = false;
  var linkRejected = false;
  Directory? temporary;
  try {
    try {
      privateDirectory(public.path);
    } on StateError {
      publicRejected = true;
    }
    try {
      privateDirectory(alias.path);
    } on StateError {
      linkRejected = true;
    }
    temporary = await createPrivateTempDirectory(parent, 'owned-');
    stdout.writeln(
      jsonEncode({
        'temporary': temporary.statSync().mode & 0x1ff,
        'parentBefore': before,
        'parentAfter': parent.statSync().mode,
        'publicAfter': public.statSync().mode & 0x1ff,
        'publicRejected': publicRejected,
        'linkRejected': linkRejected,
      }),
    );
  } finally {
    await temporary?.delete(recursive: true);
    alias.deleteSync();
    public.deleteSync();
  }
}
