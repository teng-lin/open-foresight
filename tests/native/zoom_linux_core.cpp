// The shared observer core driven with the Linux parser and a scripted Source:
// observation semantics for AT-SPI snapshots, and the shutdown behaviors the
// core guarantees (cancelled replies, broken stdout). No Zoom, AT-SPI or
// session bus is involved. The core's own platform-neutral contract is
// exercised by zoom_observer_core on macOS; these are the Linux equivalents
// that apply.
#include "zoom_atspi_parser.h"
#include "zoom_observer_core.h"

#include <nlohmann/json.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <iostream>
#include <mutex>
#include <optional>
#include <poll.h>
#include <thread>
#include <unistd.h>

using namespace foresight::zoom;
using json = nlohmann::json;
using std::chrono::milliseconds;

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

RuleSet synthetic_rules(bool speaker = true) {
  RuleSet rules;
  rules.roster = {true, {"w", ""}, {"r", ""}, "p", "me", "true"};
  rules.speaker = {speaker, "speaking"};
  return rules;
}

AxNode item(uint64_t id, const std::string &name, bool speaking = false,
            bool self = false) {
  AxNode node;
  node.object_id = id;
  node.role = "p";
  node.value = name;
  if (speaking)
    node.states.insert("speaking");
  if (self)
    node.attributes["me"] = "true";
  return node;
}

SnapshotOutcome meeting(std::vector<AxNode> people, uint64_t window = 100,
                        bool truncated = false) {
  SnapshotOutcome outcome;
  outcome.ok = true;
  outcome.pid = 4242;
  outcome.zoom_version = "0.0.0-synthetic";
  outcome.snapshot.truncated = truncated;
  outcome.snapshot.root.role = "app";
  AxNode win;
  win.role = "w";
  win.object_id = window;
  AxNode roster;
  roster.role = "r";
  roster.children = std::move(people);
  win.children.push_back(std::move(roster));
  outcome.snapshot.root.children.push_back(std::move(win));
  return outcome;
}

SnapshotOutcome gated(const char *state, const char *reason) {
  SnapshotOutcome outcome;
  outcome.state = state;
  outcome.reason = reason;
  return outcome;
}

// What LinuxSource reports when libatspi loses its registry.
SnapshotOutcome lost_registry() {
  SnapshotOutcome outcome = gated("unavailable", "atspi_bus_lost");
  outcome.fatal = true;
  outcome.fatal_exit = 4;
  return outcome;
}

class ScriptedSource final : public Source {
public:
  explicit ScriptedSource(std::vector<SnapshotOutcome> script)
      : script_(std::move(script)) {}
  void request_access() override {
    ++access_requests;
  }
  SnapshotOutcome snapshot(const std::function<bool()> &cancelled) override {
    const int call = ++snapshots;
    if (block_call == call) { // a cooperative read that ends when cancelled
      blocked = true;
      while (!cancelled())
        std::this_thread::sleep_for(milliseconds(2));
      return fatal_when_cancelled ? lost_registry()
                                  : gated("unavailable", "read_cancelled");
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
  // Replaces what later polls return.
  void script(std::vector<SnapshotOutcome> next) {
    std::lock_guard<std::mutex> lock(mutex_);
    script_ = std::move(next);
    next_ = 0;
  }

  std::atomic<int> access_requests{0}, snapshots{0};
  std::atomic<bool> blocked{false};
  int block_call = 0;
  bool fatal_when_cancelled = false;

private:
  std::mutex mutex_;
  std::vector<SnapshotOutcome> script_;
  size_t next_ = 0;
  std::atomic<uint64_t> clock_{0};
};

bool wait_for(const std::function<bool()> &condition, int timeout_ms = 5000) {
  const auto end = std::chrono::steady_clock::now() + milliseconds(timeout_ms);
  while (!condition()) {
    if (std::chrono::steady_clock::now() > end)
      return false;
    std::this_thread::sleep_for(milliseconds(2));
  }
  return true;
}

class Harness {
public:
  Harness(Source &source, const RuleSet &rules) : rules_(rules) {
    int in[2], out[2], err[2];
    if (::pipe(in) || ::pipe(out) || ::pipe(err))
      std::abort();
    request_fd_ = in[1];
    frame_fd_ = out[0];
    stderr_fd_ = err[0];
    ObserverConfig config;
    config.helper = "zoom_observer_linux";
    config.platform = "linux";
    config.parser_version = kLinuxParserVersion;
    config.parse = [this](const AxSnapshot &snapshot) {
      return parse_atspi_snapshot(snapshot, rules_);
    };
    config.in_fd = in[0];
    config.out_fd = out[1];
    config.err_fd = err[1];
    thread_ = std::thread([this, &source, config] {
      exit_code_ = run_observer(source, config);
      ::close(config.out_fd);
      ::close(config.err_fd);
      ::close(config.in_fd);
    });
  }
  ~Harness() {
    if (request_fd_ >= 0)
      ::close(request_fd_);
    join();
    if (frame_fd_ >= 0)
      ::close(frame_fd_);
    ::close(stderr_fd_);
  }
  void send(json request) {
    request["v"] = 1;
    request["seq"] = out_seq_++;
    const std::string line = request.dump() + "\n";
    (void)!::write(request_fd_, line.data(), line.size());
  }
  void close_input() {
    ::close(request_fd_);
    request_fd_ = -1;
  }
  void close_output() {
    ::close(frame_fd_);
    frame_fd_ = -1;
  }
  std::optional<json> read(int timeout_ms = 5000) {
    for (;;) {
      const auto newline = buffer_.find('\n');
      if (newline != std::string::npos) {
        json frame = json::parse(buffer_.substr(0, newline), nullptr, false);
        buffer_.erase(0, newline + 1);
        CHECK(!frame.is_discarded(), "helper output is valid JSON");
        if (frame.is_discarded())
          return std::nullopt;
        CHECK(frame["seq"].get<uint64_t>() == in_seq_++,
              "frame seq is contiguous");
        return frame;
      }
      pollfd descriptor{frame_fd_, POLLIN, 0};
      if (::poll(&descriptor, 1, timeout_ms) <= 0)
        return std::nullopt;
      char chunk[65536];
      const ssize_t count = ::read(frame_fd_, chunk, sizeof chunk);
      if (count <= 0)
        return std::nullopt;
      buffer_.append(chunk, static_cast<size_t>(count));
    }
  }
  json expect(const char *type, int timeout_ms = 5000) {
    auto frame = read(timeout_ms);
    CHECK(frame && (*frame)["type"] == type,
          std::string("expected ") + type +
              (frame ? " but got " + frame->dump() : ""));
    return frame.value_or(json::object());
  }
  std::string stderr_text() {
    std::string text;
    pollfd descriptor{stderr_fd_, POLLIN, 0};
    char chunk[4096];
    while (::poll(&descriptor, 1, 0) > 0) {
      const ssize_t count = ::read(stderr_fd_, chunk, sizeof chunk);
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
  const RuleSet &rules_;
  int request_fd_ = -1, frame_fd_ = -1, stderr_fd_ = -1;
  std::thread thread_;
  int exit_code_ = -1;
  uint64_t out_seq_ = 0, in_seq_ = 0;
  std::string buffer_;
};

// Reads observations until `accept` holds, at most `attempts` of them; records
// a failure instead of waiting for the test timeout when none does.
json observation_where(Harness &h,
                       const std::function<bool(const json &)> &accept,
                       const char *what, int attempts = 100) {
  json frame = json::object();
  for (int i = 0; i < attempts; ++i) {
    auto next = h.read(5000);
    if (!next)
      break;
    if ((*next)["type"] == "observation" && accept(*next))
      return *next;
  }
  CHECK(false, std::string("no observation matched: ") + what);
  return frame;
}

void start(Harness &h, const char *id = "s", int poll_ms = 100) {
  h.send(
      {{"type", "start"}, {"id", id}, {"session", "S"}, {"poll_ms", poll_ms}});
}

void check_hello_and_capabilities() {
  const RuleSet rules = synthetic_rules();
  ScriptedSource source({gated("needs_setup", "accessibility_disabled")});
  Harness h(source, rules);
  const json hello = h.expect("hello");
  CHECK(hello["helper"] == "zoom_observer_linux" &&
            hello["platform"] == "linux" &&
            hello["parser_version"] == "linux-0" && hello["seq"] == 0,
        "hello identifies the Linux helper");
  h.send({{"type", "capabilities"}, {"id", 1}});
  json caps = h.expect("capabilities");
  CHECK(caps["state"] == "needs_setup" &&
            caps["reason"] == "accessibility_disabled",
        "a gated state is reported as is");
  CHECK(source.access_requests == 0, "capabilities never asks for access");
  source.script({gated("needs_setup", "accessibility_disabled"),
                 meeting({item(1, "A")})});
  h.send({{"type", "setup"}, {"id", 2}});
  caps = h.expect("capabilities");
  CHECK(source.access_requests == 1 && caps["id"] == 2,
        "setup is explicit and answered with capabilities");
  h.send({{"type", "clock"}, {"id", 3}});
  const json clock = h.expect("clock");
  CHECK(clock["monotonic_ms"].is_number() && clock["uptime_ms"].is_number(),
        "clock carries both clocks");
  h.send({{"type", "stop"}, {"id", 4}});
  h.expect("stopped");
  CHECK(h.join() == 0, "stop exits 0");
}

void check_capability_mapping() {
  const RuleSet rules = synthetic_rules();
  const struct {
    SnapshotOutcome outcome;
    const char *state, *reason;
  } cases[] = {{meeting({item(1, "A")}), "available", "meeting_observed"},
               {[] {
                  SnapshotOutcome o = meeting({});
                  o.snapshot.root.children.clear();
                  return o;
                }(),
                "no_meeting", "no_meeting_window"},
               {meeting({}), "no_meeting", "no_participant_evidence"},
               {[] {
                  SnapshotOutcome o = meeting({});
                  o.snapshot.root.children.clear();
                  o.snapshot.truncated = true;
                  return o;
                }(),
                "unavailable", "incomplete_read"},
               {[] {
                  SnapshotOutcome o = meeting({item(1, "A")});
                  o.snapshot.root.children.push_back(
                      o.snapshot.root.children[0]);
                  return o;
                }(),
                "unavailable", "ambiguous_windows"}};
  for (const auto &c : cases) {
    ScriptedSource source({c.outcome});
    Harness h(source, rules);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", 1}});
    const json caps = h.expect("capabilities");
    CHECK(caps["state"] == c.state && caps["reason"] == c.reason,
          std::string("expected ") + c.state + "/" + c.reason + ", got " +
              caps.dump());
    h.send({{"type", "stop"}, {"id", 2}});
    h.expect("stopped");
  }
}

void check_start_without_zoom() {
  const RuleSet rules = synthetic_rules();
  ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
  Harness h(source, rules);
  h.expect("hello");
  start(h);
  const json started = h.expect("started");
  CHECK(started["target"]["pid"].is_null() &&
            started["target"]["zoom_version"].is_null(),
        "start without Zoom has no target");
  CHECK(h.expect("unavailable")["reason"] == "zoom_not_running",
        "start without Zoom is unavailable");
  CHECK(wait_for([&] { return source.snapshots >= 5; }, 3000),
        "polling continues");
  // The reason is unchanged across several polls: the next frame the helper
  // sends is the reply to a request, not another `unavailable`.
  h.send({{"type", "clock"}, {"id", 1}});
  CHECK(h.expect("clock")["id"] == 1, "an unchanged reason is reported once");
  h.close_input();
  CHECK(h.join() == 0, "stdin close exits 0");
}

void check_observations() {
  const RuleSet rules = synthetic_rules();
  ScriptedSource source({meeting({item(1, "Synthetic Alpha", false, true),
                                  item(2, "Beta, Synthetic", true),
                                  item(3, "Synthetic Alpha")})});
  Harness h(source, rules);
  h.expect("hello");
  start(h);
  h.expect("started");
  json obs = h.expect("observation");
  // Two people share a display name: they keep separate refs, but on first
  // sight the core cannot know which element is which person, so the read is
  // flagged (it settles once the same elements are seen again).
  CHECK(obs["parser_version"] == "linux-0" && obs["complete"] == false,
        "first sight of an equal-name pair is flagged incomplete");
  CHECK(obs["target"]["window"] == "w1" && obs["target"]["pid"] == 4242 &&
            obs["target"]["locale"].is_null(),
        "target: meeting-local window label, no locale evidence on Linux");
  const json alpha = obs["participants"][0], twin = obs["participants"][2];
  CHECK(alpha["self"] == true && alpha["ref"] != twin["ref"],
        "equal names keep separate refs");
  CHECK(obs["participants"][1]["name"] == "Beta, Synthetic", "commas are kept");
  CHECK(obs["speakers"] == json::array({{{"ref", obs["participants"][1]["ref"]},
                                         {"method", "atspi_state"}}}),
        "speaker with the atspi_state method");

  // Nobody speaking: an observed absence. A rename on the same element: new
  // ref.
  source.script(
      {meeting({item(1, "Synthetic Alpha", false, true),
                item(2, "Renamed", false), item(3, "Synthetic Alpha")})});
  const json next = observation_where(
      h,
      [](const json &o) {
        return o["participants"].size() > 1 &&
               o["participants"][1]["name"] == "Renamed";
      },
      "rename seen");
  if (next.is_null() || !next.contains("participants"))
    return;
  CHECK(next["speakers"].empty() && next["complete"] == true,
        "complete read without a speaker");
  CHECK(next["participants"][0]["ref"] == alpha["ref"],
        "an unchanged element keeps its ref");
  CHECK(next["participants"][1]["ref"] != obs["participants"][1]["ref"],
        "an element showing another name gets a new ref");

  // A failed read never extends the speaker.
  source.script({gated("unavailable", "ax_read_failed")});
  json gone = h.expect("unavailable");
  CHECK(gone["reason"] == "ax_read_failed", "failed read is unavailable");

  // Truncated roster: kept, incomplete, no speaker. An unnamed item: dropped,
  // incomplete.
  source.script({meeting({item(2, "Beta, Synthetic", true)}, 100, true)});
  json partial = h.expect("observation");
  CHECK(partial["complete"] == false && partial["speakers"].empty() &&
            partial["participants"].size() == 1,
        "truncated: roster kept, incomplete, no speaker");
  source.script({meeting({item(2, "Beta", true), item(9, "\xe2\x80\x8b")})});
  const json unnamed = observation_where(
      h,
      [](const json &o) {
        return o["participants"].size() == 1 && o["complete"] == false;
      },
      "unnamed item dropped");
  if (!unnamed.contains("speakers"))
    return;
  CHECK(unnamed["speakers"].empty(),
        "an unnamed item makes the read incomplete, with no speaker");

  // A different window gets the next label.
  source.script({meeting({item(2, "Beta")}, 200)});
  observation_where(
      h, [](const json &o) { return o["target"]["window"] == "w2"; },
      "second window label");
  h.send({{"type", "stop"}, {"id", 5}});
  json tail = h.expect("stopped");
  (void)tail;
}

void check_unique_names_are_complete_on_first_sight() {
  const RuleSet rules = synthetic_rules();
  ScriptedSource source(
      {meeting({item(1, "Synthetic Alpha"), item(2, "Synthetic Beta", true)})});
  Harness h(source, rules);
  h.expect("hello");
  start(h);
  h.expect("started");
  const json obs = h.expect("observation");
  CHECK(obs["complete"] == true && obs["speakers"].size() == 1,
        "distinct names are complete and name their speaker on first sight");
  h.send({{"type", "stop"}, {"id", 2}});
  h.expect("stopped");
}

void check_no_speaker_signal_is_never_silence() {
  const RuleSet rules = synthetic_rules(/*speaker=*/false);
  ScriptedSource source({meeting({item(1, "Synthetic Alpha", true)})});
  Harness h(source, rules);
  h.expect("hello");
  start(h);
  h.expect("started");
  const json obs = h.expect("observation");
  CHECK(obs["complete"] == false && obs["speakers"].empty() &&
            obs["participants"].size() == 1,
        "without a validated speaker signal the roster is reported, "
        "incomplete, no speaker");
  h.send({{"type", "stop"}, {"id", 2}});
  h.expect("stopped");
}

void check_fatal_source_outcome() {
  const RuleSet rules = synthetic_rules();
  // A request that causes the fatal read gets the terminal error, with its id,
  // instead of a capabilities/started reply; then the process ends with the
  // source's exit status.
  for (const char *type : {"capabilities", "setup", "start"}) {
    ScriptedSource source({lost_registry()});
    Harness h(source, rules);
    h.expect("hello");
    json request = {{"type", type}, {"id", "r7"}};
    if (std::string(type) == "start")
      request["session"] = "S";
    h.send(request);
    const json error = h.expect("error");
    CHECK(error["id"] == "r7" && error["code"] == "atspi_bus_lost",
          std::string(type) +
              ": terminal error carries the request id and reason");
    CHECK(!h.read(100).has_value(),
          std::string(type) + ": nothing follows the error");
    CHECK(h.join() == 4,
          std::string(type) + ": exits with the source's status");
  }
  // A poll that turns fatal first reports the unavailable interval, then ends.
  {
    ScriptedSource source(
        {meeting({item(1, "Synthetic Alpha")}), lost_registry()});
    Harness h(source, rules);
    h.expect("hello");
    start(h);
    h.expect("started");
    h.expect("observation");
    CHECK(h.expect("unavailable")["reason"] == "atspi_bus_lost",
          "the loss is reported");
    const json error = h.expect("error");
    CHECK(error["code"] == "atspi_bus_lost" && !error.contains("id"),
          "then a terminal error without a request id");
    CHECK(h.join() == 4, "and the process exits 4");
  }
  // A stop that arrived first wins: the queued request is answered cancelled,
  // the stop is answered, and the exit is the clean one.
  {
    ScriptedSource source({lost_registry()});
    source.block_call = 1;
    source.fatal_when_cancelled = true;
    Harness h(source, rules);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", "k1"}});
    CHECK(wait_for([&] { return source.blocked.load(); }),
          "the read is in flight");
    h.send({{"type", "stop"}, {"id", "end"}});
    const json refused = h.expect("error");
    CHECK(refused["id"] == "k1" && refused["code"] == "cancelled",
          "the request is cancelled, not turned into a fatal error");
    CHECK(h.expect("stopped")["id"] == "end", "the stop is answered");
    CHECK(h.join() == 0, "exit 0, not the fatal status");
  }
}

void check_cancellation() {
  const RuleSet rules = synthetic_rules();
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    source.block_call = 1;
    Harness h(source, rules);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", "k1"}});
    CHECK(wait_for([&] { return source.blocked.load(); }),
          "the first snapshot is in flight");
    h.send({{"type", "capabilities"}, {"id", "k2"}});
    h.send({{"type", "setup"}, {"id", "k3"}});
    h.send({{"type", "stop"}, {"id", "end"}});
    for (const char *id : {"k1", "k2", "k3"}) {
      const json frame = h.expect("error");
      CHECK(frame["id"] == id && frame["code"] == "cancelled",
            std::string("cancelled: ") + id);
    }
    h.expect("stopped");
    CHECK(source.access_requests == 0,
          "a cancelled setup never changes anything");
    CHECK(h.join() == 0, "exit 0");
  }
  {
    ScriptedSource source({gated("zoom_not_running", "zoom_not_running")});
    source.block_call = 1;
    Harness h(source, rules);
    h.expect("hello");
    h.send({{"type", "capabilities"}, {"id", "k"}});
    CHECK(wait_for([&] { return source.blocked.load(); }), "read in flight");
    h.close_input();
    CHECK(h.join() == 0, "end of input cancels the read and exits 0");
  }
}

void check_broken_stdout() {
  const RuleSet rules = synthetic_rules();
  ScriptedSource source({meeting({item(1, "Synthetic Alpha")})});
  Harness h(source, rules);
  h.expect("hello");
  start(h); // polls every 100 ms
  h.expect("started");
  h.expect("observation"); // at least one poll has run
  const int before = source.snapshots;
  h.close_output(); // the next frame the helper writes fails
  CHECK(h.join() == 3, "a broken stdout exits 3");
  CHECK(h.stderr_text().find("stdout_closed") != std::string::npos,
        "a stable token explains the exit");
  // At 100 ms a helper that kept polling would add many reads; a prompt exit
  // adds at most the poll in flight and the one whose frame failed.
  const int after = source.snapshots;
  CHECK(after - before <= 3, "polling stops promptly when stdout breaks");
}

} // namespace

int main() {
  std::signal(SIGPIPE, SIG_IGN);
  check_hello_and_capabilities();
  check_capability_mapping();
  check_start_without_zoom();
  check_observations();
  check_unique_names_are_complete_on_first_sight();
  check_no_speaker_signal_is_never_silence();
  check_cancellation();
  check_fatal_source_outcome();
  check_broken_stdout();
  std::cout << "zoom_linux_core: " << checks << " checks, " << failures
            << " failures\n";
  return failures == 0 ? 0 : 1;
}
