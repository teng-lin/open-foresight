// Internal realtime buffer contract: bounded, ordered, no overwriting unread PCM.
#include "../../native/macos_audio.mm"
#include <stdexcept>
#define REQUIRE(value) do { if (!(value)) throw std::runtime_error(#value); } while (false)
#include <iostream>
int main() { @autoreleasepool {
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

  pushAudio(*ring, format, reinterpret_cast<const AudioBufferList *>(&stereo), true);
  REQUIRE(ring->pop(sample) && sample == .75f);
  REQUIRE(ring->pop(sample) && sample == -.5f);
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
