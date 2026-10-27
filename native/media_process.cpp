#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "media_process.h"
#include "diagnostic_sha256.h"
#include "media_supervisor_protocol.h"
#include "portable_process.h"
#include <array>
#include <chrono>
#include <climits>
#include <cstring>
#include <fcntl.h>
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
#include <nlohmann/json.hpp>
#endif
#include <poll.h>
#include <set>
#include <signal.h>
#include <spawn.h>
#include <stdexcept>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <thread>
#include <vector>
#ifdef __APPLE__
#include <Security/Security.h>
#else
#include <linux/memfd.h>
#include <sched.h>
#include <sys/syscall.h>
#endif

namespace foresight {
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
std::function<void()> media_process_before_spawn_for_test;
std::function<void()> media_process_before_verify_for_test;
std::function<void(int)> media_process_after_spawn_for_test;
std::function<void()> media_process_before_transfer_for_test;
#endif
namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t stdout_max = 16384, stderr_max = 8192,
                 executable_max = 32 * 1024 * 1024;
void require(bool condition, const char *reason) {
  if (!condition)
    throw std::runtime_error(reason);
}
struct Fd {
  int value = -1;
  Fd() = default;
  explicit Fd(int n) : value(n) {
    require(n >= 0, "descriptor_failed");
  }
  ~Fd() {
    if (value >= 0)
      close(value);
  }
  Fd(const Fd &) = delete;
  Fd &operator=(const Fd &) = delete;
  Fd(Fd &&other) noexcept : value(other.value) {
    other.value = -1;
  }
  Fd &operator=(Fd &&other) noexcept {
    if (this != &other) {
      if (value >= 0)
        close(value);
      value = other.value;
      other.value = -1;
    }
    return *this;
  }
};
bool hex(const std::string &s, size_t n) {
  return s.size() == n &&
         s.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool uuid(const std::string &s) {
  if (s.size() != 36)
    return false;
  for (size_t i = 0; i < s.size(); ++i)
    if ((i == 8 || i == 13 || i == 18 || i == 23)
            ? s[i] != '-'
            : s.substr(i, 1).find_first_not_of("0123456789abcdef") !=
                  std::string::npos)
      return false;
  return true;
}
std::string operation(MediaOperation op) {
  switch (op) {
  case MediaOperation::encode_opus:
    return "encode-opus";
  case MediaOperation::encode_recording_wav_v1:
    return "encode-recording-wav-v1";
  case MediaOperation::decode_pcm:
    return "decode-pcm";
  case MediaOperation::mix_export_mp3:
    return "mix-export-mp3";
  case MediaOperation::assemble_mp3_v1:
    return "assemble-mp3-v1";
  case MediaOperation::assemble_opus_v1:
    return "assemble-opus-v1";
  case MediaOperation::assemble_pcm_v1:
    return "assemble-pcm-v1";
  }
  throw std::runtime_error("invalid_operation");
}
struct Hash {
  fs_diagnostic_sha256_context state{};
  Hash() {
    require(!fs_diagnostic_sha256_init(&state), "hash_failed");
  }
  void add(const void *p, size_t n) {
    require(!fs_diagnostic_sha256_update(&state, p, n), "hash_failed");
  }
  std::string finish() {
    unsigned char b[32];
    require(!fs_diagnostic_sha256_final(&state, b), "hash_failed");
    std::string s;
    for (auto c : b) {
      s += "0123456789abcdef"[c >> 4];
      s += "0123456789abcdef"[c & 15];
    }
    return s;
  }
};
void check_deadline(Clock::time_point end, const std::atomic<bool> &cancel) {
  require(!cancel.load(), "cancelled");
  require(Clock::now() < end, "deadline");
}
Fd open_executable(const MediaExecutable &pin) {
  require(!pin.path.empty() && pin.path.front() == '/' &&
              pin.path.size() <= 4096 &&
              pin.path.find('\0') == std::string::npos,
          "executable_path");
  Fd directory(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
  size_t start = 1;
  while (true) {
    size_t end = pin.path.find('/', start);
    auto part =
        pin.path.substr(start, end == std::string::npos ? end : end - start);
    require(!part.empty() && part != "." && part != "..", "executable_path");
    if (end == std::string::npos) {
      Fd file(openat(directory.value, part.c_str(),
                     O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK));
      struct stat st{};
      require(!fstat(file.value, &st) && S_ISREG(st.st_mode) &&
                  (st.st_uid == geteuid() || st.st_uid == 0) &&
                  !(st.st_mode & 022) && (st.st_mode & 0111) &&
                  st.st_size > 0 &&
                  st.st_size <= static_cast<off_t>(executable_max),
              "executable_metadata");
      return file;
    }
    Fd next(openat(directory.value, part.c_str(),
                   O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    directory = std::move(next);
    start = end + 1;
  }
}
[[maybe_unused]] void write_all(int fd, const unsigned char *p, size_t n) {
  while (n) {
    ssize_t got = write(fd, p, n);
    if (got < 0 && errno == EINTR)
      continue;
    require(got > 0, "executable_copy");
    p += got;
    n -= got;
  }
}
Fd pin_executable(const MediaExecutable &pin, Clock::time_point deadline,
                  const std::atomic<bool> &cancel) {
  require(hex(pin.sha256, 64) && hex(pin.build_id, 64), "invalid_pin");
  Fd original = open_executable(pin);
  Hash hash;
#ifdef __APPLE__
  require(hex(pin.macos_cdhash, 40) || hex(pin.macos_cdhash, 64),
          "invalid_cdhash");
#else
#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif
  Fd frozen(
      static_cast<int>(syscall(SYS_memfd_create, "foresight-media-code",
                               MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_EXEC)));
#endif
  std::array<unsigned char, 8192> b{};
  uint64_t total = 0;
  while (true) {
    check_deadline(deadline, cancel);
    ssize_t n = read(original.value, b.data(), b.size());
    if (n < 0 && errno == EINTR)
      continue;
    require(n >= 0, "executable_read");
    if (!n)
      break;
    total += n;
    require(total <= executable_max, "executable_limit");
    hash.add(b.data(), n);
#ifndef __APPLE__
    write_all(frozen.value, b.data(), n);
#endif
  }
  require(hash.finish() == pin.sha256, "executable_digest");
#ifdef __APPLE__
  return original;
#else
  require(!fchmod(frozen.value, 0500) &&
              !fcntl(frozen.value, F_ADD_SEALS,
                     F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL),
          "executable_seal");
  return frozen;
#endif
}
[[maybe_unused]] void verify_guest(pid_t pid, const std::string &expected) {
#ifdef __APPLE__
  struct CF {
    CFTypeRef value = nullptr;
    ~CF() {
      if (value)
        CFRelease(value);
    }
  } number, attrs, guest, info;
  number.value = CFNumberCreate(nullptr, kCFNumberIntType, &pid);
  require(number.value, "identity_memory");
  const void *keys[] = {kSecGuestAttributePid};
  const void *values[] = {number.value};
  attrs.value = CFDictionaryCreate(nullptr, keys, values, 1,
                                   &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
  require(attrs.value, "identity_memory");
  SecCodeRef code = nullptr;
  require(!SecCodeCopyGuestWithAttributes(
              nullptr, static_cast<CFDictionaryRef>(attrs.value),
              kSecCSDefaultFlags, &code),
          "child_identity");
  guest.value = code;
  require(
      !SecCodeCheckValidity(code,
                            static_cast<SecCSFlags>(kSecCSStrictValidate) |
                                static_cast<SecCSFlags>(kSecCSNoNetworkAccess),
                            nullptr),
      "child_signature");
  CFDictionaryRef dictionary = nullptr;
  require(!SecCodeCopySigningInformation(code, kSecCSSigningInformation,
                                         &dictionary),
          "child_identity");
  info.value = dictionary;
  auto data = static_cast<CFDataRef>(
      CFDictionaryGetValue(dictionary, kSecCodeInfoUnique));
  require(data && CFGetTypeID(data) == CFDataGetTypeID(), "child_cdhash");
  std::string actual;
  for (CFIndex i = 0; i < CFDataGetLength(data); ++i) {
    auto c = CFDataGetBytePtr(data)[i];
    actual += "0123456789abcdef"[c >> 4];
    actual += "0123456789abcdef"[c & 15];
  }
  require(actual == expected, "child_cdhash");
#else
  (void)pid;
  (void)expected;
#endif
}
Fd duplicate(int fd, bool output, bool pipe_allowed) {
  int flags = fcntl(fd, F_GETFL);
  struct stat st{};
  require(fd >= 0 && flags >= 0 && !fstat(fd, &st) && st.st_uid == geteuid(),
          "media_descriptor");
  bool pipe = pipe_allowed && S_ISFIFO(st.st_mode);
  require((S_ISREG(st.st_mode) && st.st_nlink == 1 &&
           (st.st_mode & 0777) == 0600) ||
              (pipe && ((st.st_mode & 0777) == 0600 || st.st_nlink == 0)),
          "media_private");
  if (output)
    require(S_ISREG(st.st_mode) && st.st_size == 0 &&
                (flags & O_ACCMODE) == O_RDWR && !(flags & O_APPEND) &&
                lseek(fd, 0, SEEK_CUR) == 0,
            "media_output");
  else
    require((flags & O_ACCMODE) == O_RDONLY &&
                (pipe || lseek(fd, 0, SEEK_CUR) == 0),
            "media_input");
  return Fd(fcntl(fd, F_DUPFD_CLOEXEC, 10));
}
Fd duplicate_pager(int fd) {
  int type = 0;
  socklen_t length = sizeof(type);
  sockaddr_un name{};
  socklen_t name_length = sizeof(name);
  struct stat st{};
  require(
      fd >= 0 && !fstat(fd, &st) && S_ISSOCK(st.st_mode) &&
          st.st_uid == geteuid() &&
          !getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) &&
          type == SOCK_DGRAM &&
          !getsockname(fd, reinterpret_cast<sockaddr *>(&name), &name_length) &&
          name.sun_family == AF_UNIX &&
          name_length >= offsetof(sockaddr_un, sun_path) &&
          name_length <= sizeof(name),
      "media_pager");
#ifdef __APPLE__
  // Darwin returns a zero-padded16-byte unnamed sockaddr, unlike Linux's2.
  auto *bytes = reinterpret_cast<const unsigned char *>(&name);
  for (size_t i = offsetof(sockaddr_un, sun_path); i < name_length; ++i)
    require(!bytes[i], "media_pager_named");
#else
  require(name_length == offsetof(sockaddr_un, sun_path), "media_pager_named");
#endif
  return Fd(fcntl(fd, F_DUPFD_CLOEXEC, 10));
}
bool alias(int a, int b) {
  struct stat x{}, y{};
  require(!fstat(a, &x) && !fstat(b, &y), "media_stat");
  return x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}
struct State {
  pid_t pid = -1;
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
  bool resumed = false, transferred = false, fence_invalid = false;
  MediaExecutable pin;
  MediaRequest request;
  std::string nonce;
  MediaFence fence{};
  size_t fence_bytes = 0;
#endif
  std::atomic<bool> identity_done{true}, identity_valid{false};
  std::promise<void> exit_promise;
  bool exit_notified = false;
  State *retained_next = nullptr;
  std::shared_ptr<State> retained_self;
  bool ownership_lost = false;
  Fd input, second, output, code, read_out, read_error, owner_lock, control;
  std::shared_ptr<void> keep_alive;
};
void signal_group(const std::shared_ptr<State> &s, int signal) {
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
  if (s->resumed) {
    // PID may already have been reaped by the host and reused. The private
    // control socket is the only post-resume cancellation authority.
    char command = 'C';
    if (s->control.value >= 0)
      (void)send(s->control.value, &command, 1, MSG_NOSIGNAL);
    return;
  }
#endif
  if (s->pid > 0 && !s->ownership_lost)
    (void)kill(-s->pid, signal);
}
[[maybe_unused]] bool observed_exit(const std::shared_ptr<State> &s) {
  siginfo_t info{};
  int n;
  do {
    n = waitid(P_PID, s->pid, &info, WEXITED | WNOHANG | WNOWAIT);
  } while (n < 0 && errno == EINTR);
  if (n < 0) {
    if (errno == ECHILD)
      s->ownership_lost = true;
    return false;
  }
  return info.si_pid == s->pid;
}
bool drain(Fd &fd, std::string &text, size_t maximum, bool &overflow) {
  std::array<char, 4096> b{};
  size_t budget = 65536;
  while (budget > 0) {
    ssize_t n = read(fd.value, b.data(), b.size());
    if (n == 0) {
      fd = Fd();
      return true;
    }
    if (n < 0) {
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN)
        return false;
      fd = Fd();
      return true;
    }
    budget -= static_cast<size_t>(n);
    size_t keep = std::min(static_cast<size_t>(n), maximum - text.size());
    text.append(b.data(), keep);
    if (keep != static_cast<size_t>(n))
      overflow = true;
  }
  return false;
}
[[maybe_unused]] void reap(const std::shared_ptr<State> &s,
                           MediaProcessResult &r) {
  int status = 0;
  pid_t got;
  do {
    got = waitpid(s->pid, &status, WNOHANG);
  } while (got < 0 && errno == EINTR);
  if (got == s->pid) {
    r.child_exit_confirmed = true;
    r.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    r.signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    s->pid = -1;
    s->exit_promise.set_value();
    s->exit_notified = true;
  }
}
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
bool finish_no_transfer(const std::shared_ptr<State> &s,
                        MediaProcessResult &result) {
  if (s->transferred || !s->identity_done.load())
    return false;
  s->control = Fd(); // no later capability transfer can occur
  int status = 0;
  pid_t got = waitpid(s->pid, &status, WNOHANG);
  if (got == 0 || (got < 0 && errno != ECHILD))
    return false;
  if (got == s->pid) {
    result.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    result.signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
  }
  // This is a no-media-delivery proof, never an ECHILD proof of leaf exit.
  result.child_exit_confirmed = true;
  s->pid = -1;
  s->exit_promise.set_value();
  s->exit_notified = true;
  return true;
}
bool observe_fence(const std::shared_ptr<State> &s,
                   MediaProcessResult &result) {
  if (!s->transferred || s->fence_invalid)
    return false;
  while (s->fence_bytes < s->fence.size()) {
    ssize_t n = recv(s->control.value, s->fence.data() + s->fence_bytes,
                     s->fence.size() - s->fence_bytes, 0);
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
      return false;
    if (n <= 0) {
      s->fence_invalid = true;
      return false;
    }
    s->fence_bytes += static_cast<size_t>(n);
  }
  MediaProcessResult terminal;
  if (!media_read_fence(s->fence, s->pin, s->request, s->nonce, terminal)) {
    s->fence_invalid = true;
    return false;
  }
  // Receipt is authenticated to this launch and only issued after leaf waitpid
  // and closure of the supervisor's own media/lock copies. Pipe EOF merely
  // finishes bounded output collection; host waitpid is not the exit fence.
  if (s->read_out.value >= 0 || s->read_error.value >= 0)
    return false;
  result.status = terminal.status;
  result.reason = terminal.reason;
  result.child_pid = terminal.child_pid;
  result.exit_code = terminal.exit_code;
  result.signal = terminal.signal;
  result.child_exit_confirmed = true;
  int ignored;
  (void)waitpid(s->pid, &ignored, WNOHANG); // optional zombie collection only
  s->pid = -1;
  s->exit_promise.set_value();
  s->exit_notified = true;
  return true;
}
#endif
struct RetainedStates {
  std::mutex mutex;
  State *head = nullptr;
};
RetainedStates &retained_states() {
  // Initialized before any launch, never allocated on failed shutdown paths.
  static auto *value = new RetainedStates;
  return *value;
}
void release_retained(State *state) {
  auto &registry = retained_states();
  std::lock_guard guard(registry.mutex);
  State **cursor = &registry.head;
  while (*cursor && *cursor != state)
    cursor = &(*cursor)->retained_next;
  if (*cursor == state)
    *cursor = state->retained_next;
  state->retained_self.reset();
}
void retain_until_exit(std::shared_ptr<State> state) {
  auto &registry = retained_states();
  {
    std::lock_guard guard(registry.mutex);
    state->retained_self = state;
    state->retained_next = registry.head;
    registry.head = state.get();
  }
  try {
    std::thread([state] {
      std::string discard_out, discard_error;
      while (state->pid > 0 && !state->ownership_lost) {
        bool overflow = false;
        if (state->read_out.value >= 0)
          drain(state->read_out, discard_out, stdout_max, overflow);
        if (state->read_error.value >= 0)
          drain(state->read_error, discard_error, stderr_max, overflow);
        signal_group(state, SIGKILL);
        MediaProcessResult result;
#ifdef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
        bool confirmed = state->identity_done.load() && observed_exit(state) &&
                         state->read_out.value < 0 &&
                         state->read_error.value < 0;
        if (confirmed)
          reap(state, result);
#else
        bool confirmed = state->transferred ? observe_fence(state, result)
                                            : finish_no_transfer(state, result);
#endif
        if (confirmed) {
          if (result.child_exit_confirmed) {
            release_retained(state.get());
            return;
          }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
      }
      // Lost wait ownership is not a termination fence. The intrusive registry
      // deliberately retains that owner until process exit.
    }).detach();
  } catch (...) {
    // Thread creation failure leaves the preallocated intrusive retention in
    // place. Never release media merely because cleanup could not be scheduled.
  }
}
void begin_verification(const std::shared_ptr<State> &state,
                        const std::string &cdhash) {
#ifdef __APPLE__
  state->identity_done = false;
  try {
    std::thread([state, cdhash] {
      try {
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
        auto hook = media_process_before_verify_for_test;
        if (hook)
          hook();
#endif
        verify_guest(state->pid, cdhash);
        state->identity_valid = true;
      } catch (...) {
      }
      state->identity_done = true;
    }).detach();
  } catch (...) {
    state->identity_done = true;
    throw;
  }
#else
  (void)cdhash;
  state->identity_valid = true;
#endif
}

std::vector<std::string> arguments(const MediaExecutable &pin,
                                   const MediaRequest &r,
                                   const MediaProcessLimits &limits,
                                   const std::string &nonce) {
  std::vector<std::string> a{"foresight-media-worker"};
#ifdef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
  a.insert(a.end(), {"--owned-bootstrap", std::to_string(getpid())});
  (void)limits;
  (void)nonce;
#else
  a.insert(a.end(), {"--owned-supervisor", std::to_string(getpid()), pin.path,
                     pin.sha256, pin.build_id, pin.macos_cdhash,
                     std::to_string(limits.total.count()),
                     std::to_string(limits.idle.count()),
                     std::to_string(limits.terminate_grace.count()),
                     std::to_string(limits.kill_grace.count()), nonce});
#endif
  a.insert(a.end(), {operation(r.operation), r.session, r.job,
                     std::to_string(r.epoch), "3"});
  if (r.operation == MediaOperation::mix_export_mp3) {
    a.insert(a.end(), {"4", "5", r.input_sha256, r.second_input_sha256,
                       std::to_string(r.source_frames)});
  } else if (media_is_assembly(r.operation)) {
    a.insert(a.end(),
             {"4", "5", r.input_sha256, std::to_string(r.source_frames)});
    if (r.operation == MediaOperation::assemble_pcm_v1)
      a.insert(a.end(),
               {std::to_string(r.start_frame), std::to_string(r.frame_count)});
  } else {
    a.insert(a.end(), {"4", r.input_sha256, std::to_string(r.source_frames)});
    if (r.operation == MediaOperation::decode_pcm)
      a.insert(a.end(),
               {std::to_string(r.start_frame), std::to_string(r.frame_count)});
  }
  (void)pin;
  return a;
}
void launch(const std::shared_ptr<State> &s, const MediaExecutable &pin,
            const MediaRequest &r, bool background,
            const MediaProcessLimits &limits, const std::string &nonce) {
  std::lock_guard guard(launch_mutex_for_process());
  (void)background;
  struct sigaction child_signal{};
  require(!sigaction(SIGCHLD, nullptr, &child_signal) &&
              child_signal.sa_handler != SIG_IGN &&
              !(child_signal.sa_flags & SA_NOCLDWAIT),
          "unsupported_child_reaping");
  int sockets[2];
#ifdef __APPLE__
  require(!socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), "bootstrap_socket");
#else
  require(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets),
          "bootstrap_socket");
#endif
  Fd original_parent(sockets[0]), original_child(sockets[1]);
  require(!fcntl(original_parent.value, F_SETFD, FD_CLOEXEC) &&
              !fcntl(original_child.value, F_SETFD, FD_CLOEXEC),
          "bootstrap_cloexec");
  Fd parent_control(fcntl(original_parent.value, F_DUPFD_CLOEXEC, 10)),
      child_control(fcntl(original_child.value, F_DUPFD_CLOEXEC, 10));
  require(!fcntl(parent_control.value, F_SETFL,
                 fcntl(parent_control.value, F_GETFL) | O_NONBLOCK),
          "bootstrap_nonblocking");
  int out[2], err[2];
  require(!cloexec_pipe(out), "stdout_pipe");
  Fd original_ro(out[0]), original_wo(out[1]);
  Fd ro(fcntl(original_ro.value, F_DUPFD_CLOEXEC, 10)),
      wo(fcntl(original_wo.value, F_DUPFD_CLOEXEC, 10));
  require(!cloexec_pipe(err), "stderr_pipe");
  Fd original_re(err[0]), original_we(err[1]);
  Fd re(fcntl(original_re.value, F_DUPFD_CLOEXEC, 10)),
      we(fcntl(original_we.value, F_DUPFD_CLOEXEC, 10));
  require(!fcntl(ro.value, F_SETFL, fcntl(ro.value, F_GETFL) | O_NONBLOCK) &&
              !fcntl(re.value, F_SETFL, fcntl(re.value, F_GETFL) | O_NONBLOCK),
          "pipe_nonblocking");
  posix_spawn_file_actions_t actions;
  require(!posix_spawn_file_actions_init(&actions), "spawn_actions");
  struct Actions {
    posix_spawn_file_actions_t *p;
    ~Actions() {
      posix_spawn_file_actions_destroy(p);
    }
  } ag{&actions};
  posix_spawnattr_t attr;
  require(!posix_spawnattr_init(&attr), "spawn_attributes");
  struct Attr {
    posix_spawnattr_t *p;
    ~Attr() {
      posix_spawnattr_destroy(p);
    }
  } at{&attr};
  require(
      !posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY,
                                        0) &&
          !posix_spawn_file_actions_adddup2(&actions, wo.value, 1) &&
          !posix_spawn_file_actions_adddup2(&actions, we.value, 2) &&
          !posix_spawn_file_actions_adddup2(&actions, child_control.value, 3),
      "spawn_descriptors");
  short flags =
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
  sigset_t mask, defaults;
  sigemptyset(&mask);
  sigemptyset(&defaults);
  for (int signal : {SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE})
    sigaddset(&defaults, signal);
  require(!posix_spawnattr_setsigmask(&attr, &mask) &&
              !posix_spawnattr_setsigdefault(&attr, &defaults) &&
              !posix_spawnattr_setpgroup(&attr, 0),
          "spawn_signals");
#ifdef __APPLE__
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED;
  std::string executable = pin.path;
#else
  require(!posix_spawn_file_actions_adddup2(&actions, s->code.value, 6) &&
              !posix_spawn_file_actions_addclose(&actions, 4) &&
              !posix_spawn_file_actions_addclose(&actions, 5) &&
              !posix_spawn_file_actions_addclose(&actions, 7) &&
              !posix_spawn_file_actions_addclosefrom_np(&actions, 8),
          "spawn_closefrom");
  // glibc's POSIX spawn policy API rejects Linux-only SCHED_BATCH. The
  // trusted supervisor self-nices compression before spawning its leaf;
  // the leaf inherits that priority without an unsupported spawn policy.
  std::string executable = "/proc/self/fd/6";
#endif
  require(!posix_spawnattr_setflags(&attr, flags), "spawn_flags");
  auto strings = arguments(pin, r, limits, nonce);
  std::vector<char *> argv;
  for (auto &str : strings)
    argv.push_back(str.data());
  argv.push_back(nullptr);
  char lang[] = "LANG=C", locale[] = "LC_ALL=C", zone[] = "TZ=UTC";
  char *env[] = {lang, locale, zone, nullptr};
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
  if (media_process_before_spawn_for_test)
    media_process_before_spawn_for_test();
#endif
  pid_t child = -1;
  require(!posix_spawn(&child, executable.c_str(), &actions, &attr, argv.data(),
                       env),
          "spawn_failed");
  s->pid = child;
#if !defined(__APPLE__) && !defined(FORESIGHT_MEDIA_PROCESS_SUPERVISOR)
  // Linux starts immediately: host reaping can already consume this PID.
  // Only the pre-media private socket remains a safe cancellation authority.
  s->resumed = true;
#endif
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
  if (media_process_after_spawn_for_test)
    media_process_after_spawn_for_test(child);
#endif
  s->control = std::move(parent_control);
  s->read_out = std::move(ro);
  s->read_error = std::move(re);
#ifdef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
  if (background) {
    if (setpriority(PRIO_PROCESS, child, 10) < 0 && errno != ESRCH)
      throw std::runtime_error("child_priority");
  }
#endif
}
void transfer_capabilities(const std::shared_ptr<State> &s, bool mix,
                           Clock::time_point deadline,
                           const std::atomic<bool> &cancel) {
  unsigned char ready = 0;
  for (;;) {
    check_deadline(deadline, cancel);
    ssize_t got = recv(s->control.value, &ready, 1, 0);
    if (got == 1)
      break;
    if (got < 0 && (errno == EAGAIN || errno == EINTR)) {
      pollfd observed{s->control.value, POLLIN, 0};
      (void)poll(&observed, 1, 10);
      continue;
    }
    throw std::runtime_error("bootstrap_not_ready");
  }
  require(ready == 'R', "bootstrap_not_ready");
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
  if (media_process_before_transfer_for_test)
    media_process_before_transfer_for_test();
#endif
  int descriptors[4]{s->input.value, mix ? s->second.value : s->output.value,
                     mix ? s->output.value : s->owner_lock.value,
                     s->owner_lock.value};
  size_t count = mix ? 3 : 2;
  if (s->owner_lock.value >= 0)
    ++count;
  unsigned char flags =
      0x40 | (mix ? 1 : 0) | (s->owner_lock.value >= 0 ? 4 : 0);
  iovec data{&flags, 1};
  alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(4 * sizeof(int))]{};
  msghdr message{};
  message.msg_iov = &data;
  message.msg_iovlen = 1;
  message.msg_control = ancillary;
  message.msg_controllen = CMSG_SPACE(count * sizeof(int));
  auto *control = CMSG_FIRSTHDR(&message);
  control->cmsg_level = SOL_SOCKET;
  control->cmsg_type = SCM_RIGHTS;
  control->cmsg_len = CMSG_LEN(count * sizeof(int));
  std::memcpy(CMSG_DATA(control), descriptors, count * sizeof(int));
  for (;;) {
    check_deadline(deadline, cancel);
    auto got = sendmsg(s->control.value, &message, MSG_NOSIGNAL);
    if (got == 1)
      break;
    if (got < 0 && (errno == EAGAIN || errno == EINTR)) {
      pollfd observed{s->control.value, POLLOUT, 0};
      (void)poll(&observed, 1, 10);
      continue;
    }
    throw std::runtime_error("bootstrap_transfer");
  }
#ifdef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
  s->control = Fd();
#else
  s->transferred = true;
#endif
}
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
void validate_result(const MediaExecutable &pin, const MediaRequest &r,
                     const std::shared_ptr<State> &s,
                     MediaProcessResult &result, Clock::time_point deadline,
                     const std::atomic<bool> &cancel) {
  std::set<std::string> keys;
  auto callback = [&](int depth, nlohmann::json::parse_event_t event,
                      nlohmann::json &value) {
    require(depth <= 2, "result_depth");
    if (event == nlohmann::json::parse_event_t::key)
      require(keys.insert(value.get<std::string>()).second,
              "result_duplicate_key");
    return true;
  };
  auto json = nlohmann::json::parse(result.result_json, callback);
  require(json.is_object() && json.size() == 15, "result_shape");
  auto uint = [&](const char *key) -> uint64_t {
    require(json.at(key).is_number_unsigned(), "result_integer");
    return json.at(key).get<uint64_t>();
  };
  auto text = [&](const char *key) -> std::string {
    require(json.at(key).is_string(), "result_string");
    return json.at(key).get<std::string>();
  };
  require(uint("protocol") == 1 && text("build_id") == pin.build_id &&
              text("session") == r.session && text("job") == r.job &&
              uint("epoch") == r.epoch &&
              text("operation") == operation(r.operation) &&
              text("input_sha256") == r.input_sha256 &&
              text("second_input_sha256") == r.second_input_sha256,
          "result_identity");
  bool decode = media_is_pcm(r.operation);
  require(uint("source_frames") == r.source_frames &&
              uint("frames") == (decode ? r.frame_count : r.source_frames) &&
              uint("range_start") == r.start_frame,
          "result_timeline");
  uint64_t bytes = uint("output_bytes");
  uint64_t maximum = (r.operation == MediaOperation::mix_export_mp3 ||
                      (media_is_assembly(r.operation) && !decode))
                         ? r.source_frames / 6 + 1048576
                         : (decode ? r.frame_count * 2 : 131072);
  struct stat st{};
  require((!decode || bytes == r.frame_count * 2) && bytes <= maximum &&
              !fstat(s->output.value, &st) && st.st_size >= 0 &&
              static_cast<uint64_t>(st.st_size) == bytes,
          "result_output_length");
  if (r.operation == MediaOperation::encode_opus ||
      r.operation == MediaOperation::encode_recording_wav_v1 ||
      r.operation == MediaOperation::assemble_opus_v1)
    require(uint("pre_skip") <= 65535 &&
                uint("final_granule") == r.source_frames + uint("pre_skip"),
            "result_granule");
  else
    require(uint("pre_skip") == 0 && uint("final_granule") == 0,
            "result_granule");
  auto expected = text("output_sha256");
  require(hex(expected, 64), "result_output_digest");
  Hash hash;
  std::array<unsigned char, 8192> b{};
  uint64_t offset = 0;
  while (offset < bytes) {
    check_deadline(deadline, cancel);
    ssize_t n = pread(s->output.value, b.data(),
                      std::min<uint64_t>(b.size(), bytes - offset), offset);
    if (n < 0 && errno == EINTR)
      continue;
    require(n > 0, "result_output_read");
    hash.add(b.data(), n);
    offset += n;
  }
  require(hash.finish() == expected, "result_output_digest");
}
#endif
} // namespace

MediaProcessResult run_media_process(const MediaExecutable &pin,
                                     const MediaRequest &r,
                                     const MediaCapabilities &caps,
                                     const MediaProcessLimits &limits,
                                     const std::atomic<bool> &cancel) {
  MediaProcessResult result;
  (void)retained_states();
  auto state = std::make_shared<State>();
  result.closed = state->exit_promise.get_future().share();
  state->keep_alive = caps.keep_alive;
  auto start = Clock::now(), deadline = start + limits.total,
       last_progress = start;
  uint64_t progress = limits.progress ? limits.progress->load() : 0;
  bool stopping = false, killed = false;
  auto stop_deadline = deadline;
  auto stop = [&](MediaProcessStatus status, const char *reason,
                  bool immediate) {
    if (stopping)
      return;
    result.status = status;
    result.reason = reason;
    stopping = true;
    killed = immediate;
    signal_group(state, immediate ? SIGKILL : SIGTERM);
    stop_deadline =
        Clock::now() + (immediate ? limits.kill_grace : limits.terminate_grace);
  };
  try {
    require(limits.total >= std::chrono::milliseconds(10) &&
                limits.total <= std::chrono::hours(24) &&
                limits.idle >= std::chrono::milliseconds(10) &&
                limits.idle <= limits.total &&
                limits.terminate_grace >= std::chrono::milliseconds(1) &&
                limits.terminate_grace <= std::chrono::seconds(5) &&
                limits.kill_grace >= std::chrono::milliseconds(1) &&
                limits.kill_grace <= std::chrono::seconds(5),
            "invalid_limits");
    bool mix = r.operation == MediaOperation::mix_export_mp3;
    bool assembly = media_is_assembly(r.operation), multi = mix || assembly;
    require(uuid(r.session) && uuid(r.job) && hex(r.input_sha256, 64) &&
                r.source_frames > 0 &&
                r.source_frames <= (multi ? 48000ULL * 24 * 3600 : 240000) &&
                r.epoch <= INT64_MAX && caps.keep_alive,
            "invalid_request");
    require(mix ? hex(r.second_input_sha256, 64)
                : r.second_input_sha256.empty(),
            "invalid_second_source");
    require(media_is_pcm(r.operation)
                ? (r.frame_count > 0 && r.frame_count <= 240000 &&
                   r.start_frame <= r.source_frames &&
                   r.frame_count <= r.source_frames - r.start_frame)
                : (r.frame_count == 0 && r.start_frame == 0),
            "invalid_range");
    {
      Fd code = pin_executable(pin, deadline, cancel);
      state->code = Fd(fcntl(code.value, F_DUPFD_CLOEXEC, 10));
    }
    if (caps.owner_lock >= 0) {
      struct stat st{};
      require(!fstat(caps.owner_lock, &st) && S_ISREG(st.st_mode) &&
                  st.st_uid == geteuid() && (st.st_mode & 0777) == 0600 &&
                  st.st_nlink == 1 &&
                  (fcntl(caps.owner_lock, F_GETFL) & O_ACCMODE) == O_RDWR,
              "owner_lock_metadata");
      state->owner_lock = Fd(fcntl(caps.owner_lock, F_DUPFD_CLOEXEC, 10));
    }
    state->input = duplicate(caps.input, false, mix);
    state->output = duplicate(caps.output, true, false);
    require(!alias(state->input.value, state->output.value), "aliased_media");
    if (state->owner_lock.value >= 0)
      require(!alias(state->owner_lock.value, state->input.value) &&
                  !alias(state->owner_lock.value, state->output.value),
              "aliased_owner_lock");
    if (multi) {
      state->second = assembly ? duplicate_pager(caps.second_input)
                               : duplicate(caps.second_input, false, true);
      if (state->owner_lock.value >= 0)
        require(!alias(state->owner_lock.value, state->second.value),
                "aliased_owner_lock");
      require(!alias(state->input.value, state->second.value) &&
                  !alias(state->second.value, state->output.value),
              "aliased_media");
    }
    check_deadline(deadline, cancel);
    std::string nonce;
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
    unsigned char random[16];
    require(!getentropy(random, sizeof(random)), "launch_entropy");
    constexpr char digits[] = "0123456789abcdef";
    for (auto b : random) {
      nonce += digits[b >> 4];
      nonce += digits[b & 15];
    }
    state->pin = pin;
    state->request = r;
    state->nonce = nonce;
#endif
    launch(state, pin, r, limits.background && !media_is_pcm(r.operation),
           limits, nonce);
    result.child_pid = state->pid;
    bool verified = false;
    try {
      begin_verification(state, pin.macos_cdhash);
      while (!state->identity_done.load()) {
        check_deadline(deadline, cancel);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      require(state->identity_valid.load(), "child_identity");
      verified = true;
      check_deadline(deadline, cancel);
#ifdef __APPLE__
      require(!kill(state->pid, SIGCONT), "child_resume");
#endif
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
      state->resumed = true;
#endif
      transfer_capabilities(state, multi, deadline, cancel);
      last_progress = Clock::now();
    } catch (...) {
      if (cancel.load())
        stop(MediaProcessStatus::cancelled, "cancelled", true);
      else if (Clock::now() >= deadline)
        stop(MediaProcessStatus::deadline, "deadline", true);
      else if (verified)
        stop(MediaProcessStatus::protocol_failed, "child_bootstrap", true);
      else
        stop(MediaProcessStatus::identity_mismatch, "child_identity", true);
    }
    while (state->pid > 0) {
      bool overflow = false;
      if (state->read_out.value >= 0)
        drain(state->read_out, result.result_json, stdout_max, overflow);
      if (state->read_error.value >= 0)
        drain(state->read_error, result.stderr_text, stderr_max, overflow);
      if (overflow)
        stop(MediaProcessStatus::output_limit, "child_output_limit", false);
#ifdef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
      bool exited = observed_exit(state);
      if (state->ownership_lost) {
        result.status = MediaProcessStatus::termination_unconfirmed;
        result.reason = "child_ownership_lost";
        break;
      }
      if (exited && state->identity_done.load() && state->read_out.value < 0 &&
          state->read_error.value < 0) {
        reap(state, result);
        if (result.child_exit_confirmed)
          break;
      }
#else
      bool exited = false;
      MediaProcessResult terminal;
      if (observe_fence(state, terminal)) {
        if (!stopping) {
          result.status = terminal.status;
          result.reason = terminal.reason;
        }
        result.child_pid = terminal.child_pid;
        result.exit_code = terminal.exit_code;
        result.signal = terminal.signal;
        result.child_exit_confirmed = true;
        break;
      }
      // No media was delivered, so closing this socket prevents a future
      // transfer. A suspended orphan has no media or inherited owner lock.
      if (stopping && finish_no_transfer(state, result))
        break;
#endif
      auto now = Clock::now();
      if (!stopping) {
        uint64_t value = limits.progress ? limits.progress->load() : 0;
        if (value != progress) {
          progress = value;
          last_progress = now;
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
          char command = 'P';
          (void)send(state->control.value, &command, 1, MSG_NOSIGNAL);
#endif
        }
        if (cancel.load())
          stop(MediaProcessStatus::cancelled, "cancelled", false);
        else if (now >= deadline)
          stop(MediaProcessStatus::deadline, "deadline", false);
        else if (now - last_progress >= limits.idle)
          stop(MediaProcessStatus::idle_timeout, "idle_timeout", false);
        else if (exited)
          stop(MediaProcessStatus::worker_failed, "descendant_output", true);
      } else if (now >= stop_deadline) {
        if (!killed) {
          killed = true;
          signal_group(state, SIGKILL);
          stop_deadline = now + limits.kill_grace;
        } else {
          result.status = MediaProcessStatus::termination_unconfirmed;
          result.reason = "child_exit_unconfirmed";
          break;
        }
      }
      pollfd fds[2]{{state->read_out.value, POLLIN, 0},
                    {state->read_error.value, POLLIN, 0}};
      (void)poll(fds, 2, 10);
    }
    if (result.child_exit_confirmed && !stopping) {
      if ((result.exit_code || result.signal)
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
          && result.status == MediaProcessStatus::success
#endif
      ) {
        result.status = MediaProcessStatus::worker_failed;
        result.reason = "worker_failed";
      } else {
        try {
#ifndef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
          if (result.status == MediaProcessStatus::success)
            validate_result(pin, r, state, result, deadline, cancel);
#else
          result.status = MediaProcessStatus::success;
#endif
          if (result.status == MediaProcessStatus::success)
            result.reason.clear();
        } catch (...) {
          result.status = MediaProcessStatus::protocol_failed;
          result.reason = "result_validation";
        }
      }
    }
  } catch (const std::exception &e) {
    result.reason = e.what();
    result.status = result.reason == "cancelled" ? MediaProcessStatus::cancelled
                    : result.reason == "deadline"
                        ? MediaProcessStatus::deadline
                        : MediaProcessStatus::launch_failed;
    if (state->pid > 0) {
      signal_group(state, SIGKILL);
      auto end = Clock::now() + limits.kill_grace;
      while (Clock::now() < end) {
        bool overflow = false;
        if (state->read_out.value >= 0)
          drain(state->read_out, result.result_json, stdout_max, overflow);
        if (state->read_error.value >= 0)
          drain(state->read_error, result.stderr_text, stderr_max, overflow);
#ifdef FORESIGHT_MEDIA_PROCESS_SUPERVISOR
        if (state->identity_done.load() && observed_exit(state) &&
            state->read_out.value < 0 && state->read_error.value < 0) {
          reap(state, result);
          if (result.child_exit_confirmed)
            break;
        }
#else
        if (observe_fence(state, result))
          break;
        if (finish_no_transfer(state, result))
          break;
#endif
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      if (!result.child_exit_confirmed)
        result.status = MediaProcessStatus::termination_unconfirmed;
    }
  }
  if (state->pid > 0)
    retain_until_exit(state);
  else if (!state->exit_notified)
    state->exit_promise.set_value();
  return result;
}
} // namespace foresight
