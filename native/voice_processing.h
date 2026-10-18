#pragma once
#include <chrono>
#include <cstdint>

enum class TapWatchdogAction { none, deferred, standardFallback, failed };

// Reference InputRecorder's one-shot startup check. A handled PCM tap buffer
// satisfies it; silence is valid capture. A delayed dispatch (for example after
// sleep/wake) rearms rather than misdiagnosing a silent engine.
class TapStartupWatchdog {
public:
  using Clock = std::chrono::steady_clock;
  using WallClock = std::chrono::system_clock;
  explicit TapStartupWatchdog(
      std::chrono::milliseconds interval = std::chrono::milliseconds(1500))
      : interval_(interval) {}
  void arm(Clock::time_point now, WallClock::time_point wallNow) {
    due_ = now + interval_;
    wallDue_ = wallNow + interval_;
    armed_ = true;
  }
  TapWatchdogAction check(Clock::time_point now, WallClock::time_point wallNow,
                          bool active, uint64_t buffers, bool processed) {
    if (!armed_)
      return TapWatchdogAction::none;
    if (!active || buffers) {
      armed_ = false;
      return TapWatchdogAction::none;
    }
    if (now < due_)
      return TapWatchdogAction::none;
    if (wallNow - wallDue_ > std::chrono::milliseconds(500)) {
      arm(now, wallNow);
      return TapWatchdogAction::deferred;
    }
    armed_ = false;
    return processed ? TapWatchdogAction::standardFallback
                     : TapWatchdogAction::failed;
  }

private:
  std::chrono::milliseconds interval_;
  Clock::time_point due_{};
  WallClock::time_point wallDue_{};
  bool armed_ = false;
};

// Original InputRecorder ignores configuration notifications while its engine
// still runs. A stopped-engine notification replaces the pending 150ms restart;
// the delayed closure checks recording ownership again before touching devices.
class InputConfigurationRecovery {
public:
  using Clock = std::chrono::steady_clock;
  void observe(Clock::time_point now, bool active, bool running) {
    if (!active || running)
      return;
    due_ = now + std::chrono::milliseconds(150);
    pending_ = true;
  }
  bool pending() const {
    return pending_;
  }
  bool restart(Clock::time_point now, bool active) {
    if (!active) {
      pending_ = false;
      return false;
    }
    if (!pending_ || now < due_)
      return false;
    pending_ = false;
    return true;
  }

private:
  Clock::time_point due_{};
  bool pending_ = false;
};

struct VoiceCaptureStart {
  int status;
  bool processed;
  int fallbackReason;
};

// A failed voice-processing engine must be destroyed before standard capture
// starts. Keep this ownership rule independent of the OS audio implementation.
template <class Reset, class Start>
VoiceCaptureStart startVoiceCapture(bool requested, Reset reset, Start start) {
  if (!requested)
    return {start(false), false, 0};
  const int failure = start(true);
  if (!failure)
    return {0, true, 0};
  reset();
  return {start(false), false, failure};
}
