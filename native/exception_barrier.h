#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <exception>
#include <string>
#include <type_traits>
#include <utility>

namespace foresight {

// Error reporting is itself an exception boundary: no allocation, mutex wait,
// static destructor, or callback is needed to retain a bounded fallback.
struct BarrierErrorState {
  std::atomic_flag busy = ATOMIC_FLAG_INIT;
  std::array<char, 1024> message{};
};
inline BarrierErrorState &barrier_error_state() noexcept {
  static BarrierErrorState state;
  return state;
}
inline void report_barrier_error(const char *message) noexcept {
  auto &state = barrier_error_state();
  if (state.busy.test_and_set(std::memory_order_acquire))
    return;
  std::size_t count = 0;
  if (message) {
    while (count + 1 < state.message.size() && message[count]) {
      state.message[count] = message[count];
      ++count;
    }
  }
  state.message[count] = '\0';
  state.busy.clear(std::memory_order_release);
}
inline void report_barrier_error(const std::string &message) noexcept {
  report_barrier_error(message.c_str());
}
// Allocation failure in this compatibility API yields an empty string. Callers
// needing an allocation-independent result can use copy_barrier_error instead.
inline std::size_t copy_barrier_error(char *output,
                                      std::size_t capacity) noexcept {
  if (!output || capacity == 0)
    return 0;
  auto &state = barrier_error_state();
  if (state.busy.test_and_set(std::memory_order_acquire)) {
    output[0] = '\0';
    return 0;
  }
  std::size_t count = 0;
  while (count + 1 < capacity && state.message[count]) {
    output[count] = state.message[count];
    ++count;
  }
  output[count] = '\0';
  state.busy.clear(std::memory_order_release);
  return count;
}
inline std::string last_barrier_error() noexcept {
  std::array<char, 1024> message{};
  const auto size = copy_barrier_error(message.data(), message.size());
  try {
    return std::string(message.data(), size);
  } catch (...) {
    return {};
  }
}

template <class Fn> class ScopeExit {
  Fn cleanup_;
  bool active_ = true;

public:
  explicit ScopeExit(Fn cleanup) : cleanup_(std::move(cleanup)) {}
  ScopeExit(const ScopeExit &) = delete;
  ~ScopeExit() noexcept {
    if (active_) {
      try {
        cleanup_();
      } catch (...) {
      }
    }
  }
  void release() noexcept {
    active_ = false;
  }
};

template <class Fn, class Fallback>
auto ffi_barrier(Fn fn, Fallback fallback) noexcept -> decltype(fn()) {
  static_assert(std::is_nothrow_convertible_v<Fallback, decltype(fn())>,
                "A C ABI fallback must not allocate or throw");
  try {
    return fn();
  } catch (const std::exception &error) {
    report_barrier_error(error.what());
  } catch (...) {
    report_barrier_error("unknown C++ exception");
  }
  return fallback;
}

template <class Fn> void ffi_barrier_void(Fn fn) noexcept {
  try {
    fn();
  } catch (const std::exception &error) {
    report_barrier_error(error.what());
  } catch (...) {
    report_barrier_error("unknown C++ exception");
  }
}

template <class Report>
void report_worker_failure(const char *message, Report &report) noexcept {
  report_barrier_error(message);
  // The callback's legacy string and all reporter work belong inside this try.
  // Sustained bad_alloc must not escape while handling the original exception.
  try {
    report(std::string(message));
  } catch (...) {
  }
}

template <class Fn, class Report>
bool guarded_worker(Fn fn, Report report) noexcept {
  try {
    fn();
    return true;
  } catch (const std::exception &error) {
    report_worker_failure(error.what(), report);
  } catch (...) {
    report_worker_failure("unknown C++ exception", report);
  }
  return false;
}

} // namespace foresight
