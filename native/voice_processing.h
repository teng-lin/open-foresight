#pragma once

struct VoiceCaptureStart {
  int status;
  bool processed;
  int fallbackReason;
};

// A failed voice-processing engine must be destroyed before standard capture
// starts. Keep this ownership rule independent of the OS audio implementation.
template<class Reset, class Start>
VoiceCaptureStart startVoiceCapture(bool requested, Reset reset, Start start) {
  if (!requested) return {start(false), false, 0};
  const int failure = start(true);
  if (!failure) return {0, true, 0};
  reset();
  return {start(false), false, failure};
}
