import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:open_foresight/desktop_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'macOS login state follows the native service, including null responses and failure',
    () async {
      final root = createTestTempDirectorySync('login-channel-');
      final settings = DesktopSettings(root, '/unused', macOS: true);
      final calls = <MethodCall>[];
      bool? native = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DesktopSettings.channel, (call) async {
        calls.add(call);
        if (call.method == 'login.get') return native;
        native = (call.arguments as Map)['enabled'] as bool;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(DesktopSettings.channel, null),
      );
      await settings.refresh();
      expect(settings.openAtLogin, true);
      await settings.setOpenAtLogin(false);
      expect(settings.openAtLogin, false);
      expect(calls.map((c) => c.method), [
        'login.get',
        'login.set',
        'login.get',
      ]);
      native = null;
      await settings.refresh();
      expect(settings.openAtLogin, false);
      await settings.ensureApplicationEntry();
      expect(root.listSync(), isEmpty);
      messenger.setMockMethodCallHandler(
        DesktopSettings.channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      await expectLater(
        settings.setOpenAtLogin(true),
        throwsA(isA<PlatformException>()),
      );
      expect(settings.openAtLogin, false);
    },
  );
  test(
    'missing Linux launcher rejects autostart and application entry before writing',
    () async {
      final root = createTestTempDirectorySync('missing-login-');
      final settings = DesktopSettings(
        root,
        '${root.path}/missing',
        macOS: false,
      );
      await expectLater(settings.setOpenAtLogin(true), throwsStateError);
      await expectLater(settings.ensureApplicationEntry(), throwsStateError);
      expect(root.listSync(), isEmpty);
      await settings.refresh();
      await settings.setOpenAtLogin(false);
      expect(settings.openAtLogin, false);
    },
  );
  test(
    'autostart uses quoted packaged launcher and removes only its own entry',
    () async {
      final tmp = createTestTempDirectorySync('foresight-autostart-');
      final launcher = File('${tmp.path}/app with spaces/foresight');
      launcher.parent.createSync(recursive: true);
      launcher.writeAsStringSync('fixture');
      final settings = DesktopSettings(
        Directory('${tmp.path}/config'),
        launcher.path,
        macOS: false,
      );
      settings.legacyEntry.parent.createSync(recursive: true);
      settings.legacyEntry.writeAsStringSync('legacy application entry');
      settings.previousEntry.writeAsStringSync('previous application entry');
      expect(settings.openAtLogin, true);
      await settings.setOpenAtLogin(true);
      expect(settings.legacyEntry.existsSync(), false);
      expect(settings.previousEntry.existsSync(), false);
      expect(
        settings.entry.readAsStringSync(),
        contains('Exec="${launcher.path}"'),
      );
      final other = File('${settings.entry.parent.path}/another.desktop')
        ..writeAsStringSync('preserve');
      await settings.setOpenAtLogin(false);
      expect(settings.openAtLogin, false);
      expect(other.existsSync(), true);
      tmp.deleteSync(recursive: true);
    },
  );
}
