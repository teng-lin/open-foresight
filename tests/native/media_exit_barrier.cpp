#include "media_exit_barrier.h"
#include <cerrno>
#include <sys/wait.h>

extern "C" int media_exit_barrier_waitid(idtype_t type, id_t id,
                                         siginfo_t *info, int flags) {
  static unsigned observations = 0;
  if (type != P_PID || !(flags & WNOWAIT))
    return waitid(type, id, info, flags);
  auto path = media_exit_input_path();
  auto mode = media_exit_mode(path);
  ++observations;
  if (observations == 1 && mode == "overflow") {
    // The child cannot exit. Let the next real production drain consume the
    // exact-limit prefix, then release its final overflow byte on observation2.
    media_exit_wait(path + ".prelude");
    return waitid(type, id, info, flags);
  }
  if (observations == (mode == "overflow" ? 2U : 1U)) {
    media_exit_publish(path + ".exit-release", "released");
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    int result;
    do {
      result = waitid(type, id, info, flags);
      if (result || info->si_pid == static_cast<pid_t>(id))
        break;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (std::chrono::steady_clock::now() < end);
    if (result || info->si_pid != static_cast<pid_t>(id))
      _exit(95);
    media_exit_publish(path + ".exit-observed", std::to_string(info->si_pid));
    return result;
  }
  return waitid(type, id, info, flags);
}
