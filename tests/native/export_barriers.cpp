#include <atomic>
#include <cstdlib>
#include <exception>
#include <new>
namespace {
std::atomic<int> allocation_failure_mode{0};
std::atomic<long> remaining{-1};
struct StandardFailure : std::exception {
  const char *what() const noexcept override {
    return "fixture standard failure";
  }
};
} // namespace
void *operator new(std::size_t size) {
  const auto left = remaining.load();
  if (left >= 0 && remaining.fetch_sub(1) == 0) {
    switch (allocation_failure_mode.load()) {
    case 1:
      throw StandardFailure{};
    case 2:
      throw 42;
    default:
      throw std::bad_alloc{};
    }
  }
  if (void *value = std::malloc(size ? size : 1))
    return value;
  throw std::bad_alloc{};
}
void operator delete(void *value) noexcept {
  std::free(value);
}
void operator delete(void *value, std::size_t) noexcept {
  std::free(value);
}
#include "../../native/foresight_native.cpp"
#include <iostream>

int main(int argc, char **argv) {
  (void)argc;
  // Establish the library-owned executor before sweeping unpublished resource
  // allocations, so asynchronous thread startup is a separate prerequisite.
  auto *initial = fs_engine_create(argv[0], "/dev/null");
  if (!initial || fs_engine_destroy(initial) != 0)
    return 1;
  for (int kind : {0, 1}) {
    bool reached_success = false;
    for (long position = 0; position < 80; ++position) {
      const auto handles = native_handles().handles.size();
      const auto polls = poll_registry.size();
      remaining = position;
      void *resource = kind == 0 ? fs_engine_create(argv[0], "/dev/null")
                                 : fs_speech_create(argv[0], "/dev/null");
      remaining = -1;
      if (resource) {
        if (kind == 0) {
          if (fs_engine_destroy(resource) != 0)
            return 2;
        } else
          fs_speech_destroy(resource);
        reached_success = true;
      }
      if (native_handles().handles.size() != handles ||
          poll_registry.size() != polls)
        return 3;
      if (reached_success)
        break;
    }
    if (!reached_success)
      return 4;
  }
  auto *engine = fs_engine_create(argv[0], "/dev/null");
  if (!engine)
    return 5;
  // Exercise the actual exported boundary with allocation, standard and unknown
  // exceptions, including an already-busy bounded reporter. Never allocate the
  // injected exception or a secondary diagnostic while handling the failure.
  for (int mode : {0, 1, 2}) {
    allocation_failure_mode = mode;
    auto &reporter = foresight::barrier_error_state();
    reporter.busy.test_and_set(std::memory_order_acquire);
    remaining = 0;
    char *state = fs_engine_state(engine);
    remaining = -1;
    reporter.busy.clear(std::memory_order_release);
    if (state) {
      fs_string_free(state);
      return 6;
    }
    auto *normal = fs_engine_state(engine);
    if (!normal)
      return 7;
    fs_string_free(normal);
  }
  remaining = 0;
  const auto retired = fs_engine_retire(engine);
  // No allocation, including successful reporting, is needed to request
  // retirement or retain its completion independently of this caller.
  const bool allocated = remaining.load() != 0;
  remaining = -1;
  if (!retired || allocated)
    return 8;
  await_native_operation(retired);
  return 0;
}
