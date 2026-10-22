part of 'main.dart';

class _IntegrationsController extends _FeatureController {
  _IntegrationsController(super.shell);

  late final DesktopSettings desktopSettings = DesktopSettings(
    Directory(widget.environment.configDirectory),
    widget.environment.launcher,
    environment: widget.environment,
  );

  bool notifications = false;

  String notificationState = 'checking notify-send';

  AppCommands? commands;

  GlobalShortcuts? globalShortcuts;

  String globalShortcutState = 'disabled';

  GoogleAccount get googleAuth => d.googleAuth;

  ConnectedSources get google => d.google;

  String googleState = '';

  List<AudioDevice> availableAudioDevices = [];

  String audioDeviceState = '';

  Map<String, dynamic> captureCapabilities = {};

  String captureCapabilityError = '';

  String loginState = '';

  String get microphoneAccessLabel =>
      const {
        'authorized': 'Allowed',
        'denied': 'Denied',
        'restricted': 'Restricted by system policy',
        'not_determined': 'Not requested',
      }[captureCapabilities['microphone']] ??
      'Checking';

  bool get granolaCalendar => d.googleStatus['provider'] == 'granola';
  bool get driveAvailable => d.googleStatus['driveAvailable'] != false;

  Future<void> connectGranolaCalendar() async {
    final state =
        await d.command(Operation.googleConfigure, {'provider': 'granola'})
            as Map;
    d.googleStatus
      ..clear()
      ..addAll(Map<String, dynamic>.from(state));
    await connectGoogle();
  }

  Future<void> completeCalendarSignIn(String url) async {
    await d.command(Operation.googleCompleteSignIn, {'url': url});
    await activateWindow(null);
  }

  bool get googleSyncing => d.googleStatus['syncing'] == true;

  bool get systemAudioSetupComplete =>
      captureCapabilities['system_audio'] != 'denied' &&
      captureCapabilities['system_audio_request'] != 'failed' &&
      (meetingFeature.systemAudioSetupReviewed ||
          captureCapabilities['permission_verified'] == true);

  String get systemAudioAccessLabel {
    if (captureCapabilities['system_audio'] == 'denied') {
      return 'Not allowed · Enable Open Foresight in System Settings.';
    }
    if (captureCapabilities['system_audio_request'] == 'failed') {
      return 'Setup needs attention · Retry the access request.';
    }
    if (captureCapabilities['permission_verified'] == true) return 'Allowed';
    if (meetingFeature.systemAudioSetupReviewed) {
      return 'Setup complete · Access is checked when recording starts.';
    }
    if (captureCapabilities['system_audio_request'] == 'completed') {
      return 'Request completed · Finish system audio setup.';
    }
    if (captureCapabilities['system_audio_request'] == 'requesting') {
      return 'Waiting for the macOS access request…';
    }
    return 'Request access for audio playing on your Mac.';
  }

  HyprShortcuts get hyprShortcuts => HyprShortcuts(
    desktopSettings.config,
    desktopSettings.launcher,
    environment: widget.environment,
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
        widget.environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
      final active = await widget.environment.run('/usr/bin/hyprctl', [
        'activewindow',
        '-j',
      ]);
      if (active.exitCode == 0 &&
          (jsonDecode(active.stdout as String) as Map)['pid'] != pid) {
        await widget.environment.run('/usr/bin/hyprctl', [
          'eval',
          'hl.dispatch(hl.dsp.focus({window="pid:$pid"}))',
        ]);
      }
    }
  }

  void reportShortcutFailure(Object failure) {
    if (!mounted) return;
    setState(() {
      shell.error = 'Global shortcut failed: $failure';
      globalShortcutState = shell.error;
    });
    unawaited(notify(shell.error));
  }

  Future<void> activateQuickMeeting(String? token) async {
    await activateWindow(token);
    if (mounted &&
        !shell.onboardingFeature.active &&
        !shell.busy &&
        meetingFeature.recording == null)
      await meetingFeature.quickStart();
  }

  Future<void> activateMenuCommand(String command) async {
    try {
      if (command == 'quick-meeting') {
        await activateQuickMeeting(null);
        return;
      }
      await activateWindow(null);
      if (!mounted || shell.onboardingFeature.active) return;
      final destination = const {
        'meetings': 3,
        'ask': 1,
        'sources': 0,
        'settings': 6,
      }[command];
      if (destination != null) setState(() => shell.tab = destination);
    } catch (failure) {
      shell.reportAsyncError(failure);
    }
  }

  Future<void> enableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        widget.environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
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

  Future<void> disableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        widget.environment.variables['HYPRLAND_INSTANCE_SIGNATURE'] != null &&
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

  Future<void> setOpenAtLogin(bool value) async {
    try {
      await desktopSettings.setOpenAtLogin(value);
      if (mounted) setState(() => loginState = '');
    } catch (error) {
      if (mounted) setState(() => loginState = error.toString());
      rethrow;
    }
  }

  Future<void> refreshCaptureCapabilities() async {
    try {
      final result = await d.command(Operation.audioCapabilities) as Map;
      if (mounted)
        setState(() {
          captureCapabilities = Map<String, dynamic>.from(result);
          captureCapabilityError =
              result['microphone_purpose_present'] == false ||
                  result['system_audio_purpose_present'] == false
              ? 'The recording service is missing audio access configuration. Reinstall Open Foresight.'
              : '';
        });
    } catch (error) {
      if (mounted) setState(() => captureCapabilityError = error.toString());
    }
  }

  Future<void> requestMicrophoneAccess() async {
    try {
      final result = await d.command(Operation.audioRequestMicrophone) as Map;
      if (mounted)
        setState(() {
          captureCapabilities = Map<String, dynamic>.from(result);
          captureCapabilityError = result['granted'] == true
              ? ''
              : 'Microphone access was denied. Enable Open Foresight in System Settings > Privacy & Security > Microphone, then refresh access status.';
        });
    } catch (error) {
      if (mounted) setState(() => captureCapabilityError = error.toString());
      rethrow;
    }
  }

  Future<bool> ensureRecordingAccess() async {
    if (!Platform.isMacOS) return true;
    final capabilities = await d.command(Operation.audioCapabilities) as Map;
    if (!mounted || !context.mounted) return false;
    if (capabilities['microphone_purpose_present'] == false ||
        capabilities['system_audio_purpose_present'] == false) {
      throw StateError(
        'The recording service is missing audio access configuration. Reinstall Open Foresight.',
      );
    }
    if (capabilities['microphone'] == 'authorized') {
      if (meetingFeature.systemAudioSetupReviewed ||
          capabilities['system_audio_request'] == 'completed')
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
    if (captureCapabilities['microphone'] != 'authorized') {
      throw StateError(
        captureCapabilityError.isNotEmpty
            ? captureCapabilityError
            : 'Microphone access is required. Enable Open Foresight in System Settings > Privacy & Security > Microphone.',
      );
    }
    if (meetingFeature.systemAudioSetupReviewed ||
        capabilities['system_audio_request'] == 'completed')
      return true;
    return setupSystemAudioAccess(forRecording: true);
  }

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
            openSystemAudioSettings(uri, environment: widget.environment),
        capabilitiesChanged: (result) {
          if (mounted)
            setState(
              () => captureCapabilities = {...captureCapabilities, ...result},
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
      setState(() => meetingFeature.systemAudioSetupReviewed = true);
      return true;
    }
    return false;
  }

  Future<void> refreshAudioDevices() async {
    try {
      final devices = await widget.deviceLoader();
      if (mounted)
        setState(() {
          availableAudioDevices = devices;
          audioDeviceState = '';
        });
    } catch (error) {
      if (mounted) setState(() => audioDeviceState = error.toString());
    }
  }

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
        openBrowser: widget.environment.openUri,
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

  Future<void> addGoogleAccount() => connectGoogle(addAccount: true);

  Future<void> switchGoogleAccount(String id) async {
    if (id == googleAuth.account) return;
    await googleAuth.switchAccount(id);
    if (!mounted) return;
    setState(() => googleState = 'Connected as ${googleAuth.email}');
    await google.syncCalendar();
  }

  Future<void> signOutGoogleAccount(String id) async {
    await googleAuth.signOutAccount(id);
    if (!mounted) return;
    setState(
      () => googleState = googleAuth.connected
          ? 'Connected as ${googleAuth.email}'
          : 'Disconnected; imported documents remain on this device.',
    );
  }

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
    await settingsFeature.preference('googleReminders', value.toString());
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

  Future<void> notify(String message) async {
    if (!notifications) return;
    try {
      await widget.environment.notify('Open Foresight', message);
    } catch (e) {
      if (mounted)
        setState(() => notificationState = 'notification unavailable: $e');
    }
  }

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
                shell.run(
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

  Future<void> changeQuickShortcut() async {
    final input = TextEditingController(
      text: d.store.preference('quickShortcut', 'CTRL + SHIFT + F'),
    );
    final saved = await shell.showInputDialog<bool>(
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
    await shell.run(() async {
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
        } else if (widget
                .environment
                .variables['HYPRLAND_INSTANCE_SIGNATURE'] !=
            null) {
          await hyprShortcuts.install(normalized);
        } else {
          await globalShortcuts!.configure();
          return;
        }
      }
      await settingsFeature.preference('quickShortcut', normalized);
    });
  }

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
      onChanged: meetingFeature.recording != null
          ? null
          : (value) => runAction(() => settingsFeature.preference(key, value!)),
    );
  }
}
