#include "diagnostic_queue_internal.h"

#include <atomic>
#include <cstddef>
#include <limits>
#include <time.h>
#include <type_traits>

namespace {
constexpr size_t general_capacity = 3000, priority_capacity = 1000;
constexpr uint64_t maximum_number = (uint64_t{1} << 53) - 1;

template <size_t N> struct Ring {
  fs_diagnostic_record records[N]{};
  uint32_t head = 0, count = 0;
  bool append(const fs_diagnostic_record &record) noexcept {
    if (count == N)
      return false;
    records[(head + count) % N] = record;
    ++count;
    return true;
  }
  const fs_diagnostic_record &front() const noexcept {
    return records[head];
  }
  fs_diagnostic_record pop() noexcept {
    const auto record = records[head];
    head = (head + 1) % N;
    --count;
    return record;
  }
};

struct Queue {
  std::atomic_flag gate = ATOMIC_FLAG_INIT;
  std::atomic<bool> precision_lost{false};
  std::atomic<foresight::diagnostics::Level> level{
      foresight::diagnostics::Level::off};
  Ring<general_capacity> general;
  Ring<priority_capacity> priority;
  uint64_t sequence = 0, next_token = 0, consumer = 0;
  uint64_t dropped_general = 0, dropped_priority = 0;
  bool counter_saturated = false;
};
static_assert(sizeof(fs_diagnostic_record) == 64);
static_assert(sizeof(fs_diagnostic_batch) == 32);
static_assert(sizeof(Queue) <= 256 * 1024);
static_assert(std::is_trivially_destructible_v<Queue>);
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<foresight::diagnostics::Level>::is_always_lock_free);
// Constant initialization, no allocator, lazy initializer, exit destructor or
// destroyed mutex. Storage survives every runtime handle and consumer session.
constinit Queue queue;

struct TryGuard {
  const bool acquired = !queue.gate.test_and_set(std::memory_order_acquire);
  ~TryGuard() {
    if (acquired)
      queue.gate.clear(std::memory_order_release);
  }
};

void drop(bool priority) noexcept {
  auto &count = priority ? queue.dropped_priority : queue.dropped_general;
  if (count == std::numeric_limits<uint64_t>::max())
    queue.counter_saturated = true;
  else
    ++count;
}

bool emit(fs_diagnostic_record record, bool priority,
          foresight::diagnostics::Level severity) noexcept {
  if (queue.level.load(std::memory_order_relaxed) < severity)
    return false;
  TryGuard guard;
  if (!guard.acquired) {
    // Exact counting would require a retry/CAS loop on the producer hot path.
    // Instead publish that the returned counters are only a lower bound.
    queue.precision_lost.store(true, std::memory_order_relaxed);
    return false;
  }
  if (queue.sequence == std::numeric_limits<uint64_t>::max()) {
    queue.counter_saturated = true;
    drop(priority);
    return false;
  }
  struct timespec time{};
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0 || time.tv_sec < 0 ||
      static_cast<uint64_t>(time.tv_sec) > maximum_number / 1000000) {
    drop(priority);
    return false;
  }
  record.sequence = queue.sequence + 1;
  record.monotonic_us = static_cast<uint64_t>(time.tv_sec) * 1000000 +
                        static_cast<uint64_t>(time.tv_nsec / 1000);
  if (record.monotonic_us > maximum_number) {
    drop(priority);
    return false;
  }
  const bool accepted =
      priority ? queue.priority.append(record) : queue.general.append(record);
  if (accepted)
    queue.sequence = record.sequence;
  else
    drop(priority);
  return accepted;
}
} // namespace

namespace foresight::diagnostics {
void configure(Level level) noexcept {
  if (level <= Level::trace)
    queue.level.store(level, std::memory_order_relaxed);
}

bool worker_failed(uint16_t category, uint16_t outcome, int32_t status,
                   int32_t signal, uint64_t bytes, uint64_t dropped) noexcept {
  if (category > 11 || outcome > 8 || bytes > maximum_number ||
      dropped > maximum_number)
    return false;
  fs_diagnostic_record record{};
  record.event = FS_DIAGNOSTIC_WORKER_FAILED;
  record.component = 5; // DiagnosticComponent.native
  record.category = category;
  record.outcome = outcome;
  record.status = status;
  record.signal = signal;
  record.bytes = bytes;
  record.dropped = dropped;
  return emit(record, true, Level::error);
}

bool capture_state(uint16_t category, uint16_t outcome, uint32_t queued,
                   bool active, uint64_t duration_us) noexcept {
  if (category > 11 || outcome > 8 || duration_us > maximum_number)
    return false;
  fs_diagnostic_record record{};
  record.event = FS_DIAGNOSTIC_CAPTURE_STATE;
  record.component = 6; // DiagnosticComponent.capture
  record.category = category;
  record.outcome = outcome;
  record.queued = queued;
  record.active = active;
  record.duration_us = duration_us;
  return emit(record, false, Level::info);
}
} // namespace foresight::diagnostics

extern "C" uint32_t fs_diagnostic_abi_version(void) {
  return FS_DIAGNOSTIC_ABI;
}

extern "C" int32_t fs_diagnostic_open(uint32_t abi_version,
                                      uint32_t record_size, uint64_t *token) {
  if (abi_version != FS_DIAGNOSTIC_ABI ||
      record_size != sizeof(fs_diagnostic_record) || token == nullptr)
    return FS_DIAGNOSTIC_INVALID;
  TryGuard guard;
  if (!guard.acquired)
    return FS_DIAGNOSTIC_BUSY;
  if (queue.consumer != 0 ||
      queue.next_token == std::numeric_limits<uint64_t>::max())
    return FS_DIAGNOSTIC_UNAVAILABLE;
  queue.consumer = ++queue.next_token;
  *token = queue.consumer;
  return FS_DIAGNOSTIC_OK;
}

extern "C" int32_t fs_diagnostic_drain(uint64_t token, uint32_t abi_version,
                                       uint32_t record_size,
                                       fs_diagnostic_record *records,
                                       uint32_t capacity, uint32_t flags,
                                       fs_diagnostic_batch *batch,
                                       uint32_t batch_size) {
  if (token == 0 || abi_version != FS_DIAGNOSTIC_ABI ||
      record_size != sizeof(fs_diagnostic_record) || records == nullptr ||
      capacity == 0 || capacity > 64 ||
      (flags & ~FS_DIAGNOSTIC_PRIORITY_ONLY) != 0 || batch == nullptr ||
      batch_size != sizeof(fs_diagnostic_batch))
    return FS_DIAGNOSTIC_INVALID;
  TryGuard guard;
  if (!guard.acquired)
    return FS_DIAGNOSTIC_BUSY;
  if (queue.consumer != token)
    return FS_DIAGNOSTIC_INVALID;
  fs_diagnostic_batch result{
      FS_DIAGNOSTIC_ABI,     sizeof(fs_diagnostic_batch), 0, 0,
      queue.dropped_general, queue.dropped_priority};
  while (result.count < capacity) {
    const bool normal =
        !(flags & FS_DIAGNOSTIC_PRIORITY_ONLY) && queue.general.count != 0;
    const bool priority = queue.priority.count != 0;
    if (!normal && !priority)
      break;
    if (priority && (!normal || queue.priority.front().sequence <
                                    queue.general.front().sequence))
      records[result.count++] = queue.priority.pop();
    else
      records[result.count++] = queue.general.pop();
  }
  if (queue.precision_lost.exchange(false, std::memory_order_relaxed))
    result.flags |= FS_DIAGNOSTIC_PRECISION_LOST;
  if (queue.counter_saturated)
    result.flags |= FS_DIAGNOSTIC_COUNTER_SATURATED;
  queue.dropped_general = queue.dropped_priority = 0;
  queue.counter_saturated = false;
  *batch = result;
  return FS_DIAGNOSTIC_OK;
}

extern "C" int32_t fs_diagnostic_close(uint64_t token) {
  if (token == 0)
    return FS_DIAGNOSTIC_INVALID;
  TryGuard guard;
  if (!guard.acquired)
    return FS_DIAGNOSTIC_BUSY;
  if (queue.consumer != token)
    return FS_DIAGNOSTIC_INVALID;
  queue.consumer = 0;
  return FS_DIAGNOSTIC_OK;
}
