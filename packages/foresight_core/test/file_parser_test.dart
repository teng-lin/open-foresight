import 'dart:async';
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
    'Linux extractors run by absolute path in an isolated read-only sandbox',
    () async {
      final source = File('${directory.path}/file ; café.pdf')
        ..writeAsStringSync('fixture');
      final helper = executable("printf 'sandbox text'");
      final parser = Parser(
        macOS: false,
        startProcess: (executable, arguments) async {
          expect(executable, '/usr/bin/bwrap');
          expect(
            arguments,
            containsAll([
              '--unshare-all',
              '--die-with-parent',
              '--new-session',
              '--cap-drop',
              'ALL',
              '--clearenv',
              '--ro-bind',
              source.path,
              '/input/document.pdf',
              '/usr/bin/pdftotext',
            ]),
          );
          expect(arguments, isNot(contains(directory.path)));
          expect(arguments.sublist(arguments.indexOf('--') + 1), [
            '/usr/bin/pdftotext',
            '-layout',
            '/input/document.pdf',
            '-',
          ]);
          return Process.start(helper.path, []);
        },
      );
      expect((await parser.extract(source.path)).$1, 'sandbox text');
    },
  );

  test(
    'document extraction deadline kills and reaps a stuck owned process',
    () async {
      final source = File('${directory.path}/file.rtf')
        ..writeAsStringSync('fixture');
      Process? process;
      final parser = Parser(
        macOS: false,
        extractionTimeout: const Duration(milliseconds: 30),
        startProcess: (_, _) async =>
            process = await Process.start('/bin/sleep', ['60']),
      );
      await expectLater(
        parser.extract(source.path),
        throwsA(isA<TimeoutException>()),
      );
      expect(await process!.exitCode, isNot(0));
    },
  );

  test(
    'Mac adapter passes mode and literal Unicode path as separate arguments',
    () async {
      final helper = executable('printf \'%s\\n\' "\$1" "\$2"');
      final source = '${directory.path}/\$(touch unexpected); café.PDF';
      File(source).writeAsStringSync('fixture');
      File('${directory.path}/notes.RTF').writeAsStringSync('fixture');
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
      for (final name in ['locked.pdf', 'empty.rtf', 'file.pdf']) {
        File('${directory.path}/$name').writeAsStringSync('fixture');
      }
      final failure = executable('echo "Import an unlocked copy" >&2\nexit 4');
      await expectLater(
        Parser(
          macOS: true,
          macParser: failure.path,
        ).extract('${directory.path}/locked.pdf'),
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
        Parser(
          macOS: true,
          macParser: empty.path,
        ).extract('${directory.path}/empty.rtf'),
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
        ).extract('${directory.path}/file.pdf'),
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
