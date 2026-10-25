class AudioDevice {
  final String name, label;
  final bool playback;
  const AudioDevice(this.name, this.label, this.playback);
  factory AudioDevice.fromWire(Map<String, Object?> value) => AudioDevice(
    value['name'] as String,
    value['label'] as String,
    value['playback'] as bool,
  );
  Map<String, Object?> toWire() => {
    'name': name,
    'label': label,
    'playback': playback,
  };
}
