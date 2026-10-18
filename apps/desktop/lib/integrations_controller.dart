part of 'main.dart';

class _IntegrationsController extends _FeatureController {
  _IntegrationsController(super.shell);

  late final DesktopSettings desktopSettings = DesktopSettings(
    Directory(
      Platform.environment['XDG_CONFIG_HOME'] ??
          '${Platform.environment['HOME']}/.config',
    ),
    '${File(Platform.resolvedExecutable).parent.parent.path}/open-foresight',
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

  bool get googleSyncing => d.googleStatus['syncing'] == true;

  HyprShortcuts get hyprShortcuts =>
      HyprShortcuts(desktopSettings.config, desktopSettings.launcher);

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
        Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
      final active = await Process.run('hyprctl', ['activewindow', '-j']);
      if (active.exitCode == 0 &&
          (jsonDecode(active.stdout as String) as Map)['pid'] != pid) {
        await Process.run('hyprctl', [
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
    if (mounted && !shell.busy && meetingFeature.recording == null)
      await meetingFeature.quickStart();
  }

  Future<void> enableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
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
        Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null &&
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
    var requesting = false;
    var completed = false;
    var message =
        'Allow Open Foresight under System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only. The exact wording varies by macOS version.';
    String? settingsUrl;
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          title: const Text('Allow system audio recording'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Permission requested: System Audio Recording Only. This lets Foresight transcribe audio playing on your Mac.',
                ),
                const SizedBox(height: 12),
                Text(message),
                if (requesting) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const Text('Waiting for the macOS audio access request…'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            if (settingsUrl != null)
              TextButton(
                onPressed: () async {
                  try {
                    await openPlatformUri(Uri.parse(settingsUrl!));
                  } catch (error) {
                    if (dialogContext.mounted)
                      updateDialog(() => message = error.toString());
                  }
                },
                child: const Text('Open System Settings'),
              ),
            TextButton(
              onPressed: requesting
                  ? null
                  : () async {
                      updateDialog(() {
                        requesting = true;
                        completed = false;
                      });
                      try {
                        final result =
                            await d.command(Operation.audioRequestSystem)
                                as Map;
                        if (!dialogContext.mounted) return;
                        updateDialog(() {
                          requesting = false;
                          completed =
                              result['system_audio_request'] == 'completed';
                          settingsUrl = result['settings_url'] as String?;
                          message =
                              '${result['message'] ?? 'The request was sent to macOS.'}\nTurn on Open Foresight under System Audio Recording Only, then return and continue. Permission is checked by actual capture.';
                        });
                        if (mounted)
                          setState(
                            () => captureCapabilities = {
                              ...captureCapabilities,
                              ...Map<String, dynamic>.from(result),
                            },
                          );
                      } catch (error) {
                        if (dialogContext.mounted)
                          updateDialog(() {
                            requesting = false;
                            message = error.toString();
                          });
                      }
                    },
              child: Text(
                settingsUrl == null ? 'Request access' : 'Retry request',
              ),
            ),
            FilledButton(
              onPressed: !completed || requesting
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text(forRecording ? 'Continue recording' : 'Done'),
            ),
          ],
        ),
      ),
    );
    if (proceed == true && mounted) {
      meetingFeature.systemAudioSetupReviewed = true;
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

  Future<void> importGoogleClient() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Google Desktop OAuth client',
          extensions: ['json'],
        ),
      ],
    );
    if (file != null) await googleAuth.configure(File(file.path));
    if (mounted) setState(() {});
  }

  Future<void> connectGoogle() async {
    if (googleAuth.client == null) {
      final configure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Set up Google Drive and Calendar'),
          content: const SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: SelectableText(
                'This build needs a Google sign-in configuration before it can connect.\n\n'
                '1. In Google Cloud Console, enable the Google Drive API and Google Calendar API.\n'
                '2. Configure the OAuth consent screen and add your account as a test user if the app is in testing.\n'
                '3. Create an OAuth client with application type Desktop app and download its JSON file.\n'
                '4. Import that JSON here, then sign in with Google in your browser.\n\n'
                'Open Foresight requests read-only access to Drive and Calendar. Your Google password stays in your browser.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import client JSON'),
            ),
          ],
        ),
      );
      if (configure != true || !mounted) return;
      await importGoogleClient();
      if (!mounted || !context.mounted || googleAuth.client == null) return;
    }
    final outcome = await showDialog<GoogleSignInOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          GoogleSignInDialog(auth: googleAuth, openBrowser: openPlatformUri),
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
      await platformNotification('Open Foresight', message);
    } catch (e) {
      if (mounted)
        setState(() => notificationState = 'notification unavailable: $e');
    }
  }

  Future<void> chooseDrive({bool folder = false}) async {
    if (!googleAuth.connected) await connectGoogle();
    if (!mounted || !context.mounted || !googleAuth.connected) return;
    final selection = await showDialog<List<String>>(
      context: context,
      builder: (_) => GoogleDrivePicker(google, folder: folder),
    );
    if (selection == null) return;
    final failures = <String>[];
    for (final id in selection) {
      try {
        if (folder) {
          await google.importDriveFolder(id);
        } else {
          await google.importDriveFile(id);
        }
      } catch (error) {
        failures.add(error.toString());
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
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
        } else if (Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] !=
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
          : (value) => settingsFeature.preference(key, value!),
    );
  }
}
