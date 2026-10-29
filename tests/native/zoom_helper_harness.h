#pragma once
// Shared harness for tests that drive a built observer helper over real pipes
// with an explicit environment.
#include <chrono>
#include <csignal>
#include <fcntl.h>
#include <iostream>
#include <nlohmann/json.hpp>
#include <optional>
#include <poll.h>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace zoom_harness {

using nlohmann::json;

inline int failures = 0;
inline int checks = 0;

inline void check(bool value, const std::string &what) {
  ++checks;
  if (!value) {
    std::cerr << "FAIL: " << what << '\n';
    ++failures;
  }
}

class Helper {
public:
  Helper(const char *executable, std::vector<std::string> arguments,
         std::vector<std::string> environment) {
    int in[2], out[2], err[2];
    if (pipe(in) != 0 || pipe(out) != 0 || pipe(err) != 0)
      std::abort();
    pid_ = fork();
    if (pid_ == 0) {
      dup2(in[0], 0);
      dup2(out[1], 1);
      dup2(err[1], 2);
      for (int fd : {in[0], in[1], out[0], out[1], err[0], err[1]})
        close(fd);
      std::vector<char *> argv{const_cast<char *>(executable)};
      for (auto &argument : arguments)
        argv.push_back(argument.data());
      argv.push_back(nullptr);
      std::vector<char *> envp;
      for (auto &entry : environment)
        envp.push_back(entry.data());
      envp.push_back(nullptr);
      execve(executable, argv.data(), envp.data());
      _exit(127);
    }
    close(in[0]);
    close(out[1]);
    close(err[1]);
    stdin_ = in[1];
    stdout_ = out[0];
    stderr_ = err[0];
    signal(SIGPIPE, SIG_IGN);
  }
  ~Helper() {
    close_stdin();
    close_output();
    close(stderr_);
    if (pid_ > 0) {
      kill(pid_, SIGKILL);
      waitpid(pid_, nullptr, 0);
    }
  }

  void write_raw(const std::string &text) {
    std::size_t done = 0;
    while (done < text.size()) {
      const ssize_t n = write(stdin_, text.data() + done, text.size() - done);
      if (n <= 0)
        return;
      done += static_cast<std::size_t>(n);
    }
  }
  void send(json request) {
    request["v"] = 1;
    request["seq"] = seq_++;
    write_raw(request.dump() + "\n");
  }
  // Closes the read end of the helper's stdout: its next write fails.
  void close_output() {
    if (stdout_ >= 0)
      close(stdout_);
    stdout_ = -1;
  }
  void signal_process(int signal_number) {
    if (pid_ > 0)
      kill(pid_, signal_number);
  }
  void close_stdin() {
    if (stdin_ >= 0)
      close(stdin_);
    stdin_ = -1;
  }

  std::optional<json> frame(int timeout_ms = 5000) {
    for (;;) {
      const auto newline = pending_.find('\n');
      if (newline != std::string::npos) {
        json parsed = json::parse(pending_.substr(0, newline), nullptr, false);
        pending_.erase(0, newline + 1);
        check(!parsed.is_discarded(), "every stdout line is JSON");
        return parsed.is_discarded() ? std::nullopt
                                     : std::optional<json>(parsed);
      }
      pollfd fd{stdout_, POLLIN, 0};
      if (poll(&fd, 1, timeout_ms) <= 0)
        return std::nullopt;
      char chunk[4096];
      const ssize_t n = read(stdout_, chunk, sizeof(chunk));
      if (n <= 0)
        return std::nullopt;
      pending_.append(chunk, static_cast<std::size_t>(n));
    }
  }
  json expect(const char *type, int timeout_ms = 5000) {
    auto next = frame(timeout_ms);
    check(next && (*next)["type"] == type,
          std::string("expected ") + type +
              (next ? ", got " + next->dump() : ", got none"));
    return next.value_or(json::object());
  }

  // A capabilities reply, or nullopt when the helper sent none in time.
  std::optional<json> try_capabilities(int id) {
    send({{"type", "capabilities"}, {"id", id}});
    auto frame = this->frame(5000);
    if (!frame || (*frame)["type"] != "capabilities")
      return std::nullopt;
    return frame;
  }

  // Sends a clock request and returns its reply; every frame in between must
  // be that reply (no unsolicited frame).
  json expect_clock(int id) {
    send({{"type", "clock"}, {"id", id}});
    return expect("clock");
  }

  // Bytes on stdout not yet consumed as frames (after the helper exited).
  std::string stdout_remainder() {
    fcntl(stdout_, F_SETFL, O_NONBLOCK);
    char chunk[4096];
    ssize_t n;
    while (stdout_ >= 0 && (n = read(stdout_, chunk, sizeof(chunk))) > 0)
      pending_.append(chunk, static_cast<std::size_t>(n));
    return pending_;
  }

  // Raw wait status, or -1 on timeout.
  int wait_exit_status(int timeout_ms = 5000) {
    const auto end = std::chrono::steady_clock::now() +
                     std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < end) {
      int status = 0;
      if (waitpid(pid_, &status, WNOHANG) == pid_) {
        pid_ = -1;
        return status;
      }
      usleep(5000);
    }
    return -1;
  }

  // Waits for the helper to exit; -1 on timeout, 128+signal if killed.
  int wait_exit(int timeout_ms = 5000) {
    const auto end = std::chrono::steady_clock::now() +
                     std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < end) {
      int status = 0;
      if (waitpid(pid_, &status, WNOHANG) == pid_) {
        pid_ = -1;
        return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
      }
      usleep(5000);
    }
    return -1;
  }

  std::string drain_stderr() {
    std::string text;
    fcntl(stderr_, F_SETFL, O_NONBLOCK);
    char chunk[4096];
    ssize_t n;
    while ((n = read(stderr_, chunk, sizeof(chunk))) > 0)
      text.append(chunk, static_cast<std::size_t>(n));
    return text;
  }

private:
  pid_t pid_ = -1;
  int stdin_ = -1, stdout_ = -1, stderr_ = -1;
  std::string pending_;
  std::uint64_t seq_ = 0;
};

} // namespace zoom_harness
