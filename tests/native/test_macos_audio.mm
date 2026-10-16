// Internal realtime buffer contract: bounded, ordered, no overwriting unread PCM.
#include "../../native/macos_audio.mm"
#include <cassert>
#include <iostream>
int main() { @autoreleasepool {
  auto ring = std::make_unique<Ring>();
  float sample = 0;
  assert(!ring->pop(sample));
  for (size_t i = 0; i < Ring::capacity - 1; ++i) ring->push(float(i));
  ring->push(-1);
  assert(ring->dropped == 1);
  for (size_t i = 0; i < Ring::capacity - 1; ++i) { assert(ring->pop(sample)); assert(sample == float(i)); }
  assert(!ring->pop(sample));
  std::thread producer([&] { for (int i = 0; i < 100000; ++i) ring->push(float(i)); });
  for (int i = 0; i < 100000; ++i) { while (!ring->pop(sample)) std::this_thread::yield(); assert(sample == float(i)); }
  producer.join();
  assert(ring->dropped == 1);
  auto before = micStatus();
  assert(fs_macos_devices().front() == '[');
  auto capabilities = fs_macos_capabilities();
  assert(capabilities.find("core_audio_tap") != std::string::npos);
  assert(before == micStatus()); // Discovery must never request microphone access.
  std::atomic<bool> cancel{true};
  unsigned frames = 0;
  fs_macos_capture("missing-device", false, 48000, cancel,
    [&](const auto &) { ++frames; }, [](const auto &) {});
  assert(frames == 0);
  std::cout << "macOS audio buffer, discovery and cancellation contracts passed\n";
} }
