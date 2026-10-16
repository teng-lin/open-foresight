#include "foresight_native.h"
#include "portable_process.h"
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
#include <poll.h>
#include <set>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>
extern char **environ;
namespace {
std::string quote(const std::string &s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c == '\n')
      out += "\\n";
    else if (c == '\r')
      out += "\\r";
    else if (c == '\t')
      out += "\\t";
    else if (c < 32) {
      const char *h = "0123456789abcdef";
      out += "\\u00";
      out += h[c >> 4];
      out += h[c & 15];
    } else
      out += c;
  }
  return out + '"';
}
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
#ifdef __APPLE__
  foresight::OwnedSpawn *owned_process = nullptr;
#endif
  std::mutex life;
  std::mutex process_mutex;
  void stop() {
    cancel = true;
    std::lock_guard lock(process_mutex);
#ifdef __APPLE__
    if (owned_process) owned_process->stop();
#else
    pid_t p = pid.load();
    if (p > 0) kill(-p, SIGKILL);
#endif
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
// posix_spawn avoids unsafe post-fork work inside a multi-threaded Flutter
// host.
int run(Worker &w, std::vector<std::string> args,
        const std::function<void(const char *, size_t)> &output) {
  std::unique_lock launch(foresight::launch_mutex);
  int pipes[2];
  if (foresight::cloexec_pipe(pipes) < 0)
    return -1;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null",
                                   O_RDONLY, 0);
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
  std::vector<char *> argv;
  for (auto &a : args)
    argv.push_back(a.data());
  argv.push_back(nullptr);
  pid_t p = -1;
#ifdef __APPLE__
  foresight::OwnedSpawn owned;
  int err = owned.spawn(&p, &actions, &attr, args);
#else
  int err = posix_spawnp(&p, argv[0], &actions, &attr, argv.data(), environ);
#endif
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  close(pipes[1]);
  if (err) {
    close(pipes[0]);
    return -err;
  }
  launch.unlock();
  {
    std::lock_guard lock(w.process_mutex);
#ifdef __APPLE__
    w.pid = owned.worker;
    w.owned_process = &owned;
#else
    w.pid = p;
#endif
  }
  if (w.cancel) {
#ifdef __APPLE__
    std::lock_guard lock(w.process_mutex);
    owned.stop();
#else
    kill(-p, SIGKILL);
#endif
  }
  char buffer[4096];
  while (!w.cancel) {
    pollfd fd{pipes[0], POLLIN, 0};
    int r = poll(&fd, 1, 100);
    if (r > 0) {
      ssize_t n = read(pipes[0], buffer, sizeof(buffer));
      if (n <= 0)
        break;
      output(buffer, size_t(n));
    } else if (r < 0 && errno != EINTR)
      break;
  }
  if (w.cancel) {
#ifdef __APPLE__
    std::lock_guard lock(w.process_mutex);
    owned.stop();
#else
    kill(-p, SIGKILL);
#endif
  }
  close(pipes[0]);
  int status = 0;
  // Do not hold life while waiting: cancellation must still be able to signal
  // a worker that closed stdout early. Keep its PID reserved until disarmed.
  siginfo_t info{};
  while (waitid(P_PID, p, &info, WEXITED | WNOWAIT) < 0 && errno == EINTR) {}
#ifdef __APPLE__
  // Supervisor has already completed worker cleanup.
#endif
  std::lock_guard lock(w.process_mutex);
  while (waitpid(p, &status, 0) < 0 && errno == EINTR) {
  }
  w.pid = -1;
#ifdef __APPLE__
  w.owned_process = nullptr;
#endif
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
bool valid_asset(const char *runtime, const char *model) {
  return runtime && *runtime && model && *model && access(model, R_OK) == 0;
}
struct Engine {
  int backend = 0;
  std::string runtime, model;
  std::mutex mu;
  int refs = 0;
  bool busy = false;
  std::string state = "configured", error;
};
struct Conversation : Worker {
  Engine *engine;
  std::set<std::string> requests;
  std::string request;
  uint64_t sequence = 0;
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
struct Speech : Worker {
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
  int rate = 48000;
  uint64_t dropped = 0;
};
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
  if (c.events.size() >= 256) {
    c.events.pop_front();
    ++c.dropped;
  }
  c.events.push_back("{" + fields + "}");
  c.cv.notify_all();
}
} // namespace
extern "C" {
int fs_abi_version() { return 1; }
char *fs_audio_capabilities() {
#ifdef __APPLE__
  return owned(fs_macos_capabilities());
#else
  return owned("{\"backend\":\"pipewire\"}");
#endif
}
char *fs_audio_request_system(int32_t timeout_ms) {
#ifdef __APPLE__
  return owned(fs_macos_request_system(timeout_ms));
#else
  (void)timeout_ms;
  return owned("{\"system_audio\":\"unavailable\",\"system_audio_request\":\"failed\",\"permission_verified\":false,\"code\":\"unsupported_platform\",\"message\":\"System audio permission requests are specific to macOS.\"}");
#endif
}
int fs_audio_request_microphone() {
#ifdef __APPLE__
  return fs_macos_request_microphone() ? 0 : 1;
#else
  return 0;
#endif
}
void fs_string_free(char *p) { free(p); }
char *fs_event_poll(void *h, int timeout) {
  if (!h)
    return nullptr;
  auto &e = *static_cast<Events *>(h);
  std::unique_lock lock(e.mu);
  e.cv.wait_for(lock, std::chrono::milliseconds(std::clamp(timeout, 0, 60000)),
                [&] { return !e.events.empty(); });
  if (e.events.empty())
    return nullptr;
  auto s = std::move(e.events.front());
  e.events.pop_front();
  return owned(s);
}
void *fs_engine_create(const char *runtime, const char *model) {
  return fs_engine_create_backend(runtime, model, 0);
}
void *fs_engine_create_backend(const char *runtime, const char *model, int backend) {
  if (backend != 0 && backend != 1) return nullptr;
  if (!valid_asset(runtime, model))
    return nullptr;
  auto *e = new Engine;
  e->runtime = runtime;
  e->model = model;
  e->backend = backend;
  return e;
}
char *fs_engine_state(void *h) {
  if (!h)
    return nullptr;
  auto &e = *static_cast<Engine *>(h);
  std::lock_guard lock(e.mu);
  if (e.backend == 1)
    return owned("{\"state\":" + quote(e.state) +
                 ",\"backend\":" + quote(std::getenv("FORESIGHT_LITERT_BACKEND") &&
                     std::string(std::getenv("FORESIGHT_LITERT_BACKEND")) == "gpu"
                     ? "litert-lm-gpu-python" : "litert-lm-cpu-python") +
                 ",\"load_policy\":\"per_request\","
                 "\"context_length\":4096,\"temperature\":0.4,\"top_k\":40,\"top_p\":0.9,"
                 "\"thinking\":false,\"json\":\"ll_guidance_and_application_validation\",\"text\":true,\"tools\":false,\"error\":" + quote(e.error) + "}");
  return owned("{\"state\":" + quote(e.state) +
               ",\"backend\":\"llama.cpp-cpu-cli\",\"load_policy\":\"per_"
               "request\",\"context_length\":4096,\"max_output_tokens\":256,"
               "\"temperature\":0,\"text\":true,\"tools\":false,\"error\":" +
               quote(e.error) + "}");
}
int fs_engine_probe(void *h) {
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
  Worker probe;
  std::string diagnostics;
  auto arguments = e.backend == 1
      ? std::vector<std::string>{e.runtime, "--model", e.model, "--probe"}
      : std::vector<std::string>{e.runtime, "-m", e.model, "-p", "probe", "-n", "0", "-c", "4096", "--no-warmup", "-no-cnv", "-t", "4"};
  int status = run(probe, std::move(arguments), [&](const char *data, size_t size) {
    if (e.backend == 1 && diagnostics.size() < 4096) diagnostics.append(data, std::min(size, 4096-diagnostics.size()));
  });
  {
    std::lock_guard lock(e.mu);
    e.busy = false;
    e.state = status == 0 ? "ready" : "failed";
    e.error = status == 0 ? ""
                          : "Model initialization probe failed with status " +
                                std::to_string(status) + diagnostics;
  }
  return status == 0 ? 0 : -1;
}
int fs_engine_destroy(void *h) {
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
}
void *fs_conversation_create(void *h) {
  if (!h)
    return nullptr;
  auto *e = static_cast<Engine *>(h);
  std::lock_guard lock(e->mu);
  ++e->refs;
  auto *c = new Conversation;
  c->engine = e;
  return c;
}
static int generate_with_schema(void *h, const char *id, const char *prompt,
                                const char *schema, int max_output_tokens = 256) {
  if (max_output_tokens < 1 || max_output_tokens > 3072) return -1;
  if (!h || !id || !*id || !prompt)
    return -1;
  auto &c = *static_cast<Conversation *>(h);
  std::lock_guard life(c.life);
  if (c.active || c.requests.count(id))
    return -1;
  c.join();
  auto &e = *c.engine;
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
  c.active = true;
  std::string text = prompt;
  std::string json_schema = schema ? schema : "";
  c.thread = std::thread([&c, text, json_schema, max_output_tokens] {
    auto &e = *c.engine;
    uint64_t seq = 0;
    // Completion mode avoids runner UI/chat banners; app assembles structured
    // prompt.
    std::string utf8;
    std::vector<std::string> args{e.runtime,     "-m",
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
    if (!json_schema.empty()) {
      args.push_back("--json-schema");
      args.push_back(json_schema);
    }
    int status = run(c, std::move(args), [&](const char *data, size_t n) {
      utf8.append(data, n);
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
    });
    if (!c.cancel) {
      size_t marker = utf8.find(" [end of text]");
      if (marker != std::string::npos)
        utf8.erase(marker);
      if (!utf8.empty())
        c.emit(event("delta", c.request, seq++, ",\"text\":" + quote(utf8)));
    }
    std::string terminal = c.cancel      ? "cancelled"
                           : status == 0 ? "completed"
                                         : "failed";
    if (terminal == "failed")
      failure(c, c.request, seq, "runtime_failure",
              "Generation runner exited with status " + std::to_string(status));
    c.emit(event("done", c.request, seq++, ",\"status\":" + quote(terminal)));
    {
      std::lock_guard lock(e.mu);
      e.busy = false;
      e.state = terminal == "failed" ? "failed" : "ready";
      e.error = terminal == "failed" ? "runtime_failure" : "";
    }
    c.active = false;
  });
  return 0;
}
int fs_generate(void *h, const char *id, const char *prompt) {
  return generate_with_schema(h, id, prompt, nullptr);
}
int fs_generate_json(void *h, const char *id, const char *prompt,
                     const char *schema) {
  if (!schema || !*schema)
    return -1;
  return generate_with_schema(h, id, prompt, schema);
}
int fs_generate_options(void *h, const char *id, const char *prompt,
                        const char *schema, int max_output_tokens) {
  return generate_with_schema(h, id, prompt, schema, max_output_tokens);
}
int fs_generation_cancel(void *h) {
  if (!h)
    return -1;
  auto &c = *static_cast<Conversation *>(h);
  std::lock_guard life(c.life);
  if (c.active)
    c.stop();
  return 0;
}
int fs_conversation_destroy(void *h, int drain) {
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
}
void *fs_speech_create(const char *runtime, const char *model) {
  const char *override_runtime = std::getenv("FORESIGHT_WHISPER_RUNTIME");
  if (override_runtime && *override_runtime) runtime = override_runtime;
  if (!valid_asset(runtime, model))
    return nullptr;
  auto *s = new Speech;
  s->runtime = runtime;
  s->model = model;
  return s;
}
int fs_speech_push(void *h, const int16_t *samples, size_t count, int rate) {
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
}
int fs_speech_finish(void *h, const char *id) {
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
    uint64_t seq = 0;
    char tmp[] = "/tmp/foresight-asr-XXXXXX";
    int fd = mkstemp(tmp);
    int status = -1;
    std::string transcript;
    if (fd >= 0) {
      close(fd);
      wav(tmp, samples);
      std::vector<std::string> arguments{
          s.runtime, "-m", s.model, "-f", tmp, "-l", "auto", "-nt", "-np", "-t", "4"};
      const char *speech_backend = std::getenv("FORESIGHT_WHISPER_BACKEND");
      if (speech_backend && std::string(speech_backend) == "cpu")
        arguments.push_back("-ng");
      else if (const char *device = std::getenv("FORESIGHT_WHISPER_DEVICE"); device && *device) {
        arguments.push_back("-dev");
        arguments.push_back(device);
      }
      status = run(s, std::move(arguments),
                   [&](const char *p, size_t n) { transcript.append(p, n); });
      unlink(tmp);
    }
    std::string terminal = s.cancel      ? "cancelled"
                           : status == 0 ? "completed"
                                         : "failed";
    if (terminal == "completed")
      s.emit(event("transcript", request, seq++,
                   ",\"text\":" + quote(transcript) +
                       ",\"final\":true,\"start_ms\":0,\"end_ms\":" +
                       std::to_string(samples.size() * 1000 / 16000) +
                       ",\"sample_rate\":16000"));
    if (terminal == "failed")
      failure(s, request, seq, "speech_runtime_failure",
              "Speech runner failed; verify model, audio and executable");
    s.emit(event("done", request, seq++, ",\"status\":" + quote(terminal)));
    s.active = false;
  });
  return 0;
}
int fs_speech_cancel(void *h) {
  if (!h)
    return -1;
  auto &s = *static_cast<Speech *>(h);
  std::lock_guard life(s.life);
  s.stop();
  return 0;
}
void fs_speech_destroy(void *h) {
  if (!h)
    return;
  auto *s = static_cast<Speech *>(h);
  {
    std::lock_guard life(s->life);
    s->stop();
    s->join();
  }
  delete s;
}
void *fs_capture_start(const char *target, int playback, int rate) {
  if (rate < 8000 || rate > 192000)
    return nullptr;
  auto *c = new Capture;
  c->target = target && *target ? target : "auto";
  if (const char *runtime = getenv("FORESIGHT_CAPTURE_RUNTIME"); runtime && *runtime) {
    if (runtime[0] != '/' || access(runtime, X_OK) != 0) { delete c; return nullptr; }
    c->runtime = runtime;
  }
  c->playback = playback != 0;
  c->rate = rate;
  c->active = true;
  c->thread = std::thread([c] {
#ifdef __APPLE__
    if (c->runtime.empty()) {
    fs_macos_capture(c->target, c->playback, c->rate, c->cancel,
                     [c](const auto &bytes) { audio_frame(*c, bytes); },
                     [c](const auto &event) { c->emit(event); });
    c->active = false;
    c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/audio_state_v1\",\"state\":\"stopped\"}");
    return;
    }
#endif
    int attempt = 0;
    while (!c->cancel) {
      c->emit("{\"type\":\"state\",\"channel\":\"foresight.linux/"
              "audio_state_v1\",\"state\":\"connecting\"}");
      std::vector<std::string> args{c->runtime.empty() ? "pw-record" : c->runtime,  "--raw",
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
      });
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
  });
  return c;
}
void fs_capture_finish(void *h) {
  if (!h) return;
  auto *c = static_cast<Capture *>(h);
  c->stop();
  c->join();
}
void fs_capture_stop(void *h) {
  if (!h)
    return;
  auto *c = static_cast<Capture *>(h);
  c->stop();
  c->join();
  delete c;
}
double fs_pcm_rms(const int16_t *samples, size_t n) {
  if (!samples || !n)
    return 0;
  long double sum = 0;
  for (size_t i = 0; i < n; ++i) {
    long double v = samples[i] / 32767.0L;
    sum += v * v;
  }
  return std::sqrt(double(sum / n));
}
size_t fs_resample_pcm(const int16_t *input, size_t n, int in_rate,
                       int16_t *out, size_t capacity, int out_rate) {
  if (!input || !out || !n || in_rate <= 0 || out_rate <= 0)
    return 0;
  size_t count = std::min(capacity, size_t(uint64_t(n) * out_rate / in_rate));
  for (size_t i = 0; i < count; ++i) {
    double pos = double(i) * in_rate / out_rate;
    size_t a = std::min(size_t(pos), n - 1), b = std::min(a + 1, n - 1);
    out[i] = int16_t(std::lround(input[a] + (input[b] - input[a]) * (pos - a)));
  }
  return count;
}
}

extern "C" int fs_process_matches(int64_t value, const char *socket,
                                  const char *storage, const char *instance) {
  if (value <= 0 || value > INT32_MAX || !socket || !storage || !instance)
    return 0;
  const auto prefix = std::to_string(value) + "-";
  if (std::string(instance).rfind(prefix, 0) != 0) return 0;
  std::vector<std::string> args;
  std::string executable;
#ifdef __APPLE__
  char executable_buffer[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(value, executable_buffer, sizeof(executable_buffer)) <= 0) return -1;
  executable = executable_buffer;
  proc_bsdinfo info{};
  if (proc_pidinfo(value, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
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
  if (sysctl(mib, 3, nullptr, &size, nullptr, 0)) return -1;
  std::vector<char> bytes(size);
  if (sysctl(mib, 3, bytes.data(), &size, nullptr, 0) || size < sizeof(int)) return -1;
  int count = 0;
  memcpy(&count, bytes.data(), sizeof(count));
  size_t offset = sizeof(count);
  while (offset < size && bytes[offset]) ++offset; // executable path
  while (offset < size && !bytes[offset]) ++offset; // padding
  for (int i = 0; i < count && offset < size; ++i) {
    size_t end = offset;
    while (end < size && bytes[end]) ++end;
    if (end == size) return -1;
    args.emplace_back(bytes.data() + offset, end - offset);
    offset = end + 1;
  }
#else
  struct stat info{};
  std::string path = "/proc/" + std::to_string(value);
  if (stat(path.c_str(), &info)) return -1;
  if (info.st_uid != getuid()) return 0;
  std::error_code error;
  executable = std::filesystem::read_symlink(path + "/exe", error).string();
  if (error) return -1;
  std::ifstream input(path + "/cmdline", std::ios::binary);
  if (!input) return -1;
  std::string arg;
  while (std::getline(input, arg, '\0')) args.push_back(arg);
#endif
  if (args.size() < 3 || args[1] != socket || args[2] != storage) return 0;
  const auto name = std::filesystem::path(args[0]).filename().string();
  const auto actual = std::filesystem::path(executable).filename().string();
  return (name == "ForesightHelper" || name == "foresight-helper") && actual == name ? 1 : 0;
}

extern "C" int fs_set_runtime_environment(const char *key, const char *value) {
  if (!key || !value) return -1;
  static const std::set<std::string> allowed{
      "FORESIGHT_LITERT_BACKEND", "FORESIGHT_WHISPER_BACKEND",
      "FORESIGHT_WHISPER_DEVICE", "FORESIGHT_HELPER", "FORESIGHT_LITERT_CACHE",
      "FORESIGHT_WHISPER_RUNTIME", "PYTHONPYCACHEPREFIX"};
  if (!allowed.count(key)) return -1;
  std::lock_guard lock(foresight::launch_mutex);
  return setenv(key, value, 1) == 0 ? 0 : -1;
}
