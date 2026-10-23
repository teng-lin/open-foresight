import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foresight_core/desktop.dart';

import '../../desktop_visuals.dart';

class IntegrationDeviceChoice extends StatelessWidget {
  const IntegrationDeviceChoice({
    super.key,
    required this.current,
    required this.devices,
    required this.onChanged,
  });
  final String current;
  final List<AudioDevice> devices;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) => DesktopSettingSelect<String>(
    width: 300,
    value: current,
    items: [
      const DropdownMenuItem(value: 'auto', child: Text('System default')),
      if (current != 'auto' && !devices.any((device) => device.name == current))
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
    onChanged: onChanged,
  );
}

class QuickMeetingConfirmation extends StatelessWidget {
  const QuickMeetingConfirmation({super.key});
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Start microphone and system audio recording?'),
    content: const Text(
      'Another process requested a quick meeting. Recording starts only after you confirm here.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Start recording'),
      ),
    ],
  );
}

class MeetingShortcutDialog extends StatelessWidget {
  const MeetingShortcutDialog({super.key, required this.input});
  final TextEditingController input;
  @override
  Widget build(BuildContext context) => AlertDialog(
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
  );
}

class MicrophoneAccessDialog extends StatelessWidget {
  const MicrophoneAccessDialog({super.key});
  @override
  Widget build(BuildContext context) => AlertDialog(
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
  );
}

String googleSyncLabel({
  required bool syncing,
  required int timestamp,
  DateTime? now,
}) {
  if (syncing) return 'Syncing…';
  if (timestamp == 0) return 'Not synced yet';
  final last = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final today = now ?? DateTime.now();
  final days = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(last.year, last.month, last.day)).inDays;
  if (days == 0) return 'Last synced today';
  if (days == 1) return 'Last synced yesterday';
  return 'Last synced $days days ago';
}

SingleActivator quickMeetingActivator(String shortcut) {
  final parts = shortcut.split(' + ');
  return SingleActivator(
    LogicalKeyboardKey(parts.last.toLowerCase().codeUnitAt(0)),
    control: parts.contains('CTRL'),
    shift: parts.contains('SHIFT'),
    alt: parts.contains('ALT'),
    meta: parts.any({'SUPER', 'CMD', 'COMMAND', 'META'}.contains),
  );
}
