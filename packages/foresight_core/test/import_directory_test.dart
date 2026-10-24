import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/agent_access.dart' show ImportPolicy;
import 'package:foresight_core/src/import_directory.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('import-scan-');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  test(
    'asynchronous recursive scan accepts supported files and skips links',
    () async {
      final nested = Directory('${root.path}/nested')..createSync();
      final first = File('${root.path}/first.TXT')..writeAsStringSync('one');
      final second = File('${nested.path}/second.md')..writeAsStringSync('two');
      File('${root.path}/unsupported.png').writeAsStringSync('ignored');
      Link('${root.path}/linked.txt').createSync(first.path);
      Link('${nested.path}/cycle').createSync(root.path);
      final files = await enumerateImportFiles(root.path);
      expect(
        files.map((file) => file.path),
        unorderedEquals([first.path, second.path]),
      );
    },
  );

  test(
    'file count bound rejects before any partial import is returned',
    () async {
      for (var i = 0; i <= ImportPolicy.maxDirectoryFiles; i++) {
        File('${root.path}/$i.txt').writeAsStringSync('');
      }
      await expectLater(enumerateImportFiles(root.path), throwsStateError);
    },
  );

  test('unsupported entries still consume the enumeration bound', () async {
    for (var i = 0; i <= ImportPolicy.maxDirectoryEntries; i++) {
      File('${root.path}/$i.bin').writeAsStringSync('');
    }
    await expectLater(enumerateImportFiles(root.path), throwsStateError);
  });

  test(
    'per-file and aggregate byte bounds use metadata without reading bodies',
    () async {
      final oversized = File(
        '${root.path}/large.txt',
      ).openSync(mode: FileMode.write);
      oversized.truncateSync(ImportPolicy.maxFileBytes + 1);
      oversized.closeSync();
      await expectLater(enumerateImportFiles(root.path), throwsStateError);
      File('${root.path}/large.txt').deleteSync();
      for (var i = 0; i < 11; i++) {
        final file = File('${root.path}/$i.txt').openSync(mode: FileMode.write);
        file.truncateSync(ImportPolicy.maxFileBytes);
        file.closeSync();
      }
      await expectLater(enumerateImportFiles(root.path), throwsStateError);
    },
  );

  test(
    'cancellation settles enumeration and event loop remains responsive',
    () async {
      for (var i = 0; i < 100; i++) {
        File('${root.path}/$i.txt').writeAsStringSync('text');
      }
      var ticks = 0;
      final heartbeat = Timer.periodic(Duration.zero, (_) => ticks++);
      addTearDown(heartbeat.cancel);
      await enumerateImportFiles(root.path);
      expect(ticks, greaterThan(0));
      var checks = 0;
      await expectLater(
        enumerateImportFiles(root.path, current: () => ++checks < 5),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      expect(checks, 5);
      // The cancelled directory subscription has settled before the next scan.
      expect(await enumerateImportFiles(root.path), hasLength(100));
    },
  );
}
