#include "media_process.h"
#include "diagnostic_sha256.h"
#include "foresight_native.h"
#include "media_bootstrap.h"
#include "media_supervisor.h"
#include "media_supervisor_protocol.h"
#include "portable_process.h"
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <poll.h>
#include <signal.h>
#include <sys/file.h>
#ifndef __APPLE__
#include <sys/syscall.h>
#endif
#include <string>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#ifdef __APPLE__
#include <Security/Security.h>
#endif

namespace {
using namespace foresight;
using namespace std::chrono_literals;
std::string hash(int fd) {
  fs_diagnostic_sha256_context c{};
  fs_diagnostic_sha256_init(&c);
  std::array<unsigned char, 8192> b{};
  off_t at = 0;
  while (true) {
    auto n = pread(fd, b.data(), b.size(), at);
    if (n < 0)
      throw std::runtime_error("test_hash");
    if (!n)
      break;
    fs_diagnostic_sha256_update(&c, b.data(), n);
    at += n;
  }
  unsigned char d[32];
  fs_diagnostic_sha256_final(&c, d);
  std::string s;
  for (auto ch : d) {
    s += "0123456789abcdef"[ch >> 4];
    s += "0123456789abcdef"[ch & 15];
  }
  return s;
}
} // namespace

#if defined(FORESIGHT_MEDIA_OWNED_DRIVER)
namespace {
std::atomic<unsigned> host_reaper_total{0};
static_assert(std::atomic<unsigned>::is_always_lock_free);
void host_reaper_signal(int) {
  int saved = errno, status;
  while (waitpid(-1, &status, WNOHANG) > 0)
    host_reaper_total.fetch_add(1, std::memory_order_relaxed);
  errno = saved;
}
} // namespace
#endif

#if defined(FORESIGHT_MEDIA_PROCESS_FIXTURE)
// A constructor sentinel on stderr is observable BEFORE fixture main and does
// not need a media capability. A wrong macOS CDHash must never run this code.
__attribute__((constructor)) static void entered() {
  char value = '0' + FORESIGHT_MEDIA_PROCESS_FIXTURE;
  write(2, &value, 1);
}

int main(int argc, char **argv) {
  int supervised = foresight::media_supervisor_main(
      argc, argv, std::string(64, '1').c_str());
  if (supervised >= 0)
    return supervised;
  if (argc >= 4 && std::string(argv[1]) == "--owned-bootstrap") {
    foresight::media_receive_capabilities(
        static_cast<pid_t>(std::stol(argv[2])),
        std::string(argv[3]) == "mix-export-mp3");
    argc -= 2;
    argv += 2;
  }
  if (argc < 9)
    return 60;
  if (getenv("FORESIGHT_MEDIA_PARENT_SECRET") || getenv("LD_LIBRARY_PATH") ||
      getenv("DYLD_LIBRARY_PATH"))
    return 61;
  for (int fd =
#ifdef __APPLE__
           9;
#else
           8;
#endif
       fd < 256; ++fd)
    if (fcntl(fd, F_GETFD) >= 0)
      return 62;
  if (fcntl(200, F_GETFD) >= 0)
    return 63;
  char byte;
  if (read(0, &byte, 1) != 0)
    return 64;
  if (std::string(argv[1]) != "decode-pcm" && getpriority(PRIO_PROCESS, 0) < 10)
    return 66;
  std::string mode = argv[7];
  if (mode == std::string(64, 'a') || mode == std::string(64, 'e')) {
    if (mode == std::string(64, 'a'))
      signal(SIGTERM, SIG_IGN);
    char path[4096]{};
#ifdef __APPLE__
    if (fcntl(3, F_GETPATH, path) < 0)
      return 68;
#else
    ssize_t size = readlink("/proc/self/fd/3", path, sizeof(path) - 1);
    if (size < 0)
      return 68;
    path[size] = 0;
#endif
    const auto published = std::string(path) + ".ready";
    const auto staging = published + ".partial";
    int ready =
        open(staging.c_str(),
             O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (ready < 0)
      return 69;
    auto identity = std::to_string(getpid());
    ssize_t written;
    do {
      written = write(ready, identity.data(), identity.size());
    } while (written < 0 && errno == EINTR);
    bool closed = close(ready) == 0;
    if (written != static_cast<ssize_t>(identity.size()) || !closed ||
        rename(staging.c_str(), published.c_str()) != 0) {
      unlink(staging.c_str()); // Only the staging file created above is ours.
      return 69;
    }
    while (true)
      pause();
  }
  if (mode == std::string(64, 'b')) {
    std::array<char, 4096> spam{};
    while (true) {
      write(1, spam.data(), spam.size());
      write(2, spam.data(), spam.size());
    }
  }
  if (mode == std::string(64, 'c')) {
    write(1, "{\"broken\":true}\n", 16);
    return 0;
  }
  if (mode == std::string(64, 'f'))
    std::this_thread::sleep_for(600ms);
  std::string op = argv[1];
  bool decode = op == "decode-pcm";
  bool mix = op == "mix-export-mp3";
  int output = mix ? 5 : 4;
  uint64_t frames = std::stoull(argv[mix ? 10 : 8]);
  uint64_t count = decode ? std::stoull(argv[10]) : frames;
  std::string payload =
      decode ? std::string(count * 2, 'A')
             : (FORESIGHT_MEDIA_PROCESS_FIXTURE == 1 ? "one" : "two");
  if (write(output, payload.data(), payload.size()) !=
      static_cast<ssize_t>(payload.size()))
    return 65;
  nlohmann::json value{
      {"protocol", 1U},
      {"build_id", std::string(64, mode == std::string(64, 'd') ? '0' : '1')},
      {"session", argv[2]},
      {"job", argv[3]},
      {"epoch", std::stoull(argv[4])},
      {"operation", op},
      {"input_sha256", argv[mix ? 8 : 7]},
      {"second_input_sha256", mix ? argv[9] : ""},
      {"output_sha256", hash(output)},
      {"output_bytes", payload.size()},
      {"source_frames", frames},
      {"frames", count},
      {"range_start", decode ? std::stoull(argv[9]) : 0ULL},
      {"pre_skip", decode || mix ? 0U : 312U},
      {"final_granule", decode || mix ? 0ULL : frames + 312}};
  std::cout << value.dump() << '\n';
  return 0;
}
#else
namespace {
void expect(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
std::string cdhash(const std::filesystem::path &p) {
#ifdef __APPLE__
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      nullptr, reinterpret_cast<const unsigned char *>(p.c_str()),
      p.string().size(), false);
  SecStaticCodeRef code = nullptr;
  expect(url &&
             SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) == 0,
         "static_code");
  CFRelease(url);
  CFDictionaryRef info = nullptr;
  expect(!SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info),
         "static_info");
  auto data =
      static_cast<CFDataRef>(CFDictionaryGetValue(info, kSecCodeInfoUnique));
  std::string result;
  expect(data, "static_cdhash");
  for (CFIndex i = 0; i < CFDataGetLength(data); ++i) {
    auto n = CFDataGetBytePtr(data)[i];
    result += "0123456789abcdef"[n >> 4];
    result += "0123456789abcdef"[n & 15];
  }
  CFRelease(info);
  CFRelease(code);
  return result;
#else
  (void)p;
  return {};
#endif
}
struct Fixture {
  std::filesystem::path root, source, output, executable;
  int in = -1, out = -1;
  std::string constructor_entered;
  MediaExecutable pin;
  MediaRequest request;
  MediaCapabilities caps;
  MediaProcessLimits limits;
  std::atomic<bool> cancel{false};
  Fixture(const std::filesystem::path &base,
          const std::filesystem::path &worker) {
    std::string pattern = (base / "media-process-XXXXXX").string();
    auto path = mkdtemp(pattern.data());
    expect(path, "mkdtemp");
    root = path;
    source = root / "input.raw";
    output = root / "output.partial";
    executable = root / "worker";
    std::filesystem::copy_file(worker, executable);
    chmod(executable.c_str(), 0700);
    in = open(source.c_str(), O_CREAT | O_EXCL | O_RDONLY, 0600);
    out = open(output.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    expect(in >= 0 && out >= 0, "media_files");
    int exe = open(executable.c_str(), O_RDONLY);
    pin = {executable.string(), hash(exe), std::string(64, '1'),
           cdhash(executable)};
    close(exe);
    request.session = "00000000-0000-4000-8000-000000000001";
    request.job = "00000000-0000-4000-8000-000000000002";
    request.input_sha256 = hash(in);
    request.source_frames = 960;
    request.epoch = 42;
    request.operation = MediaOperation::encode_opus;
    caps = {in, -1, out, std::make_shared<int>(42)};
    limits.total = 15000ms;
    limits.idle = 15000ms;
    limits.terminate_grace = 50ms;
    limits.kill_grace = 500ms;
  }
  ~Fixture() {
    close(in);
    close(out);
  } // Retain all files and child output on failure.
  MediaProcessResult run() {
    auto result = run_media_process(pin, request, caps, limits, cancel);
    std::ofstream record(root / "result.json");
    record << nlohmann::json{{"status", static_cast<int>(result.status)},
                             {"reason", result.reason},
                             {"pid", result.child_pid},
                             {"confirmed", result.child_exit_confirmed},
                             {"signal", result.signal},
                             {"exit_code", result.exit_code},
                             {"stdout", result.result_json},
                             {"stderr", result.stderr_text}}
                  .dump(2);
    if (!result.stderr_text.empty() && (result.stderr_text.front() == '1' ||
                                        result.stderr_text.front() == '2')) {
      do {
        constructor_entered += result.stderr_text.front();
        result.stderr_text.erase(0, 1);
      } while (!result.stderr_text.empty() &&
               (result.stderr_text.front() == '1' ||
                result.stderr_text.front() == '2'));
    }
    return result;
  }
  std::string entered() {
    return constructor_entered;
  }
};
[[maybe_unused]] void confirmed(const MediaProcessResult &r) {
  expect(r.child_pid > 0, "positive_child_pid_required");
  expect(r.child_exit_confirmed, "missing_wait_fence");
  expect(r.closed.valid() &&
             r.closed.wait_for(0ms) == std::future_status::ready,
         "completion_future");
  int status;
  expect(waitpid(r.child_pid, &status, WNOHANG) == -1 && errno == ECHILD,
         "child_not_reaped");
}
} // namespace
#ifndef FORESIGHT_MEDIA_OWNED_DRIVER
int main(int argc, char **argv) {
  try {
    if (argc == 5 && std::string(argv[1]) == "--parent-death-owner") {
      Fixture fixture(argv[3], argv[2]);
      fixture.request.input_sha256 = std::string(64, 'a');
      auto lock_path = std::filesystem::path(argv[3]) / "orphan-owner.lock";
      int lock =
          open(lock_path.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
      expect(lock >= 0 && !flock(lock, LOCK_EX | LOCK_NB), "orphan_owner_lock");
      fixture.caps.owner_lock = lock;
      std::string phase = argv[4];
      bool active = phase == "active" || phase == "active-stopped";
      std::atomic<int> launched{-1};
      std::atomic<bool> phase_ready{false};
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
      media_process_after_spawn_for_test = [&](int child) { launched = child; };
      auto hold = [&] {
        phase_ready = true;
        while (true)
          pause();
      };
      if (phase == "suspended" || phase == "suspended-exited")
        media_process_before_verify_for_test = hold;
      if (phase == "ready")
        media_process_before_transfer_for_test = hold;
#endif
      std::thread work([&] { fixture.run(); });
      auto end = std::chrono::steady_clock::now() + 10s;
      auto path = fixture.source.string() + ".ready";
      while (!(active ? std::filesystem::exists(path) : phase_ready.load()) &&
             std::chrono::steady_clock::now() < end)
        std::this_thread::sleep_for(2ms);
      pid_t child = launched;
      if (active) {
        std::ifstream record(path);
        record >> child;
      }
      if (child <= 1 || write(1, &child, sizeof(child)) != sizeof(child))
        _exit(90);
      while (true)
        pause(); // Outer test SIGKILLs this owner, not the codec.
    }
    expect(argc == 3 || argc == 7, "fixture_paths");
    const char *temp = getenv("FORESIGHT_TEST_TEMP_ROOT");
    expect(temp && temp[0] == '/', "private_temp_required");
    auto base = std::filesystem::canonical(temp);
    auto one = std::filesystem::canonical(argv[1]),
         two = std::filesystem::canonical(argv[2]);
    int cases = 0;
    {
      MediaExecutable pin{"", "", std::string(64, '1'), ""};
      MediaRequest request;
      request.session = "00000000-0000-4000-8000-000000000001";
      request.job = "00000000-0000-4000-8000-000000000002";
      request.epoch = 42;
      MediaProcessResult terminal, parsed;
      terminal.status = MediaProcessStatus::success;
      terminal.child_pid = 42;
      terminal.exit_code = 0;
      std::string nonce(32, 'a');
      auto receipt = media_make_fence(pin, request, nonce, terminal);
      expect(media_read_fence(receipt, pin, request, nonce, parsed),
             "valid_exit_receipt");
      for (size_t offset :
           {size_t(0), size_t(8), size_t(12), size_t(28), size_t(32),
            size_t(68), size_t(104), size_t(112), size_t(144), size_t(271)}) {
        auto corrupt = receipt;
        corrupt[offset] = 0xff;
        expect(!media_read_fence(corrupt, pin, request, nonce, parsed),
               "malformed_or_stale_exit_receipt");
      }
      expect(!media_read_fence(receipt, pin, request, std::string(32, 'b'),
                               parsed),
             "foreign_launch_nonce");
      expect(!media_read_fence(receipt, pin, request, "", parsed),
             "short_launch_nonce");
      request.session.clear();
      expect(!media_read_fence(receipt, pin, request, nonce, parsed),
             "short_receipt_session");
      ++cases;
    }
    {
      Fixture f(base, one);
      setenv("FORESIGHT_MEDIA_PARENT_SECRET", "must not inherit", 1);
      int unrelated = open("/dev/null", O_RDONLY);
      expect(dup2(unrelated, 200) == 200, "unrelated_fd");
      auto r = f.run();
      unsetenv("FORESIGHT_MEDIA_PARENT_SECRET");
      close(unrelated);
      close(200);
      expect(r.status == MediaProcessStatus::success, "success_status");
      confirmed(r);
      expect(f.entered() == "11", "verified_supervisor_and_codec_constructors");
      expect(r.stderr_text.empty(), "unexpected_stderr");
      ++cases;
    }
    {
      Fixture f(base, one);
      f.pin.sha256 = std::string(64, '0');
      auto r = f.run();
      expect(r.status != MediaProcessStatus::success && r.child_pid < 0,
             "digest_admission");
      expect(f.entered().empty(), "unverified_digest_constructor");
      ++cases;
    }
#ifdef __APPLE__
    {
      Fixture f(base, two);
      f.pin.macos_cdhash = cdhash(one);
      auto r = f.run();
      expect(r.status == MediaProcessStatus::identity_mismatch,
             "cdhash_rejection");
      confirmed(r);
      expect(f.entered().empty(), "unverified_constructor_ran");
      ++cases;
    }
#endif
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
    {
#ifndef __APPLE__
      // A no-leaf receipt must not query/reap arbitrary host children.
      struct UnrelatedChild {
        pid_t pid = fork();
        int watched = -1;
        UnrelatedChild() {
          expect(pid >= 0, "unrelated_child_fork");
          if (!pid) {
            alarm(20);
            while (true)
              pause();
          }
          watched = static_cast<int>(syscall(SYS_pidfd_open, pid, 0));
          if (watched < 0) {
            // This fresh child has not been exposed to a reaping probe yet.
            kill(pid, SIGKILL);
            int status;
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
            }
            throw std::runtime_error("unrelated_child_watch");
          }
        }
        ~UnrelatedChild() {
          // A failed probe may already have reaped the numeric PID. Signal
          // and collect only this stable kernel identity, never a reused PID.
          (void)syscall(SYS_pidfd_send_signal, watched, SIGKILL, nullptr, 0);
          siginfo_t info{};
          while (waitid(P_PIDFD, static_cast<id_t>(watched), &info, WEXITED) <
                     0 &&
                 errno == EINTR) {
          }
          close(watched);
        }
      } unrelated;
#endif
      Fixture f(base, one);
#ifndef __APPLE__
      struct OwnerLock {
        int owned = -1, observer = -1;
        ~OwnerLock() {
          if (owned >= 0)
            close(owned);
          if (observer >= 0)
            close(observer);
        }
      } lock;
      auto path = f.root / "replacement-owner.lock";
      lock.owned =
          open(path.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
      expect(lock.owned >= 0 && !flock(lock.owned, LOCK_EX | LOCK_NB),
             "replacement_owner_lock");
      lock.observer = open(path.c_str(), O_RDWR | O_CLOEXEC);
      expect(lock.observer >= 0, "replacement_lock_observer");
      f.caps.owner_lock = lock.owned;
      std::weak_ptr<void> reader = f.caps.keep_alive;
#endif
      media_process_before_spawn_for_test = [&] {
        auto replacement = f.root / "replacement";
        std::filesystem::copy_file(two, replacement);
        chmod(replacement.c_str(), 0700);
        std::filesystem::rename(replacement, f.executable);
      };
      auto r = f.run();
      media_process_before_spawn_for_test = {};
#ifdef __APPLE__
      expect(r.status == MediaProcessStatus::identity_mismatch,
             "replacement_identity");
      expect(f.entered().empty(), "replacement_constructor_ran");
#else
      expect(r.status != MediaProcessStatus::success && f.entered() == "1",
             "nested_codec_rejects_replaced_path");
      expect(r.child_pid == -1 && r.child_exit_confirmed && r.closed.valid() &&
                 r.closed.wait_for(0ms) == std::future_status::ready,
             "replacement_no_leaf_closed_fence");
      close(lock.owned);
      lock.owned = -1;
      f.caps.owner_lock = -1;
      expect(!flock(lock.observer, LOCK_EX | LOCK_NB),
             "replacement_owner_lock_retained");
      f.caps.keep_alive.reset();
      expect(reader.expired(), "replacement_reader_retained");
      int status;
      expect(waitpid(unrelated.pid, &status, WNOHANG) == 0,
             "unrelated_child_reaped");
      auto unreaped = r;
      unreaped.child_pid = unrelated.pid;
      bool rejected = false;
      try {
        confirmed(unreaped);
      } catch (const std::runtime_error &error) {
        rejected = std::string(error.what()) == "child_not_reaped";
      }
      expect(rejected, "positive_unreaped_child_accepted");
#endif
#ifdef __APPLE__
      confirmed(r);
#endif
      ++cases;
    }
#endif
    {
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, 'a');
      bool ready = false;
      auto requested = std::chrono::steady_clock::now();
      std::thread cancel([&] {
        auto deadline = std::chrono::steady_clock::now() + 10s;
        while (!std::filesystem::exists(f.source.string() + ".ready") &&
               std::chrono::steady_clock::now() < deadline)
          std::this_thread::sleep_for(2ms);
        ready = std::filesystem::exists(f.source.string() + ".ready");
        requested = std::chrono::steady_clock::now();
        f.cancel = true;
      });
      auto r = f.run();
      auto returned = std::chrono::steady_clock::now();
      cancel.join();
      expect(ready, "cancellation_fixture_not_ready");
      expect(r.status == MediaProcessStatus::cancelled, "cancel_status");
      confirmed(r);
      expect(r.signal == SIGKILL, "ignored_term_killed");
      expect(returned - requested < 1500ms, "cancel_bound");
      ++cases;
    }
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
    {
      // Deliberately crash the trusted supervisor while its leaf is stopped.
      // No receipt is possible: even after the leaf is killed the result must
      // stay unconfirmed, with the reader lease and shared owner lock retained.
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, 'a');
      f.limits.total = 1500ms;
      f.limits.idle = 1500ms;
      int lock = open((f.root / "crash-owner.lock").c_str(),
                      O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
      expect(lock >= 0 && !flock(lock, LOCK_EX | LOCK_NB), "crash_owner_lock");
      f.caps.owner_lock = lock;
      int observer =
          open((f.root / "crash-owner.lock").c_str(), O_RDWR | O_CLOEXEC);
      expect(observer >= 0, "crash_lock_observer");
      std::atomic<int> supervisor{-1};
      media_process_after_spawn_for_test = [&](int pid) { supervisor = pid; };
      auto task = std::async(std::launch::async, [&] { return f.run(); });
      auto end = std::chrono::steady_clock::now() + 10s;
      auto ready = f.source.string() + ".ready";
      while (!std::filesystem::exists(ready) &&
             std::chrono::steady_clock::now() < end)
        std::this_thread::sleep_for(2ms);
      pid_t leaf = -1;
      {
        std::ifstream input(ready);
        input >> leaf;
      }
      expect(leaf > 1 && supervisor > 1 && leaf != supervisor,
             "crash_leaf_identity");
      expect(!kill(leaf, SIGSTOP), "crash_stop_leaf");
      expect(!kill(supervisor, SIGKILL), "crash_supervisor");
      close(lock);
      f.caps.owner_lock = -1;
      expect(flock(observer, LOCK_EX | LOCK_NB) < 0 && errno == EWOULDBLOCK,
             "lock_released_while_leaf_stopped");
      expect(!kill(leaf, SIGKILL), "crash_leaf_cleanup");
      auto result = task.get();
      media_process_after_spawn_for_test = {};
      expect(result.status == MediaProcessStatus::termination_unconfirmed &&
                 !result.child_exit_confirmed &&
                 result.closed.wait_for(0ms) != std::future_status::ready,
             "missing_fence_claimed_closed");
      std::weak_ptr<void> lease = f.caps.keep_alive;
      f.caps.keep_alive.reset();
      expect(!lease.expired(), "missing_fence_released_reader");
      expect(flock(observer, LOCK_EX | LOCK_NB) < 0 && errno == EWOULDBLOCK,
             "missing_fence_released_owner_lock");
      close(observer);
      ++cases;
    }
#endif
    {
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, 'b');
      auto r = f.run();
      expect(r.status == MediaProcessStatus::output_limit, "output_limit");
      confirmed(r);
      expect(r.result_json.size() <= 16384 && r.stderr_text.size() <= 8192,
             "output_memory_bound");
      ++cases;
    }
    for (char mode : {'c', 'd'}) {
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, mode);
      auto r = f.run();
      expect(r.status == MediaProcessStatus::protocol_failed,
             "protocol_validation");
      confirmed(r);
      ++cases;
    }
    {
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, 'e');
      f.limits.idle = 80ms;
      std::atomic<uint64_t> progress{0};
      std::atomic<pid_t> ready_pid{-1};
      f.limits.progress = &progress;
      // Verification and instrumented startup are not idle codec work. Keep
      // service-owned progress alive until the actual leaf publishes its PID,
      // then leave the unchanged 80 ms idle budget to terminate that leaf.
      std::atomic<bool> stop_feed{false};
      std::thread feed([&] {
        const auto end = std::chrono::steady_clock::now() + 10s;
        while (!stop_feed.load() && std::chrono::steady_clock::now() < end) {
          ++progress;
          std::ifstream ready(f.source.string() + ".ready");
          pid_t pid = -1;
          if (ready >> pid && pid > 0) {
            ready_pid = pid;
            break;
          }
          std::this_thread::sleep_for(2ms);
        }
      });
      // Supported Apple libc++ versions may lack jthread despite C++20 mode.
      // Stop and join the feeder on normal completion and exception unwinding.
      struct StopAndJoin {
        std::atomic<bool> &stop;
        std::thread &thread;
        void finish() {
          stop = true;
          if (thread.joinable())
            thread.join();
        }
        ~StopAndJoin() {
          finish();
        }
      } stop_and_join{stop_feed, feed};
      auto r = f.run();
      stop_and_join.finish();
      expect(ready_pid > 0 && ready_pid == r.child_pid,
             "idle_leaf_not_acquired");
      expect(r.status == MediaProcessStatus::idle_timeout, "idle_timeout");
      confirmed(r);
      ++cases;
    }
    {
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, 'e');
      f.limits.total = 80ms;
      f.limits.idle = 80ms;
      struct OwnerLock {
        int owned = -1, observer = -1;
        ~OwnerLock() {
          if (owned >= 0)
            close(owned);
          if (observer >= 0)
            close(observer);
        }
      } lock;
      const auto path = f.root / "deadline-owner.lock";
      lock.owned =
          open(path.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
      expect(lock.owned >= 0 && !flock(lock.owned, LOCK_EX | LOCK_NB),
             "deadline_owner_lock");
      lock.observer = open(path.c_str(), O_RDWR | O_CLOEXEC);
      expect(lock.observer >= 0, "deadline_lock_observer");
      f.caps.owner_lock = lock.owned;
      std::weak_ptr<void> reader = f.caps.keep_alive;
      auto r = f.run();
      expect(r.status == MediaProcessStatus::deadline, "total_deadline");
      if (r.child_pid > 0) {
        confirmed(r);
      } else {
        // This budget includes cold verification. Instrumentation may exhaust
        // it before any leaf is admitted, which still requires real closure.
        expect(r.child_pid == -1 && r.closed.valid() &&
                   r.closed.wait_for(0ms) == std::future_status::ready,
               "deadline_no_leaf_closed_fence");
        expect(f.entered().empty() ||
                   (f.entered() == "1" && r.child_exit_confirmed),
               "deadline_unaccounted_constructor");
      }
      close(lock.owned);
      lock.owned = -1;
      f.caps.owner_lock = -1;
      expect(!flock(lock.observer, LOCK_EX | LOCK_NB),
             "deadline_owner_lock_retained");
      f.caps.keep_alive.reset();
      expect(reader.expired(), "deadline_reader_retained");
      ++cases;
    }
    {
      Fixture f(base, one);
      f.request.input_sha256 = std::string(64, 'f');
      // Quiet work exceeds idle, while service-owned input progress keeps the
      // lease active. Leave scheduling margin on loaded CI hosts.
      f.limits.idle = 200ms;
      std::atomic<uint64_t> progress{0};
      std::atomic<bool> done{false};
      f.limits.progress = &progress;
      std::thread feed([&] {
        while (!done) {
          ++progress;
          std::this_thread::sleep_for(20ms);
        }
      });
      auto r = f.run();
      done = true;
      feed.join();
      expect(r.status == MediaProcessStatus::success, "external_progress");
      confirmed(r);
      ++cases;
    }
#if defined(__APPLE__) && defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&       \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
    {
      Fixture f(base, one);
      std::atomic<bool> verifying{false}, release{false};
      auto verification_entered = std::chrono::steady_clock::now();
      media_process_before_verify_for_test = [&] {
        verification_entered = std::chrono::steady_clock::now();
        verifying = true;
        while (!release)
          std::this_thread::sleep_for(2ms);
      };
      f.limits.total = 100ms;
      f.limits.idle = 100ms;
      f.limits.kill_grace = 80ms;
      std::weak_ptr<void> lease = f.caps.keep_alive;
      auto r = f.run();
      expect(verifying, "verification_hook_not_started");
      expect(r.status == MediaProcessStatus::termination_unconfirmed &&
                 !r.child_exit_confirmed,
             "verification_timeout_fence");
      // posix_spawn and filesystem syscalls are not preemptible; measure the
      // suspended-verifier cancellation fence after actual launch, separately.
      expect(std::chrono::steady_clock::now() - verification_entered < 1s,
             "verification_timeout_bound");
      expect(r.closed.wait_for(0ms) == std::future_status::timeout,
             "premature_completion");
      f.caps.keep_alive.reset();
      expect(!lease.expired(), "premature_reader_release");
      expect(f.entered().empty(), "timed_out_constructor_ran");
      release = true;
      expect(r.closed.wait_for(2s) == std::future_status::ready,
             "deferred_wait_fence");
      media_process_before_verify_for_test = {};
      int status;
      expect(waitpid(r.child_pid, &status, WNOHANG) == -1 && errno == ECHILD,
             "deferred_child_not_reaped");
      for (int i = 0; i < 100 && !lease.expired(); ++i)
        std::this_thread::sleep_for(2ms);
      expect(lease.expired(), "reader_lease_retained_after_exit");
      ++cases;
    }
#endif
    {
      Fixture f(base, one);
      f.cancel = true;
      auto r = f.run();
      expect(r.status == MediaProcessStatus::cancelled && r.child_pid < 0,
             "pre_cancel");
      expect(f.entered().empty(), "pre_cancel_constructor");
      ++cases;
    }
    {
      Fixture f(base, one);
      f.request.operation = MediaOperation::decode_pcm;
      f.request.start_frame = 12;
      f.request.frame_count = 2;
      auto r = f.run();
      expect(r.status == MediaProcessStatus::success, "decode_contract");
      confirmed(r);
      ++cases;
    }
    {
      Fixture f(base, one);
      struct sigaction old{}, ignore{};
      ignore.sa_handler = SIG_IGN;
      sigemptyset(&ignore.sa_mask);
      expect(!sigaction(SIGCHLD, &ignore, &old), "test_signal");
      auto r = f.run();
      sigaction(SIGCHLD, &old, nullptr);
      expect(r.status == MediaProcessStatus::launch_failed && r.child_pid < 0 &&
                 r.reason == "unsupported_child_reaping",
             "automatic_reaping_admission");
      expect(f.entered().empty(), "automatic_reaping_constructor");
      ++cases;
    }
    std::vector<std::string> phases{"active"};
#ifdef __APPLE__
    phases.push_back("active-stopped");
#endif
#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
    phases.push_back("ready");
#ifdef __APPLE__
    phases.push_back("suspended");
    phases.push_back("suspended-exited");
#endif
#endif
    for (auto &phase : phases) {
      Fixture fixture(base, one);
      int report[2];
      expect(!cloexec_pipe(report), "orphan_report");
      posix_spawn_file_actions_t actions;
      posix_spawnattr_t attributes;
      expect(!posix_spawn_file_actions_init(&actions) &&
                 !posix_spawnattr_init(&attributes),
             "orphan_spawn_metadata");
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
      posix_spawn_file_actions_adddup2(&actions, report[1], 1);
      posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
#ifdef __APPLE__
      posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
#endif
      close_spawn_descriptors(&actions, 3);
      auto self = std::filesystem::canonical(argv[0]).string();
      std::string mode = "--parent-death-owner", worker = one.string(),
                  root = fixture.root.string();
      char *args[]{self.data(), mode.data(),  worker.data(),
                   root.data(), phase.data(), nullptr};
      char *env[]{nullptr};
      pid_t owner = -1;
      int error =
          posix_spawn(&owner, self.c_str(), &actions, &attributes, args, env);
      posix_spawn_file_actions_destroy(&actions);
      posix_spawnattr_destroy(&attributes);
      close(report[1]);
      expect(!error && owner > 1, "orphan_spawn");
      pollfd ready{report[0], POLLIN, 0};
      expect(poll(&ready, 1, 15000) > 0, "orphan_ready_timeout");
      pid_t child = -1;
      expect(read(report[0], &child, sizeof(child)) == sizeof(child) &&
                 child > 1,
             "orphan_child");
      close(report[0]);
      auto lock_path = fixture.root / "orphan-owner.lock";
      int observer = open(lock_path.c_str(), O_RDWR | O_CLOEXEC);
      expect(observer >= 0 && flock(observer, LOCK_EX | LOCK_NB) < 0 &&
                 errno == EWOULDBLOCK,
             "orphan_lock_not_held");
#ifdef __APPLE__
      int watched = kqueue();
      struct kevent event;
      EV_SET(&event, static_cast<uintptr_t>(child), EVFILT_PROC,
             EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, nullptr);
      expect(watched >= 0 && !kevent(watched, &event, 1, nullptr, 0, nullptr),
             "orphan_child_watch");
#else
      int watched = static_cast<int>(syscall(SYS_pidfd_open, child, 0));
      expect(watched >= 0, "orphan_child_watch");
#endif
      if (phase == "active-stopped") {
        expect(!kill(child, SIGSTOP), "orphan_leaf_stop");
        std::this_thread::sleep_for(20ms);
      }
      expect(!kill(owner, SIGKILL), "orphan_parent_kill");
      int status;
      expect(waitpid(owner, &status, 0) == owner && WIFSIGNALED(status),
             "orphan_parent_wait");
      // Leaf exit and release of the supervisor's own lock copies are
      // distinct observations, sharing the original five-second budget.
      const auto exit_deadline = std::chrono::steady_clock::now() + 5s;
      [[maybe_unused]] bool exit_observed = false;
      if (phase == "active-stopped") {
        // EOF cancellation may let the supervisor kill its leaf before its
        // own parent watcher fires. Accept early lock release ONLY with an
        // actual kernel exit event; a still-live stopped reader holds it.
        std::this_thread::sleep_for(50ms);
        if (!flock(observer, LOCK_EX | LOCK_NB)) {
#ifdef __APPLE__
          timespec timeout{1, 0};
          expect(kevent(watched, nullptr, 0, &event, 1, &timeout) == 1 &&
                     event.ident == static_cast<uintptr_t>(child) &&
                     (event.fflags & NOTE_EXIT),
                 "lock_released_without_leaf_exit");
          exit_observed = true;
#endif
        } else {
          expect(errno == EWOULDBLOCK, "stopped_owner_lock_observation");
          expect(!kill(child, SIGKILL) || errno == ESRCH,
                 "stopped_orphan_fixture_cleanup");
        }
      } else if (phase != "active") {
        expect(!flock(observer, LOCK_EX | LOCK_NB),
               "pretransfer_orphan_held_media_lock");
#ifdef __APPLE__
        if (phase == "suspended" || phase == "suspended-exited") {
          // No watcher/user code has run or received media capabilities.
          if (phase == "suspended-exited") {
            // Exercise cleanup after an actual watched exit, without relying
            // on a particular Darwin version's suspended-orphan behavior.
            const int stopped = kill(child, SIGKILL);
            const int stopped_errno = stopped < 0 ? errno : 0;
            expect(stopped == 0 || stopped_errno == ESRCH,
                   "suspended_control_exit_signal");
            const auto remaining =
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    exit_deadline - std::chrono::steady_clock::now());
            const auto nanos = remaining.count() > 0 ? remaining.count() : 0;
            timespec timeout{static_cast<time_t>(nanos / 1000000000),
                             static_cast<long>(nanos % 1000000000)};
            expect(kevent(watched, nullptr, 0, &event, 1, &timeout) == 1 &&
                       event.ident == static_cast<uintptr_t>(child) &&
                       (event.fflags & NOTE_EXIT),
                   "suspended_control_kernel_exit");
            exit_observed = true;
            int alive;
            do {
              alive = kill(child, 0);
              if (alive == 0)
                std::this_thread::yield();
            } while (alive == 0 &&
                     std::chrono::steady_clock::now() < exit_deadline);
            expect(alive == -1 && errno == ESRCH, "suspended_control_pid_gone");
          }
          const int cleanup = kill(child, SIGKILL);
          const int cleanup_errno = cleanup < 0 ? errno : 0;
          if (cleanup < 0)
            std::cerr << "suspended_fixture_cleanup: errno=" << cleanup_errno
                      << "; registered kernel exit fence still required"
                      << std::endl;
          expect(cleanup == 0 || cleanup_errno == ESRCH,
                 "suspended_fixture_cleanup");
        }
#endif
      }
#ifdef __APPLE__
      const auto remaining =
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              exit_deadline - std::chrono::steady_clock::now());
      const auto nanos = remaining.count() > 0 ? remaining.count() : 0;
      timespec timeout{static_cast<time_t>(nanos / 1000000000),
                       static_cast<long>(nanos % 1000000000)};
      expect(exit_observed ||
                 (kevent(watched, nullptr, 0, &event, 1, &timeout) == 1 &&
                  event.ident == static_cast<uintptr_t>(child) &&
                  (event.fflags & NOTE_EXIT)),
             "orphan_child_survived");
#else
      const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(
          exit_deadline - std::chrono::steady_clock::now());
      pollfd ended{watched, POLLIN, 0};
      expect(poll(&ended, 1,
                  remaining.count() > 0 ? static_cast<int>(remaining.count())
                                        : 0) > 0,
             "orphan_child_survived");
#endif
      close(watched);
      while (true) {
        expect(std::chrono::steady_clock::now() < exit_deadline,
               "orphan_lock_retained_after_exit");
        if (!flock(observer, LOCK_EX | LOCK_NB))
          break;
        expect(errno == EWOULDBLOCK, "orphan_lock_observation");
        std::this_thread::yield();
      }
      close(observer);
      ++cases;
    }
    if (argc == 7) {
      auto codec = std::filesystem::canonical(argv[3]);
      auto set_pin = [&](Fixture &f) {
        f.pin.sha256 = argv[5];
        f.pin.build_id = argv[4];
        f.pin.macos_cdhash = argv[6];
      };
      auto set_content = [&](Fixture &f, const std::string &bytes) {
        int fd = open(f.source.c_str(), O_WRONLY | O_TRUNC);
        expect(fd >= 0, "content_fd");
        expect(write(fd, bytes.data(), bytes.size()) ==
                   static_cast<ssize_t>(bytes.size()),
               "content_write");
        close(fd);
        f.request.input_sha256 = hash(f.in);
      };
      Fixture encoded(base, codec);
      set_pin(encoded);
      encoded.request.operation = MediaOperation::encode_recording_wav_v1;
      std::string wav(196 + 960 * 2, '\0');
      auto put = [&](size_t at, uint64_t value, size_t n) {
        for (size_t i = 0; i < n; ++i)
          wav[at + i] = static_cast<char>(value >> (8 * i));
      };
      std::memcpy(wav.data(), "RIFF", 4);
      put(4, wav.size() - 8, 4);
      std::memcpy(wav.data() + 8, "WAVEfmt ", 8);
      put(16, 16, 4);
      put(20, 1, 2);
      put(22, 1, 2);
      put(24, 48000, 4);
      put(28, 96000, 4);
      put(32, 2, 2);
      put(34, 16, 2);
      std::memcpy(wav.data() + 36, "fsid", 4);
      put(40, 144, 4);
      std::memcpy(wav.data() + 44, encoded.request.session.data(), 36);
      std::memcpy(wav.data() + 80, encoded.request.job.data(), 36);
      std::memcpy(wav.data() + 116, encoded.request.job.data(), 36);
      put(152, 0xc0000001, 4);
      put(156, 1, 8);
      put(180, 1000000, 8);
      std::memcpy(wav.data() + 188, "data", 4);
      put(192, 960 * 2, 4);
      set_content(encoded, wav);
      auto first = encoded.run();
      expect(first.status == MediaProcessStatus::success, "real_codec_encode");
      confirmed(first);
      ++cases;
      std::ifstream stream(encoded.output, std::ios::binary);
      std::string opus((std::istreambuf_iterator<char>(stream)), {});
      Fixture decoded(base, codec);
      set_pin(decoded);
      set_content(decoded, opus);
      decoded.request.operation = MediaOperation::decode_pcm;
      decoded.request.start_frame = 240;
      decoded.request.frame_count = 480;
      auto second = decoded.run();
      expect(second.status == MediaProcessStatus::success, "real_codec_decode");
      confirmed(second);
      expect(std::filesystem::file_size(decoded.output) == 960,
             "real_codec_decode_frames");
      ++cases;
      Fixture mixed(base, codec);
      set_pin(mixed);
      set_content(mixed, std::string(1920, '\0'));
      mixed.request.operation = MediaOperation::mix_export_mp3;
      auto second_source = mixed.root / "second.raw";
      int writer =
          open(second_source.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
      std::string silence(1920, '\0');
      expect(writer >= 0 &&
                 write(writer, silence.data(), silence.size()) == 1920,
             "second_source_write");
      close(writer);
      int reader = open(second_source.c_str(), O_RDONLY);
      expect(reader >= 0, "second_source_read");
      mixed.caps.second_input = reader;
      mixed.request.second_input_sha256 = hash(reader);
      auto third = mixed.run();
      close(reader);
      expect(third.status == MediaProcessStatus::success, "real_codec_mix");
      confirmed(third);
      ++cases;
    }
    std::cout
        << "media_process: " << cases
        << " cases passed; process cancellation and wait fences executed\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "media_process_test: " << e.what() << '\n';
    return 1;
  }
}
#else
int main(int argc, char **argv) {
  try {
    expect(argc == 3 || argc == 7, "owned_fixture_paths");
    const char *temp = getenv("FORESIGHT_TEST_TEMP_ROOT");
    expect(temp && temp[0] == '/', "private_temp_required");
    auto base = std::filesystem::canonical(temp);
    auto worker = std::filesystem::canonical(argv[1]);
    auto other = std::filesystem::canonical(argv[2]);
    auto options = [](const Fixture &f) {
      return nlohmann::json{
          {"version", 1},
          {"executable", f.pin.path},
          {"executable_sha256", f.pin.sha256},
          {"build_id", f.pin.build_id},
          {"macos_cdhash", f.pin.macos_cdhash},
          {"session_id", f.request.session},
          {"job_id", f.request.job},
          {"epoch", f.request.epoch},
          {"input_sha256", f.request.input_sha256},
          {"second_input_sha256", f.request.second_input_sha256},
          {"source_frames", f.request.source_frames},
          {"start_frame", f.request.start_frame},
          {"frame_count", f.request.frame_count},
          {"total_ms", 15000},
          {"idle_ms", 15000},
          {"terminate_grace_ms", 50},
          {"kill_grace_ms", 500}};
    };
    auto start = [&](Fixture &f, const nlohmann::json &json) {
      auto path = f.root / "owner.lock";
      int lock =
          open(path.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
      expect(lock >= 0 && !flock(lock, LOCK_EX | LOCK_NB), "owned_flock");
      auto value = fs_owned_media_start(static_cast<int>(f.request.operation),
                                        f.in, f.caps.second_input, f.out, lock,
                                        json.dump().c_str());
      close(lock);
      return value;
    };
    auto wait = [](uint64_t token) {
      expect(token > 0, "owned_token");
      auto end = std::chrono::steady_clock::now() + 15s;
      int status = 0;
      while ((status = fs_operation_status(token)) == 0 &&
             std::chrono::steady_clock::now() < end)
        std::this_thread::sleep_for(2ms);
      expect(status == 1, "owned_wait_fence");
    };
    auto poll = [](uint64_t owner) {
      char *text = fs_owned_media_poll(owner);
      expect(text, "owned_poll");
      auto json = nlohmann::json::parse(text);
      fs_string_free(text);
      return json;
    };
    auto retire = [&](uint64_t owner) {
      auto token = fs_media_retire(owner);
      expect(token && token == fs_media_retire(owner), "retire_identity");
      wait(token);
      expect(fs_owner_release(owner) == 0, "owned_release");
      expect(fs_owned_media_poll(owner) == nullptr, "released_poll");
    };
    int cases = 0;
    {
      Fixture f(base, worker);
      auto owner = start(f, options(f));
      expect(owner, "owned_start");
      close(f.in);
      close(f.out);
      f.in = f.out = -1; // Native already owns its duplicates.
      expect(fs_owned_media_progress(owner) == 0, "owned_progress");
      auto join = fs_media_join_async(owner);
      expect(join == fs_media_join_async(owner), "join_identity");
      wait(join);
      auto result = poll(owner);
      expect(result.at("closed") == true && result.at("status") == "success" &&
                 result.at("worker_result").at("frames") == 960,
             "owned_success");
      expect(fs_owned_event_poll(owner, 0) == nullptr,
             "media_event_type_confusion");
      expect(fs_owner_release(owner) == -1, "premature_owner_release");
      auto path = f.root / "owner.lock";
      int lock = open(path.c_str(), O_RDWR | O_CLOEXEC);
      expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) < 0,
             "owned_lock_released_early");
      expect(fs_operation_release(join) == 0, "join_acknowledgement");
      retire(owner);
      expect(!flock(lock, LOCK_EX | LOCK_NB), "owned_lock_not_released");
      close(lock);
      ++cases;
    }
    {
      Fixture f(base, worker);
      f.request.input_sha256 = std::string(64, 'a');
      auto owner = start(f, options(f));
      expect(owner, "owned_cancel_start");
      auto end = std::chrono::steady_clock::now() + 10s;
      while (!std::filesystem::exists(f.source.string() + ".ready") &&
             std::chrono::steady_clock::now() < end)
        std::this_thread::sleep_for(2ms);
      expect(std::filesystem::exists(f.source.string() + ".ready"),
             "owned_cancel_ready");
      expect(fs_owned_media_cancel(owner) == 0, "owned_cancel");
      auto join = fs_media_join_async(owner);
      wait(join);
      auto result = poll(owner);
      expect(result.at("closed") == true &&
                 result.at("status") == "cancelled" &&
                 result.at("child_exit_confirmed") == true,
             "owned_cancel_fence");
      expect(fs_operation_release(join) == 0, "cancel_join_release");
      retire(owner);
      ++cases;
    }
    {
      Fixture f(base, worker);
      f.request.input_sha256 = std::string(64, 'a');
      auto owner = start(f, options(f));
      expect(owner, "owned_retire_start");
      auto join = fs_media_join_async(owner);
      retire(owner);
      // Owner acknowledgement does not fabricate a separate join result.
      expect(fs_operation_status(join) == 1, "retire_join_fence");
      expect(fs_operation_release(join) == 0, "retire_join_release");
      ++cases;
    }
    {
      Fixture f(base, worker);
      auto json = options(f);
      json["command"] = "ignored";
      expect(!start(f, json), "unknown_media_option");
      expect(fs_lifetime_admission() == 1, "invalid_options_quarantined");
      ++cases;
    }
    {
      Fixture f(base, worker);
      f.pin.sha256 = std::string(64, '0');
      auto owner = start(f, options(f));
      expect(owner, "owned_digest_start");
      auto join = fs_media_join_async(owner);
      wait(join);
      auto result = poll(owner);
      expect(result.at("closed") == true &&
                 result.at("status") == "launch_failed" &&
                 result.at("reason") == "executable_digest" &&
                 result.at("stderr") == "",
             "owned_unverified_digest_executed");
      expect(fs_operation_release(join) == 0, "digest_join_release");
      retire(owner);
      ++cases;
    }
#ifdef __APPLE__
    {
      Fixture f(base, other);
      f.pin.macos_cdhash = cdhash(worker);
      auto owner = start(f, options(f));
      expect(owner, "owned_identity_start");
      auto join = fs_media_join_async(owner);
      wait(join);
      auto result = poll(owner);
      expect(result.at("closed") == true &&
                 result.at("status") == "identity_mismatch" &&
                 result.at("stderr") == "",
             "owned_unverified_constructor");
      expect(fs_operation_release(join) == 0, "identity_join_release");
      retire(owner);
      ++cases;
    }
#endif
    {
      // Same actual native mapping, independent executor lanes: model keeper
      // retirement must never consume a media join/retirement token.
      Fixture assets(base, worker);
      std::atomic<bool> stop{false};
      std::exception_ptr failure;
      std::atomic<unsigned> speech_count{0};
      host_reaper_total = 0;
      auto &host_reaped = host_reaper_total;
      struct sigaction previous{}, action{};
      action.sa_handler = host_reaper_signal;
      sigemptyset(&action.sa_mask);
      action.sa_flags = SA_RESTART | SA_NOCLDSTOP;
      expect(!sigaction(SIGCHLD, &action, &previous),
             "install_competing_host_reaper");
      // Models a host runtime which eagerly consumes ANY direct child. The
      // supervisor's leaf is deliberately not a child of this host process.
      std::thread reaper([&] {
        while (!stop) {
          int status;
          while (waitpid(-1, &status, WNOHANG) > 0)
            ++host_reaped;
          std::this_thread::sleep_for(100us);
        }
      });
      std::thread speech([&] {
        try {
          while (!stop || speech_count < 100) {
            auto owner = fs_owned_speech_create(assets.executable.c_str(),
                                                assets.source.c_str());
            expect(owner, "concurrent_speech_create");
            auto token = fs_speech_retire(owner);
            wait(token);
            expect(fs_owner_release(owner) == 0, "concurrent_speech_release");
            ++speech_count;
          }
        } catch (...) {
          failure = std::current_exception();
        }
      });
      try {
        for (unsigned i = 0; i < 20; ++i) {
          Fixture f(base, worker);
          auto owner = start(f, options(f));
          expect(owner, "concurrent_media_start");
          auto join = fs_media_join_async(owner);
          wait(join);
          auto result = poll(owner);
          if (result.at("status") != "success")
            std::cerr << "concurrent media failure: iteration=" << i
                      << " owner=" << owner << " join=" << join
                      << " result=" << result.dump() << '\n';
          expect(result.at("status") == "success", "concurrent_media_result");
          expect(fs_operation_release(join) == 0,
                 "concurrent_media_join_release");
          auto token = fs_media_retire(owner);
          if (!token || fs_operation_status(token) < 0)
            throw std::runtime_error("concurrent_media_retire_unknown owner=" +
                                     std::to_string(owner) +
                                     " token=" + std::to_string(token));
          wait(token);
          expect(fs_owner_release(owner) == 0,
                 "concurrent_media_owner_release");
        }
      } catch (...) {
        stop = true;
        speech.join();
        reaper.join();
        (void)sigaction(SIGCHLD, &previous, nullptr);
        throw;
      }
      stop = true;
      speech.join();
      reaper.join();
      expect(!sigaction(SIGCHLD, &previous, nullptr), "restore_host_reaper");
      if (failure)
        std::rethrow_exception(failure);
      expect(speech_count >= 100 && fs_lifetime_admission() == 1,
             "concurrent_registry_admission");
      expect(host_reaped > 0, "competing_host_reaper_exercised");
      std::cout << "concurrent media:20 jobs; speech:" << speech_count
                << " retirements; host reaped:" << host_reaped
                << " supervisors\n";
      ++cases;
    }
    if (argc == 7) {
      auto codec = std::filesystem::canonical(argv[3]);
      auto prepare = [&](Fixture &f, const std::string &content) {
        f.pin.sha256 = argv[5];
        f.pin.build_id = argv[4];
        f.pin.macos_cdhash = argv[6];
        int fd = open(f.source.c_str(), O_WRONLY | O_TRUNC);
        expect(fd >= 0 && write(fd, content.data(), content.size()) ==
                              static_cast<ssize_t>(content.size()),
               "owned_actual_content");
        close(fd);
        f.request.input_sha256 = hash(f.in);
      };
      auto run = [&](Fixture &f) {
        auto began = std::chrono::steady_clock::now();
        auto owner = start(f, options(f));
        expect(owner, "owned_actual_start");
        auto join = fs_media_join_async(owner);
        wait(join);
        auto result = poll(owner);
        expect(result.at("closed") == true &&
                   result.at("status") == "success" &&
                   result.at("worker_result").at("build_id") == argv[4],
               "owned_actual_codec");
        expect(fs_operation_release(join) == 0, "owned_actual_join_ack");
        retire(owner);
        std::cout << "actual native media operation "
                  << static_cast<int>(f.request.operation) << " total_ms="
                  << std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::steady_clock::now() - began)
                         .count()
                  << "\n";
        ++cases;
      };
      Fixture encoded(base, codec);
      prepare(encoded, std::string(1920, '\0'));
      run(encoded);
      std::ifstream input(encoded.output, std::ios::binary);
      std::string opus((std::istreambuf_iterator<char>(input)), {});
      Fixture decoded(base, codec);
      prepare(decoded, opus);
      decoded.request.operation = MediaOperation::decode_pcm;
      decoded.request.start_frame = 240;
      decoded.request.frame_count = 480;
      run(decoded);
      expect(std::filesystem::file_size(decoded.output) == 960,
             "owned_actual_range");
      Fixture mixed(base, codec);
      prepare(mixed, std::string(1920, '\0'));
      mixed.request.operation = MediaOperation::mix_export_mp3;
      auto second = mixed.root / "second.raw";
      int writer = open(second.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
      std::string silence(1920, '\0');
      expect(writer >= 0 &&
                 write(writer, silence.data(), silence.size()) == 1920,
             "owned_actual_second");
      close(writer);
      int reader = open(second.c_str(), O_RDONLY | O_CLOEXEC);
      expect(reader >= 0, "owned_actual_second_read");
      mixed.caps.second_input = reader;
      mixed.request.second_input_sha256 = hash(reader);
      run(mixed);
      close(reader);
    }
    std::cout << "media_owned: " << cases
              << " cases passed; real native ABI, descriptor leases and wait "
                 "fences executed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "media_owned_test: " << error.what() << '\n';
    return 1;
  }
}
#endif

#endif
