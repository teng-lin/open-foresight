import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/file_discovery.dart';
import 'package:open_foresight/file_discovery_sheet.dart';

void main() {
  test(
    'discovery scans chosen roots, excludes imports, skips links and hidden/build folders',
    () async {
      final root = Directory.systemTemp.createTempSync('foresight-discovery-');
      addTearDown(() => root.deleteSync(recursive: true));
      final nested = Directory('${root.path}/nested')..createSync();
      for (final path in [
        'note.TXT',
        'already; imported.md',
        'ignore.png',
        '.hidden.md',
        'nested/plan.pdf',
        '.private/secret.txt',
        'build/generated.txt',
      ]) {
        final file = File('${root.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('fixture');
      }
      Link('${root.path}/loop').createSync(root.path);
      Link('${root.path}/linked.txt').createSync('${root.path}/note.TXT');
      final result = await LocalFileDiscovery().scan(
        [root.path, nested.path, '${root.path}/.'],
        excludedPaths: {'${root.path}/already; imported.md'},
      );
      expect(result.files.map((f) => f.name).toSet(), {'note.TXT', 'plan.pdf'});
      expect(result.alreadyImported, 1);
      expect(result.truncated, false);
      expect(result.files.every((f) => f.bytes == 7), true);
    },
  );
  test(
    'unavailable folders do not prevent discovery in readable roots',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'foresight-discovery-unavailable-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/note.md').writeAsStringSync('fixture');
      final result = await LocalFileDiscovery().scan([
        '${root.path}/missing',
        root.path,
      ]);
      expect(result.files.single.name, 'note.md');
      expect(result.unavailableFolders.length, 1);
    },
  );
  test('scan limits and cancellation bound work', () async {
    final root = Directory.systemTemp.createTempSync(
      'foresight-discovery-limits-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    for (var i = 0; i < 150; i++) {
      File('${root.path}/note-$i.txt').writeAsStringSync('fixture');
    }
    final bounded = await LocalFileDiscovery().scan([root.path], maxFiles: 3);
    expect(bounded.files.length, 3);
    expect(bounded.truncated, true);
    final entries = await LocalFileDiscovery().scan([root.path], maxEntries: 2);
    expect(entries.examined, 2);
    expect(entries.truncated, true);
    final scanner = LocalFileDiscovery();
    final cancelled = await scanner.scan(
      [root.path],
      progress: (count, _) {
        if (count >= 100) scanner.cancel();
      },
    );
    expect(cancelled.examined, 100);
    final stopped = LocalFileDiscovery()..cancel();
    expect((await stopped.scan([root.path])).examined, 0);
  });
  testWidgets(
    'discovery selection returns only chosen files; cancellation returns none',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'foresight-discovery-sheet-',
      );
      File('${root.path}/Apollo.md').writeAsStringSync('fixture');
      File('${root.path}/Borealis.txt').writeAsStringSync('fixture');
      List<String>? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<List<String>>(
                    context: context,
                    builder: (_) => FileDiscoverySheet(
                      initialFolders: [root.path],
                      excludedPaths: {'${root.path}/Borealis.txt'},
                      pickFolder: () async => null,
                    ),
                  );
                },
                child: const Text('Discover'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Discover'));
      for (
        var i = 0;
        i < 100 && find.text('Apollo.md').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Apollo.md'), findsOneWidget);
      expect(find.text('Borealis.txt'), findsNothing);
      await tester.tap(find.text('Apollo.md'));
      await tester.pump();
      await tester.tap(find.text('Import selected (1)'));
      await tester.pumpAndSettle();
      expect(selected, ['${root.path}/Apollo.md']);
      await tester.tap(find.text('Discover'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      root.deleteSync(recursive: true);
    },
  );
}
