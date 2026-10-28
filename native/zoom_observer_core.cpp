#include "zoom_observer_core.h"

#include "zoom_ref_table.h"

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
#include <poll.h>
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
constexpr size_t kMaxQueuedRequests = 64;
constexpr int kMaxDiagnostics = 32;
constexpr int kExitProtocol = 2;
constexpr int kExitOutput = 3;

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
//
// A frame is written while the lock is held, so a write blocked on a full pipe
// holds the lock. The shutdown guard therefore only try-locks (see
// emit_if_idle): when stdout is wedged the closing frame could not be delivered
// anyway, and the guard exits instead of waiting behind it.
class Writer {
public:
  enum class Result { Written, TooLarge, Failed };

  explicit Writer(int fd) : fd_(fd) {}

  // Called once, outside the lock, when stdout first fails to accept a frame.
  void on_failure(std::function<void()> callback) {
    failure_ = std::move(callback);
  }

  Result emit(const char *type, json frame, bool terminal = false) {
    return write_frame(type, std::move(frame), terminal, true);
  }

  // Like a terminal emit, but gives up instead of waiting for the lock.
  Result emit_if_idle(const char *type, json frame) {
    return write_frame(type, std::move(frame), true, false);
  }

private:
  Result write_frame(const char *type, json frame, bool terminal, bool wait) {
    frame["v"] = kProtocolVersion;
    frame["type"] = type;
    Result result;
    bool first_failure = false;
    {
      std::unique_lock<std::mutex> lock(mutex_, std::defer_lock);
      if (wait)
        lock.lock();
      else if (!lock.try_lock())
        return Result::Failed;
      if (closed_)
        return Result::Failed;
      frame["seq"] = seq_;
      std::string line =
          frame.dump(-1, ' ', false, json::error_handler_t::replace);
      if (line.size() > kMaxLineBytes) {
        result = Result::TooLarge;
      } else {
        line += '\n';
        if (write_all(line)) {
          ++seq_;
          result = Result::Written;
        } else {
          closed_ = true;
          first_failure = true;
          result = Result::Failed;
        }
      }
      if (terminal)
        closed_ = true;
    }
    if (first_failure && failure_)
      failure_();
    return result;
  }

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
  std::function<void()> failure_;
};

struct Request {
  enum class Kind {
    Capabilities,
    Setup,
    Start,
    Stop,
    Reject,
    Eof,
    Fatal,
    OutputClosed
  };
  Kind kind = Kind::Eof;
  json id; // null when absent
  std::string session;
  int poll_ms = kDefaultPollMs;
  std::string code; // Reject/Fatal
};

struct Shared {
  std::mutex mutex;
  std::condition_variable requests; // new request or terminal event
  std::condition_variable space;    // queue has room again
  std::condition_variable finished; // main loop is done
  std::deque<Request> queue;
  bool done = false;
  std::atomic<bool> cancel{false};
  // Set by the reader when it forwards the one accepted start request.
  std::atomic<int> deadline_ms{kDefaultDeadlineMs};
  std::string session;
  int wake_fd = -1; // write end of the reader's wake pipe

  // Terminal wake-up used when the main loop exits or output breaks.
  void wake_reader() {
    char byte = 0;
    if (wake_fd >= 0)
      (void)!::write(wake_fd, &byte, 1);
  }
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
         int fd, int wake_fd)
      : shared_(shared), writer_(writer), source_(source), diag_(diag), fd_(fd),
        wake_fd_(wake_fd) {}

  void run() {
    std::string line;
    char chunk[65536];
    for (;;) {
      pollfd fds[2] = {{fd_, POLLIN, 0}, {wake_fd_, POLLIN, 0}};
      if (::poll(fds, 2, -1) < 0) {
        if (errno == EINTR)
          continue;
        fatal("input_error");
        return;
      }
      if (fds[1].revents)
        return; // the main loop is finishing
      if (!fds[0].revents)
        continue;
      ssize_t count = ::read(fd_, chunk, sizeof chunk);
      if (count < 0) {
        if (errno == EINTR || errno == EAGAIN)
          continue;
        fatal("input_error"); // a read failure is not a clean end of input
        return;
      }
      if (count == 0) {
        if (!line.empty()) {
          fatal("truncated_line"); // the last request lacked its newline
          return;
        }
        terminate(Request::Kind::Eof, {}, session_deadline());
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
  int session_deadline() const {
    return shared_.deadline_ms.load();
  }

  // Returns false when the session is ending and nothing more should be read.
  bool push(Request request) {
    std::unique_lock<std::mutex> lock(shared_.mutex);
    // Backpressure instead of an unbounded queue: stop reading stdin until the
    // main loop catches up. Cancellation and shutdown release the wait.
    shared_.space.wait(lock, [&] {
      return shared_.queue.size() < kMaxQueuedRequests || shared_.done ||
             shared_.cancel.load();
    });
    if (shared_.done)
      return false;
    shared_.queue.push_back(std::move(request));
    lock.unlock();
    shared_.requests.notify_all();
    return true;
  }

  // Delivers a terminal event, then guards it: if the polling thread does not
  // finish within the deadline (a stalled accessibility call), the reader
  // emits the closing frame itself and exits, so a stall cannot outlive stop.
  void terminate(Request::Kind kind, Request request, int deadline_ms) {
    request.kind = kind;
    shared_.cancel = true;
    {
      std::lock_guard<std::mutex> lock(shared_.mutex);
      shared_.queue.push_back(request); // terminal events bypass the bound
    }
    shared_.requests.notify_all();
    shared_.space.notify_all();
    std::unique_lock<std::mutex> lock(shared_.mutex);
    if (shared_.finished.wait_for(lock, std::chrono::milliseconds(deadline_ms),
                                  [&] { return shared_.done; }))
      return;
    std::string session = shared_.session;
    lock.unlock();
    diag_.note("shutdown_deadline");
    if (kind == Request::Kind::Stop)
      writer_.emit_if_idle(
          "stopped",
          {{"id", request.id},
           {"session", session.empty() ? json(nullptr) : json(session)}});
    else if (kind == Request::Kind::Fatal)
      writer_.emit_if_idle(
          "error", {{"code", request.code}, {"message", "protocol error"}});
    ::_exit(kind == Request::Kind::Fatal ? kExitProtocol : 0);
  }

  void fatal(const char *code) {
    Request request;
    request.code = code;
    terminate(Request::Kind::Fatal, request, session_deadline());
  }

  bool reject(const json &id, const char *code) {
    Request request;
    request.kind = Request::Kind::Reject;
    request.id = valid_id(id) ? id : json(nullptr);
    request.code = code;
    return push(std::move(request));
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
    if (!valid_id(id))
      return reject(id, "invalid_request");
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
                        deadline))
        return reject(id, "invalid_request");
      if (started_)
        return reject(id, "already_started"); // never touches the live session
      started_ = true;
      out.session = session->get<std::string>();
      shared_.deadline_ms = deadline;
      {
        std::lock_guard<std::mutex> lock(shared_.mutex);
        shared_.session = out.session;
      }
    } else {
      terminate(Request::Kind::Stop, out, session_deadline());
      return false;
    }
    return push(std::move(out));
  }

  Shared &shared_;
  Writer &writer_;
  Source &source_;
  Diagnostics &diag_;
  int fd_;
  int wake_fd_;
  uint64_t expected_seq_ = 0;
  bool started_ = false;
};

using ParseFn = std::function<ParseResult(const AxSnapshot &)>;

struct Verdict {
  bool available = false;
  std::string state;
  std::string reason;
  ParseResult parsed;
};

Verdict classify(const SnapshotOutcome &outcome, const ParseFn &parse) {
  Verdict verdict;
  if (!outcome.ok) {
    verdict.state = outcome.state.empty() ? "unavailable" : outcome.state;
    verdict.reason = outcome.reason.empty() ? verdict.state : outcome.reason;
    return verdict;
  }
  verdict.parsed = parse(outcome.snapshot);
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
    // Only a complete read may say there is no meeting; an incomplete read with
    // no evidence is a failed read (`incomplete_read`).
    verdict.state = empty ? "no_meeting" : "unavailable";
    verdict.reason = why;
  }
  return verdict;
}

json nullable(const std::string &text) {
  return text.empty() ? json(nullptr) : json(text);
}

class Session {
public:
  Session(Source &source, Writer &writer, Shared &shared, Diagnostics &diag,
          const ObserverConfig &config)
      : source_(source), writer_(writer), shared_(shared), diag_(diag),
        config_(config) {}

  bool started() const {
    return started_;
  }
  Clock::time_point next_poll() const {
    return next_;
  }
  std::string session() const {
    return session_;
  }

  // Returns false (and does not start) if shutdown began during the first read.
  bool start(const Request &request) {
    auto begin = Clock::now();
    SnapshotOutcome outcome = source_.snapshot(cancelled());
    if (shared_.cancel)
      return false;
    session_ = request.session;
    poll_ms_ = request.poll_ms;
    started_ = true;
    json target = {{"pid", outcome.pid > 0 ? json(outcome.pid) : json(nullptr)},
                   {"zoom_version", nullable(outcome.zoom_version)}};
    writer_.emit(
        "started",
        {{"id", request.id}, {"session", session_}, {"target", target}});
    publish(outcome);
    schedule(begin);
    return true;
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
    Verdict verdict = classify(outcome, config_.parse);
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
    RefTable::Result refs =
        refs_.assign(window_it->second, parsed.participants);

    json participants = json::array();
    for (size_t i = 0; i < parsed.participants.size(); ++i)
      participants.push_back({{"ref", refs.refs[i]},
                              {"name", parsed.participants[i].name},
                              {"self", parsed.participants[i].self}});
    json speakers = json::array();
    for (const auto &speaker : parsed.speakers)
      speakers.push_back({{"ref", refs.refs[speaker.participant]},
                          {"method", speaker.method == Method::ParticipantStatus
                                         ? "participant_status"
                                         : "compact_talking_label"}});
    bool complete =
        parsed.complete && !outcome.identity_incomplete && !refs.uncertain;
    json frame = {
        {"session", session_},
        {"read_start_ms", start_ms},
        {"read_end_ms", end_ms},
        {"target",
         {{"pid", outcome.pid > 0 ? json(outcome.pid) : json(nullptr)},
          {"window", window_it->second},
          {"zoom_version", nullable(outcome.zoom_version)},
          {"locale", nullable(parsed.locale)}}},
        {"complete", complete},
        {"parser_version", config_.parser_version},
        {"participants", participants},
        {"speakers", speakers}};
    switch (writer_.emit("observation", frame)) {
    case Writer::Result::Written:
      in_unavailable_ = false;
      break;
    case Writer::Result::TooLarge:
      diag_.note("frame_too_large");
      unavailable("frame_too_large", start_ms);
      break;
    case Writer::Result::Failed:
      break; // stdout is gone; the failure handler ends the session
    }
  }

  void unavailable(const std::string &reason, uint64_t at_ms) {
    if (in_unavailable_ && reason == reason_)
      return;
    uint64_t since = in_unavailable_ ? since_ms_ : at_ms;
    // Remember the interval only once the frame is actually out, so a failed
    // write is retried instead of silently becoming "already reported".
    if (writer_.emit(
            "unavailable",
            {{"session", session_}, {"reason", reason}, {"since_ms", since}}) ==
        Writer::Result::Written) {
      in_unavailable_ = true;
      since_ms_ = since;
      reason_ = reason;
    }
  }

  Source &source_;
  Writer &writer_;
  Shared &shared_;
  Diagnostics &diag_;
  const ObserverConfig &config_;
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

Capabilities describe_capabilities(const SnapshotOutcome &outcome,
                                   const ParseFn &parse) {
  Verdict verdict = classify(outcome, parse);
  return {verdict.state, verdict.reason, outcome.zoom_version,
          verdict.available ? verdict.parsed.locale : std::string()};
}

int run_observer(Source &source, const ObserverConfig &config) {
  Writer writer(config.out_fd);
  Diagnostics diag(config.err_fd);
  Shared shared;
  int wake[2];
  if (::pipe(wake) != 0) {
    diag.note("pipe_failed");
    return kExitProtocol;
  }
  shared.wake_fd = wake[1];
  writer.on_failure([&] {
    // Nobody can read our frames any more: stop polling and exit.
    diag.note("stdout_closed");
    shared.cancel = true;
    {
      std::lock_guard<std::mutex> lock(shared.mutex);
      Request request;
      request.kind = Request::Kind::OutputClosed;
      shared.queue.push_back(request);
    }
    shared.requests.notify_all();
    shared.space.notify_all();
    shared.wake_reader();
  });
  writer.emit("hello", {{"helper", config.helper},
                        {"helper_version", config.helper_version},
                        {"parser_version", config.parser_version},
                        {"platform", config.platform}});
  Reader reader(shared, writer, source, diag, config.in_fd, wake[0]);
  std::thread reader_thread([&] { reader.run(); });

  Session session(source, writer, shared, diag, config);
  int exit_code = 0;
  bool running = true;
  auto refuse_if_cancelled = [&](const Request &request) {
    if (!shared.cancel)
      return false;
    // Shutdown (or a broken stdout) is already under way: answer honestly
    // rather than reporting a state the cancelled read could not establish.
    writer.emit("error", {{"id", request.id},
                          {"code", "cancelled"},
                          {"message", "request cancelled by shutdown"}});
    return true;
  };
  while (running) {
    Request request;
    bool have = false;
    {
      std::unique_lock<std::mutex> lock(shared.mutex);
      auto ready = [&] { return !shared.queue.empty(); };
      if (session.started())
        shared.requests.wait_until(lock, session.next_poll(), ready);
      else
        shared.requests.wait(lock, ready);
      if (!shared.queue.empty()) {
        request = std::move(shared.queue.front());
        shared.queue.pop_front();
        have = true;
      }
    }
    shared.space.notify_all();
    if (have) {
      // One request per iteration, so a burst cannot starve polling.
      switch (request.kind) {
      case Request::Kind::Capabilities:
      case Request::Kind::Setup: {
        if (refuse_if_cancelled(request))
          break;
        if (request.kind == Request::Kind::Setup)
          source.request_access();
        SnapshotOutcome outcome =
            source.snapshot([&] { return shared.cancel.load(); });
        if (refuse_if_cancelled(request))
          break;
        Capabilities caps = describe_capabilities(outcome, config.parse);
        writer.emit("capabilities", capabilities_frame(request, caps));
        break;
      }
      case Request::Kind::Start:
        if (refuse_if_cancelled(request))
          break;
        if (session.started())
          writer.emit("error", {{"id", request.id},
                                {"code", "already_started"},
                                {"message", "a session is already running"}});
        else if (!session.start(request))
          refuse_if_cancelled(request);
        break;
      case Request::Kind::Reject:
        writer.emit("error", {{"id", request.id},
                              {"code", request.code},
                              {"message", "invalid request"}});
        break;
      case Request::Kind::Stop:
        if (writer.emit("stopped",
                        {{"id", request.id},
                         {"session", session.started() ? json(session.session())
                                                       : json(nullptr)}},
                        true) == Writer::Result::Failed)
          exit_code = kExitOutput;
        running = false;
        break;
      case Request::Kind::Eof:
        running = false;
        break;
      case Request::Kind::Fatal:
        writer.emit("error",
                    {{"code", request.code}, {"message", "protocol error"}},
                    true);
        exit_code = kExitProtocol;
        running = false;
        break;
      case Request::Kind::OutputClosed:
        exit_code = kExitOutput;
        running = false;
        break;
      }
    }
    if (running && !shared.cancel && session.started() &&
        Clock::now() >= session.next_poll())
      session.poll();
  }
  {
    std::lock_guard<std::mutex> lock(shared.mutex);
    shared.done = true;
  }
  shared.finished.notify_all();
  shared.space.notify_all();
  shared.wake_reader();
  reader_thread.join();
  ::close(wake[0]);
  ::close(wake[1]);
  return exit_code;
}

} // namespace foresight::zoom
