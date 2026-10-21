import 'package:foresight_core/src/application.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_menu.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'quick_start_test.dart' show QuickStartDomain;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('foresight/window'),
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('foresight/window'),
        null,
      ),
    );
  });
  Future<void> command(String name) async {
    await messenger.handlePlatformMessage(
      DesktopMenu.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(name)),
      (_) {},
    );
  }

  test(
    'menu commands work without enabling global shortcuts and stop on close',
    () async {
      final received = <String>[];
      final menu = DesktopMenu((name) async => received.add(name), macOS: true);
      for (final name in DesktopMenu.commands) {
        await command(name);
      }
      await command('unknown');
      expect(received, DesktopMenu.commands.toList());
      menu.close();
      await command('meetings');
      expect(received, DesktopMenu.commands.toList());
    },
  );

  testWidgets(
    'menu routes to workspace pages and uses recording consent',
    (tester) async {
      final root = createTestTempDirectorySync('of-menu-');
      addTearDown(() => root.deleteSync(recursive: true));
      final store = Store('${root.path}/app.db');
      await tester.runAsync(() async {
        final model = File('${root.path}/speech.bin')
          ..writeAsStringSync('fixture');
        final runner = File('${root.path}/speech-runner')
          ..writeAsStringSync('#!/bin/sh\nexit 0\n');
        Process.runSync('/bin/chmod', ['700', runner.path]);
        await store.register('speech', model.path, runner.path);
      });
      final domain = QuickStartDomain(
        store,
        OfflineHelper('${root.path}/sock', '${root.path}/helper'),
      );
      domain.denyMicrophone = true;
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Application(domain)),
          deviceLoader: () async => [],
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      for (final route in {
        'settings': 6,
        'ask': 1,
        'sources': 0,
        'meetings': 3,
      }.entries) {
        final navigating = command(route.key);
        await tester.pumpAndSettle();
        await navigating;
        expect(state.tab, route.value);
      }
      final starting = command('quick-meeting');
      await tester.pumpAndSettle();
      expect(find.text('Allow recording access'), findsOneWidget);
      expect(domain.operations, isNot(contains('meetings.start')));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await starting;
      await tester.pumpWidget(const SizedBox());
    },
    skip: !Platform.isMacOS,
  );
}
