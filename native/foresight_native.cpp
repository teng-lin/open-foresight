#include "foresight_native.h"
#include "exception_barrier.h"
#include "one_shot_launch.h"
#include "portable_process.h"
#include "speech_audio.h"
#include "speech_cpu.h"
#include "json_string.h"
#ifdef __APPLE__
#include <libproc.h>
#include <sys/sysctl.h>
#include "macos_audio.h"
#endif
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <fstream>
#include <functional>
#include <mutex>
#include <memory>
#include <poll.h>
#include <set>
#include <map>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>
extern char **environ;
namespace {
using foresight::quote;
char *owned(const std::string &s) { return strdup(s.c_str()); }
struct Events {
  std::mutex mu;
  std::condition_variable cv;
  std::deque<std::string> events;
  virtual ~Events() = default;
  void emit(std::string s) {
    std::lock_guard lock(mu);
    events.push_back(std::move(s));
    cv.notify_all();
  }
};
struct Worker : Events {
  std::thread thread;
  std::atomic<bool> cancel{false}, active{false};
  std::atomic<pid_t> pid{-1};
  foresight::OwnedSpawn *owned_process = nullptr;
  std::mutex life;
  std::mutex process_mutex;
  std::mutex input_mutex;
  std::deque<std::string> input;
  bool finish_input = false;
  void stop() {
    cancel = true;
    std::lock_guard lock(process_mutex);
    if (owned_process) owned_process->stop();
  }
  void join() {
    if (thread.joinable())
      thread.join();
  }
  ~Worker() {
    stop();
    join();
  }
};
// pw-record's stdout contains unconnected/error diagnostics even without -v.
// A private raw FIFO gives libsndfile a separate PCM destination. Keep one
// nonblocking writer open here so a slow child open cannot look like EOF.
struct CapturePcmPipe {
  std::string directory, path;
  int fd = -1, error = 0;
  explicit CapturePcmPipe(bool enabled) {
    if (!enabled) return;
    char pattern[] = "/tmp/foresight-capture-XXXXXX";
    const char *created = mkdtemp(pattern);
    if (!created) { error = errno; return; }
    directory = created;
    path = directory + "/audio.raw";
    if (mkfifo(path.c_str(), 0600) < 0) { error = errno; return; }
    fd = open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) error = errno;
  }
  ~CapturePcmPipe() {
    if (fd >= 0) close(fd);
    if (!path.empty()) unlink(path.c_str());
    if (!directory.empty()) rmdir(directory.c_str());
  }
};
// posix_spawn avoids unsafe post-fork work inside a multi-threaded Flutter
// host.
int run(Worker &w, std::vector<std::string> args,
        const std::function<void(const char *, size_t)> &output,
        bool duplex = false, bool raw_capture = false) {
  CapturePcmPipe capture_pipe(raw_capture);
  if (capture_pipe.error) return -capture_pipe.error;
  if (raw_capture) args.back() = capture_pipe.path;
  std::unique_lock launch(foresight::launch_mutex);
  int pipes[2];
  if (foresight::cloexec_pipe(pipes) < 0)
    return -1;
  int input[2] = {-1, -1};
  if (duplex) {
#ifdef __APPLE__
    constexpr int input_type = SOCK_STREAM;
#else
    constexpr int input_type = SOCK_STREAM | SOCK_CLOEXEC;
#endif
    if (socketpair(AF_UNIX, input_type, 0, input) < 0) {
      close(pipes[0]); close(pipes[1]); return -1;
    }
    // Keep descriptors away from stdio, including a host with closed stdin.
    for (auto slot : {&pipes[0], &pipes[1], &input[0], &input[1]}) {
      int moved = fcntl(*slot, F_DUPFD_CLOEXEC, 10);
      if (moved < 0) {
        int error = errno;
        close(pipes[0]); close(pipes[1]); close(input[0]); close(input[1]);
        return -error;
      }
      close(*slot); *slot = moved;
    }
#ifdef __APPLE__
    int enabled = 1;
    if (setsockopt(input[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled))) {
      int error = errno;
      close(pipes[0]); close(pipes[1]); close(input[0]); close(input[1]);
      return -error;
    }
#endif
    if (fcntl(input[1], F_SETFL, O_NONBLOCK) < 0) {
      int error = errno;
      close(pipes[0]); close(pipes[1]); close(input[0]); close(input[1]);
      return -error;
    }
  }
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  if (raw_capture)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  else
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  if (duplex) {
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, input[0]);
    posix_spawn_file_actions_addclose(&actions, input[1]);
  } else {
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null",
                                     O_RDONLY, 0);
  }
  posix_spawn_file_actions_addclose(&actions, pipes[0]);
  posix_spawn_file_actions_addclose(&actions, pipes[1]);
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  short flags = POSIX_SPAWN_SETPGROUP;
#ifdef __APPLE__
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  posix_spawnattr_setflags(&attr, flags);
  posix_spawnattr_setpgroup(&attr, 0);
  pid_t p = -1;
  foresight::OwnedSpawn owned;
  int err = owned.spawn(&p, &actions, &attr, args);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  close(pipes[1]);
  if (duplex) close(input[0]);
  if (err) {
    close(pipes[0]);
    if (duplex) close(input[1]);
    return -err;
  }
  launch.unlock();
  {
    std::lock_guard lock(w.process_mutex);
    w.pid = owned.worker;
    w.owned_process = &owned;
  }
  if (w.cancel) {
    std::lock_guard lock(w.process_mutex);
    owned.stop();
  }
  const int read_fd = raw_capture ? capture_pipe.fd : pipes[0];
  char buffer[4096];
  auto drain_pcm = [&] {
    ssize_t n;
    while ((n = read(read_fd, buffer, sizeof(buffer))) > 0)
      output(buffer, size_t(n));
  };
  std::string pending_input;
  size_t sent = 0;
  while (!w.cancel) {
    if (duplex && input[1] >= 0 && pending_input.empty()) {
      std::lock_guard lock(w.input_mutex);
      if (!w.input.empty()) {
        pending_input = std::move(w.input.front());
        w.input.pop_front(); sent = 0;
      } else if (w.finish_input) {
        close(input[1]);
        input[1] = -1;
      }
    }
    pollfd fds[2]{{read_fd, POLLIN, 0},
                  {input[1], short(input[1] >= 0 && !pending_input.empty() ? POLLOUT : 0), 0}};
    int r = poll(fds, duplex && input[1] >= 0 ? 2 : 1, 100);
    if (r > 0) {
      if (duplex && input[1] >= 0 && (fds[1].revents & POLLOUT)) {
#ifdef __APPLE__
        constexpr int send_flags = 0;
#else
        constexpr int send_flags = MSG_NOSIGNAL;
#endif
        auto n = send(input[1], pending_input.data() + sent,
                      pending_input.size() - sent, send_flags);
        if (n > 0) {
          sent += size_t(n);
          if (sent == pending_input.size()) pending_input.clear();
        } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
          w.stop(); break;
        }
      }
      if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
        ssize_t n = read(read_fd, buffer, sizeof(buffer));
        if (n <= 0 && !(raw_capture && n < 0 && errno == EAGAIN)) break;
        if (n > 0) output(buffer, size_t(n));
      }
    } else if (r < 0 && errno != EINTR)
      break;
    if (raw_capture && owned.finished()) {
      drain_pcm();
      break;
    }
  }
  if (w.cancel) {
    std::lock_guard lock(w.process_mutex);
    owned.stop();
  }
  if (duplex && input[1] >= 0) close(input[1]);
  // Cancellation can still close the ownership pipe while this waits. The
  // supervisor reserves the worker PID and finishes all group cleanup before
  // reporting its result, independently of the host runtime's child reaper.
  const int worker_status = owned.result();
  if (raw_capture) drain_pcm();
  close(pipes[0]);
  std::lock_guard lock(w.process_mutex);
  pid_t reaped;
  do { reaped = waitpid(p, nullptr, 0); } while (reaped < 0 && errno == EINTR);
  w.pid = -1;
  w.owned_process = nullptr;
  return worker_status;
}
bool valid_asset(const char *runtime, const char *model) {
  return runtime && *runtime && model && *model && access(model, R_OK) == 0;
}
struct PersistentGeneration;
struct Engine {
  int backend = 0;
  int model_type = 0;
  std::string runtime, model;
  std::mutex mu;
  int refs = 0;
  bool busy = false;
  std::string state = "configured", error;
  bool cpu_fallback = false;
  bool persistent_protocol = false;
  bool native_stop_token_sequences = false;
  uint64_t generation = 0;
  std::unique_ptr<PersistentGeneration> persistent;
  ~Engine();
};
struct Conversation : Worker {
  Engine *engine;
  std::set<std::string> requests;
  std::string request;
  uint64_t sequence = 0;
  std::atomic<bool> awaiting_tool{false};
};
std::string event(const std::string &type, const std::string &id,
                  uint64_t sequence, const std::string &extra) {
  return "{\"type\":" + quote(type) + ",\"request_id\":" + quote(id) +
         ",\"sequence\":" + std::to_string(sequence) + extra + "}";
}
void failure(Worker &w, const std::string &id, uint64_t &seq,
             const std::string &code, const std::string &message) {
  w.emit(event("error", id, seq++,
               ",\"code\":" + quote(code) + ",\"message\":" + quote(message) +
                   ",\"retryable\":false"));
}
#include "persistent_generation.h"
Engine::~Engine() { shutdown_persistent(*this); }
struct SpeechEngine { Engine engine; std::timed_mutex mutex; };
std::mutex speech_engines_mutex;
std::map<std::string,std::weak_ptr<SpeechEngine>> speech_engines;
struct Speech : Worker {
  std::shared_ptr<SpeechEngine> worker_engine;
  std::string runtime, model;
  std::vector<int16_t> samples, pending;
  double phase = 0;
  int input_rate = 0;
};
void wav(const std::string &path, const std::vector<int16_t> &samples) {
  std::ofstream f(path, std::ios::binary);
  auto u16 = [&](uint16_t v) {
    f.put(v & 255);
    f.put(v >> 8);
  };
  auto u32 = [&](uint32_t v) {
    u16(v & 65535);
    u16(v >> 16);
  };
  f.write("RIFF", 4);
  u32(36 + samples.size() * 2);
  f.write("WAVEfmt ", 8);
  u32(16);
  u16(1);
  u16(1);
  u32(16000);
  u32(32000);
  u16(2);
  u16(16);
  f.write("data", 4);
  u32(samples.size() * 2);
  for (auto s : samples)
    u16(uint16_t(s));
}
std::string base64(const std::vector<unsigned char> &in) {
  const char *a =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  size_t i = 0;
  for (; i + 2 < in.size(); i += 3) {
    uint32_t x = (in[i] << 16) | (in[i + 1] << 8) | in[i + 2];
    out += a[x >> 18];
    out += a[(x >> 12) & 63];
    out += a[(x >> 6) & 63];
    out += a[x & 63];
  }
  if (i < in.size()) {
    uint32_t x = in[i] << 16;
    if (i + 1 < in.size())
      x |= in[i + 1] << 8;
    out += a[x >> 18];
    out += a[(x >> 12) & 63];
    out += i + 1 < in.size() ? a[(x >> 6) & 63] : '=';
    out += '=';
  }
  return out;
}
struct Capture : Worker {
  std::string target, runtime;
  bool playback = false;
  std::atomic<bool> echoCancellation{false};
  int rate = 48000;
  uint64_t dropped = 0, pending_dropped_bytes = 0;
};
std::string capture_overflow(Capture &c) {
  const auto bytes = c.pending_dropped_bytes;
  c.pending_dropped_bytes = 0;
  return "{\"type\":\"gap\",\"reason\":\"capture_buffer_overflow\",\"discarded_bytes\":" + std::to_string(bytes) + "}";
}
void audio_frame(Capture &c, const std::vector<unsigned char> &bytes) {
  std::vector<int16_t> pcm(bytes.size() / 2);
  for (size_t i = 0; i < pcm.size(); ++i)
    pcm[i] = int16_t(bytes[i * 2] | bytes[i * 2 + 1] << 8);
  auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                 std::chrono::steady_clock::now().time_since_epoch())
                 .count();
  std::string fields =
      "\"type\":\"pcm\",\"channel\":" +
      quote("plugins.foresight.xeno.com/audio_capture_events") +
      ",\"data\":" + quote(base64(bytes)) +
      ",\"volume\":" + std::to_string(fs_pcm_rms(pcm.data(), pcm.size())) +
      ",\"sampleRate\":" + std::to_string(c.rate);
  std::string legacy = "{\"type\":" + quote(c.playback ? "output" : "input") +
                       ",\"payload\":" + quote(base64(bytes)) + ",\"volume\":" +
                       std::to_string(fs_pcm_rms(pcm.data(), pcm.size()));
  if (c.playback)
    legacy += ",\"bufferDurationMs\":" + std::to_string(40) +
              ",\"sampleRate\":" + std::to_string(double(c.rate));
  fields += ",\"event\":" + legacy + "}";
  fields += ",\"timestamp_ms\":" + std::to_string(now) +
            ",\"dropped_frames\":" + std::to_string(c.dropped);
  std::lock_guard lock(c.mu);
  // Retain chronological PCM already queued. A gap belongs after that PCM
  // and before the next accepted frame; never silently drop a control event.
  if (c.events.size() >= 255) {
    ++c.dropped;
    c.pending_dropped_bytes += bytes.size();
    return;
  }
  if (c.pending_dropped_bytes) c.events.push_back(capture_overflow(c));
  c.events.push_back("{" + fields + "}");
  c.cv.notify_all();
}
} // namespace
extern "C" {
int fs_abi_version() {
  try { return 1;
  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return 1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return 1;
  }
}
char *fs_audio_capabilities() {
  try {
#ifdef __APPLE__
  return owned(fs_macos_capabilities());
#else
  return owned("{\"backend\":\"pipewire\"}");
#endif

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
char *fs_audio_request_system(int32_t timeout_ms) {
  try {
#ifdef __APPLE__
  return owned(fs_macos_request_system(timeout_ms));
#else
  (void)timeout_ms;
  return owned("{\"system_audio\":\"unavailable\",\"system_audio_request\":\"failed\",\"permission_verified\":false,\"code\":\"unsupported_platform\",\"message\":\"System audio permission requests are specific to macOS.\"}");
#endif

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
int fs_audio_request_microphone() {
  try {
#ifdef __APPLE__
  return fs_macos_request_microphone() ? 0 : 1;
#else
  return 0;
#endif

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
void fs_string_free(char *p) {
  try { free(p);
  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
  }
}
char *fs_event_poll(void *h, int timeout) {
  try {
  if (!h)
    return nullptr;
  auto &e = *static_cast<Events *>(h);
  std::unique_lock lock(e.mu);
  e.cv.wait_for(lock, std::chrono::milliseconds(std::clamp(timeout, 0, 60000)),
                [&] { return !e.events.empty(); });
  if (e.events.empty()) {
    if (auto *capture = dynamic_cast<Capture *>(&e); capture && capture->pending_dropped_bytes)
      return owned(capture_overflow(*capture));
    return nullptr;
  }
  auto s = std::move(e.events.front());
  e.events.pop_front();
  return owned(s);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
void *fs_engine_create(const char *runtime, const char *model) {
  try {
  return fs_engine_create_backend(runtime, model, 0);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
void *fs_engine_create_backend(const char *runtime, const char *model, int backend) {
  try {
  if (backend != 0 && backend != 1) return nullptr;
  if (!valid_asset(runtime, model))
    return nullptr;
  auto *e = new Engine;
  e->runtime = runtime;
  e->model = model;
  e->backend = backend;
  return e;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
void *fs_engine_create_model_type(const char *runtime, const char *model, int model_type) {
  try {
  if (model_type < 0 || model_type > 17) return nullptr;
  auto *engine = static_cast<Engine *>(fs_engine_create_backend(runtime, model, 1));
  if (engine) engine->model_type = model_type;
  return engine;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
char *fs_engine_state(void *h) {
  try {
  if (!h)
    return nullptr;
  auto &e = *static_cast<Engine *>(h);
  std::lock_guard lock(e.mu);
  if (e.backend == 1)
    return owned("{\"state\":" + quote(e.state) +
                 ",\"backend\":" + quote(!e.cpu_fallback && std::getenv("FORESIGHT_LITERT_BACKEND") &&
                     std::string(std::getenv("FORESIGHT_LITERT_BACKEND")) == "gpu"
                     ? "litert-lm-gpu-native" : "litert-lm-cpu-native") +
                 ",\"load_policy\":" + quote(e.persistent_protocol ? "persistent_worker" : "per_request") + ","
                 "\"native_stop_token_sequences\":" + std::string(e.native_stop_token_sequences ? "true" : "false") + ","
                 "\"context_length\":4096,\"temperature\":0.4,\"top_k\":40,\"top_p\":0.9,"
                 "\"thinking\":false,\"json\":\"ll_guidance_and_application_validation\",\"text\":true,\"tools\":true,\"error\":" + quote(e.error) + "}");
  return owned("{\"state\":" + quote(e.state) +
               ",\"backend\":\"llama.cpp-cpu-cli\",\"load_policy\":\"per_"
               "request\",\"context_length\":4096,\"max_output_tokens\":256,"
               "\"temperature\":0,\"text\":true,\"tools\":false,\"error\":" +
               quote(e.error) + "}");

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
int fs_engine_probe(void *h) {
  try {
  if (!h)
    return -1;
  auto &e = *static_cast<Engine *>(h);
  {
    std::lock_guard lock(e.mu);
    if (e.busy)
      return -1;
    e.busy = true;
    e.state = "loading";
  }
  shutdown_persistent(e);
  Worker probe;
  std::string diagnostics;
  auto arguments = e.backend == 1
      ? std::vector<std::string>{e.runtime, "--model", e.model, "--probe"}
      : std::vector<std::string>{e.runtime, "-m", e.model, "-p", "probe", "-n", "0", "-c", "4096", "--no-warmup", "-no-cnv", "-t", "4"};
  if (e.backend == 1 && e.model_type) { arguments.push_back("--model-type"); arguments.push_back(std::to_string(e.model_type)); }
  if (e.backend == 1 && e.cpu_fallback) { arguments.push_back("--backend"); arguments.push_back("cpu"); }
  int status = run(probe, std::move(arguments), [&](const char *data, size_t size) {
    if (e.backend == 1 && diagnostics.size() < 4096) diagnostics.append(data, std::min(size, 4096-diagnostics.size()));
  });
  {
    std::lock_guard lock(e.mu);
    e.busy = false;
    e.persistent_protocol = status == 0 && e.backend == 1 &&
        (diagnostics.find("\"worker_protocol\":1") != std::string::npos ||
         diagnostics.find("\"worker_protocol\": 1") != std::string::npos);
    e.native_stop_token_sequences = status == 0 && e.backend == 1 &&
        (diagnostics.find("\"native_stop_token_sequences\":true") != std::string::npos ||
         diagnostics.find("\"native_stop_token_sequences\": true") != std::string::npos);
    e.state = status == 0 ? "ready" : "failed";
    e.error = status == 0 ? ""
                          : "Model initialization probe failed with status " +
                                std::to_string(status) + diagnostics;
  }
  return status == 0 ? 0 : -1;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_engine_destroy(void *h) {
  try {
  if (!h)
    return 0;
  auto *e = static_cast<Engine *>(h);
  {
    std::lock_guard lock(e->mu);
    if (e->refs)
      return -1;
  }
  delete e;
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
void *fs_conversation_create(void *h) {
  try {
  if (!h)
    return nullptr;
  auto *e = static_cast<Engine *>(h);
  std::lock_guard lock(e->mu);
  ++e->refs;
  auto *c = new Conversation;
  c->engine = e;
  return c;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
static int generate_with_schema(void *h, const char *id, const char *prompt,
                                const char *schema, int max_output_tokens = 256,
                                bool tools = false) {
  // Zero is the plain-conversation request to preserve the runtime default.
  if (max_output_tokens < 0 || max_output_tokens > 3072 ||
      (max_output_tokens == 0 && !tools)) return -1;
  if (!h || !id || !*id || !prompt)
    return -1;
  auto &c = *static_cast<Conversation *>(h);
  std::lock_guard life(c.life);
  if (c.active || c.requests.count(id))
    return -1;
  c.join();
  auto &e = *c.engine;
  if (tools && e.backend != 1) return -1;
  {
    std::lock_guard lock(e.mu);
    if (e.busy)
      return -1;
    e.busy = true;
    e.state = "loading";
  }
  c.requests.insert(id);
  c.request = id;
  c.sequence = 0;
  c.cancel = false;
  c.awaiting_tool = false;
  {
    std::lock_guard lock(c.input_mutex);
    c.input.clear();
  }
  c.finish_input = false;
  c.active = true;
  std::string text = prompt;
  std::string json_schema = schema ? schema : "";
  c.thread = std::thread([&c, text, json_schema, max_output_tokens, tools] {
    auto &e = *c.engine;
    bool settled = false;
    foresight::guarded_worker([&] {
    uint64_t seq = 0;
    // Completion mode avoids runner UI/chat banners; app assembles structured
    // prompt.
    std::string utf8;
    bool tool_answer_received = false;
    bool tool_protocol_failed = false;
    bool worker_error_received = false;
    bool plain_text_received = false;
    auto tool_line = [&](const std::string &line) {
      bool request = line.starts_with("tool ");
      bool model = line.starts_with("model ");
      bool answer = line.starts_with("answer ");
      bool delta = line.starts_with("delta ");
      if (line.starts_with("error ") && !tool_answer_received) {
        worker_error_received = true;
        failure(c, c.request, seq, "runtime_failure", line.substr(6));
        return;
      }
      if ((!request && !model && !answer && !delta) || tool_answer_received ||
          (delta && c.awaiting_tool)) {
        tool_protocol_failed = true;
        failure(c, c.request, seq, "tool_protocol", "Invalid tool worker frame");
        c.stop(); return;
      }
      if (answer) tool_answer_received = true;
      if (request || model) c.awaiting_tool = true;
      c.emit(event(delta ? "model_delta" : model ? "model_response" : request ? "tool_request" : "tool_answer", c.request,
                   seq++, ",\"text\":" + quote(line.substr(model || delta ? 6 : request ? 5 : 7))));
    };
    std::vector<std::string> args;
    bool duplex = tools;
    if (tools) {
      args = {e.runtime,     "-m",
              e.model,       "-p",
              text,          "-n",
              std::to_string(max_output_tokens), "-c",
              "4096",        "--temp",
              "0",           "-t",
              "4",           "--no-display-prompt",
              "--simple-io", "--no-warmup",
              "-no-cnv"};
      if (e.backend == 1)
        args = {e.runtime, "--model", e.model, "--prompt", text,
                "--max-output-tokens", std::to_string(max_output_tokens)};
      if (e.backend == 1 && e.model_type) { args.push_back("--model-type"); args.push_back(std::to_string(e.model_type)); }
      if (e.backend == 1 && e.cpu_fallback) { args.push_back("--backend"); args.push_back("cpu"); }
      if (!json_schema.empty()) {
        args.push_back("--tools");
        args.push_back(json_schema);
      }
    } else {
      auto launch = foresight::one_shot_launch(e.backend, e.runtime, e.model, text,
                                               max_output_tokens, e.model_type, json_schema);
      args = std::move(launch.arguments);
      if (e.backend == 1 && e.cpu_fallback) {
        args.push_back("--backend");
        args.push_back("cpu");
      }
      {
        std::lock_guard lock(c.input_mutex);
        c.input.push_back(std::move(launch.standard_input));
      }
      c.finish_input = e.backend != 1;
      duplex = true;
    }
    int status;
    if (e.persistent_protocol) {
      // A persistent request owns its input; discard the one-shot stdin envelope.
      { std::lock_guard lock(c.input_mutex); c.input.clear(); }
      const auto payload = "{\"prompt\":" + quote(text) +
          (tools ? ",\"tools\":" : ",\"schema\":") +
          (json_schema.empty() ? "null" : json_schema) +
          ",\"max_output_tokens\":" + std::to_string(max_output_tokens) + "}";
      status = run_persistent(e, c, payload, [&](const std::string &line) {
        if (tools) { tool_line(line); return; }
        if (line.starts_with("text ") && foresight::json_string_literal(line.substr(5))) {
          plain_text_received = true;
          // The worker frames text as a JSON string, preserving Unicode/newlines.
          c.emit(event("delta", c.request, seq++, ",\"text\":" + line.substr(5)));
        } else {
          worker_error_received = true;
          failure(c, c.request, seq, "runtime_failure", line);
        }
      });
      if (tool_protocol_failed) shutdown_persistent(e, false);
    } else {
      // A one-shot mode must not load another model alongside the retained worker.
      shutdown_persistent(e);
      status = run(c, std::move(args), [&](const char *data, size_t n) {
        utf8.append(data, n);
        if (tools) {
          size_t newline;
          while ((newline = utf8.find('\n')) != std::string::npos) {
            auto line = utf8.substr(0, newline);
            utf8.erase(0, newline + 1);
            tool_line(line);
            if (tool_protocol_failed) return;
          }
          return;
        }
        size_t complete = utf8.size() > 32 ? utf8.size() - 32 : 0;
        if (complete) {
          size_t lead = complete - 1;
          while (lead > 0 &&
                 (static_cast<unsigned char>(utf8[lead]) & 0xc0) == 0x80)
            --lead;
          unsigned char byte = utf8[lead];
          size_t width = byte < 128              ? 1
                         : (byte & 0xe0) == 0xc0 ? 2
                         : (byte & 0xf0) == 0xe0 ? 3
                                                 : 4;
          if (complete - lead < width)
            complete = lead;
        }
        if (complete && !c.cancel) {
          c.emit(event("delta", c.request, seq++,
                       ",\"text\":" + quote(utf8.substr(0, complete))));
          utf8.erase(0, complete);
        }
      }, duplex);
    }
    c.finish_input = false;
    if (!c.cancel && !tools) {
      size_t marker = utf8.find(" [end of text]");
      if (marker != std::string::npos)
        utf8.erase(marker);
      if (!utf8.empty())
        c.emit(event("delta", c.request, seq++, ",\"text\":" + quote(utf8)));
    }
    std::string terminal = (tool_protocol_failed || worker_error_received || (!tools && e.persistent_protocol && !plain_text_received && !c.cancel)) ? "failed"
                           : c.cancel      ? "cancelled"
                           : status == 0 ? "completed"
                                         : "failed";
    if (tools && (!utf8.empty() || !tool_answer_received) && !c.cancel)
      terminal = "failed";
    bool cpu_recovered = false;
    if (terminal == "failed" && !c.cancel && !tool_protocol_failed && e.backend == 1 &&
        !e.cpu_fallback && std::getenv("FORESIGHT_LITERT_BACKEND") &&
        std::string(std::getenv("FORESIGHT_LITERT_BACKEND")) == "gpu") {
      {
        std::lock_guard lock(e.mu);
        e.cpu_fallback = true;
        e.state = "loading";
      }
      shutdown_persistent(e, false);
      if (e.persistent_protocol) {
        cpu_recovered = start_persistent(e, c);
      } else {
        std::vector<std::string> probe{e.runtime, "--model", e.model, "--probe", "--backend", "cpu"};
        if (e.model_type) { probe.push_back("--model-type"); probe.push_back(std::to_string(e.model_type)); }
        cpu_recovered = run(c, std::move(probe), [](const char *, size_t) {}) == 0;
      }
      if (cpu_recovered) c.emit(event("state", c.request, seq++,
          ",\"state\":\"ready\",\"backend\":\"cpu\",\"message\":\"GPU generation failed; CPU runtime rebuilt. Retry the answer.\""));
    }
    c.awaiting_tool = false;
    if (terminal == "failed" && !tool_protocol_failed && !worker_error_received)
      failure(c, c.request, seq, "runtime_failure",
              tools && status == 0 ? "Tool worker exited without a complete answer"
              : "Generation runner exited with status " + std::to_string(status));
    settled = true;
    c.emit(event("done", c.request, seq++, ",\"status\":" + quote(terminal)));
    {
      std::lock_guard lock(e.mu);
      e.busy = false;
      e.state = terminal == "failed" && !cpu_recovered ? "failed" : "ready";
      e.error = terminal == "failed" ? (cpu_recovered ? "GPU generation failed; CPU runtime ready for retry" : "runtime_failure") : "";
    }
    c.active = false;
    }, [&](const std::string &message) {
      if (settled) return;
      uint64_t seq = 0;
      failure(c, c.request, seq, "runtime_failure", message);
      c.emit(event("done", c.request, seq, ",\"status\":" + quote("failed")));
      {
        std::lock_guard lock(e.mu);
        e.busy = false;
        e.state = "failed";
        e.error = "runtime_failure";
      }
      c.finish_input = false;
      c.active = false;
    });
  });
  return 0;
}
int fs_generate(void *h, const char *id, const char *prompt) {
  try {
  return generate_with_schema(h, id, prompt, nullptr);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_generate_json(void *h, const char *id, const char *prompt,
                     const char *schema) {
  try {
  if (!schema || !*schema)
    return -1;
  return generate_with_schema(h, id, prompt, schema);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_generate_options(void *h, const char *id, const char *prompt,
                        const char *schema, int max_output_tokens) {
  try {
  return generate_with_schema(h, id, prompt, schema, max_output_tokens);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_generate_tools(void *h, const char *id, const char *prompt,
                      const char *tools, int max_output_tokens) {
  try {
  if (!tools || !*tools) return -1;
  return generate_with_schema(h, id, prompt, tools, max_output_tokens, true);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_generation_tool_reply(void *h, const char *id, const char *message) {
  try {
  if (!h || !id || !message) return -1;
  auto &c = *static_cast<Conversation *>(h);
  std::lock_guard life(c.life);
  if (!c.active || c.cancel || c.request != id || !c.awaiting_tool.exchange(false))
    return -1;
  std::lock_guard lock(c.input_mutex);
  c.input.push_back(std::string(message) + "\n");
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_generation_cancel(void *h) {
  try {
  if (!h)
    return -1;
  auto &c = *static_cast<Conversation *>(h);
  std::lock_guard life(c.life);
  if (c.active)
    c.stop();
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_conversation_destroy(void *h, int drain) {
  try {
  if (!h)
    return 0;
  auto *c = static_cast<Conversation *>(h);
  {
    std::lock_guard life(c->life);
    if (c->active && !drain)
      return -1;
    c->stop();
    c->join();
  }
  {
    std::lock_guard lock(c->engine->mu);
    --c->engine->refs;
  }
  delete c;
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
void *fs_speech_create(const char *runtime, const char *model) {
  try {
  const char *override_runtime = std::getenv("FORESIGHT_WHISPER_RUNTIME");
  if (override_runtime && *override_runtime) runtime = override_runtime;
  if (!valid_asset(runtime, model))
    return nullptr;
  auto *s = new Speech;
  s->runtime = runtime;
  s->model = model;
  // Bundles install the speech server beside the diagnostic CLI. Explicit
  // worker overrides are also supported for external runtime installations.
  auto server = std::filesystem::path(runtime).parent_path() / "foresight-whisper-worker";
  if (const char *configured = std::getenv("FORESIGHT_WHISPER_WORKER"); configured && *configured) server = configured;
  if (access(server.c_str(), X_OK) == 0) {
    const char *backend = std::getenv("FORESIGHT_WHISPER_BACKEND");
    const char *device = std::getenv("FORESIGHT_WHISPER_DEVICE");
    const auto key = quote(server.string()) + quote(model) + quote(backend ? backend : "") + quote(device ? device : "");
    std::lock_guard lock(speech_engines_mutex);
    for (auto i=speech_engines.begin();i!=speech_engines.end();) {
      if(i->second.expired())i=speech_engines.erase(i);else ++i;
    }
    s->worker_engine = speech_engines[key].lock();
    if (!s->worker_engine) {
      s->worker_engine = std::make_shared<SpeechEngine>();
      auto &engine=s->worker_engine->engine;
      engine.runtime = server.string(); engine.model = model; engine.backend = 2;
      engine.cpu_fallback = backend && std::string(backend) == "cpu";
      speech_engines[key] = s->worker_engine;
    }
  }
  return s;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
int fs_speech_push(void *h, const int16_t *samples, size_t count, int rate) {
  try {
  if (!h || (!samples && count) || rate < 8000 || rate > 192000)
    return -1;
  auto &s = *static_cast<Speech *>(h);
  std::lock_guard life(s.life);
  if (s.active)
    return -1;
  if (s.input_rate && s.input_rate != rate)
    return -1;
  if (s.samples.size() + uint64_t(count) * 16000 / rate > 16000 * 60 * 60 * 2)
    return -1;
  s.input_rate = rate;
  if (count)
    s.pending.insert(s.pending.end(), samples, samples + count);
  while (size_t(s.phase) + 1 < s.pending.size()) {
    size_t a = size_t(s.phase);
    s.samples.push_back(int16_t(std::lround(
        s.pending[a] + (s.pending[a + 1] - s.pending[a]) * (s.phase - a))));
    s.phase += rate / 16000.0;
  }
  size_t consumed = std::min(size_t(s.phase), s.pending.size());
  s.pending.erase(s.pending.begin(), s.pending.begin() + consumed);
  s.phase -= consumed;
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_speech_finish(void *h, const char *id) {
  try {
  if (!h || !id || !*id)
    return -1;
  auto &s = *static_cast<Speech *>(h);
  std::lock_guard life(s.life);
  if (s.active)
    return -1;
  s.join();
  s.cancel = false;
  s.active = true;
  std::string request = id;
  if (!s.pending.empty())
    s.samples.push_back(s.pending.back());
  auto samples = std::move(s.samples);
  s.pending.clear();
  s.phase = 0;
  s.input_rate = 0;
  s.thread = std::thread([&s, request, samples = std::move(samples)] {
    bool settled = false;
    foresight::guarded_worker([&] {
    uint64_t seq = 0;
    if (const auto blocked = linux_speech_cpu_block()) {
      failure(s, request, seq, "speech_runtime_failure", *blocked);
      s.emit(event("done", request, seq++, ",\"status\":\"failed\""));
      s.active = false;
      settled = true;
      return;
    }
    int status = -1;
    std::string transcript;
    {
      auto audio = foresight::create_speech_audio();
      if (audio.fd >= 0) {
        close(audio.fd);
        audio.fd = -1;
      }
      wav(audio.path, samples);
      const char *speech_backend = std::getenv("FORESIGHT_WHISPER_BACKEND");
      const bool cpu = speech_backend && std::string(speech_backend) == "cpu";
      auto arguments = [&](bool cpu_only) {
        std::vector<std::string> result{s.runtime, "-m", s.model, "-f", audio.path,
            "-l", "auto", "-nt", "-np", "-t", "4"};
        if (cpu_only) result.push_back("-ng");
        else if (const char *device = std::getenv("FORESIGHT_WHISPER_DEVICE"); device && *device) {
          result.push_back("-dev"); result.push_back(device);
        }
        return result;
      };
      auto recognize = [&](bool cpu_only) {
        if (s.worker_engine) {
          std::unique_lock lock(s.worker_engine->mutex, std::defer_lock);
          while (!lock.try_lock_for(std::chrono::milliseconds(20))) {
            if (s.cancel) return -1;
          }
          if (s.cancel) return -1;
          auto &engine = s.worker_engine->engine;
          if (cpu_only && !engine.cpu_fallback) { shutdown_persistent(engine, false); engine.cpu_fallback = true; }
          bool received = false, invalid = false;
          transcript = quote("");
          const auto result = run_persistent(engine, s, "{\"prompt\":" + quote(audio.path) + "}", [&](const std::string &line) {
            if (line.starts_with("text ") && !received && line.size() >= 7 &&
                foresight::json_string_literal(line.substr(5))) {
              transcript = line.substr(5); received = true;
            } else invalid = true;
          });
          return result == 0 && received && !invalid ? 0 : 1;
        }
        return run(s, arguments(cpu_only), [&](const char *p, size_t n) { transcript.append(p, n); });
      };
      status = recognize(cpu);
      if (status != 0 && !cpu && !s.cancel) {
        // The failed attempt must not contaminate the CPU transcript.
        transcript.clear();
        s.emit(event("state", request, seq++, ",\"message\":\"GPU speech recognition failed; retrying on CPU\""));
        status = recognize(true);
      }
    }
    std::string terminal = s.cancel      ? "cancelled"
                           : status == 0 ? "completed"
                                         : "failed";
    if (terminal == "completed")
      s.emit(event("transcript", request, seq++,
                   ",\"text\":" + (s.worker_engine ? transcript : quote(transcript)) +
                       ",\"final\":true,\"start_ms\":0,\"end_ms\":" +
                       std::to_string(samples.size() * 1000 / 16000) +
                       ",\"sample_rate\":16000"));
    if (terminal == "failed")
      failure(s, request, seq, "speech_runtime_failure",
              "Speech runner failed; verify model, audio and executable");
    settled = true;
    s.active = false;
    s.emit(event("done", request, seq++, ",\"status\":" + quote(terminal)));
    }, [&](const std::string &message) {
      if (settled) return;
      uint64_t seq = 0;
      failure(s, request, seq, "speech_runtime_failure", message);
      s.emit(event("done", request, seq, ",\"status\":" + quote("failed")));
      s.active = false;
    });
  });
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
int fs_speech_cancel(void *h) {
  try {
  if (!h)
    return -1;
  auto &s = *static_cast<Speech *>(h);
  std::lock_guard life(s.life);
  s.stop();
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
void fs_speech_destroy(void *h) {
  try {
  if (!h)
    return;
  auto *s = static_cast<Speech *>(h);
  {
    std::lock_guard life(s->life);
    s->stop();
    s->join();
  }
  delete s;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
  }
}
void *fs_capture_start(const char *target, int playback, int rate) {
  try {
  return fs_capture_start_with_options(target, playback, rate, 0);

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
int fs_capture_set_echo_cancellation(void *handle, int enabled) {
  try {
  if (!handle) return 0;
#ifdef __APPLE__
  auto *capture = static_cast<Capture *>(handle);
  if (!capture->playback && capture->runtime.empty()) {
    capture->echoCancellation = enabled != 0;
    return 1;
  }
#else
  (void)enabled;
#endif
  return 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
void *fs_capture_start_with_options(const char *target, int playback, int rate, int echo) {
  try {
  if (rate < 8000 || rate > 192000)
    return nullptr;
  auto *c = new Capture;
  c->target = target && *target ? target : "auto";
  if (const char *runtime = getenv("FORESIGHT_CAPTURE_RUNTIME"); runtime && *runtime) {
    if (runtime[0] != '/' || access(runtime, X_OK) != 0) { delete c; return nullptr; }
    c->runtime = runtime;
  }
  c->playback = playback != 0;
  if (echo && !fs_capture_set_echo_cancellation(c, echo)) { delete c; return nullptr; }
  c->rate = rate;
  c->active = true;
  c->thread = std::thread([c] {
    foresight::guarded_worker([&] {
#ifdef __APPLE__
    if (c->runtime.empty()) {
    fs_macos_capture(c->target, c->playback, c->rate, c->cancel,
                     [c](const auto &bytes) { audio_frame(*c, bytes); },
                     [c](const auto &event) { c->emit(event); }, &c->echoCancellation);
    c->active = false;
    c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/audio_state_v1\",\"state\":\"stopped\"}");
    return;
    }
#endif
    int attempt = 0;
    while (!c->cancel) {
      c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/"
              "audio_state_v1\",\"state\":\"connecting\"}");
      // PipeWire (including Ubuntu 24.04) has no --raw option. The production
      // path writes to an owned .raw FIFO so stdout diagnostics cannot be PCM.
      std::vector<std::string> args{c->runtime.empty() ? "pw-record" : c->runtime,
                                    "--format",   "s16",
                                    "--rate",     std::to_string(c->rate),
                                    "--channels", "1",
                                    "--target",   c->target};
      if (c->playback || c->target != "auto") {
        args.push_back("--properties");
        std::string properties = "{ ";
        if (c->playback)
          properties += "stream.capture.sink = true ";
        // An explicitly selected device must not silently migrate to another
        // microphone/output when it disappears. Auto continues following the
        // session's default device; owned retries reconnect the named target.
        if (c->target != "auto")
          properties += "node.dont-fallback = true node.dont-reconnect = true ";
        args.push_back(properties + "}");
      }
      args.push_back("-");
      std::vector<unsigned char> residual;
      bool announced = false;
      int status = run(*c, args, [&](const char *data, size_t n) {
        if (!announced) {
          c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/"
                  "audio_state_v1\",\"state\":\"capturing\"}");
          announced = true;
          attempt = 0;
        }
        residual.insert(residual.end(), data, data + n);
        size_t frame = c->playback ? size_t(c->rate * 2 * 40 / 1000)
                                   : residual.size() & ~size_t(1);
        while (frame && residual.size() >= frame) {
          std::vector<unsigned char> bytes(residual.begin(),
                                           residual.begin() + frame);
          audio_frame(*c, bytes);
          residual.erase(residual.begin(), residual.begin() + frame);
          if (!c->playback)
            break;
        }
      }, false, c->runtime.empty());
      if (c->cancel) {
        residual.resize(residual.size() & ~size_t(1));
        if (!residual.empty()) audio_frame(*c, residual);
        break;
      }
      c->emit("{\"type\":\"gap\",\"channel\":\"foresight.linux/"
              "audio_state_v1\",\"reason\":\"device_or_pipewire_lost\","
              "\"discarded_bytes\":" +
              std::to_string(residual.size()) +
              ",\"exit_status\":" + std::to_string(status) + "}");
      if (++attempt >= 5) {
        c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/"
                "audio_state_v1\",\"state\":\"failed\",\"message\":\"Capture "
                "retries exhausted; select device and restart\"}");
        break;
      }
      for (int i = 0; i < 10 * attempt && !c->cancel; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    c->active = false;
    c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/"
            "audio_state_v1\",\"state\":\"stopped\"}");
    }, [&](const std::string &) {
      c->active = false;
      c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/"
              "audio_state_v1\",\"state\":\"failed\",\"message\":\"Capture failed\"}");
    });
  });
  return c;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return nullptr;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return nullptr;
  }
}
void fs_capture_finish(void *h) {
  try {
  if (!h) return;
  auto *c = static_cast<Capture *>(h);
  c->stop();
  c->join();

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
  }
}
void fs_capture_stop(void *h) {
  try {
  if (!h)
    return;
  auto *c = static_cast<Capture *>(h);
  c->stop();
  c->join();
  delete c;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
  }
}
double fs_pcm_rms(const int16_t *samples, size_t n) {
  try {
  if (!samples || !n)
    return 0;
  long double sum = 0;
  for (size_t i = 0; i < n; ++i) {
    long double v = samples[i] / 32767.0L;
    sum += v * v;
  }
  return std::sqrt(double(sum / n));

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return 0;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return 0;
  }
}
size_t fs_resample_pcm(const int16_t *input, size_t n, int in_rate,
                       int16_t *out, size_t capacity, int out_rate) {
  try {
  if (!input || !out || !n || in_rate <= 0 || out_rate <= 0)
    return 0;
  size_t count = std::min(capacity, size_t(uint64_t(n) * out_rate / in_rate));
  for (size_t i = 0; i < count; ++i) {
    double pos = double(i) * in_rate / out_rate;
    size_t a = std::min(size_t(pos), n - 1), b = std::min(a + 1, n - 1);
    out[i] = int16_t(std::lround(input[a] + (input[b] - input[a]) * (pos - a)));
  }
  return count;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return 0;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return 0;
  }
}
}

// ESRCH positively proves that the process no longer exists. Inspection errors
// such as EPERM or inaccessible /proc remain unknown; they must never authorize
// signalling an unverified PID or certify successful shutdown.
static int process_inspection_failure(pid_t value) {
  if (kill(value, 0) < 0 && errno == ESRCH) return 0;
  return -1;
}

extern "C" int fs_process_matches(int64_t value, const char *socket,
                                  const char *storage, const char *instance) {
  try {
  if (value <= 0 || value > INT32_MAX || !socket || !storage || !instance)
    return 0;
  const auto prefix = std::to_string(value) + "-";
  if (std::string(instance).rfind(prefix, 0) != 0) return 0;
  std::vector<std::string> args;
  std::string executable;
#ifdef __APPLE__
  char executable_buffer[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(value, executable_buffer, sizeof(executable_buffer)) <= 0) return process_inspection_failure(static_cast<pid_t>(value));
  executable = executable_buffer;
  proc_bsdinfo info{};
  if (proc_pidinfo(value, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return process_inspection_failure(static_cast<pid_t>(value));
  if (info.pbi_uid != getuid()) return 0;
  // Helper IDs use system_clock's native ticks (microseconds on Apple libc++).
  // Refuse an instance older than this process's creation, preventing stale
  // persisted state from authorizing a reused PID with identical arguments.
  std::string stamp = std::string(instance).substr(prefix.size());
  if (stamp.empty() || stamp.find_first_not_of("0123456789") != std::string::npos) return 0;
  try {
    uint64_t ticks = std::stoull(stamp);
    const auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::system_clock::duration(ticks)).count();
    if (micros < int64_t(info.pbi_start_tvsec) * 1000000 + int64_t(info.pbi_start_tvusec)) return 0;
  } catch (...) { return 0; }
  int mib[] = {CTL_KERN, KERN_PROCARGS2, static_cast<int>(value)};
  size_t size = 0;
  if (sysctl(mib, 3, nullptr, &size, nullptr, 0)) return process_inspection_failure(static_cast<pid_t>(value));
  std::vector<char> bytes(size);
  if (sysctl(mib, 3, bytes.data(), &size, nullptr, 0) || size < sizeof(int)) return process_inspection_failure(static_cast<pid_t>(value));
  int count = 0;
  memcpy(&count, bytes.data(), sizeof(count));
  size_t offset = sizeof(count);
  while (offset < size && bytes[offset]) ++offset; // executable path
  while (offset < size && !bytes[offset]) ++offset; // padding
  for (int i = 0; i < count && offset < size; ++i) {
    size_t end = offset;
    while (end < size && bytes[end]) ++end;
    if (end == size) return process_inspection_failure(static_cast<pid_t>(value));
    args.emplace_back(bytes.data() + offset, end - offset);
    offset = end + 1;
  }
#else
  struct stat info{};
  std::string path = "/proc/" + std::to_string(value);
  if (stat(path.c_str(), &info)) return process_inspection_failure(static_cast<pid_t>(value));
  if (info.st_uid != getuid()) return 0;
  std::error_code error;
  executable = std::filesystem::read_symlink(path + "/exe", error).string();
  if (error) return process_inspection_failure(static_cast<pid_t>(value));
  std::ifstream input(path + "/cmdline", std::ios::binary);
  if (!input) return process_inspection_failure(static_cast<pid_t>(value));
  std::string arg;
  while (std::getline(input, arg, '\0')) args.push_back(arg);
#endif
  if (args.size() < 3 || args[1] != socket || args[2] != storage) return 0;
  const auto name = std::filesystem::path(args[0]).filename().string();
  const auto actual = std::filesystem::path(executable).filename().string();
  return (name == "ForesightHelper" || name == "foresight-helper") && actual == name ? 1 : 0;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}

extern "C" int fs_set_runtime_environment(const char *key, const char *value) {
  try {
  if (!key || !value) return -1;
  static const std::set<std::string> allowed{
      "FORESIGHT_LITERT_LIBRARY", "FORESIGHT_ONNX_LIBRARY",
      "FORESIGHT_LITERT_BACKEND", "FORESIGHT_WHISPER_BACKEND",
      "FORESIGHT_WHISPER_DEVICE", "FORESIGHT_HELPER", "FORESIGHT_LITERT_CACHE",
      "FORESIGHT_WHISPER_RUNTIME", "FORESIGHT_WHISPER_WORKER", "PYTHONPYCACHEPREFIX"};
  if (!allowed.count(key)) return -1;
  std::lock_guard lock(foresight::launch_mutex);
  return setenv(key, value, 1) == 0 ? 0 : -1;

  } catch (const std::exception &barrier_error) {
    foresight::report_barrier_error(barrier_error.what());
    return -1;
  } catch (...) {
    foresight::report_barrier_error("unknown C++ exception");
    return -1;
  }
}
