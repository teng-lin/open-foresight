import 'desktop_fixture_owner.dart';
import 'package:open_foresight/desktop_environment.dart';
import '../test_support/platform_fixture.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/app_theme.dart';
import 'package:open_foresight/desktop_visuals.dart';

import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'Settings selectors retain selection, keyboard and disabled behavior',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('desktop-select-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/app.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(Application(Domain(store, helper))),
            deviceLoader: () async => [],
            environment: DesktopEnvironment(
              capabilities: testHostPlatformCapabilities,
            ),
          ),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        final inactivity = find.byKey(const Key('inactivity'));
        final serviceIdle = find.byKey(const Key('serviceIdleMinutes'));
        await tester.ensureVisible(inactivity);
        await tester.tap(
          find.descendant(
            of: inactivity,
            matching: find.byType(DropdownButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('15 minutes (Default)'), findsWidgets);
        await tester.tap(find.text('30 minutes').last);
        await tester.pumpAndSettle();
        expect(store.preference('inactivity'), '30');
        final label = find
            .descendant(of: inactivity, matching: find.text('30 minutes'))
            .first;
        Focus.of(tester.element(label)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(find.text('5 minutes'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(store.preference('inactivity'), '30');
        expect(
          find.text('Stop the background service after agent inactivity'),
          findsOneWidget,
        );
        expect(
          find.text(
            'With the window closed, the service and its models exit this long after the last agent request.',
          ),
          findsOneWidget,
        );
        final serviceSelect = tester.widget<DesktopSettingSelect<String>>(
          serviceIdle,
        );
        expect(serviceSelect.value, '30');
        expect(serviceSelect.items.map((item) => item.value), [
          '0',
          '15',
          '30',
          '60',
          '120',
        ]);
        expect(serviceSelect.items.map((item) => (item.child as Text).data), [
          'Never',
          '15 minutes',
          '30 minutes (Default)',
          '60 minutes',
          '120 minutes',
        ]);
        await tester.ensureVisible(serviceIdle);
        await tester.tap(
          find.descendant(
            of: serviceIdle,
            matching: find.byType(DropdownButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('60 minutes').last);
        await tester.pumpAndSettle();
        expect(store.preference('serviceIdleMinutes'), '60');
        expect(store.preference('inactivity'), '30');
        expect(
          tester.widget<DesktopSettingSelect<String>>(serviceIdle).value,
          '60',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            theme: foresightTheme(),
            home: Scaffold(
              body: DesktopSettingSelect<String>(
                value: 'fixture',
                items: const [
                  DropdownMenuItem(
                    value: 'fixture',
                    child: Text('Saved device unavailable'),
                  ),
                ],
                onChanged: null,
              ),
            ),
          ),
        );
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .onChanged,
          isNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
        root.deleteSync(recursive: true);
      }
    }),
  );

  testWidgets(
    'Settings preserves a custom service idle period',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('desktop-service-idle-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/app.db');
      store.setPreference('serviceIdleMinutes', '0.05');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(Application(Domain(store, helper))),
            deviceLoader: () async => [],
            environment: DesktopEnvironment(
              capabilities: testHostPlatformCapabilities,
            ),
          ),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final serviceIdle = find.byKey(const Key('serviceIdleMinutes'));
        final select = tester.widget<DesktopSettingSelect<String>>(serviceIdle);
        expect(select.value, '0.05');
        expect(select.items.map((item) => item.value), [
          '0',
          '15',
          '30',
          '60',
          '120',
          '0.05',
        ]);
        expect(
          (select.items.singleWhere((item) => item.value == '0.05').child
                  as Text)
              .data,
          '0.05 minutes',
        );
        await tester.ensureVisible(serviceIdle);
        await tester.tap(
          find.descendant(
            of: serviceIdle,
            matching: find.byType(DropdownButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('0.05 minutes'), findsWidgets);
        await tester.tap(find.text('Never').last);
        await tester.pumpAndSettle();
        expect(store.preference('serviceIdleMinutes'), '0');
        final updated = tester.widget<DesktopSettingSelect<String>>(
          serviceIdle,
        );
        expect(updated.value, '0');
        expect(updated.items.map((item) => item.value), [
          '0',
          '15',
          '30',
          '60',
          '120',
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
      }
    }),
  );

  testWidgets(
    'desktop audit screens, menu and URL dialog fit normal and scaled narrow layouts',
    (tester) async => withDesktopFixtures(tester, () async {
      final semantics = tester.ensureSemantics();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('foresight/desktop'),
        (call) async => call.method == 'login.get' ? false : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('foresight/desktop'),
          null,
        ),
      );
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fonts = FontLoader('GoogleSans');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        fonts.addFont(rootBundle.load('assets/fonts/GoogleSans-$weight.ttf'));
      }
      await fonts.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      final root = createTestTempDirectorySync('desktop-audit-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/app.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      for (final title in [
        'Product review',
        'Launch checklist',
        'Research notes',
      ]) {
        final id = store.importText(
          title,
          'Controlled local content.',
          'text/plain',
          'fixture',
        );
        store.db.execute("UPDATE sources SET state='indexed' WHERE id=?", [id]);
      }
      store.meeting('Product review');
      final key = GlobalKey();
      Future<void> capture(String name) async {
        final path = Platform.environment['FORESIGHT_DESKTOP_AUDIT'];
        if (path == null) return;
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final png = await picture.toByteData(format: ui.ImageByteFormat.png);
          await Directory(path).create(recursive: true);
          await File('$path/$name.png').writeAsBytes(png!.buffer.asUint8List());
          picture.dispose();
        });
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: Foresight(
              TestDesktopConnection(Application(Domain(store, helper))),
              deviceLoader: () async => [],
              environment: DesktopEnvironment(
                capabilities: testHostPlatformCapabilities,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ask'));
        await tester.pumpAndSettle();
        await capture('01-ask-empty');
        store.answer(
          'What are the next steps?',
          '## Review\n\nKeep the scope focused.\n\n- Revise the draft\n- Confirm the checklist\n\n**Owner:** Mira',
          'completed',
          [],
          'fixture',
        );
        final state =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        state.update(() {});
        await tester.pumpAndSettle();
        await capture('02-ask-answer');
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        await capture('03-sources');
        expect(
          tester.getCenter(find.text('Product review')).dy -
              tester.getCenter(find.text('Launch checklist')).dy,
          closeTo(44, 1),
        );
        await tester.tap(find.byTooltip('Add source'));
        await tester.pumpAndSettle();
        await capture('04-import-menu');
        for (final tile in tester.widgetList<DesktopImportMenuTile>(
          find.byType(DesktopImportMenuTile),
        )) {
          expect(tile.label, isNotEmpty);
        }
        expect(
          find.text(
            Platform.isMacOS
                ? 'Find files on this Mac'
                : 'Find files on this computer',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Add from URL'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Please enter the URL'), findsWidgets);
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isFalse,
        );
        await tester.tap(find.text('Allow private network addresses'));
        await tester.pump();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue,
        );
        await capture('05-url-dialog');
        final titleContext = tester.element(find.byType(AlertDialog));
        expect(Theme.of(titleContext).dialogTheme.titleTextStyle!.fontSize, 24);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(store.sources.length, 3);
        for (final screen in ['Stats', 'Settings']) {
          await tester.tap(find.text(screen).first);
          await tester.pumpAndSettle();
          await capture('06-${screen.toLowerCase()}');
          expect(tester.takeException(), isNull);
        }
        tester.view.physicalSize = const Size(800, 800);
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await capture('07-settings-scaled');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Stats').first);
        await tester.pumpAndSettle();
        await capture('08-stats-scaled');
        expect(
          find.semantics
              .byLabel(RegExp(r'Week of .*: .* local output words'))
              .evaluate(),
          hasLength(5),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Sources').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add source'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add from URL'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isFalse,
        );
        await capture('09-dialog-scaled');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          MaterialApp(
            theme: foresightTheme(),
            home: const Scaffold(
              body: SizedBox(
                width: 120,
                child: DesktopMetricValue(1234567890, fontSize: 52),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1,234,567,890'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        debugDisableShadows = previousShadows;
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
        root.deleteSync(recursive: true);
      }
    }),
  );
}
