#pragma once
#include <chrono>
#include <condition_variable>
#include <mutex>

namespace foresight {
enum class ReconfigWait { ready, cancelled, deadline, busy_timeout };
template <class Cancelled, class Expired>
ReconfigWait wait_for_reconfiguration(
    std::condition_variable &changed, std::unique_lock<std::mutex> &lock,
    const bool &busy, Cancelled cancelled, Expired expired,
    std::chrono::milliseconds maximum_wait = std::chrono::seconds(30)) {
  const auto maximum = std::chrono::steady_clock::now() + maximum_wait;
  for (;;) {
    if (expired())
      return ReconfigWait::deadline;
    if (cancelled())
      return ReconfigWait::cancelled;
    if (!busy)
      return ReconfigWait::ready;
    if (std::chrono::steady_clock::now() >= maximum)
      return ReconfigWait::busy_timeout;
    changed.wait_for(lock, std::chrono::milliseconds(25));
  }
}
} // namespace foresight
