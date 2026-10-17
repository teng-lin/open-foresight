#include "exception_barrier.h"
#include <iostream>
#include <stdexcept>
#include <thread>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

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
    std::cout << "exception barrier passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
