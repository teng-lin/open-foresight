#pragma once
#include <exception>
#include <mutex>
#include <string>

namespace foresight {

inline std::mutex &barrier_mutex() {
  static std::mutex mu;
  return mu;
}
inline std::string &barrier_error_slot() {
  static std::string error;
  return error;
}
inline void report_barrier_error(const std::string &message) {
  std::lock_guard lock(barrier_mutex());
  barrier_error_slot() = message;
}
inline std::string last_barrier_error() {
  std::lock_guard lock(barrier_mutex());
  return barrier_error_slot();
}

// C ABI exports and worker threads must report a C++ exception and return.
// An uncaught exception calls std::terminate and aborts the host process.
template <class Fn, class Fallback>
auto ffi_barrier(Fn fn, Fallback fallback) -> decltype(fn()) {
  try {
    return fn();
  } catch (const std::exception &error) {
    report_barrier_error(error.what());
    return fallback;
  } catch (...) {
    report_barrier_error("unknown C++ exception");
    return fallback;
  }
}

template <class Fn> void ffi_barrier_void(Fn fn) {
  try {
    fn();
  } catch (const std::exception &error) {
    report_barrier_error(error.what());
  } catch (...) {
    report_barrier_error("unknown C++ exception");
  }
}

template <class Fn, class Report> bool guarded_worker(Fn fn, Report report) {
  try {
    fn();
    return true;
  } catch (const std::exception &error) {
    const std::string message = error.what();
    report_barrier_error(message);
    try {
      report(message);
    } catch (...) {
    }
    return false;
  } catch (...) {
    const std::string message = "unknown C++ exception";
    report_barrier_error(message);
    try {
      report(message);
    } catch (...) {
    }
    return false;
  }
}

} // namespace foresight
