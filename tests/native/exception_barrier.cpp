#include "exception_barrier.h"
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <new>
#include <stdexcept>
#include <thread>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

namespace {
std::atomic<bool> fail_allocations{false};
struct FixedFailure : std::exception {
  const char *what() const noexcept override {
    return "long allocation-independent original worker failure: "
           "01234567890123456789";
  }
};
} // namespace
void *operator new(std::size_t size) {
  if (fail_allocations.load())
    throw std::bad_alloc();
  if (void *result = std::malloc(size ? size : 1))
    return result;
  throw std::bad_alloc();
}
void operator delete(void *value) noexcept {
  std::free(value);
}
void operator delete(void *value, std::size_t) noexcept {
  std::free(value);
}
void *operator new[](std::size_t size) {
  return ::operator new(size);
}
void operator delete[](void *value) noexcept {
  std::free(value);
}
void operator delete[](void *value, std::size_t) noexcept {
  std::free(value);
}

int main() {
  try {
    std::string reported;
    std::thread worker([&] {
      foresight::guarded_worker(
          [] { throw std::runtime_error("worker exploded"); },
          [&](const std::string &message) { reported = message; });
    });
    worker.join();
    REQUIRE(reported == "worker exploded");
    REQUIRE(foresight::last_barrier_error() == "worker exploded");

    const int status = foresight::ffi_barrier(
        []() -> int { throw std::runtime_error("ffi exploded"); }, -1);
    REQUIRE(status == -1);
    REQUIRE(foresight::last_barrier_error() == "ffi exploded");
    // The original two-argument reporting pattern can swallow the allocation
    // failure before reaching mandatory state. Retain it as a negative control.
    bool legacy_active = true;
    fail_allocations.store(true);
    foresight::guarded_worker(
        [] { throw FixedFailure{}; },
        [&](const std::string &) { legacy_active = false; });
    fail_allocations.store(false);
    REQUIRE(legacy_active);
    bool escaped = false;
    fail_allocations.store(true);
    try {
      for (int i = 0; i < 1000; ++i) {
        if (foresight::ffi_barrier([]() -> int { throw FixedFailure{}; }, -7) !=
            -7)
          std::abort();
        foresight::ffi_barrier_void([] { throw FixedFailure{}; });
        if (foresight::guarded_worker(
                [] { throw FixedFailure{}; },
                [](const std::string &) { throw FixedFailure{}; }))
          std::abort();
        bool active = true, finished = false, notified = false;
        int terminal_status = 0;
        if (foresight::guarded_worker(
                [] { throw FixedFailure{}; },
                [](const std::string &) { throw FixedFailure{}; },
                [&] {
                  active = false;
                  finished = true;
                  terminal_status = -1;
                  notified = true;
                }) ||
            active || !finished || terminal_status != -1 || !notified)
          std::abort();
        char message[128]{};
        if (!foresight::copy_barrier_error(message, sizeof(message)) ||
            std::strcmp(message, FixedFailure{}.what()) != 0)
          std::abort();
        // Error retrieval may need allocation; it must retain a safe fallback.
        if (!foresight::last_barrier_error().empty())
          std::abort();
      }
    } catch (...) {
      escaped = true;
    }
    fail_allocations.store(false);
    REQUIRE(!escaped);
    int reporter_calls = 0;
    for (int i = 0; i < 1000; ++i) {
      REQUIRE(!foresight::guarded_worker([] { throw FixedFailure{}; },
                                         [&](const std::string &) {
                                           ++reporter_calls;
                                           throw 43;
                                         }));
    }
    REQUIRE(reporter_calls == 1000);
    bool settled_before_report = false;
    REQUIRE(!foresight::guarded_worker([] { throw FixedFailure{}; },
                                       [&](const std::string &) {
                                         REQUIRE(settled_before_report);
                                         throw 43;
                                       },
                                       [&] { settled_before_report = true; }));
    REQUIRE(settled_before_report);
    // A blocked reporter never blocks or throws through another C boundary.
    auto &state = foresight::barrier_error_state();
    state.busy.test_and_set();
    REQUIRE(foresight::ffi_barrier([]() -> int { throw 42; }, -9) == -9);
    char unavailable[4] = {'x'};
    REQUIRE(foresight::copy_barrier_error(unavailable, sizeof(unavailable)) ==
            0);
    REQUIRE(unavailable[0] == '\0');
    state.busy.clear();
    REQUIRE(!foresight::guarded_worker([] { throw 42; },
                                       [](const std::string &) { throw 43; }));
    REQUIRE(foresight::last_barrier_error() == "unknown C++ exception");
    std::cout
        << "exception barrier passed: sustained allocation/reporter failure\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
