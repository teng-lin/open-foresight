import 'dart:convert';
import 'dart:io';

class AudioDevice {
  final String name, label;
  final bool playback;
  AudioDevice(this.name, this.label, this.playback);
}

Future<List<AudioDevice>> audioDevices() async {
  final result = await Process.run(
    'pw-dump',
    [],
  ).timeout(const Duration(seconds: 10));
  if (result.exitCode != 0)
    throw StateError('PipeWire audio devices are unavailable.');
  final devices = <AudioDevice>[];
  for (final item in jsonDecode(result.stdout as String) as List) {
    final info = (item as Map)['info'];
    if (info is! Map) continue;
    final properties = info['props'];
    if (properties is! Map) continue;
    final media = properties['media.class'];
    if (media != 'Audio/Source' && media != 'Audio/Sink') continue;
    final name = properties['node.name'];
    if (name is! String) continue;
    devices.add(
      AudioDevice(
        name,
        (properties['node.description'] ?? properties['node.nick'] ?? name)
            .toString(),
        media == 'Audio/Sink',
      ),
    );
  }
  devices.sort((a, b) => a.label.compareTo(b.label));
  return devices;
}
