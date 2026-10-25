import 'package:foresight_core/desktop.dart' show AudioCapabilityResult;

/// Immutable presentation of audio capability command replies. These replies
/// are separate from the live recording status in CapturePresentation.
final class AudioAccessPresentation {
  AudioAccessPresentation.fromWire(Map<Object?, Object?> wire)
    : _value = AudioCapabilityResult.fromWire(wire);
  const AudioAccessPresentation.fromResult(this._value);
  final AudioCapabilityResult _value;
  String get microphone => _value.microphone.value ?? '';
  String get systemAudio => _value.systemAudio.value ?? '';
  String get systemAudioRequest => _value.systemAudioRequest.value ?? '';
  bool get microphoneAuthorized => microphone == 'authorized';
  bool get permissionVerified => _value.permissionVerified.value == true;
  bool get granted => _value.granted.value == true;
  bool get purposeMissing =>
      _value.microphonePurposePresent.value == false ||
      _value.systemAudioPurposePresent.value == false;
  AudioAccessPresentation merge(Map<String, dynamic> reply) =>
      AudioAccessPresentation.fromWire({..._value.toWire(), ...reply});
}
