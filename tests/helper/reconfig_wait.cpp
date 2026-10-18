#include "reconfig_wait.h"
#include <atomic>
#include <future>
#include <stdexcept>

int main() {
  for (const bool expire : {false, true}) {
    std::mutex mutex;
    std::condition_variable changed;
    bool busy = true;
    std::atomic<bool> interrupted{false};
    std::promise<void> entered;
    auto work = std::async(std::launch::async, [&] {
      std::unique_lock lock(mutex);
      entered.set_value();
      return foresight::wait_for_reconfiguration(
          changed, lock, busy, [&] { return !expire && interrupted.load(); },
          [&] { return expire && interrupted.load(); });
    });
    entered.get_future().wait();
    interrupted = true;
    if (work.wait_for(std::chrono::milliseconds(200)) !=
        std::future_status::ready)
      throw std::runtime_error(
          "Reconfiguration wait ignored cancellation/deadline");
    const auto result = work.get();
    if (result != (expire ? foresight::ReconfigWait::deadline
                          : foresight::ReconfigWait::cancelled))
      return 1;
  }
}
