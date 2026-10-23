import 'package:open_foresight/features/integrations/audio_access.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'controller_fixture.dart';

class RefreshStatusSources implements ConnectedSources {
  @override
  int lastCompletedRefreshMs = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'calendar sync status distinguishes first sync, in-progress and calendar-day age',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final refresh = RefreshStatusSources();
      f.connection.connectedSources = refresh;
      f.connection.googleState = {'syncing': true};
      final dynamic integration = f.shell.integrationFeature;
      expect(integration.googleSyncStatus(), 'Syncing…');
      f.connection.googleState = {};
      expect(integration.googleSyncStatus(), 'Not synced yet');
      final now = DateTime.now();
      for (final (days, label) in [
        (0, 'Last synced today'),
        (1, 'Last synced yesterday'),
        (3, 'Last synced 3 days ago'),
      ]) {
        refresh.lastCompletedRefreshMs = DateTime(
          now.year,
          now.month,
          now.day - days,
          12,
        ).millisecondsSinceEpoch;
        expect(integration.googleSyncStatus(), label);
      }
      f.connection.connectedSources = null;
    },
  );
  testWidgets(
    'connection help explains missing sign-in configuration and returns to settings',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      f.shell.update(() => f.shell.navigate(WorkspaceTab.settings));
      await tester.pumpAndSettle();
      final help = find.text('Connection help');
      await tester.ensureVisible(help);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text('Google connection setup'), findsOneWidget);
      expect(
        find.textContaining(
          'Your Google password is never entered into Foresight.',
        ),
        findsOneWidget,
      );
      final context = tester.element(find.byType(AlertDialog));
      Navigator.pop(context);
      await tester.pumpAndSettle();
      expect(find.text('Google connection setup'), findsNothing);
    },
  );
  testWidgets(
    'capability refresh and microphone requests report denial, malformed bundle and retry',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final dynamic integration = f.shell.integrationFeature;
      for (final (code, label) in [
        ('authorized', 'Allowed'),
        ('denied', 'Denied'),
        ('restricted', 'Restricted by system policy'),
        ('not_determined', 'Not requested'),
        ('other', 'Checking'),
      ]) {
        f.connection.replies[Operation.audioCapabilities] = {
          'microphone': code,
        };
        await integration.refreshCaptureCapabilities();
        expect(integration.microphoneAccessLabel, label);
      }
      f.connection.replies[Operation.audioCapabilities] = {
        'microphone_purpose_present': false,
      };
      await integration.refreshCaptureCapabilities();
      expect(integration.captureCapabilityError, contains('Reinstall'));
      f.connection.failures[Operation.audioCapabilities] = StateError(
        'service offline',
      );
      await integration.refreshCaptureCapabilities();
      expect(integration.captureCapabilityError, contains('service offline'));
      f.connection.replies[Operation.audioRequestMicrophone] = {
        'granted': false,
        'microphone': 'denied',
      };
      await integration.requestMicrophoneAccess();
      expect(
        integration.captureCapabilityError,
        contains('Microphone access was denied'),
      );
      f.connection.replies[Operation.audioRequestMicrophone] = {
        'granted': true,
        'microphone': 'authorized',
      };
      await integration.requestMicrophoneAccess();
      expect(integration.captureCapabilityError, isEmpty);
      f.connection.failures[Operation.audioRequestMicrophone] = StateError(
        'request disconnected',
      );
      await expectLater(
        integration.requestMicrophoneAccess() as Future<void>,
        throwsStateError,
      );
      expect(
        integration.captureCapabilityError,
        contains('request disconnected'),
      );
      final cases = [
        ({'system_audio': 'denied'}, 'Not allowed', false),
        ({'system_audio_request': 'failed'}, 'Setup needs attention', false),
        ({'permission_verified': true}, 'Allowed', true),
        ({'system_audio_request': 'completed'}, 'Request completed', false),
        ({'system_audio_request': 'requesting'}, 'Waiting for', false),
        (<String, dynamic>{}, 'Request access', false),
      ];
      for (final (capabilities, label, complete) in cases) {
        integration.captureCapabilities = AudioAccessPresentation.fromWire(
          capabilities,
        );
        expect(integration.systemAudioAccessLabel, startsWith(label));
        expect(integration.systemAudioSetupComplete, complete);
      }
      f.shell.meetingFeature.systemAudioSetupReviewed = true;
      integration.captureCapabilities = AudioAccessPresentation.fromWire(
        const {},
      );
      expect(integration.systemAudioAccessLabel, startsWith('Setup complete'));
      expect(integration.systemAudioSetupComplete, true);
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'system audio setup persists review only after explicit completion',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      f.connection.replies[Operation.audioRequestSystem] = {
        'system_audio_request': 'completed',
      };
      final dynamic integration = f.shell.integrationFeature;
      final setup = integration.setupSystemAudioAccess() as Future<bool>;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(await setup, true);
      expect(f.store.preference('audio.systemSetupReviewed'), 'true');
      expect(integration.systemAudioSetupComplete, true);
      final again =
          integration.setupSystemAudioAccess(forRecording: true)
              as Future<bool>;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await again, false);
    },
  );
  testWidgets(
    'notification preferences persist and unavailable service errors remain visible',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final dynamic integration = f.shell.integrationFeature;
      await integration.setNotifications(true);
      expect(f.store.preference('notifications'), 'true');
      expect(integration.notifications, true);
      expect(integration.notificationState, 'Notifications available');
      f.connection.replies[Operation.notificationsCapabilities] = {
        'available': false,
      };
      await integration.setNotifications(false);
      expect(f.store.preference('notifications'), 'false');
      expect(
        integration.notificationState,
        Platform.isMacOS
            ? 'Notification permission required; enable to request access'
            : 'Notifications unavailable',
      );
      f.connection.failures[Operation.notificationsCapabilities] = StateError(
        'notification service lost',
      );
      await integration.refreshNotifications();
      expect(
        integration.notificationState,
        contains('notification service lost'),
      );
      await integration.setMeetingReminders(false);
      expect(f.store.preference('googleReminders'), 'false');
      await integration.disableGlobalShortcuts();
      expect(f.store.preference('globalShortcut'), 'false');
      expect(integration.globalShortcutState, 'disabled');
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'menu navigation, shortcut editing and activation errors are controlled',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final dynamic integration = f.shell.integrationFeature;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('foresight/window');
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final (command, tab) in [
        ('sources', WorkspaceTab.sources),
        ('ask', WorkspaceTab.chat),
        ('settings', WorkspaceTab.settings),
        ('meetings', WorkspaceTab.meetings),
      ]) {
        await integration.activateMenuCommand(command);
        expect(f.shell.tab, tab);
      }
      await integration.activateMenuCommand('unknown');
      expect(f.shell.tab, WorkspaceTab.meetings);
      var editing = integration.changeQuickShortcut() as Future<void>;
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'alt+shift+2');
      await tester.tap(find.text('Save shortcut'));
      await tester.pumpAndSettle();
      await editing;
      expect(f.store.preference('quickShortcut'), 'ALT + SHIFT + 2');
      expect(integration.quickActivator.alt, true);
      editing = integration.changeQuickShortcut() as Future<void>;
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'CTRL+F');
      await tester.tap(find.text('Save shortcut'));
      await tester.pumpAndSettle();
      await editing;
      expect(f.shell.error, contains('at least two modifiers'));
      expect(f.store.preference('quickShortcut'), 'ALT + SHIFT + 2');
      editing = integration.changeQuickShortcut() as Future<void>;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await editing;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'activation failed'),
      );
      await integration.activateMenuCommand('ask');
      expect(f.shell.error, contains('activation failed'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'audio device refresh failures recover without losing saved unavailable routes',
    (tester) async {
      var reject = true;
      final f = await ControllerFixture.mount(
        tester,
        devices: () async {
          if (reject) throw StateError('device enumeration failed');
          return [];
        },
      );
      final dynamic integration = f.shell.integrationFeature;
      await integration.refreshAudioDevices();
      expect(
        integration.audioDeviceState,
        contains('device enumeration failed'),
      );
      reject = false;
      await integration.refreshAudioDevices();
      expect(integration.audioDeviceState, isEmpty);
      f.store.setPreference('microphoneTarget', 'disconnected-microphone');
      f.shell.update(() => f.shell.navigate(WorkspaceTab.settings));
      await tester.pumpAndSettle();
      expect(find.text('Saved device unavailable'), findsOneWidget);
      expect(f.store.preference('microphoneTarget'), 'disconnected-microphone');
    },
  );
}
