// Internal realtime buffer contract: bounded, ordered, no overwriting unread PCM.
#include "../../native/macos_audio.mm"
#include <stdexcept>
#define REQUIRE(value) do { if (!(value)) throw std::runtime_error(#value); } while (false)
#include <iostream>
// Decode synthetic interleaved PCM through the actual callback converter.
template<class T>
void checkInterleaved(std::array<T, 4> input, AudioFormatFlags flags,
                      std::array<float, 2> mixed, std::array<float, 2> microphone) {
  auto ring = std::make_unique<Ring>();
  AudioStreamBasicDescription format{44100, kAudioFormatLinearPCM,
      flags | kAudioFormatFlagIsPacked, UInt32(sizeof(T) * 2), 1,
      UInt32(sizeof(T) * 2), 2, UInt32(sizeof(T) * 8), 0};
  AudioBufferList data{1, {{2, UInt32(sizeof(input)), input.data()}}};
  REQUIRE(pushAudio(*ring, format, &data));
  float sample;
  for (float expected : mixed) {
    REQUIRE(ring->pop(sample) && std::abs(sample - expected) < 1e-7f);
  }
  REQUIRE(!ring->pop(sample));
  pushMicrophoneAudio(*ring, format, &data, 44100);
  REQUIRE(ring->convertedBuffers == 1);
  for (float expected : microphone) {
    REQUIRE(ring->pop(sample) && std::abs(sample - expected) < 1e-7f);
  }
  REQUIRE(!ring->pop(sample));
  // A route changing sample rate must trigger reconfiguration without putting
  // mismatched PCM into the queue or satisfying the startup watchdog.
  pushMicrophoneAudio(*ring, format, &data, 48000);
  REQUIRE(ring->changed && ring->convertedBuffers == 1 && !ring->pop(sample));
}

void checkPcmFormats() {
  checkInterleaved<float>({.5f, -.25f, -.5f, .25f}, kAudioFormatFlagIsFloat,
      {.125f, -.125f}, {.5f, -.5f});
  checkInterleaved<double>({.5, -.25, -.5, .25}, kAudioFormatFlagIsFloat,
      {.125f, -.125f}, {.5f, -.5f});
  checkInterleaved<int16_t>({16384, -8192, -16384, 8192}, kAudioFormatFlagIsSignedInteger,
      {.125f, -.125f}, {.5f, -.5f});
  checkInterleaved<int32_t>({1073741824, -536870912, -1073741824, 536870912}, kAudioFormatFlagIsSignedInteger,
      {.125f, -.125f}, {.5f, -.5f});
  auto ring = std::make_unique<Ring>();
  float input[] = {.5f, -.5f};
  AudioBufferList data{1, {{1, sizeof(input), input}}};
  const AudioStreamBasicDescription good{48000, kAudioFormatLinearPCM,
      kAudioFormatFlagIsFloat, 4, 1, 4, 1, 32, 0};
  for (int variant = 0; variant < 5; ++variant) {
    auto invalid = good;
    switch (variant) {
      case 0: invalid.mFormatID = kAudioFormatMPEG4AAC; break;
      case 1: invalid.mBytesPerFrame = 0; break;
      case 2: invalid.mFormatFlags |= kAudioFormatFlagIsBigEndian; break;
      case 3: invalid.mBitsPerChannel = 24; break;
      case 4: invalid.mFormatFlags = 0; break;
    }
    ring->changed = false;
    REQUIRE(!pushAudio(*ring, invalid, &data));
    float sample;
    REQUIRE(ring->changed && !ring->pop(sample));
  }
  AudioBufferList empty{};
  REQUIRE(!pushAudio(*ring, good, nullptr));
  REQUIRE(!pushAudio(*ring, good, &empty));
  // A short channel buffer is never read past its end. Missing samples are
  // ignored when averaging the channels that remain available.
  float left[] = {.75f, -.5f}, right[] = {.25f};
  struct { UInt32 count; AudioBuffer buffers[2]; } shortChannel{
      2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
  REQUIRE(pushAudio(*ring, good, reinterpret_cast<const AudioBufferList *>(&shortChannel)));
  float sample;
  REQUIRE(ring->pop(sample) && sample == .5f);
  REQUIRE(ring->pop(sample) && sample == -.5f);
  REQUIRE(!ring->pop(sample));
}

int main() { @autoreleasepool {
  checkPcmFormats();
  // One-shot startup watchdog: converted PCM, including silent buffers, satisfies
  // startup; only an on-time zero-callback check falls back or fails.
  using namespace std::chrono_literals;
  using Action = TapWatchdogAction;
  const TapStartupWatchdog::Clock::time_point now{};
  const TapStartupWatchdog::WallClock::time_point wall{};
  TapStartupWatchdog referenceWatchdog;
  referenceWatchdog.arm(now, wall);
  REQUIRE(referenceWatchdog.check(now + 1499ms, wall + 1499ms, true, 0, false) == Action::none);
  REQUIRE(referenceWatchdog.check(now + 1500ms, wall + 1500ms, true, 0, false) == Action::failed);
  TapStartupWatchdog watchdog(1000ms);
  watchdog.arm(now, wall);
  REQUIRE(watchdog.check(now + 999ms, wall + 999ms, true, 0, true) == Action::none);
  REQUIRE(watchdog.check(now + 1000ms, wall + 1000ms, true, 0, true) == Action::standardFallback);
  REQUIRE(watchdog.check(now + 2000ms, wall + 2000ms, true, 0, false) == Action::none);
  watchdog.arm(now, wall);
  REQUIRE(watchdog.check(now + 1000ms, wall + 1500ms, true, 0, false) == Action::failed);
  watchdog.arm(now, wall);
  REQUIRE(watchdog.check(now + 1000ms, wall + 1500ms + TapStartupWatchdog::WallClock::duration(1), true, 0, true) == Action::deferred);
  REQUIRE(watchdog.check(now + 1999ms, wall + 2499ms, true, 0, true) == Action::none);
  REQUIRE(watchdog.check(now + 2000ms, wall + 2500ms, true, 0, true) == Action::standardFallback);
  watchdog.arm(now, wall);
  REQUIRE(watchdog.check(now + 1000ms, wall + 1000ms, true, 1, true) == Action::none);
  REQUIRE(watchdog.check(now + 2000ms, wall + 2000ms, true, 0, true) == Action::none);
  watchdog.arm(now, wall);
  REQUIRE(watchdog.check(now + 1000ms, wall + 1000ms, false, 0, true) == Action::none);

  // A partially started processed engine must be released before the standard
  // engine is created. Failed fallback must propagate rather than report capture.
  std::vector<std::string> startup;
  int engine = 1;
  auto fallback = startVoiceCapture(true, [&] { startup.push_back("dispose"); ++engine; },
    [&](bool processed) {
      startup.push_back(processed ? "processed" : "standard");
      REQUIRE(engine == (processed ? 1 : 2));
      return processed ? -7 : 0;
    });
  REQUIRE((startup == std::vector<std::string>{"processed", "dispose", "standard"}));
  REQUIRE(fallback.status == 0 && !fallback.processed && fallback.fallbackReason == -7);
  auto failed = startVoiceCapture(true, [] {}, [](bool processed) { return processed ? -7 : -9; });
  REQUIRE(failed.status == -9 && !failed.processed && failed.fallbackReason == -7);
  bool reset = false;
  auto processed = startVoiceCapture(true, [&] { reset = true; }, [](bool enabled) { REQUIRE(enabled); return 0; });
  REQUIRE(processed.processed && !reset);
  auto plain = startVoiceCapture(false, [&] { REQUIRE(false); }, [](bool enabled) { REQUIRE(!enabled); return 0; });
  REQUIRE(!plain.processed && plain.status == 0);

  auto ring = std::make_unique<Ring>();
  float sample = 0;
  REQUIRE(!ring->pop(sample));
  for (size_t i = 0; i < Ring::capacity - 1; ++i) ring->push(float(i));
  ring->push(-1);
  REQUIRE(ring->dropped == 1);
  for (size_t i = 0; i < Ring::capacity - 1; ++i) { REQUIRE(ring->pop(sample)); REQUIRE(sample == float(i)); }
  REQUIRE(!ring->pop(sample));
  std::thread producer([&] { for (int i = 0; i < 100000; ++i) ring->push(float(i)); });
  for (int i = 0; i < 100000; ++i) { while (!ring->pop(sample)) std::this_thread::yield(); REQUIRE(sample == float(i)); }
  producer.join();
  REQUIRE(ring->dropped == 1);
  // System audio downmixes channels; the microphone's mono route selects the
  // first channel, matching the reference converter's explicit channel map.
  float left[] = {.75f, -.5f}, right[] = {.25f, .5f};
  struct { UInt32 count; AudioBuffer buffers[2]; } stereo{2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
  AudioStreamBasicDescription format{48000, kAudioFormatLinearPCM,
      kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
  pushAudio(*ring, format, reinterpret_cast<const AudioBufferList *>(&stereo));
  REQUIRE(ring->pop(sample) && sample == .5f);
  REQUIRE(ring->pop(sample) && sample == 0.f);
  REQUIRE(!ring->pop(sample));

  pushMicrophoneAudio(*ring, format, reinterpret_cast<const AudioBufferList *>(&stereo), 48000);
  REQUIRE(ring->convertedBuffers == 1);
  REQUIRE(ring->pop(sample) && sample == .75f);
  REQUIRE(ring->pop(sample) && sample == -.5f);
  REQUIRE(!ring->pop(sample));

  auto invalidFormat = format;
  invalidFormat.mBitsPerChannel = 24;
  pushMicrophoneAudio(*ring, invalidFormat, reinterpret_cast<const AudioBufferList *>(&stereo), 48000);
  REQUIRE(ring->convertedBuffers == 1 && ring->changed);
  ring->changed = false;
  pushMicrophoneAudio(*ring, format, reinterpret_cast<const AudioBufferList *>(&stereo), 16000);
  REQUIRE(ring->convertedBuffers == 1 && ring->changed);
  pushMicrophoneAudio(*ring, format, nullptr, 48000);
  REQUIRE(ring->convertedBuffers == 1);
  left[0] = left[1] = right[0] = right[1] = 0;
  pushMicrophoneAudio(*ring, format, reinterpret_cast<const AudioBufferList *>(&stereo), 48000);
  REQUIRE(ring->convertedBuffers == 2);
  REQUIRE(ring->pop(sample) && sample == 0);
  REQUIRE(ring->pop(sample) && sample == 0);
  REQUIRE(!ring->pop(sample));

  // Setup callbacks must never inspect private PCM, even if Core Audio
  // presents buffers. An intentionally unreadable pointer proves the discard
  // branch runs before any AudioBufferList/sample access.
  auto discarded = std::make_unique<Session>();
  discarded->discardAudio = true;
  auto *privateAudio = reinterpret_cast<const AudioBufferList *>(uintptr_t(1));
  REQUIRE(output(0, nullptr, privateAudio, nullptr, nullptr, nullptr, discarded.get()) == noErr);
  REQUIRE(!discarded->ring->pop(sample));

  REQUIRE([systemAudioState(nullptr)[@"system_audio"] isEqual:@"unknown"]);
  REQUIRE([systemAudioState(nullptr)[@"system_audio_request"] isEqual:@"not_requested"]);
  auto request = std::make_shared<SystemAudioRequest>();
  REQUIRE([systemAudioState(request)[@"system_audio"] isEqual:@"pending"]);
  request->completed.store(true, std::memory_order_release);
  auto completed = systemAudioState(request);
  REQUIRE([completed[@"system_audio"] isEqual:@"unknown"]);
  REQUIRE([completed[@"system_audio_request"] isEqual:@"completed"]);
  REQUIRE(![completed[@"permission_verified"] boolValue]);
  request->status = kAudioDevicePermissionsError;
  REQUIRE([systemAudioState(request)[@"system_audio"] isEqual:@"denied"]);
  request->status = kAudioHardwareIllegalOperationError;
  REQUIRE([systemAudioState(request)[@"system_audio"] isEqual:@"unavailable"]);
  REQUIRE(![systemAudioState(request)[@"permission_verified"] boolValue]);

  // This unbundled unit executable has no audio purpose string. Fail before
  // making any Core Audio permission request, preserving consent-free CI.
  REQUIRE(![[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSAudioCaptureUsageDescription"]);
  REQUIRE(fs_macos_request_system(0).find("capture_bundle_misconfigured") != std::string::npos);
  auto before = micStatus();
  REQUIRE(fs_macos_devices().front() == '[');
  auto capabilities = fs_macos_capabilities();
  REQUIRE(capabilities.find("core_audio_tap") != std::string::npos);
  REQUIRE(capabilities.find("permission_verified") != std::string::npos);
  // Discovery does not create taps or launch permission requests.
  { std::lock_guard lock(systemRequestMutex); REQUIRE(!systemRequest); }
  REQUIRE(before == micStatus()); // Discovery must never request microphone access.
  std::atomic<bool> cancel{true};
  unsigned frames = 0;
  fs_macos_capture("missing-device", false, 48000, cancel,
    [&](const auto &) { ++frames; }, [](const auto &) {});
  REQUIRE(frames == 0);
  std::cout << "macOS audio buffer, discovery and cancellation contracts passed\n";
} }
