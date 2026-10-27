#define FORESIGHT_ENABLE_TEST_HOOKS 1
#include "../../native/foresight_native.cpp"
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
      for (bool finish : {false, true}) {
        auto capture = std::make_unique<Capture>();
        capture->macos = fs_macos_capture_owner();
        auto *raw = publish_native(std::move(capture), NativeKind::capture);
        auto retained = native_handles().handles.at(raw);
        auto mac = raw->macos;
        mac->session = std::make_shared<Session>(mac->revoked);
        std::weak_ptr<Session> private_session = mac->session;
        auto pending = std::make_shared<EndGate>();
        launchCaptureStartup(mac, mac->session, [pending](Session &) {
          pending->entered = true;
          while (!pending->release)
            std::this_thread::sleep_for(1ms);
          return noErr;
        });
        until([&] { return pending->entered.load(); });
        auto request = std::async(std::launch::async, [&] {
          if (finish)
            fs_capture_finish(raw);
          else
            fs_capture_stop(raw);
        });
        const bool prompt = request.wait_for(1s) == std::future_status::ready;
        if (!prompt)
          pending->release =
              true; // Failure-path fixture cleanup, not a production timeout.
        request.get();
        require(prompt && !private_session.expired(),
                "legacy capture returns promptly retaining held startup");
        if (finish)
          fs_capture_stop(raw);
        require(bool(retained->object),
                "quarantine retains original capture until "
                "actual initialization settles");
        pending->release = true;
        until([&] {
          return retained->private_operations->status(retained->retire) == -1;
        });
        require(!retained->object && private_session.expired() &&
                    mac->startup.joined(),
                "legacy quarantine actually joins and destroys late startup "
                "and private session");
      }
      {
        auto capture = std::make_unique<Capture>();
        capture->macos = fs_macos_capture_owner();
        auto *raw = publish_native(std::move(capture), NativeKind::capture);
        auto retained = native_handles().handles.at(raw);
        raw->macos->session = std::make_shared<Session>(raw->macos->revoked);
        std::weak_ptr<Session> physical = raw->macos->session;
        raw->emit("ready-final-pcm");
        fs_capture_finish(raw);
        require(physical.expired(), "ready legacy finish completes actual "
                                    "session cleanup synchronously");
        char *frame = fs_event_poll(raw, 0);
        require(frame && std::string(frame) == "ready-final-pcm",
                "ready legacy finish preserves final PCM before return");
        fs_string_free(frame);
        fs_capture_stop(raw);
        require(
            !retained->object &&
                retained->private_operations->status(retained->retire) == -1,
            "ready legacy stop completes release without quarantine metadata");
      }
      {
        // Lost v2 acknowledgements cannot consume legacy quarantine capacity.
        auto &owned = native_handles().operations;
        std::vector<uint64_t> abandoned;
        for (size_t n = 0; n < 4096; ++n) {
          auto op = owned.create(
              [](NativeOperation &) {
                return NativeOperation::Result::succeeded;
              },
              nullptr);
          require(owned.submit(op, nullptr),
                  "fill independent v2 completion budget");
          abandoned.push_back(op->token);
        }
        std::vector<Capture *> legacy;
        for (size_t n = 0; n < 32; ++n) {
          auto capture = std::make_unique<Capture>();
          capture->macos = fs_macos_capture_owner();
          legacy.push_back(
              publish_native(std::move(capture), NativeKind::capture));
        }
        const auto handles = native_handles().handles.size();
        require(!fs_capture_start("auto", 0, 48000) &&
                    native_handles().handles.size() == handles,
                "33rd legacy capture refuses before physical work at its "
                "independent bound");
        for (auto *capture : legacy)
          fs_capture_stop(capture);
        for (auto token : abandoned) {
          until([&] { return owned.status(token) == 1; });
          require(owned.release(token), "acknowledge controlled v2 budget");
        }
        require(native_handles().handles.empty(),
                "all controlled legacy captures released");
      }
      return 0;
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return 1;
    }
  }
}
