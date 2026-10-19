import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/app_theme.dart';
import 'package:open_foresight/file_discovery_sheet.dart';
import 'package:open_foresight/model_terms_dialog.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets(
    'copilot panel applies readable dark styles and inverse branding',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: foresightTheme(),
          home: const Scaffold(
            body: CopilotPanel(child: ForesightBrand(inverse: true)),
          ),
        ),
      );
      expect(find.text('Open Foresight'), findsOneWidget);
      final context = tester.element(find.byType(ForesightBrand));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(DefaultTextStyle.of(context).style.color, Colors.white);
      final scheme =
          foresightTheme().segmentedButtonTheme.style!.backgroundColor!;
      expect(scheme.resolve({WidgetState.selected}), const Color(0xffbfe8ff));
      expect(scheme.resolve({}), const Color(0xffdee3e9));
    },
  );
  testWidgets(
    'dedicated model terms require explicit acceptance and show exact revision',
    (tester) async {
      BuildContext? context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      for (final accept in [false, true]) {
        final pending = confirmQueryModelTerms(
          context!,
          Uri.parse('https://publisher.example/terms'),
          'fixture-revision',
        );
        await tester.pumpAndSettle();
        expect(find.text('Model revision: fixture-revision'), findsOneWidget);
        expect(find.text('https://publisher.example/terms'), findsOneWidget);
        await tester.tap(find.text(accept ? 'Accept and download' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(await pending, accept);
      }
    },
  );
  testWidgets(
    'file discovery adds folders, filters names, selects visible files and rescans on removal',
    (tester) async {
      final root = createTestTempDirectorySync('discovery-dialog-');
      final first = File('${root.path}/first.txt')..writeAsStringSync('one');
      File('${root.path}/second.md').writeAsStringSync('two');
      List<String>? imported;
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    imported = await showDialog<List<String>>(
                      context: context,
                      builder: (_) => FileDiscoverySheet(
                        initialFolders: const [],
                        excludedPaths: const {},
                        pickFolder: () async => root.path,
                      ),
                    ),
                child: const Text('Open discovery'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open discovery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add folder'));
      await pumpUntil(
        tester,
        () => find.textContaining('2 files found').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump();
      expect(find.text('second.md'), findsNothing);
      await tester.tap(find.text('Select all shown'));
      await tester.pump();
      await tester.tap(find.text('Import selected (1)'));
      await tester.pumpAndSettle();
      expect(imported, [first.path]);
      await tester.tap(find.text('Open discovery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add folder'));
      await pumpUntil(
        tester,
        () => find.textContaining('2 files found').evaluate().isNotEmpty,
      );
      final chip = tester.widget<InputChip>(find.byType(InputChip));
      chip.onDeleted!();
      await pumpUntil(
        tester,
        () => find.textContaining('0 files found').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'onboarding errors retain progress, reject concurrent actions and expose source status',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final dynamic onboarding = f.shell.onboardingFeature;
      for (final (state, expected) in [
        ('pending', 'Waiting for model setup'),
        ('indexing', 'Indexing…'),
        ('indexed', 'Ready'),
        ('failed', 'Couldn’t index'),
        ('other', 'Saved'),
      ]) {
        expect(
          onboarding.sourceStatus(<String, Object?>{'state': state}),
          startsWith(expected),
        );
      }
      expect(
        onboarding.sourceStatus(<String, Object?>{
          'state': 'failed',
          'error': 'Pipeline not initialized',
        }),
        'Waiting for model setup',
      );
      f.store.db.execute(
        "INSERT INTO models(kind,path,digest,runtime,backend) VALUES('embedding','fixture','fixture','','fixture')",
      );
      expect(
        onboarding.sourceStatus(<String, Object?>{'state': 'pending'}),
        'Waiting to index',
      );
      final gate = Completer<void>();
      final action = onboarding.perform(() => gate.future) as Future<void>;
      var concurrent = false;
      await onboarding.perform(() async {
        concurrent = true;
      });
      expect(concurrent, false);
      gate.completeError(StateError('Service retry required'));
      await action;
      expect(onboarding.failure, 'Service retry required');
      expect(onboarding.working, false);
      await onboarding.perform(() async {});
      expect(onboarding.failure, isEmpty);
      await tester.pumpAndSettle();
    },
  );
}
