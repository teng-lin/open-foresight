#pragma once
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <fcntl.h>
#include <future>
#include <memory>
#include <mutex>
#include <signal.h>
#include <stdexcept>
#include <string>
#include "../../native/portable_process.h"
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include <spawn.h>
extern char **environ;
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

// Linux's parent-death signal belongs to the *creating thread*, not just
// its process. Keep that thread alive until the owned adapter has been reaped.
// In particular, a retired gRPC request thread must not terminate the model.
class ChildProcess {
  std::thread creator_;
  std::mutex mutex_;
  std::condition_variable condition_;
  bool stopping_ = false;
  std::atomic<pid_t> pid_{-1};
  std::atomic<bool> alive_{false};

  static void terminate(pid_t child) {
    if (child <= 0)
      return;
    kill(child, SIGTERM);
    for (int n = 0; n < 50; ++n) {
      const auto result = waitpid(child, nullptr, WNOHANG);
      if (result == child || (result < 0 && errno == ECHILD))
        return;
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    kill(child, SIGKILL);
    while (waitpid(child, nullptr, 0) < 0 && errno == EINTR) {
    }
  }

public:
  ChildProcess(std::string python, std::string adapter, std::string model,
               int input, int output, std::string option = {}) {
    auto started = std::make_shared<std::promise<pid_t>>();
    auto result = started->get_future();
    const pid_t owner = getpid();
    creator_ = std::thread([this, started, owner, input, output,
                            python = std::move(python),
                            adapter = std::move(adapter),
                            model = std::move(model),
                            option = std::move(option)]() mutable {
#ifdef __APPLE__
      posix_spawn_file_actions_t actions;
      posix_spawn_file_actions_init(&actions);
      posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
      posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
      posix_spawnattr_t attr;
      posix_spawnattr_init(&attr);
      posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
      posix_spawnattr_setpgroup(&attr, 0);
      std::vector<std::string> args{python, adapter, model};
      if (!option.empty()) args.push_back(option);
      pid_t child = -1;
      foresight::OwnedSpawn owned;
      const int error = owned.spawn(&child, &actions, &attr, args);
      posix_spawn_file_actions_destroy(&actions);
      posix_spawnattr_destroy(&attr);
      if (error) child = -1;
#else
      pid_t child = fork();
      if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != owner)
          _exit(127);
        if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0)
          _exit(127);
        if (fcntl(STDIN_FILENO, F_SETFD, 0) < 0 ||
            fcntl(STDOUT_FILENO, F_SETFD, 0) < 0)
          _exit(127);
        // The frontend may close its helper stderr reader while this model
        // remains alive. Structured adapter failures use stdout; third-party
        // progress/warnings must not depend on that former reader.
        int quiet = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (quiet < 0 || dup2(quiet, STDERR_FILENO) < 0)
          _exit(127);
        if (quiet != STDERR_FILENO)
          close(quiet);
        if (fcntl(STDERR_FILENO, F_SETFD, 0) < 0)
          _exit(127);
        if (option.empty())
          execlp(python.c_str(), python.c_str(), adapter.c_str(), model.c_str(),
                 static_cast<char *>(nullptr));
        else
          execlp(python.c_str(), python.c_str(), adapter.c_str(), model.c_str(),
                 option.c_str(), static_cast<char *>(nullptr));
        _exit(127);
      }

#endif
#ifdef __APPLE__
      pid_.store(child > 0 ? owned.worker : -1);
#else
      pid_.store(child);
#endif
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
#ifdef __APPLE__
      owned.stop();
      // The supervisor owns worker reaping and exits after bounded cleanup.
      if (child > 0) while (waitpid(child, nullptr, 0) < 0 && errno == EINTR) {}
#else
      terminate(child);
#endif
      pid_.store(-1);
      alive_.store(false);
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
