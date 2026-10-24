#pragma once
#include "exception_barrier.h"
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <unordered_map>

namespace foresight {

// The token owns completion independently of the initiating caller/isolate.
// Registry/allocation and executor startup happen before publishing a resource;
// submitting its preallocated node cannot allocate another close request.
class OwnedOperation {
public:
  enum class State { idle, queued, running, succeeded, failed };
  enum class Result { succeeded, failed, unsettled };
  using Action = Result (*)(OwnedOperation &);
  const uint64_t token;
  const Action action;
  void *const context;
  std::atomic<State> state{State::idle};
  std::atomic<bool> boundary_failed{false};

  OwnedOperation(uint64_t identity, Action body, void *value)
      : token(identity), action(body), context(value) {}

  bool terminal() const noexcept {
    const auto value = state.load(std::memory_order_acquire);
    return value == State::succeeded || value == State::failed;
  }
  void wait() {
    std::unique_lock lock(completion_mutex_);
    completion_changed_.wait(lock, [&] { return terminal(); });
  }

private:
  friend class OwnedOperations;
  // The executor publishes only after the action and retained resource/lease
  // destruction, never before a worker/isolate acknowledgement.
  void complete(bool success) noexcept {
    // Publication itself cannot fail or depend on a secondary reporter/lock.
    // The mutex only makes the legacy blocking wait's notification race safe.
    state.store(success ? State::succeeded : State::failed,
                std::memory_order_release);
    ffi_barrier_void([&] {
      std::lock_guard lock(completion_mutex_);
      completion_changed_.notify_all();
    });
  }

  std::shared_ptr<OwnedOperation> queued_reference_;
  std::shared_ptr<void> resource_;
  OwnedOperation *next_ = nullptr;
  std::mutex completion_mutex_;
  std::condition_variable completion_changed_;
};

class OwnedOperations {
public:
  // A lost acknowledgement retains its token, never an unbounded completion
  // history. Refuse new admission at capacity rather than evicting an owner or
  // making a still-observable completion ambiguous.
  explicit OwnedOperations(std::size_t capacity = 4096)
      : capacity_(capacity), worker_([this] { run(); }) {}
  OwnedOperations(const OwnedOperations &) = delete;
  OwnedOperations &operator=(const OwnedOperations &) = delete;
  ~OwnedOperations() noexcept {
    shutdown();
  }
  void shutdown() noexcept {
    {
      std::lock_guard lock(queue_mutex_);
      stopping_ = true;
    }
    changed_.notify_all();
    if (worker_.joinable())
      worker_.join();
  }

  std::shared_ptr<OwnedOperation> create(OwnedOperation::Action action,
                                         void *context) {
    std::lock_guard lock(registry_mutex_);
    if (operations_.size() >= capacity_)
      throw std::length_error("Native operation capacity exhausted");
    if (next_token_ >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
      throw std::overflow_error("Native operation identity exhausted");
    auto operation =
        std::make_shared<OwnedOperation>(next_token_++, action, context);
    operations_.emplace(operation->token, operation);
    return operation;
  }

  std::shared_ptr<OwnedOperation> find(uint64_t token) {
    std::lock_guard lock(registry_mutex_);
    const auto found = operations_.find(token);
    return found == operations_.end() ? nullptr : found->second;
  }

  // Cancel a never-submitted node during unpublished-resource rollback only.
  bool discard(const std::shared_ptr<OwnedOperation> &operation) {
    std::lock_guard lock(registry_mutex_);
    if (operation->state.load(std::memory_order_acquire) !=
        OwnedOperation::State::idle)
      return false;
    return operations_.erase(operation->token) != 0;
  }

  bool submit(const std::shared_ptr<OwnedOperation> &operation,
              std::shared_ptr<void> resource) {
    std::lock_guard lock(queue_mutex_);
    auto expected = OwnedOperation::State::idle;
    if (stopping_ ||
        !operation->state.compare_exchange_strong(
            expected, OwnedOperation::State::queued, std::memory_order_acq_rel))
      return false;
    operation->resource_ = std::move(resource);
    operation->queued_reference_ = operation;
    if (tail_)
      tail_->next_ = operation.get();
    else
      head_ = operation.get();
    tail_ = operation.get();
    changed_.notify_one();
    return true;
  }

  // 0 pending, 1 completed successfully, 2 completed with a known error,
  // -1 unknown/released. Neither acknowledgement loss nor a reporter failure
  // changes this state or permits releasing an in-flight resource.
  int status(uint64_t token) {
    std::lock_guard lock(registry_mutex_);
    const auto found = operations_.find(token);
    if (found == operations_.end())
      return -1;
    const auto state = found->second->state.load(std::memory_order_acquire);
    return state == OwnedOperation::State::succeeded ? 1
           : state == OwnedOperation::State::failed  ? 2
                                                     : 0;
  }

  bool release(uint64_t token) {
    std::lock_guard lock(registry_mutex_);
    const auto found = operations_.find(token);
    if (found == operations_.end() || !found->second->terminal())
      return false;
    operations_.erase(found);
    return true;
  }

private:
  void run() noexcept {
    for (;;) {
      std::shared_ptr<OwnedOperation> operation;
      {
        std::unique_lock lock(queue_mutex_);
        changed_.wait(lock, [&] { return stopping_ || head_; });
        if (!head_ && stopping_)
          return;
        auto *next = head_;
        head_ = next->next_;
        if (!head_)
          tail_ = nullptr;
        next->next_ = nullptr;
        operation = std::move(next->queued_reference_);
        operation->state.store(OwnedOperation::State::running,
                               std::memory_order_release);
      }
      const auto result =
          ffi_barrier([&] { return operation->action(*operation); },
                      OwnedOperation::Result::unsettled);
      if (result == OwnedOperation::Result::unsettled) {
        operation->boundary_failed.store(true, std::memory_order_release);
        // Keep unconfirmed ownership after an unexpected cleanup exception.
        // A reporter/fallback cannot turn it into a completed/releasable token.
        continue;
      }
      operation->resource_.reset();
      operation->complete(result == OwnedOperation::Result::succeeded);
    }
  }

  std::mutex registry_mutex_;
  const std::size_t capacity_;
  std::unordered_map<uint64_t, std::shared_ptr<OwnedOperation>> operations_;
  uint64_t next_token_ = 1;
  std::mutex queue_mutex_;
  std::condition_variable changed_;
  OwnedOperation *head_ = nullptr, *tail_ = nullptr;
  bool stopping_ = false;
  std::thread worker_;
};

} // namespace foresight
