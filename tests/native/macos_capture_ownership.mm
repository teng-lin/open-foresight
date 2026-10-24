#define FORESIGHT_ENABLE_TEST_HOOKS 1
#include "../../native/macos_audio.mm"
#include <future>
#include <iostream>
using namespace std::chrono_literals;
void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
template <class Fn> void until(Fn ready) {
  const auto deadline = std::chrono::steady_clock::now() + 3s;
  while (!ready()) {
    require(std::chrono::steady_clock::now() < deadline,
            "bounded Mac owner barrier");
    std::this_thread::sleep_for(1ms);
  }
}
struct EndGate {
  std::atomic<bool> entered{false}, release{false};
};
struct HeldExit {
  std::shared_ptr<EndGate> gate;
  ~HeldExit() {
    gate->entered = true;
    while (!gate->release)
      std::this_thread::sleep_for(1ms);
  }
};
int main() {
  @autoreleasepool {
    try {
      auto owner = fs_macos_capture_owner();
      owner->session = std::make_shared<Session>(owner->revoked);
      std::weak_ptr<Session> session = owner->session;
      std::weak_ptr<Ring> ring = owner->session->ring;
      auto callbacks = owner->session->ring->callbacks;
      auto gate = std::make_shared<EndGate>();
      auto exit = std::make_unique<HeldExit>();
      exit->gate = gate;
      launchCaptureStartup(
          owner, owner->session,
          [exit = std::move(exit)](Session &) { return noErr; });
      until(
          [&] { return owner->session->ready.load() && gate->entered.load(); });
      fs_macos_capture_revoke(owner);
      auto closing = std::async(std::launch::async,
                                [&] { fs_macos_capture_close(owner); });
      const bool held = closing.wait_for(100ms) == std::future_status::timeout;
      gate->release = true;
      closing.get();
      const bool joinedByOwner = owner->startup.joined();
      if (!joinedByOwner)
        owner->startup.join(); // Failure-path fixture cleanup only.
      require(held && joinedByOwner && session.expired() && ring.expired(),
              "ready is not actual startup exit or private session cleanup");
      bool invoked = false;
      captureCallback(ring, callbacks, [&](Ring &) { invoked = true; });
      require(!invoked,
              "late callback cannot acquire private PCM after owner close");

      owner = fs_macos_capture_owner();
      owner->session = std::make_shared<Session>(owner->revoked);
      ring = owner->session->ring;
      callbacks = owner->session->ring->callbacks;
      std::atomic<bool> entered{false}, release{false};
      std::thread callback([&] {
        captureCallback(ring, callbacks, [&](Ring &pcm) {
          entered = true;
          while (!release)
            std::this_thread::sleep_for(1ms);
          pcm.samples[0] = 0.5f;
        });
      });
      until([&] { return entered.load(); });
      closing = std::async(std::launch::async,
                           [&] { fs_macos_capture_close(owner); });
      const bool callbackHeld =
          closing.wait_for(100ms) == std::future_status::timeout;
      release = true;
      callback.join();
      closing.get();
      require(callbackHeld && ring.expired(),
              "native close joins actual callback before PCM destruction");

      owner = fs_macos_capture_owner();
      owner->session = std::make_shared<Session>(owner->revoked);
      owner->session->failCloseForTesting = true;
      bool refused = false;
      try {
        fs_macos_capture_close(owner);
      } catch (...) {
        refused = true;
      }
      require(refused && owner->session,
              "failed platform cleanup retains original native owner");
      owner->session->failCloseForTesting = false;
      fs_macos_capture_close(owner);
      require(!owner->session, "explicit retry closes retained partial owner");

      owner = fs_macos_capture_owner();
      owner->session = std::make_shared<Session>(owner->revoked);
      launchCaptureStartup(owner, owner->session, [](Session &) -> OSStatus {
        throw std::bad_alloc{};
      });
      until([&] { return owner->session->ready.load(); });
      require(owner->session->startStatus == kAudioHardwareUnspecifiedError,
              "startup exception is published safely");
      fs_macos_capture_close(owner);
      require(!owner->session && owner->startup.joined(),
              "failed startup still joins and releases partial session");
      return 0;
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return 1;
    }
  }
}
