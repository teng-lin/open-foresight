#include "zoom_observer_core.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace foresight::zoom {
namespace {

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;

constexpr size_t kMaxIdBytes = 128;
constexpr size_t kMaxSessionBytes = 128;
constexpr int kMaxRequestNesting = 16;
constexpr size_t kMaxRefEntries = 4096;
constexpr int kMaxDiagnostics = 32;

// Bounded stderr diagnostics: stable tokens only, never names or text.
class Diagnostics {
public:
  explicit Diagnostics(int fd) : fd_(fd) {}
  void note(const char *token) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (count_ >= kMaxDiagnostics)
      return;
    ++count_;
    std::string line = "zoom_observer: ";
    line += token;
    line += '\n';
    (void)!::write(fd_, line.data(), line.size());
  }

private:
  std::mutex mutex_;
  int fd_;
  int count_ = 0;
};

// Serializes frames from the reader and polling threads and owns `seq`.
class Writer {
public:
  explicit Writer(int fd) : fd_(fd) {}

  // Returns false when the frame was not written (closed or oversized).
  bool emit(const char *type, json frame, bool terminal = false) {
    frame["v"] = kProtocolVersion;
    frame["type"] = type;
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_)
      return false;
    frame["seq"] = seq_;
    std::string line =
        frame.dump(-1, ' ', false, json::error_handler_t::replace);
    if (line.size() >= kMaxLineBytes)
      return false;
    line += '\n';
    bool written = write_all(line);
    if (written)
      ++seq_;
    if (!written || terminal)
      closed_ = true;
    return written;
  }

private:
  bool write_all(const std::string &data) {
    size_t offset = 0;
    while (offset < data.size()) {
      ssize_t written =
          ::write(fd_, data.data() + offset, data.size() - offset);
      if (written < 0) {
        if (errno == EINTR)
          continue;
        return false;
      }
      offset += static_cast<size_t>(written);
    }
    return true;
  }

  std::mutex mutex_;
  int fd_;
  uint64_t seq_ = 0;
  bool closed_ = false;
};

struct Request {
  enum class Kind { Capabilities, Setup, Start, Stop, Reject, Eof, Fatal };
  Kind kind = Kind::Eof;
  json id; // null when absent
  std::string session;
  int poll_ms = kDefaultPollMs;
  std::string code; // Reject/Fatal
};

struct Shared {
  std::mutex mutex;
  std::condition_variable wake;     // new request or terminal event
  std::condition_variable finished; // main loop is done
  std::deque<Request> queue;
  bool done = false;
  std::atomic<bool> cancel{false};
  std::atomic<int> deadline_ms{kDefaultDeadlineMs};
  std::string session; // last valid start request
};

bool nesting_exceeds(const std::string &line, int limit) {
  int depth = 0;
  bool in_string = false, escaped = false;
  for (char c : line) {
    if (in_string) {
      if (escaped)
        escaped = false;
      else if (c == '\\')
        escaped = true;
      else if (c == '"')
        in_string = false;
    } else if (c == '"') {
      in_string = true;
    } else if (c == '[' || c == '{') {
      if (++depth > limit)
        return true;
    } else if (c == ']' || c == '}') {
      --depth;
    }
  }
  return false;
}

bool valid_id(const json &value) {
  return value.is_number_integer() ||
         (value.is_string() && !value.get_ref<const std::string &>().empty() &&
          value.get_ref<const std::string &>().size() <= kMaxIdBytes);
}

// Reads an optional bounded integer field. Returns false if present but
// invalid.
bool optional_int(const json &request, const char *name, int low, int high,
                  int &out) {
  auto it = request.find(name);
  if (it == request.end() || it->is_null())
    return true;
  if (!it->is_number_integer())
    return false;
  long long value = it->get<long long>();
  if (value < low || value > high)
    return false;
  out = static_cast<int>(value);
  return true;
}

class Reader {
public:
  Reader(Shared &shared, Writer &writer, Source &source, Diagnostics &diag,
         int fd)
      : shared_(shared), writer_(writer), source_(source), diag_(diag),
        fd_(fd) {}

  void run() {
    std::string line;
    char chunk[65536];
    for (;;) {
      ssize_t count = ::read(fd_, chunk, sizeof chunk);
      if (count < 0 && errno == EINTR)
        continue;
      if (count <= 0) {
        terminate(Request::Kind::Eof, {}, kDefaultDeadlineMs);
        return;
      }
      for (ssize_t i = 0; i < count; ++i) {
        if (chunk[i] != '\n') {
          line.push_back(chunk[i]);
          if (line.size() > kMaxLineBytes) {
            fatal("line_too_long");
            return;
          }
          continue;
        }
        bool keep_reading = handle_line(line);
        line.clear();
        if (!keep_reading)
          return;
      }
    }
  }

private:
  void push(Request request) {
    {
      std::lock_guard<std::mutex> lock(shared_.mutex);
      shared_.queue.push_back(std::move(request));
    }
    shared_.wake.notify_all();
  }

  // Delivers a terminal event, then guards it: if the polling thread does not
  // finish within the deadline (a stalled accessibility call), the reader
  // emits the closing frame itself and exits, so a stall cannot outlive stop.
  void terminate(Request::Kind kind, Request request, int deadline_ms) {
    request.kind = kind;
    shared_.cancel = true;
    push(request);
    std::unique_lock<std::mutex> lock(shared_.mutex);
    if (shared_.finished.wait_for(lock, std::chrono::milliseconds(deadline_ms),
                                  [&] { return shared_.done; }))
      return;
    lock.unlock();
    diag_.note("shutdown_deadline");
    if (kind == Request::Kind::Stop)
      writer_.emit(
          "stopped",
          {{"id", request.id},
           {"session",
            shared_.session.empty() ? json(nullptr) : json(shared_.session)}},
          true);
    else if (kind == Request::Kind::Fatal)
      writer_.emit("error",
                   {{"code", request.code}, {"message", "protocol error"}},
                   true);
    ::_exit(kind == Request::Kind::Fatal ? 2 : 0);
  }

  void fatal(const char *code) {
    Request request;
    request.code = code;
    terminate(Request::Kind::Fatal, request, kDefaultDeadlineMs);
  }

  void reject(const json &id, const char *code) {
    Request request;
    request.kind = Request::Kind::Reject;
    request.id = valid_id(id) ? id : json(nullptr);
    request.code = code;
    push(std::move(request));
  }

  bool handle_line(const std::string &raw) {
    std::string line = raw;
    if (!line.empty() && line.back() == '\r')
      line.pop_back();
    if (nesting_exceeds(line, kMaxRequestNesting)) {
      fatal("malformed_json");
      return false;
    }
    json request = json::parse(line, nullptr, false);
    if (request.is_discarded() || !request.is_object()) {
      fatal("malformed_json");
      return false;
    }
    auto version = request.find("v");
    if (version == request.end() || !version->is_number_integer() ||
        version->get<long long>() != kProtocolVersion) {
      fatal("protocol_version");
      return false;
    }
    auto seq = request.find("seq");
    if (seq == request.end() || !seq->is_number_unsigned() ||
        seq->get<uint64_t>() != expected_seq_) {
      fatal("protocol_seq");
      return false;
    }
    ++expected_seq_;
    auto type_it = request.find("type");
    if (type_it == request.end() || !type_it->is_string()) {
      fatal("protocol_type");
      return false;
    }
    const std::string &type = type_it->get_ref<const std::string &>();
    json id = request.value("id", json(nullptr));
    if (type != "capabilities" && type != "setup" && type != "start" &&
        type != "stop" && type != "clock") {
      fatal("protocol_type");
      return false;
    }
    if (!valid_id(id)) {
      reject(id, "invalid_request");
      return true;
    }
    if (type == "clock") {
      writer_.emit("clock", {{"id", id},
                             {"monotonic_ms", source_.monotonic_ms()},
                             {"uptime_ms", source_.uptime_ms()}});
      return true;
    }
    Request out;
    out.id = id;
    if (type == "capabilities") {
      out.kind = Request::Kind::Capabilities;
    } else if (type == "setup") {
      out.kind = Request::Kind::Setup;
    } else if (type == "start") {
      out.kind = Request::Kind::Start;
      auto session = request.find("session");
      int deadline = kDefaultDeadlineMs;
      if (session == request.end() || !session->is_string() ||
          session->get_ref<const std::string &>().empty() ||
          session->get_ref<const std::string &>().size() > kMaxSessionBytes ||
          !optional_int(request, "poll_ms", kMinPollMs, kMaxPollMs,
                        out.poll_ms) ||
          !optional_int(request, "deadline_ms", kMinDeadlineMs, kMaxDeadlineMs,
                        deadline)) {
        reject(id, "invalid_request");
        return true;
      }
      out.session = session->get<std::string>();
      shared_.deadline_ms = deadline;
      {
        std::lock_guard<std::mutex> lock(shared_.mutex);
        shared_.session = out.session;
      }
    } else {
      terminate(Request::Kind::Stop, out, shared_.deadline_ms.load());
      return false;
    }
    push(std::move(out));
    return true;
  }

  Shared &shared_;
  Writer &writer_;
  Source &source_;
  Diagnostics &diag_;
  int fd_;
  uint64_t expected_seq_ = 0;
};

struct Verdict {
  bool available = false;
  std::string state;
  std::string reason;
  ParseResult parsed;
};

Verdict classify(const SnapshotOutcome &outcome) {
  Verdict verdict;
  if (!outcome.ok) {
    verdict.state = outcome.state.empty() ? "unavailable" : outcome.state;
    verdict.reason = outcome.reason.empty() ? verdict.state : outcome.reason;
    return verdict;
  }
  verdict.parsed = parse_snapshot(outcome.snapshot);
  if (verdict.parsed.available) {
    verdict.available = true;
    verdict.state = "available";
    verdict.reason = "meeting_observed";
    return verdict;
  }
  const std::string &why = verdict.parsed.reason;
  bool empty = why == "no_meeting_window" || why == "no_participant_evidence";
  if (empty && outcome.locale_unsupported) {
    verdict.state = "unavailable";
    verdict.reason = "unsupported_locale";
  } else {
    verdict.state = empty ? "no_meeting" : "unavailable";
    verdict.reason = why;
  }
  return verdict;
}

json nullable(const std::string &text) {
  return text.empty() ? json(nullptr) : json(text);
}

// Meeting-local participant references: stable while the same accessibility
// element (or, lacking one, the same name and ordinal) persists in a window.
class RefTable {
public:
  void assign(const std::string &window, std::vector<std::string> &refs,
              const std::vector<Participant> &participants) {
    if (window != window_ || entries() > kMaxRefEntries) {
      window_ = window;
      by_object_.clear();
      by_key_.clear();
    }
    std::map<std::string, int> ordinals;
    refs.clear();
    for (const auto &participant : participants) {
      std::string ref;
      if (participant.object_id != 0) {
        auto [it, inserted] = by_object_.try_emplace(participant.object_id);
        if (inserted)
          it->second = next();
        ref = it->second;
      } else {
        int ordinal = ordinals[participant.key]++;
        auto [it, inserted] = by_key_.try_emplace({participant.key, ordinal});
        if (inserted)
          it->second = next();
        ref = it->second;
      }
      refs.push_back(ref);
    }
  }

private:
  size_t entries() const {
    return by_object_.size() + by_key_.size();
  }
  std::string next() {
    return "p" + std::to_string(++counter_);
  }

  std::string window_;
  uint64_t counter_ = 0;
  std::map<uint64_t, std::string> by_object_;
  std::map<std::pair<std::string, int>, std::string> by_key_;
};

class Session {
public:
  Session(Source &source, Writer &writer, Shared &shared, Diagnostics &diag)
      : source_(source), writer_(writer), shared_(shared), diag_(diag) {}

  bool started() const {
    return started_;
  }
  Clock::time_point next_poll() const {
    return next_;
  }

  void start(const Request &request) {
    session_ = request.session;
    poll_ms_ = request.poll_ms;
    started_ = true;
    auto begin = Clock::now();
    SnapshotOutcome outcome = source_.snapshot(cancelled());
    json target = {{"pid", outcome.pid > 0 ? json(outcome.pid) : json(nullptr)},
                   {"zoom_version", nullable(outcome.zoom_version)}};
    writer_.emit(
        "started",
        {{"id", request.id}, {"session", session_}, {"target", target}});
    publish(outcome);
    schedule(begin);
  }

  void poll() {
    auto begin = Clock::now();
    SnapshotOutcome outcome = source_.snapshot(cancelled());
    if (shared_.cancel) {
      next_ = Clock::now() + std::chrono::milliseconds(5);
      return; // a read abandoned for shutdown reports nothing
    }
    publish(outcome);
    schedule(begin);
  }

  std::string session() const {
    return session_;
  }

private:
  std::function<bool()> cancelled() {
    return [this] { return shared_.cancel.load(); };
  }

  void schedule(Clock::time_point begin) {
    next_ = std::max(begin + std::chrono::milliseconds(poll_ms_),
                     Clock::now() + std::chrono::milliseconds(20));
  }

  void publish(const SnapshotOutcome &outcome) {
    uint64_t start_ms =
        outcome.read_start_ms ? outcome.read_start_ms : source_.monotonic_ms();
    uint64_t end_ms = outcome.read_end_ms ? outcome.read_end_ms : start_ms;
    Verdict verdict = classify(outcome);
    if (!verdict.available) {
      unavailable(verdict.reason, start_ms);
      return;
    }
    const ParseResult &parsed = verdict.parsed;
    // Window labels are meeting-local and assigned in order of first sight.
    uint64_t window_key = parsed.window_object_id
                              ? parsed.window_object_id
                              : static_cast<uint64_t>(parsed.window_index) + 1;
    auto [window_it, fresh] = windows_.try_emplace(
        window_key, "w" + std::to_string(windows_.size() + 1));
    (void)fresh;
    std::vector<std::string> refs;
    refs_.assign(window_it->second, refs, parsed.participants);

    json participants = json::array();
    for (size_t i = 0; i < parsed.participants.size(); ++i)
      participants.push_back({{"ref", refs[i]},
                              {"name", parsed.participants[i].name},
                              {"self", parsed.participants[i].self}});
    json speakers = json::array();
    for (const auto &speaker : parsed.speakers)
      speakers.push_back({{"ref", refs[speaker.participant]},
                          {"method", speaker.method == Method::ParticipantStatus
                                         ? "participant_status"
                                         : "compact_talking_label"}});
    json frame = {
        {"session", session_},
        {"read_start_ms", start_ms},
        {"read_end_ms", end_ms},
        {"target",
         {{"pid", outcome.pid > 0 ? json(outcome.pid) : json(nullptr)},
          {"window", window_it->second},
          {"zoom_version", nullable(outcome.zoom_version)},
          {"locale", nullable(parsed.locale)}}},
        {"complete", parsed.complete},
        {"parser_version", kParserVersion},
        {"participants", participants},
        {"speakers", speakers}};
    if (!writer_.emit("observation", frame)) {
      diag_.note("observation_not_written");
      unavailable("frame_too_large", start_ms);
      return;
    }
    in_unavailable_ = false;
  }

  void unavailable(const std::string &reason, uint64_t at_ms) {
    if (in_unavailable_ && reason == reason_)
      return;
    if (!in_unavailable_)
      since_ms_ = at_ms;
    in_unavailable_ = true;
    reason_ = reason;
    writer_.emit(
        "unavailable",
        {{"session", session_}, {"reason", reason}, {"since_ms", since_ms_}});
  }

  Source &source_;
  Writer &writer_;
  Shared &shared_;
  Diagnostics &diag_;
  RefTable refs_;
  std::map<uint64_t, std::string> windows_;
  std::string session_;
  std::string reason_;
  uint64_t since_ms_ = 0;
  int poll_ms_ = kDefaultPollMs;
  bool started_ = false;
  bool in_unavailable_ = false;
  Clock::time_point next_ = Clock::now();
};

json capabilities_frame(const Request &request, const Capabilities &caps) {
  return {{"id", request.id},
          {"state", caps.state},
          {"reason", caps.reason},
          {"zoom_version", nullable(caps.zoom_version)},
          {"locale", nullable(caps.locale)}};
}

} // namespace

Capabilities describe_capabilities(const SnapshotOutcome &outcome) {
  Verdict verdict = classify(outcome);
  return {verdict.state, verdict.reason, outcome.zoom_version,
          verdict.available ? verdict.parsed.locale : std::string()};
}

int run_observer(Source &source, const ObserverConfig &config) {
  Writer writer(config.out_fd);
  Diagnostics diag(config.err_fd);
  Shared shared;
  writer.emit("hello", {{"helper", config.helper},
                        {"helper_version", config.helper_version},
                        {"parser_version", kParserVersion},
                        {"platform", config.platform}});
  Reader reader(shared, writer, source, diag, config.in_fd);
  std::thread reader_thread([&] { reader.run(); });

  Session session(source, writer, shared, diag);
  int exit_code = 0;
  bool running = true;
  while (running) {
    std::deque<Request> batch;
    {
      std::unique_lock<std::mutex> lock(shared.mutex);
      auto ready = [&] { return !shared.queue.empty(); };
      if (session.started())
        shared.wake.wait_until(lock, session.next_poll(), ready);
      else
        shared.wake.wait(lock, ready);
      batch.swap(shared.queue);
    }
    for (const Request &request : batch) {
      switch (request.kind) {
      case Request::Kind::Capabilities:
      case Request::Kind::Setup: {
        if (request.kind == Request::Kind::Setup)
          source.request_access();
        Capabilities caps = describe_capabilities(
            source.snapshot([&] { return shared.cancel.load(); }));
        writer.emit("capabilities", capabilities_frame(request, caps));
        break;
      }
      case Request::Kind::Start:
        if (session.started())
          writer.emit("error", {{"id", request.id},
                                {"code", "already_started"},
                                {"message", "a session is already running"}});
        else
          session.start(request);
        break;
      case Request::Kind::Reject:
        writer.emit("error", {{"id", request.id},
                              {"code", request.code},
                              {"message", "invalid request"}});
        break;
      case Request::Kind::Stop:
        writer.emit("stopped",
                    {{"id", request.id},
                     {"session", session.started() ? json(session.session())
                                                   : json(nullptr)}},
                    true);
        running = false;
        break;
      case Request::Kind::Eof:
        running = false;
        break;
      case Request::Kind::Fatal:
        writer.emit("error",
                    {{"code", request.code}, {"message", "protocol error"}},
                    true);
        exit_code = 2;
        running = false;
        break;
      }
      if (!running)
        break;
    }
    if (running && session.started() && Clock::now() >= session.next_poll())
      session.poll();
  }
  {
    std::lock_guard<std::mutex> lock(shared.mutex);
    shared.done = true;
  }
  shared.finished.notify_all();
  reader_thread.join();
  return exit_code;
}

} // namespace foresight::zoom
