import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('of parser ; '));
  tearDown(() => directory.deleteSync(recursive: true));

  File executable(String body) {
    final file = File('${directory.path}/parser helper')
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('/bin/chmod', ['700', file.path]);
    return file;
  }

  test(
    'Mac adapter passes mode and literal Unicode path as separate arguments',
    () async {
      final helper = executable('printf \'%s\\n\' "\$1" "\$2"');
      final source = '${directory.path}/\$(touch unexpected); café.PDF';
      final (text, provenance) = await Parser(
        macOS: true,
        macParser: helper.path,
      ).extract(source);
      expect(text, '--pdf\n$source\n');
      expect(provenance, 'PDFKit (macOS adapter)');
      expect(File('${directory.path}/unexpected').existsSync(), false);
      final rtf = await Parser(
        macOS: true,
        macParser: helper.path,
      ).extract('${directory.path}/notes.RTF');
      expect(rtf.$1, startsWith('--rtf\n'));
      expect(rtf.$2, 'NSAttributedString RTF (macOS adapter)');
    },
  );

  test(
    'Mac extraction failures preserve actionable diagnostics and reject empty output',
    () async {
      final failure = executable('echo "Import an unlocked copy" >&2\nexit 4');
      await expectLater(
        Parser(macOS: true, macParser: failure.path).extract('locked.pdf'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('unlocked copy'),
          ),
        ),
      );
      final empty = executable('exit 0');
      await expectLater(
        Parser(macOS: true, macParser: empty.path).extract('empty.rtf'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no extractable text'),
          ),
        ),
      );
      await expectLater(
        Parser(
          macOS: true,
          macParser: '${directory.path}/missing',
        ).extract('file.pdf'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Reinstall'),
          ),
        ),
      );
    },
  );

  test(
    'plain UTF8 source imports do not require the document adapter',
    () async {
      final source = File('${directory.path}/notes.md')
        ..writeAsStringSync('café Ω');
      final result = await Parser(
        macOS: true,
        macParser: '/missing',
      ).extract(source.path);
      expect(result, ('café Ω', 'UTF-8 text'));
    },
  );
}
