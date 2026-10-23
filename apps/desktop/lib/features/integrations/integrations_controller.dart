import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foresight_core/desktop.dart';

import '../../commands.dart';
import '../../desktop_environment.dart';
import '../../desktop_visuals.dart';
import '../../feature_request_identity.dart';
import '../../shell/ports.dart'
    show
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceDialogs,
        PreferenceCommands,
        MeetingActivity,
        MeetingCommands,
        OnboardingActivity;
import '../../shell/workspace_tab.dart';
import 'audio_access.dart';
import 'desktop_settings.dart';
import 'global_shortcuts.dart';
import 'google_picker.dart';
import 'google_sign_in_dialog.dart';
import 'hypr_shortcuts.dart';
import 'ports.dart';
import 'system_audio_setup_dialog.dart';

class IntegrationsController implements IntegrationsPort {
  IntegrationsController({
    required FeatureHost host,
    required WorkspaceNavigation navigation,
    required OperationGate operations,
    required WorkspaceDialogs dialogs,
    required PreferenceCommands preferences,
    required MeetingActivity meetings,
    required MeetingCommands meetingCommands,
    required OnboardingActivity onboarding,
  }) : _host = host,
       _navigation = navigation,
       _operations = operations,
       _dialogs = dialogs,
       _preferences = preferences,
       _meetings = meetings,
       _meetingCommands = meetingCommands,
       _onboarding = onboarding;

  final FeatureHost _host;
  final WorkspaceNavigation _navigation;
  final OperationGate _operations;
  final WorkspaceDialogs _dialogs;
  final PreferenceCommands _preferences;
  final MeetingActivity _meetings;
  final MeetingCommands _meetingCommands;
  final OnboardingActivity _onboarding;

  DesktopConnection get d => _host.connection;
  DesktopEnvironment get environment => _host.environment;
  BuildContext get context => _host.context;
  bool get mounted => !_disposed && _host.mounted;
  bool _disposed = false;
  void setState(VoidCallback action) => _host.update(action);

  /// The shared gate keeps nesting and notifications; this owner retires stale
  /// failures on tab, selection, preview, client-session or workspace changes.
  Future<void> runAction(Future<void> Function() action) async {
    final identity = FeatureRequestIdentity.capture(d);
    final tab = _navigation.selectedTab;
    final selectedMeeting = _meetings.selectedMeetingId;
    final preview = _meetings.previewMeetingId;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        _navigation.selectedTab == tab &&
        _meetings.selectedMeetingId == selectedMeeting &&
        _meetings.previewMeetingId == preview;
    if (!current()) return;
    await _operations.run(() async {
      try {
        await action();
      } catch (_) {
        if (current()) rethrow;
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(googleAuth.close());
    unawaited(commands?.close() ?? Future<void>.value());
    unawaited(globalShortcuts?.close() ?? Future<void>.value());
  }

  @override
  bool get openAtLogin => desktopSettings.openAtLogin;
  @override
  bool get microphoneAuthorized => captureCapabilities.microphoneAuthorized;
  @override
  int get lastCompletedRefreshMilliseconds => google.lastCompletedRefreshMs;
  @override
  void cancelGoogleSignIn() => googleAuth.cancelSignIn();
  @override
  Future<void> refreshGoogle() => google.refresh();
  @override
  Future<void> syncCalendar() => google.syncCalendar();
  @override
  Future<void> importLastYear() => google.importLastYear();
  @override
  Future<void> importMeetingAttachments(int meeting) =>
      google.importAttachments(meeting);

  late final DesktopSettings desktopSettings = DesktopSettings(
    Directory(environment.configDirectory),
    environment.launcher,
    environment: environment,
  );

  @override
  bool notifications = false;

  @override
  String notificationState = 'checking notify-send';

  AppCommands? commands;

  GlobalShortcuts? globalShortcuts;

  @override
  String globalShortcutState = 'disabled';
  bool _quickMeetingReviewPending = false;

  GoogleAccount get googleAuth => d.googleAuth;

  ConnectedSources get google => d.google;

  @override
  String googleState = '';

  List<AudioDevice> availableAudioDevices = [];

  @override
  String audioDeviceState = '';

  AudioAccessPresentation captureCapabilities =
      AudioAccessPresentation.fromWire(const {});

  @override
  String captureCapabilityError = '';

  @override
  String loginState = '';

  @override
  String get microphoneAccessLabel =>
      const {
        'authorized': 'Allowed',
        'denied': 'Denied',
        'restricted': 'Restricted by system policy',
        'not_determined': 'Not requested',
      }[captureCapabilities.microphone] ??
      'Checking';

  @override
  GooglePresentation get googlePresentation => d.googlePresentation;
  @override
  bool get granolaCalendar => googlePresentation.provider == 'granola';
  @override
  bool get driveAvailable => googlePresentation.driveAvailable;

  @override
  Future<void> connectGranolaCalendar() async {
    // The service flushes the provider status before the configure reply.
    // The connection owns that snapshot; features only read its typed value.
    await d.command(Operation.googleConfigure, {'provider': 'granola'});
    await connectGoogle();
  }

  Future<void> completeCalendarSignIn(String url) async {
    await d.command(Operation.googleCompleteSignIn, {'url': url});
    await activateWindow(null);
  }

  @override
  bool get googleSyncing => googlePresentation.syncing;

  @override
  bool get systemAudioSetupComplete =>
      captureCapabilities.systemAudio != 'denied' &&
      captureCapabilities.systemAudioRequest != 'failed' &&
      (_meetings.systemAudioSetupReviewed ||
          captureCapabilities.permissionVerified);

  @override
  String get systemAudioAccessLabel {
    if (captureCapabilities.systemAudio == 'denied') {
      return 'Not allowed · Enable Open Foresight in System Settings.';
    }
    if (captureCapabilities.systemAudioRequest == 'failed') {
      return 'Setup needs attention · Retry the access request.';
    }
    if (captureCapabilities.permissionVerified) return 'Allowed';
    if (_meetings.systemAudioSetupReviewed) {
      return 'Setup complete · Access is checked when recording starts.';
    }
    if (captureCapabilities.systemAudioRequest == 'completed') {
      return 'Request completed · Finish system audio setup.';
    }
    if (captureCapabilities.systemAudioRequest == 'requesting') {
      return 'Waiting for the macOS access request…';
    }
    return 'Request access for audio playing on your Mac.';
  }

  HyprShortcuts get hyprShortcuts => HyprShortcuts(
    desktopSettings.config,
    desktopSettings.launcher,
    environment: environment,
  );

  Future<void> activateWindow(String? token) async {
    if (!mounted) return;
    try {
      await const MethodChannel(
        'foresight/window',
      ).invokeMethod<void>('activate', {'token': token ?? ''});
    } on MissingPluginException {
      /* pure widget tests */
    }
    if (!Platform.isMacOS &&
        environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
      final active = await environment.run('/usr/bin/hyprctl', [
        'activewindow',
        '-j',
      ]);
      if (active.exitCode == 0 &&
          (jsonDecode(active.stdout as String) as Map)['pid'] != pid) {
        await environment.run('/usr/bin/hyprctl', [
          'eval',
          'hl.dispatch(hl.dsp.focus({window="pid:$pid"}))',
        ]);
      }
    }
  }

  void reportShortcutFailure(Object failure) {
    if (!mounted) return;
    setState(() {
      _operations.setError('Global shortcut failed: $failure');
      globalShortcutState = _operations.error;
    });
    unawaited(notify(_operations.error));
  }

  Future<void> activateQuickMeeting(String? token) async {
    await activateWindow(token);
    if (mounted &&
        !_onboarding.active &&
        !_operations.busy &&
        _meetings.recording == null)
      await _meetingCommands.quickStart();
  }

  Future<void> requestQuickMeeting(String? token) async {
    await activateWindow(token);
    if (!mounted ||
        !context.mounted ||
        _quickMeetingReviewPending ||
        _onboarding.active ||
        _operations.busy ||
        _meetings.recording != null)
      return;
    _quickMeetingReviewPending = true;
    try {
      final allow = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Start microphone and system audio recording?'),
          content: const Text(
            'Another process requested a quick meeting. Recording starts only after you confirm here.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Start recording'),
            ),
          ],
        ),
      );
      if (allow == true &&
          mounted &&
          !_onboarding.active &&
          !_operations.busy &&
          _meetings.recording == null) {
        await _meetingCommands.quickStart();
      }
    } finally {
      _quickMeetingReviewPending = false;
    }
  }

  Future<void> activateMenuCommand(String command) async {
    try {
      if (command == 'quick-meeting') {
        await activateQuickMeeting(null);
        return;
      }
      await activateWindow(null);
      if (!mounted || _onboarding.active) return;
      final destination = switch (command) {
        'meetings' => WorkspaceTab.meetings,
        'ask' => WorkspaceTab.chat,
        'sources' => WorkspaceTab.sources,
        'settings' => WorkspaceTab.settings,
        _ => null,
      };
      if (destination != null) _navigation.navigate(destination);
    } catch (failure) {
      _operations.reportAsyncError(failure);
    }
  }

  @override
  Future<void> enableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
      await hyprShortcuts.install(
        d.store.preference('quickShortcut', 'CTRL + SHIFT + F'),
      );
      globalShortcutState = 'Global shortcut installed';
    } else {
      await desktopSettings.ensureApplicationEntry();
      globalShortcuts ??= GlobalShortcuts(
        (id, token) {
          if (id == 'quick-meeting') {
            unawaited(
              activateQuickMeeting(token).catchError(reportShortcutFailure),
            );
          }
        },
        changed: () {
          if (mounted)
            setState(() => globalShortcutState = globalShortcuts!.state);
        },
      );
      await globalShortcuts!.enable(
        preferredTrigger: d.store
            .preference('quickShortcut', 'CTRL + SHIFT + F')
            .replaceAll(' ', ''),
      );
      globalShortcutState = globalShortcuts!.state;
    }
    await d.command(Operation.preferencesSet, {
      'key': 'globalShortcut',
      'value': 'true',
    });
    if (mounted) setState(() {});
  }

  @override
  Future<void> disableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] != null &&
        hyprShortcuts.installed)
      await hyprShortcuts.remove();
    await globalShortcuts?.disable();
    await d.command(Operation.preferencesSet, {
      'key': 'globalShortcut',
      'value': 'false',
    });
    if (mounted) setState(() => globalShortcutState = 'disabled');
  }

  Future<void> refreshLoginSetting() async {
    try {
      await desktopSettings.refresh();
      if (mounted) setState(() => loginState = '');
    } catch (error) {
      if (mounted) setState(() => loginState = error.toString());
    }
  }

  @override
  Future<void> setOpenAtLogin(bool value) async {
    try {
      await desktopSettings.setOpenAtLogin(value);
      if (mounted) setState(() => loginState = '');
    } catch (error) {
      if (mounted) setState(() => loginState = error.toString());
      rethrow;
    }
  }

  @override
  Future<void> refreshCaptureCapabilities() async {
    try {
      final result = AudioAccessPresentation.fromWire(
        await d.command(Operation.audioCapabilities) as Map,
      );
      if (mounted)
        setState(() {
          captureCapabilities = result;
          captureCapabilityError = result.purposeMissing
              ? 'The recording service is missing audio access configuration. Reinstall Open Foresight.'
              : '';
        });
    } catch (error) {
      if (mounted) setState(() => captureCapabilityError = error.toString());
    }
  }

  @override
  Future<void> requestMicrophoneAccess() async {
    try {
      final result = AudioAccessPresentation.fromWire(
        await d.command(Operation.audioRequestMicrophone) as Map,
      );
      if (mounted)
        setState(() {
          captureCapabilities = result;
          captureCapabilityError = result.granted
              ? ''
              : 'Microphone access was denied. Enable Open Foresight in System Settings > Privacy & Security > Microphone, then refresh access status.';
        });
    } catch (error) {
      if (mounted) setState(() => captureCapabilityError = error.toString());
      rethrow;
    }
  }

  @override
  Future<bool> ensureRecordingAccess() async {
    if (!Platform.isMacOS) return true;
    final capabilities = AudioAccessPresentation.fromWire(
      await d.command(Operation.audioCapabilities) as Map,
    );
    if (!mounted || !context.mounted) return false;
    if (capabilities.purposeMissing) {
      throw StateError(
        'The recording service is missing audio access configuration. Reinstall Open Foresight.',
      );
    }
    if (capabilities.microphoneAuthorized) {
      if (_meetings.systemAudioSetupReviewed ||
          capabilities.systemAudioRequest == 'completed')
        return true;
      return setupSystemAudioAccess(forRecording: true);
    }
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Allow recording access'),
        content: const Text(
          'Allow microphone access to transcribe your voice. macOS may also ask for Screen & System Audio Recording access when recording starts. If access was denied, enable Open Foresight in System Settings > Privacy & Security.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow microphone'),
          ),
        ],
      ),
    );
    if (allow != true || !mounted) return false;
    await requestMicrophoneAccess();
    if (!mounted || !context.mounted) return false;
    if (captureCapabilities.microphone != 'authorized') {
      throw StateError(
        captureCapabilityError.isNotEmpty
            ? captureCapabilityError
            : 'Microphone access is required. Enable Open Foresight in System Settings > Privacy & Security > Microphone.',
      );
    }
    if (_meetings.systemAudioSetupReviewed ||
        capabilities.systemAudioRequest == 'completed')
      return true;
    return setupSystemAudioAccess(forRecording: true);
  }

  @override
  Future<bool> setupSystemAudioAccess({bool forRecording = false}) async {
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SystemAudioSetupDialog(
        forRecording: forRecording,
        requestAccess: () async => Map<String, dynamic>.from(
          await d.command(Operation.audioRequestSystem) as Map,
        ),
        readCapabilities: () async => Map<String, dynamic>.from(
          await d.command(Operation.audioCapabilities) as Map,
        ),
        openSettings: (uri) =>
            openSystemAudioSettings(uri, environment: environment),
        capabilitiesChanged: (result) {
          if (mounted)
            setState(
              () => captureCapabilities = captureCapabilities.merge(result),
            );
        },
      ),
    );
    if (proceed == true && mounted) {
      await d.command(Operation.preferencesSet, {
        'key': 'audio.systemSetupReviewed',
        'value': 'true',
      });
      if (!mounted) return false;
      setState(() => _meetingCommands.setSystemAudioSetupReviewed(true));
      return true;
    }
    return false;
  }

  @override
  Future<void> refreshAudioDevices() async {
    try {
      final devices =
          await (_host.deviceLoader?.call() ??
              audioDevices(runProcess: environment.run));
      if (mounted)
        setState(() {
          availableAudioDevices = devices;
          audioDeviceState = '';
        });
    } catch (error) {
      if (mounted) setState(() => audioDeviceState = error.toString());
    }
  }

  @override
  Future<void> connectGoogle({bool addAccount = false}) async {
    if (googleAuth.client == null) {
      throw StateError(
        'Google sign-in is unavailable in this build. Install a distribution with Google sign-in included.',
      );
    }
    final outcome = await showDialog<GoogleSignInOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GoogleSignInDialog(
        auth: googleAuth,
        openBrowser: environment.openUri,
        returnToApp: () => activateWindow(null),
        addAccount: addAccount,
        calendarThroughGranola: granolaCalendar,
        completeSignIn: granolaCalendar
            ? (url) async {
                await d.command(Operation.googleCompleteSignIn, {
                  'url': url,
                  'manual': true,
                });
              }
            : null,
      ),
    );
    if (!mounted) return;
    if (outcome == null || outcome.cancelled) {
      setState(() => googleState = 'Google sign-in cancelled.');
      return;
    }
    if (outcome.error != null) {
      setState(() => googleState = 'Google sign-in did not finish. Try again.');
      Error.throwWithStackTrace(outcome.error!, outcome.stackTrace!);
    }
    setState(() => googleState = 'Connected as ${googleAuth.email}');
    await google.syncCalendar();
  }

  @override
  Future<void> disconnectGoogle() async {
    await googleAuth.disconnect();
    if (mounted) {
      setState(
        () => googleState = googleAuth.connected
            ? 'Connected as ${googleAuth.email}'
            : 'Disconnected; imported documents remain on this device.',
      );
    }
  }

  @override
  Future<void> addGoogleAccount() => connectGoogle(addAccount: true);

  @override
  Future<void> switchGoogleAccount(String id) async {
    if (id == googleAuth.account) return;
    await googleAuth.switchAccount(id);
    if (!mounted) return;
    setState(() => googleState = 'Connected as ${googleAuth.email}');
    await google.syncCalendar();
  }

  @override
  Future<void> signOutGoogleAccount(String id) async {
    await googleAuth.signOutAccount(id);
    if (!mounted) return;
    setState(
      () => googleState = googleAuth.connected
          ? 'Connected as ${googleAuth.email}'
          : 'Disconnected; imported documents remain on this device.',
    );
  }

  @override
  Future<void> setMeetingReminders(bool value) async {
    if (value && Platform.isMacOS) {
      final result =
          await d.command(Operation.notificationsRequestPermission) as Map;
      if (result['granted'] != true) {
        throw StateError(
          'Meeting reminders need notification access. Enable Open Foresight in System Settings > Notifications.',
        );
      }
    }
    await _preferences.preference('googleReminders', value.toString());
    await refreshNotifications();
  }

  Future<void> refreshNotifications() async {
    try {
      final result =
          await d.command(Operation.notificationsCapabilities) as Map;
      if (mounted)
        setState(
          () => notificationState = result['available'] == true
              ? 'Notifications available'
              : Platform.isMacOS
              ? 'Notification permission required; enable to request access'
              : 'Notifications unavailable',
        );
    } catch (error) {
      if (mounted) setState(() => notificationState = error.toString());
    }
  }

  @override
  Future<void> setNotifications(bool value) async {
    if (value && Platform.isMacOS) {
      final result =
          await d.command(Operation.notificationsRequestPermission) as Map;
      if (result['granted'] != true) {
        if (mounted)
          setState(
            () => notificationState =
                'Notification permission denied; enable Open Foresight in System Settings',
          );
        return;
      }
    }
    await d.command(Operation.preferencesSet, {
      'key': 'notifications',
      'value': value.toString(),
    });
    if (mounted) setState(() => notifications = value);
    await refreshNotifications();
  }

  @override
  Future<void> notify(String message) async {
    if (!notifications) return;
    try {
      await environment.notify('Open Foresight', message);
    } catch (e) {
      if (mounted)
        setState(() => notificationState = 'notification unavailable: $e');
    }
  }

  @override
  Future<void> chooseDrive({bool folder = false}) async {
    if (!driveAvailable)
      throw StateError(
        'Drive is unavailable through the Granola calendar connection.',
      );
    if (!googleAuth.connected) await connectGoogle();
    if (!mounted || !context.mounted || !googleAuth.connected) return;
    final selection = await showDialog<List<String>>(
      context: context,
      builder: (_) => GoogleDrivePicker(google, folder: folder),
    );
    if (selection == null) return;
    await importDriveSelection(selection, folder: folder);
  }

  Future<void> importDriveSelection(
    List<String> selection, {
    bool folder = false,
  }) async {
    final failures = <String>[];
    final failedIds = <String>[];
    for (final id in selection) {
      try {
        if (folder) {
          await google.importDriveFolder(id);
        } else {
          await google.importDriveFile(id);
        }
      } catch (error) {
        failedIds.add(id);
        failures.add(
          error is StateError ? error.message.toString() : error.toString(),
        );
      }
    }
    final kind = folder ? 'folders' : 'files';
    if (failures.isNotEmpty) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported ${selection.length - failures.length} of ${selection.length} $kind from Drive.',
            ),
            action: SnackBarAction(
              label: 'Retry failed $kind',
              onPressed: () => unawaited(
                _operations.run(
                  () => importDriveSelection(failedIds, folder: folder),
                ),
              ),
            ),
          ),
        );
      }
      throw StateError(
        'Imported ${selection.length - failures.length} of ${selection.length} $kind from Drive.\n'
        'Could not import:\n${failures.join('\n')}',
      );
    }
    if (mounted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported ${selection.length} $kind from Drive.'),
        ),
      );
    }
  }

  SingleActivator get quickActivator {
    final parts = d.store
        .preference('quickShortcut', 'CTRL + SHIFT + F')
        .split(' + ');
    return SingleActivator(
      LogicalKeyboardKey(parts.last.toLowerCase().codeUnitAt(0)),
      control: parts.contains('CTRL'),
      shift: parts.contains('SHIFT'),
      alt: parts.contains('ALT'),
      meta: parts.any({'SUPER', 'CMD', 'COMMAND', 'META'}.contains),
    );
  }

  @override
  Future<void> changeQuickShortcut() async {
    final input = TextEditingController(
      text: d.store.preference('quickShortcut', 'CTRL + SHIFT + F'),
    );
    final saved = await _dialogs.showInputDialog<bool>(
      builder: (context) => AlertDialog(
        title: const Text('Meeting shortcut'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(hintText: 'CTRL + SHIFT + F'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save shortcut'),
          ),
        ],
      ),
    );
    final value = input.text;
    input.dispose();
    if (saved != true || !mounted) return;
    await _operations.run(() async {
      final normalized = HyprShortcuts.normalize(
        Platform.isMacOS
            ? value
                  .toUpperCase()
                  .replaceAll(RegExp(r'\b(CMD|COMMAND|META)\b'), 'SUPER')
                  .replaceAll('OPTION', 'ALT')
                  .replaceAll('CONTROL', 'CTRL')
            : value,
      );
      if (d.store.preference('globalShortcut') == 'true') {
        if (Platform.isMacOS) {
          await globalShortcuts!.enable(
            preferredTrigger: normalized.replaceAll(' ', ''),
          );
        } else if (environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] !=
            null) {
          await hyprShortcuts.install(normalized);
        } else {
          await globalShortcuts!.configure();
          return;
        }
      }
      await _preferences.preference('quickShortcut', normalized);
    });
  }

  @override
  String googleSyncStatus() {
    if (googleSyncing) return 'Syncing…';
    final timestamp = google.lastCompletedRefreshMs;
    if (timestamp == 0) return 'Not synced yet';
    final last = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final days = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(last.year, last.month, last.day)).inDays;
    if (days == 0) return 'Last synced today';
    if (days == 1) return 'Last synced yesterday';
    return 'Last synced $days days ago';
  }

  @override
  Widget deviceChoice(bool playback) {
    final key = playback ? 'playbackTarget' : 'microphoneTarget';
    final current = d.store.preference(key, 'auto');
    final devices = availableAudioDevices
        .where((device) => device.playback == playback)
        .toList();
    return DesktopSettingSelect<String>(
      width: 300,
      value: current,
      items: [
        const DropdownMenuItem(value: 'auto', child: Text('System default')),
        if (current != 'auto' &&
            !devices.any((device) => device.name == current))
          DropdownMenuItem(
            value: current,
            child: const Text('Saved device unavailable'),
          ),
        ...devices.map(
          (device) => DropdownMenuItem(
            value: device.name,
            child: Text(device.label, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: _meetings.recording != null
          ? null
          : (value) => runAction(() => _preferences.preference(key, value!)),
    );
  }
}
