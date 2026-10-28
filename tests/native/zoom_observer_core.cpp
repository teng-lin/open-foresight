// Protocol core contract: framing, sequencing, session semantics and shutdown,
// driven in-process through pipes with a scripted Source (no Zoom, no
// Accessibility permission).
#include "zoom_observer_core.h"

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
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

using namespace foresight::zoom;
using json = nlohmann::json;

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

class ScriptedSource final : public Source {
public:
  explicit ScriptedSource(std::vector<SnapshotOutcome> script)
      : script_(std::move(script)) {}

  void request_access() override {
    ++access_requests;
  }

  SnapshotOutcome snapshot(const std::function<bool()> &) override {
    ++snapshots;
    if (stall_ms) {
      std::this_thread::sleep_for(std::chrono::milliseconds(stall_ms));
    }
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
  int stall_ms = 0;

private:
  std::mutex mutex_;
  std::vector<SnapshotOutcome> script_;
  size_t next_ = 0;
  std::atomic<uint64_t> clock_{0};
};

// One observer wired to pipes, driven from the test thread.
class Harness {
public:
  explicit Harness(Source &source) {
    int in[2], out[2], err[2];
    if (::pipe(in) || ::pipe(out) || ::pipe(err))
      std::abort();
    request_fd_ = in[1];
    frame_fd_ = out[0];
    ObserverConfig config;
    config.in_fd = in[0];
    config.out_fd = out[1];
    config.err_fd = err[1];
    thread_ = std::thread([this, &source, config, in0 = in[0], out1 = out[1],
                           err1 = err[1], err0 = err[0]] {
      exit_code_ = run_observer(source, config);
      ::close(out1);
      ::close(err1);
      ::close(in0);
      ::close(err0);
    });
  }

  ~Harness() {
    if (request_fd_ >= 0)
      ::close(request_fd_);
    if (thread_.joinable())
      thread_.join();
    ::close(frame_fd_);
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

  void close_input() {
    ::close(request_fd_);
    request_fd_ = -1;
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

  int join() {
    if (thread_.joinable())
      thread_.join();
    return exit_code_;
  }

private:
  int request_fd_ = -1, frame_fd_ = -1;
  std::thread thread_;
  int exit_code_ = -1;
  uint64_t out_seq_ = 0, in_seq_ = 0;
  std::string buffer_;
};

const std::string kUnmuted = ", Computer audio unmuted";

void check_hello_and_clock() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  json hello = h.expect("hello");
  CHECK(hello["seq"] == 0, "hello is seq 0");
  CHECK(hello["helper"] == "zoom_observer_macos", "helper name");
  CHECK(hello["platform"] == "macos", "platform");
  CHECK(hello["parser_version"] == "mac-1", "parser version");
  h.send({{"type", "clock"}, {"id", "c1"}});
  json clock = h.expect("clock");
  CHECK(clock["id"] == "c1", "clock echoes id");
  CHECK(clock["monotonic_ms"].is_number_unsigned(), "monotonic_ms");
  CHECK(clock["uptime_ms"].is_number_unsigned(), "uptime_ms");
  h.send({{"type", "stop"}, {"id", 9}});
  json stopped = h.expect("stopped");
  CHECK(stopped["id"] == 9 && stopped["session"].is_null(),
        "stop before start reports no session");
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
      {meeting({}), "no_meeting", "no_meeting_window", true},
      {unsupported_locale, "unavailable", "unsupported_locale", true},
      {meeting({tile("Ada Example" + kUnmuted)}), "available",
       "meeting_observed", true},
  };
  // The meeting({}) window has no tiles; give the no_meeting case a window-free
  // application so the reason is the intended one.
  cases[6].outcome.snapshot.root.children.clear();
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
          std::string("reason ") + entry.reason);
    CHECK(frame["zoom_version"].is_null() != entry.version,
          "zoom_version presence");
    CHECK(source.access_requests == 0, "capabilities never prompts");
    if (std::string(entry.state) == "available")
      CHECK(frame["locale"] == "en", "capabilities reports the locale");
    h.close_input();
    CHECK(h.join() == 0, "stdin close exits 0");
  }
  // Explicit setup prompts once and replies with capabilities.
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

json participant_by_name(const json &observation, const std::string &name,
                         size_t occurrence = 0) {
  for (const auto &p : observation["participants"])
    if (p["name"] == name && occurrence-- == 0)
      return p;
  return json::object();
}

void check_session() {
  SnapshotOutcome speaking =
      meeting({tile("Ada Example" + kUnmuted + ", Active speaker", 11),
               tile("Bob Example" + kUnmuted, 12)});
  SnapshotOutcome silent = meeting(
      {tile("Ada Example" + kUnmuted, 11), tile("Bob Example" + kUnmuted, 12)});
  SnapshotOutcome renamed =
      meeting({tile("Ada Renamed" + kUnmuted + ", Active speaker", 11),
               tile("Bob Example" + kUnmuted, 12)});
  SnapshotOutcome truncated = silent;
  truncated.snapshot.truncated = true;
  SnapshotOutcome second_window =
      meeting({tile("Ada Example" + kUnmuted, 11)}, 777);
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running"),
                         gated("zoom_not_running", "zoom_not_running"),
                         speaking, silent, renamed,
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

  // The repeated failure produces no second frame; the next frame is the
  // first observation.
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

  json rename = h.expect("observation");
  CHECK(participant_by_name(rename, "Ada Renamed")["ref"] == ada["ref"],
        "rename keeps the ref while the element persists");
  CHECK(rename["speakers"][0]["ref"] == ada["ref"], "renamed speaker");

  json failed = h.expect("unavailable");
  CHECK(failed["reason"] == "ax_read_failed", "failed read is unavailable");
  CHECK(failed["since_ms"].get<uint64_t>() >
            rename["read_start_ms"].get<uint64_t>(),
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

  json other = {{"type", "start"}, {"id", "again"}, {"session", "s2"}};
  h.send(other);
  // Observations may interleave; find the error.
  for (int i = 0; i < 10; ++i) {
    auto frame = h.read();
    if (frame && (*frame)["type"] == "error") {
      CHECK((*frame)["code"] == "already_started" && (*frame)["id"] == "again",
            "second start is refused");
      break;
    }
  }
  h.send({{"type", "stop"}, {"id", "end"}});
  for (int i = 0; i < 10; ++i) {
    auto frame = h.read();
    if (frame && (*frame)["type"] == "stopped") {
      CHECK((*frame)["id"] == "end" && (*frame)["session"] == "s1",
            "stopped echoes the session");
      break;
    }
  }
  CHECK(h.join() == 0, "stop exits 0");
}

void check_refs_without_element_identity() {
  // No object ids: refs fall back to name and ordinal, so equal names stay
  // separate and stable.
  SnapshotOutcome both =
      meeting({tile("Twin Example" + kUnmuted),
               tile("Twin Example" + kUnmuted + ", Active speaker")});
  ScriptedSource source({both});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
  h.expect("started");
  json one = h.expect("observation");
  json two = h.expect("observation");
  CHECK(one["participants"].size() == 2, "both twins reported");
  CHECK(one["participants"][0]["ref"] != one["participants"][1]["ref"],
        "equal names have different refs");
  CHECK(one["participants"][0]["ref"] == two["participants"][0]["ref"] &&
            one["participants"][1]["ref"] == two["participants"][1]["ref"],
        "ordinal refs are stable");
  CHECK(one["speakers"][0]["ref"] == one["participants"][1]["ref"],
        "the speaker is the marked twin");
  h.close_input();
  CHECK(h.join() == 0, "stdin close exits 0");
}

void check_max_observation_fits() {
  std::vector<AxNode> tiles;
  for (size_t i = 0; i < kMaxParticipants; ++i) {
    std::string name = std::to_string(1000 + i);
    name.resize(kMaxNameBytes, 'n');
    tiles.push_back(tile(name + kUnmuted, 100 + i));
  }
  ScriptedSource source({meeting(std::move(tiles))});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
  h.expect("started");
  json frame = h.expect("observation");
  CHECK(frame["participants"].size() == kMaxParticipants,
        "a maximal observation is delivered");
  h.close_input();
  h.join();
}

void expect_fatal(const char *label, const std::string &raw, const char *code) {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  h.send_raw(raw);
  json frame = h.expect("error");
  CHECK(frame["code"] == code, std::string(label) + " code " + frame.dump());
  CHECK(!frame.contains("id") || frame["id"].is_null(),
        "fatal error has no id");
  CHECK(!h.read(300).has_value(), std::string(label) + ": session closed");
  CHECK(h.join() == 2, std::string(label) + ": exit code 2");
}

void check_protocol_errors() {
  expect_fatal("malformed", "{not json\n", "malformed_json");
  expect_fatal("array", "[1,2]\n", "malformed_json");
  expect_fatal("blank", "\n", "malformed_json");
  expect_fatal("truncated utf8",
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
  expect_fatal("deep nesting",
               "{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":1,\"x\":" +
                   std::string(40, '[') + std::string(40, ']') + "}\n",
               "malformed_json");
  // Exactly at the bound is accepted as a line; one byte more is refused.
  expect_fatal("line too long", std::string(kMaxLineBytes + 1, 'a'),
               "line_too_long");

  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "clock"}, {"id", 1}});
    h.expect("clock");
    // A repeat of an already used seq is also a gap.
    h.send_raw("{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":2}\n");
    CHECK(h.expect("error")["code"] == "protocol_seq", "repeated seq refused");
    CHECK(h.join() == 2, "repeat exits 2");
  }
  {
    // A line of exactly the maximum size is not a length error (it fails
    // later, as malformed JSON, but never as line_too_long).
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    Harness h(source);
    h.expect("hello");
    std::string padded =
        "{\"v\":1,\"seq\":0,\"type\":\"clock\",\"id\":1,\"pad\":\"";
    std::string tail = "\"}";
    padded.append(kMaxLineBytes - padded.size() - tail.size(), 'p');
    padded += tail;
    padded += '\n';
    h.send_raw(padded);
    json clock = h.expect("clock");
    CHECK(clock["id"] == 1, "a maximum-size line is accepted");
    h.close_input();
    CHECK(h.join() == 0, "exits 0");
  }
  {
    // Well-formed requests with bad fields are refused without closing.
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    Harness h(source);
    h.expect("hello");
    h.send({{"type", "capabilities"}});
    json missing_id = h.expect("error");
    CHECK(missing_id["code"] == "invalid_request" && missing_id["id"].is_null(),
          "missing id is a request error");
    h.send({{"type", "start"}, {"id", "x"}});
    json no_session = h.expect("error");
    CHECK(no_session["code"] == "invalid_request" && no_session["id"] == "x",
          "missing session");
    h.send({{"type", "start"}, {"id", "y"}, {"session", "s"}, {"poll_ms", 5}});
    CHECK(h.expect("error")["id"] == "y", "poll_ms below the minimum");
    h.send({{"type", "start"},
            {"id", "z"},
            {"session", "s"},
            {"poll_ms", "fast"}});
    CHECK(h.expect("error")["id"] == "z", "poll_ms must be an integer");
    h.send({{"type", "start"},
            {"id", "w"},
            {"session", "s"},
            {"deadline_ms", 10}});
    CHECK(h.expect("error")["id"] == "w", "deadline_ms below the minimum");
    h.send({{"type", "capabilities"}, {"id", std::string(200, 'i')}});
    CHECK(h.expect("error")["code"] == "invalid_request", "oversized id");
    h.send({{"type", "capabilities"}, {"id", "ok"}, {"unknown_field", {1, 2}}});
    CHECK(h.expect("capabilities")["id"] == "ok",
          "unknown fields are ignored and the session continues");
    h.close_input();
    CHECK(h.join() == 0, "still exits 0 on stdin close");
  }
}

void check_start_without_zoom() {
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source);
  h.expect("hello");
  h.send({{"type", "start"}, {"id", "a"}, {"session", "s"}, {"poll_ms", 100}});
  h.expect("started");
  json frame = h.expect("unavailable");
  CHECK(frame["reason"] == "zoom_not_running",
        "start without Zoom is unavailable");
  CHECK(!h.read(450).has_value(),
        "an unchanged unavailable reason is reported once");
  h.close_input();
  CHECK(h.join() == 0, "stdin close exits 0");
}

// A source stuck in an accessibility call must not outlive stop's deadline.
void check_stalled_read_stop() {
  int in[2], out[2];
  if (::pipe(in) || ::pipe(out))
    std::abort();
  pid_t child = ::fork();
  if (child == 0) {
    ::close(in[1]);
    ::close(out[0]);
    ScriptedSource source({meeting({tile("Ada Example" + kUnmuted)})});
    source.stall_ms = 6000;
    ObserverConfig config;
    config.in_fd = in[0];
    config.out_fd = out[1];
    config.err_fd = ::open("/dev/null", O_WRONLY);
    int code = run_observer(source, config);
    ::_exit(code);
  }
  ::close(in[0]);
  ::close(out[1]);
  auto send = [&](const json &request) {
    std::string line = request.dump() + "\n";
    (void)!::write(in[1], line.data(), line.size());
  };
  send({{"v", 1},
        {"seq", 0},
        {"type", "start"},
        {"id", "a"},
        {"session", "s"},
        {"poll_ms", 100},
        {"deadline_ms", 300}});
  ::usleep(150000); // let the stalled first read begin
  auto begin = std::chrono::steady_clock::now();
  send({{"v", 1}, {"seq", 1}, {"type", "stop"}, {"id", "b"}});
  std::string output;
  pollfd descriptor{out[0], POLLIN, 0};
  while (output.find("\"stopped\"") == std::string::npos &&
         ::poll(&descriptor, 1, 3000) > 0) {
    char chunk[4096];
    ssize_t count = ::read(out[0], chunk, sizeof chunk);
    if (count <= 0)
      break;
    output.append(chunk, static_cast<size_t>(count));
  }
  auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now() - begin)
                     .count();
  CHECK(output.find("\"stopped\"") != std::string::npos,
        "stop is answered while a read is stalled");
  CHECK(elapsed < 2000, "stop honors deadline_ms rather than the stall");
  int status = 0;
  ::waitpid(child, &status, 0);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "stalled helper exits 0 after stop");
  ::close(in[1]);
  ::close(out[0]);
}

} // namespace

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;
  std::signal(SIGPIPE, SIG_IGN);
  // Fork-based test first, before any other thread exists.
  check_stalled_read_stop();
  check_hello_and_clock();
  check_capabilities();
  check_session();
  check_refs_without_element_identity();
  check_max_observation_fits();
  check_protocol_errors();
  check_start_without_zoom();
  std::printf("zoom_observer_core: %d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
