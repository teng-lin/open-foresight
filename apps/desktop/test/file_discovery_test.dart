import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/file_discovery_sheet.dart';

void main() {
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
        final pollingClock = Stopwatch()..start();
        pollingClock.elapsed < const Duration(seconds: 5) &&
            find.text('Apollo.md').evaluate().isEmpty;
      ) {
        await tester.runAsync(() => Future<void>(() {}));
        await tester.pump();
      }
      expect(find.text('Apollo.md'), findsOneWidget);
      expect(find.text('Borealis.txt'), findsNothing);
      await tester.tap(find.text('Apollo.md'));
      await tester.pump();
      await tester.tap(find.text('Import selected (1)'));
      await tester.pumpAndSettle();
      expect(selected, [
        File('${root.path}/Apollo.md').resolveSymbolicLinksSync(),
      ]);
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
