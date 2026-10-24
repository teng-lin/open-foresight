#pragma once
#include "exception_barrier.h"
#include <array>
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
  enum class State {
    idle,
    queued,
    running,
    succeeded,
    failed,
    unconfirmed,
    discarded
  };
  enum class Result { succeeded, failed, unsettled };
  using Action = Result (*)(OwnedOperation &);
  const uint64_t token;
  const Action action;
  const size_t group;
  const uint64_t owner;
  bool releases_group = false, automatic_release = false;
  void *const context;
  std::atomic<State> state{State::idle};
  std::atomic<bool> boundary_failed{false};

  OwnedOperation(uint64_t identity, Action body, void *value,
                 size_t execution_group, uint64_t owner_identity)
      : token(identity), action(body), group(execution_group),
        owner(owner_identity), context(value) {}

  bool terminal() const noexcept {
    const auto value = state.load(std::memory_order_acquire);
    return value == State::succeeded || value == State::failed;
  }
  void wait() {
    std::unique_lock lock(completion_mutex_);
    completion_changed_.wait(lock, [&] {
      return terminal() ||
             state.load(std::memory_order_acquire) == State::unconfirmed;
    });
  }

private:
  friend class OwnedOperations;
  // The executor publishes only after the action and retained resource/lease
  // destruction, never before a worker/isolate acknowledgement.
  void complete(State result) noexcept {
    // Publication itself cannot fail or depend on a secondary reporter/lock.
    // The mutex only makes the legacy blocking wait's notification race safe.
    state.store(result, std::memory_order_release);
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
  static constexpr size_t max_owner_groups = 32;
  explicit OwnedOperations(std::size_t capacity = 4096,
                           bool default_executor = true)
      : capacity_(capacity) {
    groups_[0].reserved = true;
    if (default_executor)
      groups_[0].worker = std::thread([this] { run(0); });
  }
  OwnedOperations(const OwnedOperations &) = delete;
  OwnedOperations &operator=(const OwnedOperations &) = delete;
  ~OwnedOperations() noexcept {
    shutdown();
  }
  void shutdown() noexcept {
    {
      std::lock_guard admission(groups_mutex_);
      stopping_ = true;
      for (auto &group : groups_) {
        {
          std::lock_guard lock(group.mutex);
          group.stopping = true;
        }
        group.changed.notify_all();
      }
    }
    for (auto &group : groups_)
      if (group.worker.joinable())
        group.worker.join();
  }
  // Each admitted owner gets an independent execution group. Idle workers hold
  // no resource/model/profile lease. Admission cannot wait behind another
  // owner.
  size_t reserve_group() {
    std::lock_guard lock(groups_mutex_);
    if (stopping_)
      throw std::runtime_error("Native executor closed");
    for (size_t id = 1; id < groups_.size(); ++id) {
      auto &group = groups_[id];
      if (group.reserved)
        continue;
      if (!group.worker.joinable())
        group.worker = std::thread([this, id] { run(id); });
      group.reserved = true;
      return id;
    }
    throw std::length_error("Native owner capacity exhausted");
  }
  void release_group(size_t id) {
    if (!id)
      return;
    std::lock_guard lock(groups_mutex_);
    groups_[id].reserved = false;
  }

  std::shared_ptr<OwnedOperation> create(OwnedOperation::Action action,
                                         void *context, size_t group = 0,
                                         uint64_t owner = 0) {
    if (!group) {
      std::lock_guard admission(groups_mutex_);
      if (stopping_)
        throw std::runtime_error("Native executor closed");
      if (!groups_[0].worker.joinable())
        groups_[0].worker = std::thread([this] { run(0); });
    }
    std::lock_guard lock(registry_mutex_);
    if (operations_.size() >= capacity_)
      throw std::length_error("Native operation capacity exhausted");
    if (next_token_ >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
      throw std::overflow_error("Native operation identity exhausted");
    auto operation = std::make_shared<OwnedOperation>(next_token_++, action,
                                                      context, group, owner);
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
    auto idle = OwnedOperation::State::idle;
    if (!operation->state.compare_exchange_strong(
            idle, OwnedOperation::State::discarded, std::memory_order_acq_rel))
      return false;
    return operations_.erase(operation->token) != 0;
  }

  bool submit(const std::shared_ptr<OwnedOperation> &operation,
              std::shared_ptr<void> resource) {
    if (!operation)
      return false;
    auto &group = groups_[operation->group];
    std::lock_guard lock(group.mutex);
    auto expected = operation->state.load(std::memory_order_acquire);
    if (group.stopping ||
        (expected != OwnedOperation::State::idle &&
         expected != OwnedOperation::State::unconfirmed) ||
        !operation->state.compare_exchange_strong(
            expected, OwnedOperation::State::queued, std::memory_order_acq_rel))
      return false;
    operation->resource_ = std::move(resource);
    operation->queued_reference_ = operation;
    if (group.tail)
      group.tail->next_ = operation.get();
    else
      group.head = operation.get();
    group.tail = operation.get();
    group.changed.notify_one();
    return true;
  }

  // 0 pending, 1 completed successfully, 2 completed with a known error,
  // 3 retained-unconfirmed, -1 unknown/released. Neither acknowledgement loss
  // nor a reporter failure changes this state or permits releasing an in-flight
  // resource.
  int status(uint64_t token) {
    std::lock_guard lock(registry_mutex_);
    const auto found = operations_.find(token);
    if (found == operations_.end())
      return -1;
    const auto state = found->second->state.load(std::memory_order_acquire);
    return state == OwnedOperation::State::succeeded     ? 1
           : state == OwnedOperation::State::failed      ? 2
           : state == OwnedOperation::State::unconfirmed ? 3
                                                         : 0;
  }

  bool release(uint64_t token) {
    std::lock_guard lock(registry_mutex_);
    const auto found = operations_.find(token);
    if (found == operations_.end() || !found->second->terminal() ||
        found->second->releases_group)
      return false;
    operations_.erase(found);
    return true;
  }

  bool release_owner(uint64_t owner, uint64_t retirement,
                     bool discard_results = false) {
    std::lock_guard lock(registry_mutex_);
    const auto retired = operations_.find(retirement);
    if (!owner || retired == operations_.end() ||
        retired->second->owner != owner ||
        retired->second->state != OwnedOperation::State::succeeded)
      return false;
    for (const auto &[token, operation] : operations_) {
      if (operation->owner != owner)
        continue;
      const auto state = operation->state.load();
      if (state == OwnedOperation::State::queued ||
          state == OwnedOperation::State::running)
        return false;
    }
    for (auto it = operations_.begin(); it != operations_.end();) {
      const auto &operation = it->second;
      if (operation->owner != owner) {
        ++it;
        continue;
      }
      auto state = operation->state.load();
      if (discard_results || it->first == retirement ||
          state == OwnedOperation::State::idle ||
          state == OwnedOperation::State::discarded) {
        it = operations_.erase(it);
        continue;
      }
      // Physical retirement is now confirmed, even if a prior operation was
      // unconfirmed. Its subscriber still owns the result/acknowledgement.
      if (state == OwnedOperation::State::unconfirmed) {
        operation->resource_.reset();
        operation->complete(OwnedOperation::State::failed);
      }
      ++it;
    }
    return true;
  }

private:
  void run(size_t id) noexcept {
    auto &group = groups_[id];
    for (;;) {
      std::shared_ptr<OwnedOperation> operation;
      {
        std::unique_lock lock(group.mutex);
        group.changed.wait(lock, [&] { return group.stopping || group.head; });
        if (!group.head && group.stopping)
          return;
        auto *next = group.head;
        group.head = next->next_;
        if (!group.head)
          group.tail = nullptr;
        next->next_ = nullptr;
        operation = std::move(next->queued_reference_);
        operation->state.store(OwnedOperation::State::running,
                               std::memory_order_release);
      }
      auto result = OwnedOperation::Result::unsettled;
      try {
        result = operation->action(*operation);
      } catch (const std::exception &error) {
        operation->boundary_failed.store(true, std::memory_order_release);
        operation->complete(OwnedOperation::State::unconfirmed);
        report_barrier_error(error.what());
        continue;
      } catch (...) {
        operation->boundary_failed.store(true, std::memory_order_release);
        operation->complete(OwnedOperation::State::unconfirmed);
        report_barrier_error("Native cleanup unconfirmed");
        continue;
      }
      if (result == OwnedOperation::Result::unsettled) {
        operation->boundary_failed.store(true, std::memory_order_release);
        // Keep unconfirmed ownership after an unexpected cleanup exception.
        // A reporter/fallback cannot turn it into a completed/releasable token.
        operation->complete(OwnedOperation::State::unconfirmed);
        continue;
      }
      operation->resource_.reset();
      const bool release = operation->releases_group &&
                           result == OwnedOperation::Result::succeeded;
      // The execution group is idle and has no physical authority before it is
      // reusable. Completion metadata may outlive the actual resource.
      if (release)
        release_group(id);
      operation->complete(result == OwnedOperation::Result::succeeded
                              ? OwnedOperation::State::succeeded
                              : OwnedOperation::State::failed);
      if (operation->automatic_release &&
          result == OwnedOperation::Result::succeeded)
        ffi_barrier_void(
            [&] { release_owner(operation->owner, operation->token, true); });
    }
  }

  std::mutex registry_mutex_;
  const std::size_t capacity_;
  std::unordered_map<uint64_t, std::shared_ptr<OwnedOperation>> operations_;
  uint64_t next_token_ = 1;
  struct Group {
    std::mutex mutex;
    std::condition_variable changed;
    OwnedOperation *head = nullptr, *tail = nullptr;
    bool stopping = false, reserved = false;
    std::thread worker;
  };
  std::mutex groups_mutex_;
  bool stopping_ = false;
  std::array<Group, max_owner_groups + 1> groups_;
};

} // namespace foresight
