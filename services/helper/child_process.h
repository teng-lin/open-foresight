#pragma once
#include "../../native/portable_process.h"
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <fcntl.h>
#include <future>
#include <memory>
#include <mutex>
#include <signal.h>
#include <spawn.h>
#include <stdexcept>
#include <string>
extern char **environ;
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

// The supervisor owns the adapter's process group and watches a liveness pipe.
// Keep its owning thread alive until the supervisor has reaped the adapter.
class ChildProcess {
  std::thread creator_;
  std::mutex mutex_;
  std::condition_variable condition_;
  bool stopping_ = false;
  std::atomic<pid_t> pid_{-1};
  std::atomic<bool> alive_{false};

public:
  ChildProcess(std::string executable, std::string mode, std::string model,
               int input, int output, std::string option = {}) {
    auto started = std::make_shared<std::promise<pid_t>>();
    auto result = started->get_future();
    creator_ = std::thread([this, started, input, output,
                            executable = std::move(executable),
                            mode = std::move(mode), model = std::move(model),
                            option = std::move(option)]() mutable {
      try {
        std::unique_lock launch(foresight::launch_mutex);
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                         O_WRONLY, 0);
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        short flags = POSIX_SPAWN_SETPGROUP;
#ifdef __APPLE__
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
        posix_spawnattr_setflags(&attr, flags);
        posix_spawnattr_setpgroup(&attr, 0);
        std::vector<std::string> args{executable, mode, model};
        if (!option.empty())
          args.push_back(option);
        pid_t child = -1;
        foresight::OwnedSpawn owned;
        const int error = owned.spawn(&child, &actions, &attr, args);
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attr);
        if (error)
          child = -1;
        pid_.store(child > 0 ? owned.worker : -1);
        launch.unlock();
        alive_.store(child > 0);
        started->set_value(child);
        std::unique_lock lock(mutex_);
        while (!stopping_) {
          condition_.wait_for(lock, std::chrono::milliseconds(50),
                              [this] { return stopping_; });
          if (child > 0) {
            const auto ended = waitpid(child, nullptr, WNOHANG);
            if (ended == child || (ended < 0 && errno == ECHILD)) {
              child = -1;
              pid_.store(-1);
              alive_.store(false);
            }
          }
        }
        owned.stop();
        // The supervisor owns worker reaping and exits after bounded cleanup.
        if (child > 0)
          while (waitpid(child, nullptr, 0) < 0 && errno == EINTR) {
          }
        pid_.store(-1);
        alive_.store(false);
      } catch (...) {
        try {
          started->set_value(-1);
        } catch (...) {
        }
      }
    });
    if (result.get() < 0) {
      stop();
      throw std::runtime_error("Cannot start embedding adapter");
    }
  }
  ChildProcess(const ChildProcess &) = delete;
  ChildProcess &operator=(const ChildProcess &) = delete;
  ~ChildProcess() { stop(); }
  void stop() {
    {
      std::lock_guard lock(mutex_);
      stopping_ = true;
    }
    condition_.notify_all();
    if (creator_.joinable())
      creator_.join();
  }
  bool alive() const { return alive_.load(); }
  pid_t pid() const { return pid_.load(); }
};
