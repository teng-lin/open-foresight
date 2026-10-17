#pragma once
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <stdexcept>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#include <dlfcn.h>
#include <poll.h>
#include <spawn.h>
#include <vector>
extern char **environ;
#include <filesystem>

namespace foresight {
// macOS has no pipe2. Serialize our descriptor creation and launches; Mac
// posix_spawn also uses CLOEXEC_DEFAULT so concurrent launches cannot inherit
// descriptors during the pipe/fcntl window.
inline std::mutex launch_mutex;
inline int cloexec_pipe(int fd[2]) {
#ifdef __linux__
  return pipe2(fd, O_CLOEXEC);
#else
  if (pipe(fd)) return -1;
  if (fcntl(fd[0], F_SETFD, FD_CLOEXEC) ||
      fcntl(fd[1], F_SETFD, FD_CLOEXEC)) {
    const int error = errno;
    close(fd[0]); close(fd[1]); errno = error; return -1;
  }
  return 0;
#endif
}
inline std::filesystem::path executable_path() {
#ifdef __APPLE__
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string path(size, '\0');
  if (_NSGetExecutablePath(path.data(), &size))
    throw std::runtime_error("Cannot resolve executable path");
  path.resize(path.find('\0'));
  return std::filesystem::canonical(path);
#else
  return std::filesystem::read_symlink("/proc/self/exe");
#endif
}
// This entrypoint runs only in a fresh helper process, before any runtime
// threads exist. The service's liveness descriptor is inherited explicitly;
// a crash at any point during launch therefore cannot leave an unowned model.
inline int supervise_worker(int argc, char **argv) {
  if (argc < 3 || std::string(argv[1]) != "--foresight-supervise-worker") return -1;
  // A host may ignore SIGCHLD. This fresh, single-threaded supervisor owns
  // its child, and reports the result over a pipe the host cannot reap.
  signal(SIGCHLD, SIG_DFL);
  if (fcntl(3, F_SETFD, FD_CLOEXEC) || fcntl(4, F_SETFD, FD_CLOEXEC)) return 127;
  pollfd owner{3, POLLIN, 0};
  if (poll(&owner, 1, 0) != 0) return 127; // owner already gone
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  for (int fd = 0; fd < 3; ++fd) posix_spawn_file_actions_adddup2(&actions, fd, fd);
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  short flags = POSIX_SPAWN_SETPGROUP;
#ifdef __APPLE__
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  posix_spawnattr_setflags(&attr, flags);
  posix_spawnattr_setpgroup(&attr, 0);
  pid_t worker = -1;
  int error = posix_spawnp(&worker, argv[2], &actions, &attr, argv + 2, environ);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  if (error) return 127;
  // SIGPIPE is ignored in this internal executable, so failed reporting still
  // reaches the cleanup below.
  bool reported = write(4, &worker, sizeof(worker)) == sizeof(worker);
  auto finish = [](int result) {
    // One small atomic message, separate from model-controlled stdout.
    (void)!write(4, &result, sizeof(result));
    close(4);
    return result;
  };
  int status = 0;
  for (;;) {
    if (!reported) break;
    siginfo_t info{};
    auto observed = waitid(P_PID, worker, &info, WEXITED | WNOHANG | WNOWAIT);
    if (observed == 0 && info.si_pid == worker) {
      // Reserve the leader PID until all final group signals are sent.
      kill(-worker, SIGKILL);
      pid_t reaped;
      do { reaped = waitpid(worker, &status, 0); } while (reaped < 0 && errno == EINTR);
      if (reaped < 0) return finish(-errno);
      return finish(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    }
    if (observed < 0 && errno != EINTR) break;
    int ready = poll(&owner, 1, 50);
    if (ready > 0 || (ready < 0 && errno != EINTR)) break;
  }
  kill(-worker, SIGKILL);
  while (waitpid(worker, &status, 0) < 0 && errno == EINTR) {}
  return finish(128 + SIGKILL);
}
inline std::string supervisor_path() {
  if (const char *configured = getenv("FORESIGHT_HELPER")) return configured;
  auto exe = executable_path();
  auto name = exe.filename().string();
  if (name == "ForesightHelper" || name == "foresight-helper") return exe.string();
  Dl_info info{};
  if (dladdr(reinterpret_cast<void *>(&supervisor_path), &info) && info.dli_fname) {
    auto lib = std::filesystem::canonical(info.dli_fname).parent_path();
    for (auto candidate : {lib / "../bin/ForesightHelper", lib / "../bin/foresight-helper"})
      if (access(candidate.c_str(), X_OK) == 0) return candidate.lexically_normal().string();
  }
  return "ForesightHelper";
}
class OwnedSpawn {
  int control_ = -1;
  int report_ = -1;
public:
  pid_t worker = -1;
  int spawn(pid_t *supervisor, posix_spawn_file_actions_t *actions,
            posix_spawnattr_t *attr, const std::vector<std::string> &args) {
    int control[2], report[2];
    if (cloexec_pipe(control)) return errno;
    if (cloexec_pipe(report)) { int e = errno; close(control[0]); close(control[1]); return e; }
    // Keep ownership descriptors away from conventional stdin/out and the
    // fixed supervisor descriptors, including in hosts with closed stdio.
    int fds[4] = {-1, -1, -1, -1};
    int originals[] = {control[0], control[1], report[0], report[1]};
    for (int i = 0; i < 4; ++i) {
      fds[i] = fcntl(originals[i], F_DUPFD_CLOEXEC, 10);
      if (fds[i] < 0) {
        int e = errno;
        for (int fd : fds) if (fd >= 0) close(fd);
        for (int fd : originals) close(fd);
        return e;
      }
    }
    for (int fd : originals) close(fd);
    posix_spawn_file_actions_adddup2(actions, fds[0], 3);
    posix_spawn_file_actions_adddup2(actions, fds[3], 4);
    std::vector<std::string> command{supervisor_path(), "--foresight-supervise-worker"};
    command.insert(command.end(), args.begin(), args.end());
    std::vector<char *> argv;
    for (auto &arg : command) argv.push_back(arg.data());
    argv.push_back(nullptr);
    int error = posix_spawnp(supervisor, argv[0], actions, attr, argv.data(), environ);
    close(fds[0]); close(fds[3]);
    if (!error) {
      size_t received = 0;
      while (received < sizeof(worker)) {
        auto n = read(fds[2], reinterpret_cast<char *>(&worker) + received, sizeof(worker) - received);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        received += n;
      }
      if (received != sizeof(worker)) error = ECHILD;
    }
    if (!error) report_ = fds[2];
    else close(fds[2]);
    if (error) {
      close(fds[1]);
      if (*supervisor > 0) while (waitpid(*supervisor, nullptr, 0) < 0 && errno == EINTR) {}
      *supervisor = -1;
      return error;
    }
    control_ = fds[1];
    return 0;
  }
  void stop() { if (control_ >= 0) { close(control_); control_ = -1; } }
  bool finished() const {
    pollfd report{report_, POLLIN, 0};
    return poll(&report, 1, 0) > 0;
  }
  int result() {
    int status;
    size_t received = 0;
    while (received < sizeof(status)) {
      auto n = read(report_, reinterpret_cast<char *>(&status) + received, sizeof(status) - received);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return -ECHILD;
      received += n;
    }
    return status;
  }
  ~OwnedSpawn() {
    stop();
    if (report_ >= 0) close(report_);
  }
};
}
