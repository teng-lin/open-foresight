#include "../../native/owned_capture_work.h"
#include <future>
#include <iostream>
#include <stdexcept>
using namespace std::chrono_literals;
void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
int main() {
  try {
    auto revoked = std::make_shared<std::atomic<bool>>(false);
    auto fence = std::make_shared<foresight::CallbackFence>(revoked);
    auto ring = std::make_shared<int>(7);
    std::weak_ptr<int> weak = ring;
    std::atomic<bool> entered{false}, release{false};
    foresight::CaptureStartup startup;
    startup.start([&] {
      auto lease = fence->enter();
      auto owned = weak.lock();
      entered = bool(lease) && bool(owned);
      while (!release)
        std::this_thread::sleep_for(1ms);
      // Drop actual PCM ownership before the callback lease is released.
    });
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (!entered && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(1ms);
    require(entered, "held callback entered");
    *revoked = true;
    require(!fence->enter(),
            "parent cancellation refuses late callback before PCM lookup");
    fence->revoke();
    auto closed = std::async(std::launch::async, [&] {
      fence->join();
      startup.join();
    });
    const bool pending = closed.wait_for(100ms) == std::future_status::timeout;
    release = true;
    closed.get();
    require(pending && startup.joined(),
            "close joins actual held startup and callback exit");
    ring.reset();
    require(weak.expired(), "final PCM owner released off callback after join");
    require(!fence->enter(),
            "late callback only retains inert fence, never PCM ring");
    std::atomic<bool> init_entered{false}, init_release{false},
        init_closed{false};
    startup.start([&] {
      init_entered = true;
      while (!init_release)
        std::this_thread::sleep_for(1ms);
      init_closed = true;
    });
    while (!init_entered)
      std::this_thread::sleep_for(1ms);
    auto joined = std::async(std::launch::async, [&] { startup.join(); });
    const bool waiting = joined.wait_for(100ms) == std::future_status::timeout;
    init_release = true;
    joined.get();
    require(waiting && init_closed && startup.joined(),
            "late startup cannot be mistaken for completed capture cleanup");
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
