/// Immutable presentation of audio capability command replies. These replies
/// are separate from the live recording status in CapturePresentation.
final class AudioAccessPresentation {
  AudioAccessPresentation.fromWire(Map<dynamic, dynamic> wire)
    : _wire = Map<String, Object?>.unmodifiable(wire.cast<String, Object?>());

  final Map<String, Object?> _wire;
  String get microphone => _wire['microphone'] as String? ?? '';
  String get systemAudio => _wire['system_audio'] as String? ?? '';
  String get systemAudioRequest =>
      _wire['system_audio_request'] as String? ?? '';
  bool get microphoneAuthorized => microphone == 'authorized';
  bool get permissionVerified => _wire['permission_verified'] == true;
  bool get granted => _wire['granted'] == true;
  bool get purposeMissing =>
      _wire['microphone_purpose_present'] == false ||
      _wire['system_audio_purpose_present'] == false;

  AudioAccessPresentation merge(Map<String, dynamic> reply) =>
      AudioAccessPresentation.fromWire({..._wire, ...reply});
}
