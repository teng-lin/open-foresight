import '../audio_models.dart';

/// Optional service barrier before any physical capture starts. Capture marks
/// its provisional ownership first, so configuration/clear cannot race this
/// asynchronous join of an existing background codec/output owner.
abstract interface class RecordingAudioAdmission {
  Future<void> prepareForCapture();
}

/// Capture never owns or drains background speech/codec workers. The synchronous
/// preparation freezes durable segmentation metadata before physical admission;
/// the remaining calls only wake work reconstructible from the manifests.
abstract interface class RecordingAudioWorkPort {
  void prepareSpan(
    AudioSpan span, {
    required String modelRevision,
    required Map<AudioSource, int> sourceStarts,
  });
  void published(AudioChunk chunk);
  void spanSealed(AudioSpan span);
  void captureStopped(AudioSession session);
}
