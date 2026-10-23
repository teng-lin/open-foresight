import '../../desktop_environment.dart';
import 'dart:async';
import 'package:flutter/material.dart';

// The legacy com.apple.preference.security identifier can open only the root
// Privacy pane on newer macOS versions. Target the current Settings extension
// and its audio-only anchor, including when an older native library supplies
// a legacy settings_url hint.
final systemAudioSettingsUri = Uri.parse(
  'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture',
);

/// Settings navigation is a trusted app action. The general source-link opener
/// deliberately rejects custom schemes and must remain strict for imports.
Future<void> openSystemAudioSettings(
  Uri settings, {
  DesktopEnvironment environment = const DesktopEnvironment(),
}) async {
  if (settings != systemAudioSettingsUri) {
    throw ArgumentError.value(
      settings,
      'settings',
      'Unsupported Settings destination',
    );
  }
  if (!environment.capabilities.supportsSystemAudioSettings)
    throw UnsupportedError('macOS System Settings is unavailable');
  final result = await environment.run('/usr/bin/open', [settings.toString()]);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not open System Settings. Open Privacy & Security > Screen & System Audio Recording > System Audio Recording Only.',
    );
  }
}

/// The action that opens this dialog is the explicit permission request. macOS
/// owns consent; a completed Core Audio request does not prove authorization.
class SystemAudioSetupDialog extends StatefulWidget {
  const SystemAudioSetupDialog({
    super.key,
    required this.requestAccess,
    required this.openSettings,
    required this.capabilitiesChanged,
    this.readCapabilities,
    this.forRecording = false,
  });
  final Future<Map<String, dynamic>> Function() requestAccess;
  final Future<void> Function(Uri) openSettings;
  final ValueChanged<Map<String, dynamic>> capabilitiesChanged;
  final Future<Map<String, dynamic>> Function()? readCapabilities;
  final bool forRecording;

  @override
  State<SystemAudioSetupDialog> createState() => _SystemAudioSetupDialogState();
}

class _SystemAudioSetupDialogState extends State<SystemAudioSetupDialog>
    with WidgetsBindingObserver {
  bool requesting = true, completed = false;
  bool openedSettings = false, refreshing = false;
  int requestRevision = 0;
  Timer? poll;
  String message =
      'macOS may ask you to allow System Audio Recording Only. This requests audio access without recording your screen.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => request());
  }

  @override
  void dispose() {
    poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && openedSettings) {
      unawaited(refresh());
    }
  }

  void updateCapabilities(Map<String, dynamic> result) {
    if (!mounted) return;
    poll?.cancel();
    widget.capabilitiesChanged(result);
    setState(() {
      requesting = result['system_audio_request'] == 'requesting';
      completed =
          result['system_audio_request'] == 'completed' ||
          result['permission_verified'] == true;
      message = completed
          ? 'The macOS access request has finished. If Open Foresight is enabled under System Audio Recording Only, choose ${widget.forRecording ? 'Continue recording' : 'Done'} to finish setup. Access is checked when recording starts.'
          : '${result['message'] ?? 'The request was sent to macOS.'}';
    });
    if (requesting && widget.readCapabilities != null) {
      poll = Timer(const Duration(seconds: 1), () => unawaited(refresh()));
    }
  }

  Future<void> refresh() async {
    final read = widget.readCapabilities;
    if (!mounted || read == null || refreshing) return;
    refreshing = true;
    final revision = requestRevision;
    try {
      final result = await read();
      if (revision == requestRevision) updateCapabilities(result);
    } catch (error) {
      if (mounted && revision == requestRevision) {
        setState(() {
          requesting = false;
          message =
              'Could not refresh system audio setup. Retry the access request.';
        });
      }
    } finally {
      refreshing = false;
    }
  }

  Future<void> request() async {
    if (!mounted) return;
    final revision = ++requestRevision;
    setState(() {
      requesting = true;
      completed = false;
    });
    poll?.cancel();
    try {
      final result = await widget.requestAccess();
      if (!mounted || revision != requestRevision) return;
      updateCapabilities(result);
    } catch (error) {
      if (mounted)
        setState(() {
          requesting = false;
          message = error.toString();
        });
    }
  }

  Future<void> openSettings() async {
    try {
      await widget.openSettings(systemAudioSettingsUri);
      openedSettings = true;
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Allow system audio recording'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
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
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: openSettings,
        child: const Text('Open System Settings'),
      ),
      TextButton(
        onPressed: requesting ? null : request,
        child: const Text('Retry request'),
      ),
      FilledButton(
        onPressed: !completed || requesting
            ? null
            : () => Navigator.pop(context, true),
        child: Text(widget.forRecording ? 'Continue recording' : 'Done'),
      ),
    ],
  );
}
