#pragma once
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <thread>
#include <utility>
namespace foresight {
// Realtime callbacks acquire this fence before locking a weak PCM ring. Closing
// joins those acquisitions; rejected late callbacks hold no private PCM owner.
class CallbackFence {
  static constexpr uint32_t closed = uint32_t{1} << 31;
  std::atomic<uint32_t> state_{0};
  const std::shared_ptr<std::atomic<bool>> revoked_;

public:
  static_assert(std::atomic<uint32_t>::is_always_lock_free);
  explicit CallbackFence(std::shared_ptr<std::atomic<bool>> revoked = {})
      : revoked_(std::move(revoked)) {}
  class Lease {
    CallbackFence *owner_;

  public:
    explicit Lease(CallbackFence *owner) noexcept : owner_(owner) {}
    Lease(const Lease &) = delete;
    Lease(Lease &&other) noexcept
        : owner_(std::exchange(other.owner_, nullptr)) {}
    ~Lease() {
      if (owner_)
        owner_->state_.fetch_sub(1, std::memory_order_release);
    }
    explicit operator bool() const noexcept {
      return owner_ != nullptr;
    }
  };
  Lease enter() noexcept {
    if (revoked_ && revoked_->load(std::memory_order_acquire))
      return Lease(nullptr);
    auto value = state_.load(std::memory_order_acquire);
    while (!(value & closed) && value != closed - 1) {
      if (state_.compare_exchange_weak(value, value + 1,
                                       std::memory_order_acq_rel)) {
        if (revoked_ && revoked_->load(std::memory_order_acquire)) {
          state_.fetch_sub(1, std::memory_order_release);
          return Lease(nullptr);
        }
        return Lease(this);
      }
    }
    return Lease(nullptr);
  }
  void revoke() noexcept {
    state_.fetch_or(closed, std::memory_order_acq_rel);
  }
  void join() {
    while (state_.load(std::memory_order_acquire) & ~closed)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
};
// The native capture owns this member, never a detached stack-local startup.
// Join failure leaves the thread in the retained owner for explicit retry.
class CaptureStartup {
  std::thread thread_;

public:
  template <class Fn> void start(Fn run) {
    join();
    thread_ = std::thread(std::move(run));
  }
  void join() {
    if (thread_.joinable())
      thread_.join();
  }
  bool joined() const noexcept {
    return !thread_.joinable();
  }
  ~CaptureStartup() {
    if (thread_.joinable())
      std::terminate();
  }
};
} // namespace foresight
