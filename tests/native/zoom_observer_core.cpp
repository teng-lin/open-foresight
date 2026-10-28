// Protocol core contract: framing, sequencing, session semantics and shutdown,
// driven in-process through pipes with a scripted Source (no Zoom, no
// Accessibility permission).
#include "zoom_observer_core.h"
#include "zoom_ref_table.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <iostream>
#include <mutex>
#include <optional>
#include <poll.h>
#include <set>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

using namespace foresight::zoom;
using json = nlohmann::json;
using std::chrono::milliseconds;
using std::chrono::steady_clock;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition, message)                                              \
  do {                                                                         \
    ++checks;                                                                  \
    if (!(condition)) {                                                        \
      ++failures;                                                              \
      std::cerr << "FAIL: " << (message) << "  [" #condition "]\n";            \
    }                                                                          \
  } while (0)

AxNode node(const std::string &role, const std::string &description = {},
            const std::string &value = {}, uint64_t object_id = 0) {
  AxNode result;
  result.role = role;
  result.description = description;
  result.value = value;
  result.object_id = object_id;
  return result;
}

SnapshotOutcome meeting(std::vector<AxNode> tiles, uint64_t window_id = 100) {
  SnapshotOutcome outcome;
  outcome.ok = true;
  outcome.pid = 4242;
  outcome.zoom_version = "7.2.2.88465";
  outcome.snapshot.root = node("AXApplication");
  AxNode window = node("AXWindow", {}, {}, window_id);
  window.children = std::move(tiles);
  outcome.snapshot.root.children.push_back(std::move(window));
  return outcome;
}

AxNode tile(const std::string &description, uint64_t object_id = 0) {
  return node("AXTabGroup", description, {}, object_id);
}

SnapshotOutcome gated(const std::string &state, const std::string &reason) {
  SnapshotOutcome outcome;
  outcome.ok = false;
  outcome.state = state;
  outcome.reason = reason;
  return outcome;
}

void fill_pipe(int fd);

class ScriptedSource final : public Source {
public:
  explicit ScriptedSource(std::vector<SnapshotOutcome> script)
      : script_(std::move(script)) {}

  void request_access() override {
    ++access_requests;
  }

  SnapshotOutcome snapshot(const std::function<bool()> &cancelled) override {
    int call = ++snapshots;
    if (fill_fd >= 0 && call == 1)
      fill_pipe(fill_fd);
    if (stall_ms) // an uncooperative accessibility call
      std::this_thread::sleep_for(milliseconds(stall_ms));
    if (block_call == call) { // a cooperative read: ends when cancelled
      blocked = true;
      while (!cancelled())
        std::this_thread::sleep_for(milliseconds(2));
      return gated("unavailable", "read_cancelled");
    }
    if (pause_ms)
      std::this_thread::sleep_for(milliseconds(pause_ms));
    std::lock_guard<std::mutex> lock(mutex_);
    SnapshotOutcome outcome = script_[std::min(next_, script_.size() - 1)];
    ++next_;
    outcome.read_start_ms = monotonic_ms();
    outcome.read_end_ms = outcome.read_start_ms + 3;
    return outcome;
  }

  uint64_t monotonic_ms() override {
    return 1000 + 10 * ++clock_;
  }
  uint64_t uptime_ms() override {
    return 500 + 10 * ++clock_;
  }

  std::atomic<int> access_requests{0};
  std::atomic<int> snapshots{0};
  std::atomic<bool> blocked{false};
  int stall_ms = 0;
  int pause_ms = 0;
  int fill_fd = -1; // fill this pipe with junk before the first read
  int block_call = 0;

private:
  std::mutex mutex_;
  std::vector<SnapshotOutcome> script_;
  size_t next_ = 0;
  std::atomic<uint64_t> clock_{0};
};

// Fills a pipe's buffer so that the next write would block.
void fill_pipe(int fd) {
  int flags = ::fcntl(fd, F_GETFL);
  ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  char junk[4096] = {};
  while (::write(fd, junk, sizeof junk) > 0) {
  }
  ::fcntl(fd, F_SETFL, flags);
}

ObserverConfig test_config(int in_fd, int out_fd, int err_fd) {
  ObserverConfig config;
  config.in_fd = in_fd;
  config.out_fd = out_fd;
  config.err_fd = err_fd;
  config.helper = "zoom_observer_macos";
  config.platform = "macos";
  config.parse = parse_snapshot;
  config.parser_version = kParserVersion;
  return config;
}

bool wait_for(const std::function<bool()> &condition, int timeout_ms = 5000) {
  auto deadline = steady_clock::now() + milliseconds(timeout_ms);
  while (!condition()) {
    if (steady_clock::now() > deadline)
      return false;
    std::this_thread::sleep_for(milliseconds(2));
  }
  return true;
}

// One observer wired to pipes, driven from the test thread.
class Harness {
public:
  explicit Harness(Source &source) {
    int in[2], out[2], err[2];
    if (::pipe(in) || ::pipe(out) || ::pipe(err))
      std::abort();
    request_fd_ = in[1];
    frame_fd_ = out[0];
    stderr_fd_ = err[0];
    ObserverConfig config = test_config(in[0], out[1], err[1]);
    thread_ = std::thread(
        [this, &source, config, in0 = in[0], out1 = out[1], err1 = err[1]] {
          exit_code_ = run_observer(source, config);
          ::close(out1);
          ::close(err1);
          ::close(in0);
        });
  }

  ~Harness() {
    if (request_fd_ >= 0)
      ::close(request_fd_);
    if (thread_.joinable())
      thread_.join();
    if (frame_fd_ >= 0)
      ::close(frame_fd_);
    ::close(stderr_fd_);
  }

  void send_raw(const std::string &text) {
    size_t offset = 0;
    while (offset < text.size()) {
      ssize_t written =
          ::write(request_fd_, text.data() + offset, text.size() - offset);
      if (written <= 0)
        return; // the helper may already have closed the session
      offset += static_cast<size_t>(written);
    }
  }

  void send(json request) {
    request["v"] = 1;
    request["seq"] = out_seq_++;
    send_raw(request.dump() + "\n");
  }

  void skip_seq() {
    ++out_seq_;
  } // after a hand-framed request

  void close_input() {
    ::close(request_fd_);
    request_fd_ = -1;
  }

  void close_output() {
    ::close(frame_fd_);
    frame_fd_ = -1;
  }

  // Next frame, or nullopt after the timeout or end of stream.
  std::optional<json> read(int timeout_ms = 5000) {
    for (;;) {
      auto newline = buffer_.find('\n');
      if (newline != std::string::npos) {
        json frame = json::parse(buffer_.substr(0, newline), nullptr, false);
        buffer_.erase(0, newline + 1);
        CHECK(!frame.is_discarded(), "helper output is valid JSON");
        if (frame.is_discarded())
          return std::nullopt;
        CHECK(frame["v"] == 1, "frame version");
        CHECK(frame["seq"].get<uint64_t>() == in_seq_,
              "frame seq is contiguous");
        ++in_seq_;
        return frame;
      }
      pollfd descriptor{frame_fd_, POLLIN, 0};
      if (::poll(&descriptor, 1, timeout_ms) <= 0)
        return std::nullopt;
      char chunk[65536];
      ssize_t count = ::read(frame_fd_, chunk, sizeof chunk);
      if (count <= 0)
        return std::nullopt;
      buffer_.append(chunk, static_cast<size_t>(count));
    }
  }

  json expect(const char *type, int timeout_ms = 5000) {
    auto frame = read(timeout_ms);
    CHECK(frame.has_value(), std::string("expected a ") + type + " frame");
    if (!frame)
      return json::object();
    CHECK((*frame)["type"] == type,
          std::string("expected ") + type + " but got " + frame->dump());
    return *frame;
  }

  // Reads until a frame of `type` arrives (other frames are returned through
  // `skipped`). Records a failure when none does.
  json find(const char *type, std::vector<json> *skipped = nullptr,
            int limit = 50, int timeout_ms = 5000) {
    for (int i = 0; i < limit; ++i) {
      auto frame = read(timeout_ms);
      if (!frame)
        break;
      if ((*frame)["type"] == type)
        return *frame;
      if (skipped)
        skipped->push_back(*frame);
    }
    CHECK(false, std::string("no ") + type + " frame arrived");
    return json::object();
  }

  std::string stderr_text() {
    std::string text;
    char chunk[4096];
    pollfd descriptor{stderr_fd_, POLLIN, 0};
    while (::poll(&descriptor, 1, 0) > 0) {
      ssize_t count = ::read(stderr_fd_, chunk, sizeof chunk);
      if (count <= 0)
        break;
      text.append(chunk, static_cast<size_t>(count));
    }
    return text;
  }

  int join() {
    if (thread_.joinable())
      thread_.join();
    return exit_code_;
  }

private:
  int request_fd_ = -1, frame_fd_ = -1, stderr_fd_ = -1;
  std::thread thread_;
  int exit_code_ = -1;
  uint64_t out_seq_ = 0, in_seq_ = 0;
  std::string buffer_;
};

const std::string kUnmuted = ", Computer audio unmuted";

json participant_by_name(const json &observation, const std::string &name,
                         size_t occurrence = 0) {
  for (const auto &p : observation["participants"])
    if (p["name"] == name && occurrence-- == 0)
      return p;
  return json::object();
}

// ---- fork-based shutdown tests (run before any thread exists) -------------

struct Child {
  pid_t pid = -1;
  int to_child = -1, from_child = -1;
  uint64_t seq = 0;
  std::string output;

  void send(json request) {
    request["v"] = 1;
    request["seq"] = seq++;
    std::string line = request.dump() + "\n";
    (void)!::write(to_child, line.data(), line.size());
  }

  // Reads until `needle` appears, the stream ends, or the timeout passes.
  bool wait_output(const std::string &needle, int timeout_ms) {
    auto deadline = steady_clock::now() + milliseconds(timeout_ms);
    while (output.find(needle) == std::string::npos) {
      int remaining = static_cast<int>(std::chrono::duration_cast<milliseconds>(
                                           deadline - steady_clock::now())
                                           .count());
      pollfd descriptor{from_child, POLLIN, 0};
      if (remaining <= 0 || ::poll(&descriptor, 1, remaining) <= 0)
        return false;
      char chunk[4096];
      ssize_t count = ::read(from_child, chunk, sizeof chunk);
      if (count <= 0)
        return false;
      output.append(chunk, static_cast<size_t>(count));
    }
    return true;
  }

  // Waits for the child to exit; kills it (by exact PID) after `timeout_ms`.
  int reap_within(int timeout_ms, bool &timed_out) {
    int status = 0;
    auto deadline = steady_clock::now() + milliseconds(timeout_ms);
    timed_out = false;
    while (::waitpid(pid, &status, WNOHANG) == 0) {
      if (steady_clock::now() > deadline) {
        timed_out = true;
        ::kill(pid, SIGKILL);
        ::waitpid(pid, &status, 0);
        break;
      }
      ::usleep(5000);
    }
    ::close(to_child);
    ::close(from_child);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  }

  int reap() {
    int status = 0;
    ::waitpid(pid, &status, 0);
    ::close(to_child);
    ::close(from_child);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  }
};

// Forks an observer whose snapshot() sleeps `stall_ms` without looking at
// cancellation, like an accessibility call stuck inside Zoom.
Child spawn_stalled(int stall_ms, bool fill_stdout = false) {
  int in[2], out[2];
  if (::pipe(in) || ::pipe(out))
    std::abort();
  pid_t pid = ::fork();
  if (pid == 0) {
    ::close(in[1]);
    ::close(out[0]);
    ScriptedSource source({meeting({tile("Ada Example" + kUnmuted)})});
    source.stall_ms = stall_ms;
    if (fill_stdout)
      source.fill_fd = out[1];
    ObserverConfig config =
        test_config(in[0], out[1], ::open("/dev/null", O_WRONLY));
    ::_exit(run_observer(source, config));
  }
  ::close(in[0]);
  ::close(out[1]);
  Child child;
  child.pid = pid;
  child.to_child = in[1];
  child.from_child = out[0];
  return child;
}

long elapsed_ms(steady_clock::time_point since) {
  return static_cast<long>(
      std::chrono::duration_cast<milliseconds>(steady_clock::now() - since)
          .count());
}

void check_stalled_read_stop() {
  Child child = spawn_stalled(6000);
  child.send({{"type", "start"},
              {"id", "a"},
              {"session", "s"},
              {"poll_ms", 100},
              {"deadline_ms", 300}});
  ::usleep(150000); // let the stalled first read begin
  auto begin = steady_clock::now();
  child.send({{"type", "stop"}, {"id", "b"}});
  CHECK(child.wait_output("\"stopped\"", 3000),
        "stop is answered while a read is stalled");
  CHECK(elapsed_ms(begin) < 1000, "stop honors deadline_ms, not the stall");
  CHECK(child.reap() == 0, "stalled helper exits 0 after stop");
}

// A refused second start must not change the live session or its deadline.
void check_duplicate_start_keeps_session() {
  Child child = spawn_stalled(6000);
  child.send({{"type", "start"},
              {"id", "a"},
              {"session", "S1"},
              {"poll_ms", 100},
              {"deadline_ms", 1200}});
  child.send({{"type", "start"},
              {"id", "b"},
              {"session", "S2"},
              {"poll_ms", 100},
              {"deadline_ms", 100}});
  ::usleep(150000);
  auto begin = steady_clock::now();
  child.send({{"type", "stop"}, {"id", "c"}});
  CHECK(child.wait_output("\"stopped\"", 4000), "stopped arrives");
  long elapsed = elapsed_ms(begin);
  CHECK(elapsed >= 900, "the first start's 1200 ms deadline still applies (" +
                            std::to_string(elapsed) + " ms)");
  auto at = child.output.find("\"type\":\"stopped\"");
  CHECK(at != std::string::npos, "stopped frame present");
  std::string line;
  if (at != std::string::npos) {
    auto begin = child.output.rfind('\n', at);
    auto end = child.output.find('\n', at);
    line = child.output.substr(begin == std::string::npos ? 0 : begin + 1,
                               end == std::string::npos ? std::string::npos
                                                        : end - begin);
  }
  // The first start is still inside its stalled read, so no session was
  // started; the guard reports none and never the refused S2.
  CHECK(line.find("\"session\":null") != std::string::npos &&
            line.find("S2") == std::string::npos,
        "stopped reports no started session and never the refused one: " +
            line);
  CHECK(child.reap() == 0, "exits 0");
}

void check_eof_and_fatal_during_stall() {
  {
    Child child = spawn_stalled(6000);
    child.send({{"type", "start"},
                {"id", "a"},
                {"session", "s"},
                {"poll_ms", 100},
                {"deadline_ms", 300}});
    ::usleep(150000);
    auto begin = steady_clock::now();
    ::close(child.to_child);
    child.to_child = ::open("/dev/null", O_WRONLY);
    CHECK(child.reap() == 0, "stdin close during a stalled read exits 0");
    CHECK(elapsed_ms(begin) < 1500, "end of input honors the session deadline");
    CHECK(child.output.find("stopped") == std::string::npos,
          "end of input emits no stopped frame");
  }
  {
    Child child = spawn_stalled(6000);
    child.send({{"type", "start"},
                {"id", "a"},
                {"session", "s"},
                {"poll_ms", 100},
                {"deadline_ms", 300}});
    ::usleep(150000);
    auto begin = steady_clock::now();
    (void)!::write(child.to_child, "garbage\n", 8);
    CHECK(child.wait_output("malformed_json", 3000),
          "a protocol error is reported during a stalled read");
    CHECK(elapsed_ms(begin) < 1500, "fatal error honors the deadline");
    CHECK(child.reap() == 2, "exit 2 after a fatal error during a stall");
  }
}

// The stop guard must not block on a stdout nobody reads.
void check_guard_survives_a_full_stdout() {
  Child child = spawn_stalled(6000, true);
  child.send({{"type", "start"},
              {"id", "a"},
              {"session", "s"},
              {"poll_ms", 100},
              {"deadline_ms", 100}});
  ::usleep(300000); // the first read fills the pipe, then stalls
  child.send({{"type", "stop"}, {"id", "b"}});
  bool timed_out = false;
  int code = child.reap_within(3000, timed_out);
  CHECK(!timed_out, "the guard exits although stdout is full and wedged");
  CHECK(code == 0, "exit 0 after stop");
}

// Requests that never started must not be reported as a session.
void check_guard_reports_only_a_started_session() {
  Child child = spawn_stalled(6000);
  child.send({{"type", "capabilities"}, {"id", "k"}}); // main loop stalls here
  ::usleep(150000);
  child.send({{"type", "start"},
              {"id", "a"},
              {"session", "never"},
              {"poll_ms", 100},
              {"deadline_ms", 300}});
  child.send({{"type", "stop"}, {"id", "b"}});
  CHECK(child.wait_output("\"stopped\"", 3000), "stopped arrives");
  CHECK(child.output.find("never") == std::string::npos,
        "a start that never ran is not reported: " + child.output);
  CHECK(child.output.find("\"session\":null") != std::string::npos,
        "stopped carries a null session");
  CHECK(child.reap() == 0, "exits 0");
}

void check_clock_during_stall() {
  Child child = spawn_stalled(6000);
  child.send({{"type", "start"},
              {"id", "a"},
              {"session", "s"},
              {"poll_ms", 100},
              {"deadline_ms", 300}});
  ::usleep(150000);
  auto begin = steady_clock::now();
  child.send({{"type", "clock"}, {"id", "k"}});
  CHECK(child.wait_output("\"monotonic_ms\"", 2000),
        "clock is answered while a read is stalled");
  CHECK(elapsed_ms(begin) < 500, "clock reply is immediate");
  child.send({{"type", "stop"}, {"id", "z"}});
  child.wait_output("\"stopped\"", 3000);
  child.reap();
}

// ---- in-process tests ------------------------------------------------------

void check_hello_and_clock() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  json hello = h.expect("hello");
  CHECK(hello["seq"] == 0, "hello is seq 0");
  CHECK(hello["helper"] == "zoom_observer_macos", "helper name");
  CHECK(hello["platform"] == "macos", "platform");
  CHECK(hello["parser_version"] == "mac-1", "parser version comes from config");
  h.send({{"type", "clock"}, {"id", "c1"}});
  json clock = h.expect("clock");
  CHECK(clock["id"] == "c1", "clock echoes id");
  CHECK(clock["monotonic_ms"].is_number_unsigned(), "monotonic_ms");
  CHECK(clock["uptime_ms"].is_number_unsigned(), "uptime_ms");
  h.send({{"type", "stop"}, {"id", 9}});
  json stopped = h.expect("stopped");
  CHECK(stopped["id"] == 9 && stopped["session"].is_null(),
        "stop before start reports no session");
  CHECK(!h.read(300).has_value(), "nothing follows stopped");
  CHECK(h.join() == 0, "stop exits 0");
}

void check_capabilities() {
  struct Case {
    SnapshotOutcome outcome;
    const char *state;
    const char *reason;
    bool version;
  };
  SnapshotOutcome unsupported_locale = meeting({});
  unsupported_locale.locale_unsupported = true;
  SnapshotOutcome version =
      gated("unsupported_version", "zoom_version_unsupported");
  version.zoom_version = "7.3.0.1";
  SnapshotOutcome truncated_empty = meeting({});
  truncated_empty.snapshot.truncated = true;
  SnapshotOutcome no_windows = meeting({});
  no_windows.snapshot.root.children.clear();
  SnapshotOutcome truncated_no_windows = no_windows;
  truncated_no_windows.snapshot.truncated = true;
  std::vector<Case> cases = {
      {gated("zoom_not_running", "zoom_not_running"), "zoom_not_running",
       "zoom_not_running", false},
      {gated("needs_setup", "accessibility_not_trusted"), "needs_setup",
       "accessibility_not_trusted", false},
      {gated("permission_denied", "accessibility_not_trusted"),
       "permission_denied", "accessibility_not_trusted", false},
      {version, "unsupported_version", "zoom_version_unsupported", true},
      {gated("unsupported_platform", "macos_15_required"),
       "unsupported_platform", "macos_15_required", false},
      {gated("unavailable", "ax_read_failed"), "unavailable", "ax_read_failed",
       false},
      {no_windows, "no_meeting", "no_meeting_window", true},
      {meeting({}), "no_meeting", "no_participant_evidence", true},
      {unsupported_locale, "unavailable", "unsupported_locale", true},
      // A read that was cut short cannot say there is no meeting.
      {truncated_no_windows, "unavailable", "incomplete_read", true},
      {truncated_empty, "unavailable", "incomplete_read", true},
      {meeting({tile("Ada Example" + kUnmuted)}), "available",
       "meeting_observed", true},
  };
  for (auto &entry : cases) {
    ScriptedSource source({entry.outcome});
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", "k"}});
    json frame = h.expect("capabilities");
    CHECK(frame["id"] == "k", "capabilities echoes id");
    CHECK(frame["state"] == entry.state,
          std::string("state ") + entry.state + " got " + frame.dump());
    CHECK(frame["reason"] == entry.reason,
          std::string("reason ") + entry.reason + " got " + frame.dump());
    CHECK(frame["zoom_version"].is_null() != entry.version,
          "zoom_version presence");
    CHECK(source.access_requests == 0, "capabilities never prompts");
    if (std::string(entry.state) == "available")
      CHECK(frame["locale"] == "en", "capabilities reports the locale");
    h.close_input();
    CHECK(h.join() == 0, "stdin close exits 0");
  }
  ScriptedSource source(
      {gated("permission_denied", "accessibility_not_trusted")});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "setup"}, {"id", "s"}});
  json frame = h.expect("capabilities");
  CHECK(frame["id"] == "s" && frame["state"] == "permission_denied",
        "setup replies with capabilities");
  CHECK(source.access_requests == 1, "setup prompts exactly once");
  h.close_input();
  h.join();
}

void check_session() {
  SnapshotOutcome speaking =
      meeting({tile("Ada Example" + kUnmuted + ", Active speaker", 11),
               tile("Bob Example" + kUnmuted, 12)});
  SnapshotOutcome silent = meeting(
      {tile("Ada Example" + kUnmuted, 11), tile("Bob Example" + kUnmuted, 12)});
  SnapshotOutcome renamed =
      meeting({tile("Bob Renamed" + kUnmuted + ", Active speaker", 11),
               tile("Bob Example" + kUnmuted, 12)});
  SnapshotOutcome truncated = silent;
  truncated.snapshot.truncated = true;
  SnapshotOutcome second_window =
      meeting({tile("Ada Example" + kUnmuted, 11)}, 777);
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running"),
                         gated("zoom_not_running", "zoom_not_running"),
                         gated("needs_setup", "accessibility_not_trusted"),
                         speaking, silent, renamed, speaking,
                         gated("unavailable", "ax_read_failed"),
                         gated("unavailable", "ax_read_failed"), truncated,
                         speaking, second_window});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"},
          {"id", "st"},
          {"session", "s1"},
          {"poll_ms", 100},
          {"deadline_ms", 500}});
  json started = h.expect("started");
  CHECK(started["id"] == "st" && started["session"] == "s1", "started echoes");
  CHECK(started["target"]["pid"].is_null(), "no pid before Zoom runs");

  json unavailable = h.expect("unavailable");
  CHECK(unavailable["session"] == "s1" &&
            unavailable["reason"] == "zoom_not_running",
        "unavailable reports why");
  uint64_t since = unavailable["since_ms"].get<uint64_t>();
  CHECK(since > 0, "since_ms comes from the helper clock");

  // The repeated failure produces no frame; a changed reason produces one but
  // the interval keeps its start.
  json changed = h.expect("unavailable");
  CHECK(changed["reason"] == "accessibility_not_trusted",
        "a changed reason is reported");
  CHECK(changed["since_ms"].get<uint64_t>() == since,
        "since_ms stays at the start of the unavailable interval");

  json first = h.expect("observation");
  CHECK(first["session"] == "s1" && first["complete"] == true, "observation");
  CHECK(first["read_end_ms"].get<uint64_t>() >=
            first["read_start_ms"].get<uint64_t>(),
        "read interval ordered");
  CHECK(first["read_start_ms"].get<uint64_t>() > since,
        "monotonic clock advances");
  CHECK(first["parser_version"] == "mac-1", "parser version");
  CHECK(first["target"]["pid"] == 4242 &&
            first["target"]["zoom_version"] == "7.2.2.88465" &&
            first["target"]["locale"] == "en" &&
            first["target"]["window"] == "w1",
        "target description");
  json ada = participant_by_name(first, "Ada Example");
  json bob = participant_by_name(first, "Bob Example");
  CHECK(ada["ref"] != bob["ref"], "distinct refs");
  CHECK(first["speakers"].size() == 1 &&
            first["speakers"][0]["ref"] == ada["ref"] &&
            first["speakers"][0]["method"] == "participant_status",
        "speaker references the participant");

  json absent = h.expect("observation");
  CHECK(absent["speakers"].empty() && absent["complete"] == true,
        "observed absence: no speakers, complete");
  CHECK(participant_by_name(absent, "Ada Example")["ref"] == ada["ref"],
        "ref is stable across observations");

  // The same screen element now shows someone else: a new person, new ref.
  json rename = h.expect("observation");
  json renamed_ref = participant_by_name(rename, "Bob Renamed")["ref"];
  CHECK(renamed_ref != ada["ref"],
        "a renamed element does not lend its ref to the new name");
  CHECK(rename["speakers"][0]["ref"] == renamed_ref, "renamed speaker");
  json back = h.expect("observation");
  CHECK(participant_by_name(back, "Ada Example")["ref"] == ada["ref"],
        "the original name on the same element keeps its ref");

  json failed = h.expect("unavailable");
  CHECK(failed["reason"] == "ax_read_failed", "failed read is unavailable");
  CHECK(failed["since_ms"].get<uint64_t>() >
            back["read_start_ms"].get<uint64_t>(),
        "unavailable interval starts at the failure");

  json partial = h.expect("observation");
  CHECK(partial["complete"] == false && partial["speakers"].empty(),
        "truncated read is incomplete and never extends the old speaker");
  json again = h.expect("observation");
  CHECK(again["complete"] == true && again["speakers"].size() == 1, "recovers");
  CHECK(participant_by_name(again, "Ada Example")["ref"] == ada["ref"],
        "ref survives an unavailable interval");

  json moved = h.expect("observation");
  CHECK(moved["target"]["window"] == "w2", "a new window gets a new label");
  CHECK(participant_by_name(moved, "Ada Example")["ref"] != ada["ref"],
        "refs are scoped to the window");

  h.send({{"type", "start"}, {"id", "again"}, {"session", "s2"}});
  json refused = h.find("error");
  CHECK(refused["code"] == "already_started" && refused["id"] == "again",
        "second start is refused");
  h.send({{"type", "stop"}, {"id", "end"}});
  json stopped = h.find("stopped");
  CHECK(stopped["id"] == "end" && stopped["session"] == "s1",
        "stopped names the live session, not the refused start");
  CHECK(!h.read(300).has_value(), "nothing is emitted after stopped");
  CHECK(h.join() == 0, "stop exits 0");
}

void check_identity_flags_incomplete() {
  // Without element identity, duplicate names cannot be told apart across
  // polls: refs stay distinct but the read is flagged incomplete.
  SnapshotOutcome twins =
      meeting({tile("Twin Example" + kUnmuted),
               tile("Twin Example" + kUnmuted + ", Active speaker")});
  SnapshotOutcome solo = meeting({tile("Solo Example" + kUnmuted)});
  SnapshotOutcome no_ids = meeting({tile("Ada Example" + kUnmuted, 5)});
  no_ids.identity_incomplete = true;
  ScriptedSource source({twins, twins, solo, solo, no_ids});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
  h.expect("started");
  json one = h.expect("observation");
  json two = h.expect("observation");
  CHECK(one["participants"].size() == 2, "both twins reported");
  CHECK(one["participants"][0]["ref"] != one["participants"][1]["ref"],
        "equal names have different refs");
  CHECK(one["complete"] == false,
        "duplicate names without identity: incomplete");
  CHECK(one["participants"][0]["ref"] == two["participants"][0]["ref"],
        "ordinal refs are stable while the set is unchanged");
  CHECK(one["speakers"][0]["ref"] == one["participants"][1]["ref"],
        "the speaker is the marked twin");
  json solo_one = h.expect("observation");
  CHECK(solo_one["complete"] == true, "a unique name without identity is fine");
  json solo_two = h.expect("observation");
  CHECK(solo_one["participants"][0]["ref"] ==
            solo_two["participants"][0]["ref"],
        "unique-name refs are stable");
  json flagged = h.expect("observation");
  CHECK(flagged["complete"] == false,
        "a source that lost identity marks the read incomplete");
  h.close_input();
  CHECK(h.join() == 0, "stdin close exits 0");
}

void check_ref_table() {
  auto person = [](uint64_t id, const std::string &key) {
    Participant participant;
    participant.name = key;
    participant.key = key;
    participant.object_id = id;
    return participant;
  };
  {
    RefTable table;
    auto a = table.assign("w1", {person(1, "ann"), person(2, "bob")});
    auto b = table.assign("w1", {person(1, "ann"), person(2, "bob")});
    CHECK(a.refs == b.refs && !a.uncertain && !b.uncertain,
          "same element and name keep their refs");
    auto c = table.assign("w1", {person(1, "eve"), person(2, "bob")});
    CHECK(c.refs[0] != a.refs[0] && c.refs[1] == a.refs[1],
          "a renamed element gets a new ref");
    auto d = table.assign("w1", {person(1, "ann"), person(2, "bob")});
    CHECK(d.refs[0] == a.refs[0], "returning to the earlier name restores it");
    auto e = table.assign("w2", {person(1, "ann")});
    CHECK(e.refs[0] != a.refs[0], "refs are scoped to a window");
  }
  {
    RefTable table;
    auto twins = table.assign("w", {person(0, "twin"), person(0, "twin")});
    CHECK(twins.refs[0] != twins.refs[1] && twins.uncertain,
          "twins without identity are distinct but uncertain");
    auto left = table.assign("w", {person(0, "twin")});
    CHECK(left.refs[0] != twins.refs[0] && left.refs[0] != twins.refs[1],
          "the survivor never inherits a departed twin's ref");
    auto unique = table.assign("w", {person(0, "solo")});
    auto again = table.assign("w", {person(0, "solo")});
    CHECK(unique.refs == again.refs && !again.uncertain,
          "a unique name keeps its ref without identity");
  }
  {
    // People still present keep their references when a newcomer needs room.
    RefTable table(4);
    auto first = table.assign(
        "w", {person(1, "a"), person(2, "b"), person(3, "c"), person(4, "d")});
    auto second = table.assign("w", {person(9, "new"), person(1, "a"),
                                     person(2, "b"), person(3, "c")});
    CHECK(second.refs[1] == first.refs[0] && second.refs[2] == first.refs[1] &&
              second.refs[3] == first.refs[2],
          "present people keep their refs when a newcomer arrives first");
    CHECK(second.refs[0] != first.refs[3], "the newcomer is a new ref");
    CHECK(second.uncertain, "evicting the person who left is flagged");
    auto third = table.assign("w", {person(1, "a"), person(2, "b"),
                                    person(3, "c"), person(9, "new")});
    CHECK(third.refs[0] == first.refs[0] && third.refs[3] == second.refs[0],
          "later observations stay stable");
    CHECK(!third.uncertain, "stable and unique: certain");
  }
  {
    // Equal names are never certain, even with element identity: if their
    // tiles trade places the references would swap silently.
    RefTable table;
    auto first = table.assign("w", {person(1, "ann"), person(2, "ann")});
    CHECK(first.refs[0] != first.refs[1] && first.uncertain,
          "twins with identity are distinct but uncertain");
    auto traded = table.assign("w", {person(2, "ann"), person(1, "ann")});
    CHECK(traded.uncertain, "traded twin tiles stay flagged");
  }
  {
    RefTable table(4);
    auto first =
        table.assign("w", {person(1, "a"), person(2, "b"), person(3, "c")});
    CHECK(!first.uncertain, "within capacity");
    auto second = table.assign("w", {person(4, "d"), person(5, "e")});
    CHECK(second.uncertain, "evicting people who left flags the observation");
    CHECK(second.refs[0] != second.refs[1], "refs stay distinct");
    CHECK(table.entries() <= 4, "the table stays within capacity");
    auto wide =
        table.assign("w", {person(10, "a"), person(11, "b"), person(12, "c"),
                           person(13, "d"), person(14, "e")});
    CHECK(wide.uncertain, "more people than capacity: uncertain");
    std::set<std::string> distinct(wide.refs.begin(), wide.refs.end());
    CHECK(distinct.size() == 5, "even untracked people get distinct refs");
    CHECK(table.entries() <= 4, "overflow never grows the table");
  }
}

void check_max_observation_fits_and_oversize_recovers() {
  // A maximal observation of ordinary names fits.
  {
    std::vector<AxNode> tiles;
    for (size_t i = 0; i < kMaxParticipants; ++i) {
      std::string name = std::to_string(1000 + i);
      name.resize(kMaxNameBytes, 'n');
      tiles.push_back(tile(name + kUnmuted, 100 + i));
    }
    ScriptedSource source({meeting(std::move(tiles))});
    Harness h(source);
    h.expect("hello");
    h.send(
        {{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
    h.expect("started");
    json frame = h.expect("observation");
    CHECK(frame["participants"].size() == kMaxParticipants,
          "a maximal observation is delivered");
    h.close_input();
    h.join();
  }
  // 256 names of 512 JSON-escaped bytes exceed the line limit: the frame is
  // refused, reported as unavailable, sequence numbers stay contiguous, and the
  // next ordinary observation is delivered.
  {
    std::vector<AxNode> hostile;
    for (size_t i = 0; i < kMaxParticipants; ++i) {
      std::string name(kMaxNameBytes, '"');
      name[0] = static_cast<char>('A' + i % 26); // keep names distinct
      hostile.push_back(tile(name + kUnmuted, 100 + i));
    }
    ScriptedSource source({meeting(std::move(hostile)),
                           meeting({tile("Ada Example" + kUnmuted, 1)})});
    Harness h(source);
    h.expect("hello");
    h.send(
        {{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
    h.expect("started");
    json refused = h.expect("unavailable");
    CHECK(refused["reason"] == "frame_too_large", "oversize frame is reported");
    json recovered = h.expect("observation");
    CHECK(recovered["participants"].size() == 1 &&
              recovered["complete"] == true,
          "the next observation is delivered");
    CHECK(h.stderr_text().find("frame_too_large") != std::string::npos,
          "a bounded diagnostic names the cause");
    h.close_input();
    h.join();
  }
}

void expect_fatal(const char *label, const std::string &raw, const char *code,
                  bool close_after = false) {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  h.send_raw(raw);
  if (close_after)
    h.close_input();
  json frame = h.expect("error");
  CHECK(frame["code"] == code, std::string(label) + " code " + frame.dump());
  CHECK(!frame.contains("id") || frame["id"].is_null(),
        "fatal error has no id");
  CHECK(!h.read(300).has_value(), std::string(label) + ": session closed");
  CHECK(h.join() == 2, std::string(label) + ": exit code 2");
}

std::string nested(int arrays) {
  return "{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":1,\"x\":" +
         std::string(arrays, '[') + std::string(arrays, ']') + "}\n";
}

void check_protocol_errors() {
  expect_fatal("malformed", "{not json\n", "malformed_json");
  expect_fatal("array", "[1,2]\n", "malformed_json");
  expect_fatal("blank", "\n", "malformed_json");
  expect_fatal("invalid utf8",
               std::string("{\"v\":1,\"seq\":0,\"type\":\"\xff\"}\n"),
               "malformed_json");
  expect_fatal("version", "{\"v\":2,\"seq\":0,\"type\":\"clock\",\"id\":1}\n",
               "protocol_version");
  expect_fatal("missing version", "{\"seq\":0,\"type\":\"clock\",\"id\":1}\n",
               "protocol_version");
  expect_fatal("seq gap", "{\"v\":1,\"seq\":3,\"type\":\"clock\",\"id\":1}\n",
               "protocol_seq");
  expect_fatal("seq missing", "{\"v\":1,\"type\":\"clock\",\"id\":1}\n",
               "protocol_seq");
  expect_fatal("unknown type",
               "{\"v\":1,\"seq\":0,\"type\":\"dance\",\"id\":1}\n",
               "protocol_type");
  expect_fatal("missing type", "{\"v\":1,\"seq\":0}\n", "protocol_type");
  // Nesting: the top-level object counts as one level.
  expect_fatal("nesting 17", nested(16), "malformed_json");
  expect_fatal("line too long", std::string(kMaxLineBytes + 1, 'a'),
               "line_too_long");
  // A request cut off by end of input is an error, not a clean EOF.
  expect_fatal("no trailing newline",
               "{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":1}",
               "truncated_line", true);
  // Frames behind a fatal one are never processed.
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    Harness h(source);
    h.expect("hello");
    h.send_raw("garbage\n{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":1}\n");
    CHECK(h.expect("error")["code"] == "malformed_json", "fatal first");
    CHECK(!h.read(300).has_value(), "no pipelined frame is answered");
    CHECK(h.join() == 2, "exit 2");
  }
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "clock"}, {"id", 1}});
    h.expect("clock");
    h.send_raw("{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":2}\n");
    CHECK(h.expect("error")["code"] == "protocol_seq", "repeated seq refused");
    CHECK(h.join() == 2, "repeat exits 2");
  }
}

void check_boundaries() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  // Nesting 16 (object plus 15 arrays) is accepted.
  {
    h.send_raw(nested(15));
    h.skip_seq();
    CHECK(h.expect("clock")["id"] == 1, "nesting of 16 levels is accepted");
  }
  auto reply = [&](json request, const char *type) {
    h.send(std::move(request));
    return h.expect(type);
  };
  CHECK(reply({{"type", "clock"}, {"id", std::string(128, 'i')}},
              "clock")["id"] == std::string(128, 'i'),
        "a 128-byte id is accepted");
  CHECK(reply({{"type", "clock"}, {"id", std::string(129, 'i')}},
              "error")["code"] == "invalid_request",
        "a 129-byte id is refused");
  CHECK(reply({{"type", "clock"}, {"id", ""}}, "error")["code"] ==
            "invalid_request",
        "an empty id is refused");
  CHECK(reply({{"type", "clock"}, {"id", 1.5}}, "error")["code"] ==
            "invalid_request",
        "a fractional id is refused");
  CHECK(reply({{"type", "clock"}, {"id", -7}}, "clock")["id"] == -7,
        "an integer id is echoed");
  CHECK(reply({{"type", "clock"}}, "error")["code"] == "invalid_request",
        "a missing id is refused");

  // Start field bounds, each refused request leaves the session unstarted.
  struct Bound {
    json fields;
    bool accepted;
    const char *label;
  };
  std::vector<Bound> bounds = {
      {{{"session", std::string(129, 's')}}, false, "session 129 bytes"},
      {{{"session", ""}}, false, "empty session"},
      {{{"session", 5}}, false, "numeric session"},
      {{{"session", "s"}, {"poll_ms", 99}}, false, "poll_ms 99"},
      {{{"session", "s"}, {"poll_ms", 5001}}, false, "poll_ms 5001"},
      {{{"session", "s"}, {"poll_ms", 1.5}}, false, "poll_ms fraction"},
      {{{"session", "s"}, {"deadline_ms", 99}}, false, "deadline_ms 99"},
      {{{"session", "s"}, {"deadline_ms", 30001}}, false, "deadline_ms 30001"},
      {{{"session", "s"}, {"deadline_ms", nullptr}, {"poll_ms", nullptr}},
       true,
       "null optional fields"},
  };
  for (const auto &bound : bounds) {
    if (bound.accepted)
      continue;
    json request = bound.fields;
    request["type"] = "start";
    request["id"] = bound.label;
    json frame = reply(request, "error");
    CHECK(frame["code"] == "invalid_request" && frame["id"] == bound.label,
          std::string("refused: ") + bound.label);
  }
  for (const auto &accepted :
       {json{{"session", std::string(128, 's')},
             {"poll_ms", 100},
             {"deadline_ms", 100}},
        json{{"session", "s"}, {"poll_ms", 5000}, {"deadline_ms", 30000}}}) {
    ScriptedSource ok_source({gated("zoom_not_running", "zoom_not_running")});
    Harness inner(ok_source);
    inner.expect("hello");
    json request = accepted;
    request["type"] = "start";
    request["id"] = "ok";
    inner.send(request);
    CHECK(inner.expect("started")["id"] == "ok", "boundary start accepted");
    inner.close_input();
    inner.join();
  }
  h.close_input();
  CHECK(h.join() == 0, "exits 0");
}

void check_framing() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  // A request split across reads, then several requests in one write.
  std::string first =
      "{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":\"split\"}\n";
  h.send_raw(first.substr(0, 17));
  ::usleep(30000);
  h.send_raw(first.substr(17));
  CHECK(h.expect("clock")["id"] == "split", "a split request is reassembled");
  h.send_raw("{\"v\":1,\"seq\":1,\"type\":\"clock\",\"id\":\"a\"}\n"
             "{\"v\":1,\"seq\":2,\"type\":\"clock\",\"id\":\"b\"}\r\n"
             "{\"v\":1,\"seq\":3,\"type\":\"clock\",\"id\":\"c\"}\n");
  CHECK(h.expect("clock")["id"] == "a", "pipelined request one");
  CHECK(h.expect("clock")["id"] == "b", "CRLF line endings are accepted");
  CHECK(h.expect("clock")["id"] == "c", "pipelined request three");
  h.close_input();
  CHECK(h.join() == 0, "clean end of input exits 0");
}

void check_start_without_zoom_and_cadence() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
  h.expect("started");
  json frame = h.expect("unavailable");
  CHECK(frame["reason"] == "zoom_not_running",
        "start without Zoom is unavailable");
  CHECK(wait_for([&] { return source.snapshots >= 6; }, 3000),
        "polling continues at the requested cadence");
  CHECK(!h.read(50).has_value(),
        "an unchanged unavailable reason is reported once");
  h.close_input();
  CHECK(h.join() == 0, "stdin close exits 0");
}

void check_cooperative_cancellation() {
  // stop while a capabilities snapshot is in flight, with more queued behind.
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    source.block_call = 1;
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", "k1"}});
    CHECK(wait_for([&] { return source.blocked.load(); }),
          "the first snapshot is in flight");
    h.send({{"type", "capabilities"}, {"id", "k2"}});
    h.send({{"type", "setup"}, {"id", "k3"}});
    h.send({{"type", "stop"}, {"id", "end"}});
    for (const char *id : {"k1", "k2", "k3"}) {
      json frame = h.expect("error");
      CHECK(frame["id"] == id && frame["code"] == "cancelled",
            std::string("queued request ") + id +
                " is answered as cancelled, not as a state: " + frame.dump());
    }
    CHECK(h.expect("stopped")["id"] == "end", "stopped follows");
    CHECK(!h.read(300).has_value(), "nothing after stopped");
    CHECK(source.access_requests == 0, "a cancelled setup never prompts");
    CHECK(h.join() == 0, "exit 0");
  }
  // stop while the first read of start is in flight: no started frame.
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    source.block_call = 1;
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "start"}, {"id", "s"}, {"session", "S"}});
    CHECK(wait_for([&] { return source.blocked.load(); }),
          "start read in flight");
    h.send({{"type", "stop"}, {"id", "end"}});
    json refused = h.expect("error");
    CHECK(refused["id"] == "s" && refused["code"] == "cancelled",
          "start cancelled during its first read");
    json stopped = h.expect("stopped");
    CHECK(stopped["session"].is_null(), "no session was started");
    CHECK(!h.read(300).has_value(), "nothing after stopped");
    CHECK(h.join() == 0, "exit 0");
  }
  // end of input while a snapshot is in flight.
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    source.block_call = 1;
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", "k"}});
    CHECK(wait_for([&] { return source.blocked.load(); }), "read in flight");
    h.close_input();
    CHECK(h.join() == 0, "end of input cancels the read and exits 0");
  }
}

void check_polling_not_starved_by_requests() {
  ScriptedSource source({meeting({tile("Ada Example" + kUnmuted, 1)})});
  source.pause_ms = 5;
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "s"}, {"session", "S"}, {"poll_ms", 100}});
  h.expect("started");
  std::string burst;
  constexpr int kBurst = 120;
  for (int i = 0; i < kBurst; ++i)
    burst += json{{"v", 1}, {"seq", i + 1}, {"type", "capabilities"}, {"id", i}}
                 .dump() +
             "\n";
  h.send_raw(burst);
  int answered = 0, busy = 0, observations_between = 0;
  for (int guard = 0; guard < 600 && answered + busy < kBurst; ++guard) {
    auto frame = h.read(5000);
    if (!frame)
      break;
    if ((*frame)["type"] == "capabilities")
      ++answered;
    else if ((*frame)["type"] == "error" && (*frame)["code"] == "busy")
      ++busy;
    else if ((*frame)["type"] == "observation" && answered > 0 &&
             answered + busy < kBurst)
      ++observations_between;
  }
  CHECK(answered + busy == kBurst,
        "every request is answered or refused as busy (" +
            std::to_string(answered) + " + " + std::to_string(busy) + ")");
  CHECK(busy > 0, "a full queue refuses instead of blocking the reader");
  CHECK(observations_between > 0, "polling continues between queued requests");
  h.close_input();
  h.join();
}

void check_broken_stdout_ends_the_helper() {
  ScriptedSource source({meeting({tile("Ada Example" + kUnmuted, 1)})});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "s"}, {"session", "S"}, {"poll_ms", 100}});
  h.expect("started");
  h.close_output(); // the reader of our frames goes away
  auto begin = steady_clock::now();
  CHECK(h.join() == 3, "a broken stdout exits 3");
  CHECK(elapsed_ms(begin) < 2000, "it stops promptly instead of polling on");
  CHECK(h.stderr_text().find("stdout_closed") != std::string::npos,
        "a stable token explains the exit");
  int polled = source.snapshots;
  ::usleep(300000);
  CHECK(source.snapshots == polled, "no accessibility reads continue");
}

// stop must not wait for queue space.
void check_stop_is_not_queued_behind_a_full_queue() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  source.pause_ms = 30;
  Harness h(source);
  h.expect("hello");
  std::string burst;
  constexpr int kBurst = 200;
  for (int i = 0; i < kBurst; ++i)
    burst +=
        json{{"v", 1}, {"seq", i}, {"type", "capabilities"}, {"id", i}}.dump() +
        "\n";
  burst +=
      json{{"v", 1}, {"seq", kBurst}, {"type", "stop"}, {"id", "end"}}.dump() +
      "\n";
  auto begin = steady_clock::now();
  h.send_raw(burst);
  std::vector<json> skipped;
  json stopped = h.find("stopped", &skipped, 400);
  CHECK(stopped["id"] == "end", "stopped arrives");
  CHECK(elapsed_ms(begin) < 1500, "stop is honored promptly behind a burst (" +
                                      std::to_string(elapsed_ms(begin)) +
                                      " ms)");
  int refused = 0;
  for (const auto &frame : skipped)
    refused += frame["type"] == "error";
  CHECK(refused > 0, "the burst was refused or cancelled, not served");
  CHECK(h.join() == 0, "exit 0");
}

// A consumer that hangs up while we are idle is noticed without a write.
void check_idle_hangup_is_detected() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  h.close_output();
  auto begin = steady_clock::now();
  CHECK(h.join() == 3, "a closed stdout exits 3 even with no session");
  CHECK(elapsed_ms(begin) < 2000, "detected promptly");
  CHECK(h.stderr_text().find("stdout_closed") != std::string::npos,
        "the token explains the exit");
}

void check_invalid_configuration_is_refused() {
  int in[2], out[2], err[2];
  if (::pipe(in) || ::pipe(out) || ::pipe(err))
    std::abort();
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  ObserverConfig config = test_config(in[0], out[1], err[1]);
  config.parse = nullptr;
  CHECK(run_observer(source, config) == 64,
        "a missing parse function is refused");
  config = test_config(in[0], out[1], err[1]);
  config.platform.clear();
  CHECK(run_observer(source, config) == 64, "a missing platform is refused");
  config = test_config(in[0], out[1], err[1]);
  config.helper.clear();
  CHECK(run_observer(source, config) == 64, "a missing helper name is refused");
  ::close(out[1]);
  char byte;
  CHECK(::read(out[0], &byte, 1) == 0, "nothing is written to stdout");
  CHECK(source.snapshots == 0, "the source is never read");
  for (int fd : {in[0], in[1], out[0], err[0], err[1]})
    ::close(fd);
}

} // namespace

// ZOOM_TEST_TRACE=1 names each test before it runs, to find a hang.
void trace(const char *name) {
  if (std::getenv("ZOOM_TEST_TRACE"))
    std::fprintf(stderr, "running %s\n", name);
}

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;
  std::signal(SIGPIPE, SIG_IGN);
  // Fork-based tests first, before any other thread exists.
  trace("check_stalled_read_stop");
  check_stalled_read_stop();
  trace("check_duplicate_start_keeps_session");
  check_duplicate_start_keeps_session();
  trace("check_eof_and_fatal_during_stall");
  check_eof_and_fatal_during_stall();
  trace("check_clock_during_stall");
  check_clock_during_stall();
  trace("check_guard_survives_a_full_stdout");
  check_guard_survives_a_full_stdout();
  trace("check_guard_reports_only_a_started_session");
  check_guard_reports_only_a_started_session();
  trace("check_hello_and_clock");
  check_hello_and_clock();
  trace("check_capabilities");
  check_capabilities();
  trace("check_session");
  check_session();
  trace("check_identity_flags_incomplete");
  check_identity_flags_incomplete();
  trace("check_ref_table");
  check_ref_table();
  trace("check_max_observation_fits_and_oversize_recovers");
  check_max_observation_fits_and_oversize_recovers();
  trace("check_protocol_errors");
  check_protocol_errors();
  trace("check_boundaries");
  check_boundaries();
  trace("check_framing");
  check_framing();
  trace("check_start_without_zoom_and_cadence");
  check_start_without_zoom_and_cadence();
  trace("check_cooperative_cancellation");
  check_cooperative_cancellation();
  trace("check_polling_not_starved_by_requests");
  check_polling_not_starved_by_requests();
  trace("check_broken_stdout_ends_the_helper");
  check_broken_stdout_ends_the_helper();
  trace("check_stop_is_not_queued_behind_a_full_queue");
  check_stop_is_not_queued_behind_a_full_queue();
  trace("check_idle_hangup_is_detected");
  check_idle_hangup_is_detected();
  trace("check_invalid_configuration_is_refused");
  check_invalid_configuration_is_refused();
  std::printf("zoom_observer_core: %d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
