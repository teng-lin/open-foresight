import 'package:open_foresight/desktop_environment.dart';
import '../test_support/platform_fixture.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'package:foresight_test_support/test_paths.dart';
import '../test_support/core_fixture.dart';
import 'desktop_connection_fixture.dart';

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/integrations/desktop_settings.dart';
import 'package:open_foresight/features/integrations/global_shortcuts.dart';
import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

class PermissionDomain extends CommandFixtureDomain {
  final requests = <String>[];
  PermissionDomain(super.store, super.helper);
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    requests.add(operation.wire);
    if (operation == Operation.audioCapabilities)
      return {
        'microphone': 'not_determined',
        'system_audio': 'permission_checked_on_capture',
      };
    if (operation == Operation.audioRequestMicrophone)
      return {'granted': false, 'microphone': 'denied'};
    if (operation == Operation.notificationsRequestPermission)
      return {'granted': false};
    if (operation == Operation.notificationsCapabilities)
      return {'available': false, 'authorization': 0};
    return super.command(operation, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('foresight/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });

  test(
    'Mac login reflects native status and retains value when permission fails',
    () async {
      bool enabled = false, reject = false;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'login.get') return enabled;
        if (reject)
          throw PlatformException(
            code: 'approval',
            message: 'Allow in Login Items',
          );
        enabled = (call.arguments as Map)['enabled'] as bool;
        return null;
      });
      final settings = DesktopSettings(
        Directory('/not-used'),
        '/not-used',
        macOS: true,
      );
      await settings.refresh();
      expect(settings.openAtLogin, false);
      await settings.setOpenAtLogin(true);
      expect(settings.openAtLogin, true);
      reject = true;
      await expectLater(
        settings.setOpenAtLogin(false),
        throwsA(isA<PlatformException>()),
      );
      expect(settings.openAtLogin, true);
      expect(methods, ['login.get', 'login.set', 'login.get', 'login.set']);
    },
  );

  test(
    'Mac global shortcut uses native channel, routes callback and closes registration',
    () async {
      final methods = <MethodCall>[], activations = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call);
        return null;
      });
      final shortcuts = GlobalShortcuts(
        (id, token) => activations.add(id),
        macOS: true,
      );
      await shortcuts.enable(preferredTrigger: 'CMD+SHIFT+F');
      expect(methods.single.method, 'shortcut.enable');
      expect(methods.single.arguments, {'trigger': 'CMD+SHIFT+F'});
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('quick-meeting'),
        ),
        (_) {},
      );
      expect(activations, ['quick-meeting']);
      await shortcuts.close();
      expect(methods.last.method, 'shortcut.disable');
      expect(shortcuts.state, 'disabled');
    },
  );

  test(
    'Mac registration conflict keeps an existing callback active and reports failure',
    () async {
      bool reject = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (reject && call.method == 'shortcut.enable')
          throw PlatformException(code: 'conflict', message: 'Already used');
        return null;
      });
      int activations = 0;
      final shortcuts = GlobalShortcuts((_, _) => ++activations, macOS: true);
      await shortcuts.enable();
      reject = true;
      await expectLater(
        shortcuts.enable(preferredTrigger: 'CMD+SHIFT+G'),
        throwsA(isA<PlatformException>()),
      );
      expect(shortcuts.state, contains('Already used'));
      expect(shortcuts.trigger, 'CTRL+SHIFT+f');
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('quick-meeting'),
        ),
        (_) {},
      );
      expect(activations, 1);
      await shortcuts.close();
    },
  );

  testWidgets(
    'Mac audio setup requests service permission only after explicit action and displays denial',
    (tester) async {
      final tmp = createTestTempDirectorySync('foresight-mac-permissions-');
      final store = Store('${tmp.path}/app.db');
      final domain = PermissionDomain(
        store,
        OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper'),
      );
      final app = Application(domain);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'login.get' ? false : null,
      );
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(app),
          deviceLoader: () async => [],
          environment: DesktopEnvironment(
            capabilities: testHostPlatformCapabilities,
          ),
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      final workspace =
          tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(workspace.tab, WorkspaceTab.notes);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(domain.requests, contains('audio.capabilities'));
      expect(domain.requests, isNot(contains('audio.request_microphone')));
      await tester.ensureVisible(find.text('Allow microphone'));
      await tester.tap(find.text('Allow microphone'));
      await tester.pumpAndSettle();
      expect(
        domain.requests
            .where((method) => method == 'audio.request_microphone')
            .length,
        1,
      );
      expect(
        find.textContaining('Microphone access was denied'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Upcoming meeting reminders'));
      await tester.tap(find.text('Upcoming meeting reminders'));
      await tester.pumpAndSettle();
      expect(domain.requests, contains('notifications.request_permission'));
      expect(store.preference('googleReminders'), isNot('true'));
      expect(store.preference('notifications'), isNot('true'));
      expect(app.recording, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      tmp.deleteSync(recursive: true);
    },
    skip: !Platform.isMacOS,
  );
}
