#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
// Only this fixture process opts in. Block the real writer's PCM pwrite,
// never its header/intent, so a fast filesystem still exercises backpressure.
bool private_fixture_path(const char *path, const char *base) {
  if (!path)
    return false;
  const std::string name(path);
  const auto slash = name.find_last_of('/');
  if (slash == std::string::npos || name.substr(slash + 1) != base)
    return false;
  const auto directory = name.substr(0, slash);
  char *canonical = realpath(directory.c_str(), nullptr);
  const bool exact = canonical && directory == canonical;
  std::free(canonical);
  struct stat parent;
  return exact && lstat(directory.c_str(), &parent) == 0 &&
         S_ISDIR(parent.st_mode) && parent.st_uid == geteuid() &&
         (parent.st_mode & 0777) == 0700;
}
void evidence(const char *variable, const char *base) {
  const char *path = std::getenv(variable);
  if (!private_fixture_path(path, base))
    return;
  const int fd =
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd >= 0) {
    const char message[] = "controlled writer boundary observed\n";
    (void)write(fd, message, sizeof(message) - 1);
    close(fd);
  }
}
#ifdef __APPLE__
// dyld has already installed this image's interposer in the service process.
// The domain worker is an isolate in that same process. Descendant utilities
// and inference/capture executables must not inherit this test-only image.
__attribute__((constructor)) void retire_descendant_injection() {
  const char *injected = std::getenv("DYLD_INSERT_LIBRARIES");
  Dl_info image{};
  if (!injected ||
      dladdr(reinterpret_cast<const void *>(&retire_descendant_injection),
             &image) == 0 ||
      !image.dli_fname)
    return;
  char *canonical = realpath(image.dli_fname, nullptr);
  const bool own_image = canonical && std::strcmp(injected, canonical) == 0;
  std::free(canonical);
  if (own_image)
    (void)unsetenv("DYLD_INSERT_LIBRARIES");
}
#endif
bool uuid(const std::string &text) {
  if (text.size() != 36)
    return false;
  for (size_t i = 0; i < text.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (text[i] != '-')
        return false;
    } else if (!((text[i] >= '0' && text[i] <= '9') ||
                 (text[i] >= 'a' && text[i] <= 'f'))) {
      return false;
    }
  }
  return true;
}
void hold_owned_pcm_write(int fd, off_t offset) {
  const char *gate = std::getenv("FORESIGHT_TEST_CAPTURE_POLL_GATE");
  const char *data = std::getenv("FORESIGHT_DATA");
  if (offset < 196 || !data ||
      !private_fixture_path(gate, "hold-capture-poll") ||
      access(gate, F_OK) != 0)
    return;
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) ||
      info.st_uid != geteuid() || (info.st_mode & 0777) != 0600 ||
      info.st_nlink != 1)
    return;
  char *canonical = realpath(data, nullptr);
  const bool exact = canonical && std::strcmp(canonical, data) == 0;
  std::free(canonical);
  if (!exact)
    return;
  char path[PATH_MAX];
#ifdef __APPLE__
  if (fcntl(fd, F_GETPATH, path) != 0)
    return;
#else
  const auto link = "/proc/self/fd/" + std::to_string(fd);
  const auto length = readlink(link.c_str(), path, sizeof(path) - 1);
  if (length < 0 || static_cast<size_t>(length) >= sizeof(path) - 1)
    return;
  path[length] = 0;
#endif
  const auto prefix = std::string(data) + "/recordings/";
  const std::string file(path);
  if (file.compare(0, prefix.size(), prefix) != 0)
    return;
  const auto relative = file.substr(prefix.size());
  if (relative.size() != 36 + 1 + 36 + 1 + 36 + 8 || relative[36] != '/' ||
      relative[73] != '/' || !uuid(relative.substr(0, 36)) ||
      !uuid(relative.substr(37, 36)) || !uuid(relative.substr(74, 36)) ||
      relative.substr(110) != ".partial")
    return;
  evidence("FORESIGHT_TEST_RECORDING_WRITE_ENTERED", "recording-write-entered");
#ifdef __APPLE__
  if (!std::getenv("DYLD_INSERT_LIBRARIES"))
    evidence("FORESIGHT_TEST_CAPTURE_INJECTION_RETIRED",
             "capture-injection-retired");
#endif
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (access(gate, F_OK) == 0) {
    if (std::chrono::steady_clock::now() >= deadline) {
      evidence("FORESIGHT_TEST_RECORDING_WRITE_TIMEOUT",
               "recording-write-timeout");
      return;
    }
    usleep(1000); // The disk worker is not a real-time capture callback.
  }
}
void *real_image() {
  static void *image = [] {
    void *library = dlopen(std::getenv("FORESIGHT_TEST_REAL_NATIVE"), RTLD_NOW);
    if (!library) {
      std::fputs(dlerror(), stderr);
      std::abort();
    }
    return library;
  }();
  return image;
}
// Observe only synthetic fixture metadata. The original pointer and every
// returned field pass through unchanged; no writer hook or delay is installed.
void observe_pressure(const char *value) {
  static std::mutex mutex;
  static unsigned records = 0;
  std::lock_guard lock(mutex);
  if (!value || records >= 256)
    return;
  const char *path = std::getenv("FORESIGHT_TEST_CAPTURE_TRACE");
  if (!path)
    return;
  const std::string name(path);
  const auto slash = name.find_last_of('/');
  if (slash == std::string::npos ||
      name.substr(slash + 1) != "capture-pressure.jsonl")
    return;
  const auto directory = name.substr(0, slash);
  char *canonical = realpath(directory.c_str(), nullptr);
  const bool exact = canonical && directory == canonical;
  std::free(canonical);
  struct stat parent;
  if (!exact || lstat(directory.c_str(), &parent) != 0 ||
      !S_ISDIR(parent.st_mode) || parent.st_uid != geteuid() ||
      (parent.st_mode & 0777) != 0700)
    return;
  const size_t length = strnlen(value, 65537);
  if (length > 65536)
    return;
  const int fd =
      open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0)
    return;
  struct stat info;
  if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
      info.st_uid == geteuid() && (info.st_mode & 0777) == 0600 &&
      info.st_nlink == 1 &&
      info.st_size + static_cast<off_t>(length + 1) <= 2 * 1024 * 1024) {
    std::string line(value, length);
    line += '\n';
    if (write(fd, line.data(), line.size()) ==
        static_cast<ssize_t>(line.size()))
      ++records;
  }
  close(fd);
}
} // namespace

extern "C" char *fs_owned_capture_recording_poll(uint64_t owner) {
  using Poll = char *(*)(uint64_t);
  static const auto poll = reinterpret_cast<Poll>(
      dlsym(real_image(), "fs_owned_capture_recording_poll"));
  if (!poll)
    std::abort();
  char *value = poll(owner);
  observe_pressure(value);
  if (value &&
      std::strstr(value, "\"error\":\"Recording storage handoff failed\"")) {
    const char *gate = std::getenv("FORESIGHT_TEST_CAPTURE_POLL_GATE");
    if (private_fixture_path(gate, "hold-capture-poll") && unlink(gate) == 0)
      evidence("FORESIGHT_TEST_RECORDING_WRITE_RELEASED",
               "recording-write-released");
  }
  return value;
}

// The linked production library supplies every other native entry point.
// Keep the legacy result hold scoped to this fixture until real capture stops.
extern "C" char *fs_event_poll(void *handle, int timeout) {
  const char *gate = std::getenv("FORESIGHT_TEST_CAPTURE_POLL_GATE");
  const char *ready = std::getenv("FORESIGHT_TEST_CAPTURE_READY");
  if (gate && ready && access(gate, F_OK) == 0 && access(ready, F_OK) != 0)
    return nullptr;
  using Poll = char *(*)(void *, int);
  static const Poll poll = [] {
    auto function =
        reinterpret_cast<Poll>(dlsym(real_image(), "fs_event_poll"));
    if (!function) {
      std::fputs(dlerror(), stderr);
      std::abort();
    }
    return function;
  }();
  return poll(handle, timeout);
}

// Owned polling must be held at its public entry point too. Darwin binds the
// production library's internal legacy call locally, so overriding only the
// legacy export does not hold fs_owned_event_poll.
extern "C" char *fs_owned_event_poll(uint64_t owner, int timeout) {
  const char *gate = std::getenv("FORESIGHT_TEST_CAPTURE_POLL_GATE");
  const char *ready = std::getenv("FORESIGHT_TEST_CAPTURE_READY");
  if (gate && ready && access(gate, F_OK) == 0 && access(ready, F_OK) != 0)
    return nullptr;
  using Poll = char *(*)(uint64_t, int);
  static const Poll poll = [] {
    void *library = dlopen(std::getenv("FORESIGHT_TEST_REAL_NATIVE"), RTLD_NOW);
    if (!library) {
      std::fputs(dlerror(), stderr);
      std::abort();
    }
    auto function =
        reinterpret_cast<Poll>(dlsym(library, "fs_owned_event_poll"));
    if (!function) {
      std::fputs(dlerror(), stderr);
      std::abort();
    }
    return function;
  }();
  return poll(owner, timeout);
}
namespace {
ssize_t controlled_pwrite(int fd, const void *data, size_t count,
                          off_t offset) {
  hold_owned_pcm_write(fd, offset);
#ifdef __APPLE__
  // dyld excludes the interposing image's own direct calls. RTLD_NEXT may
  // return an interposed function pointer and recurse on this platform.
  return ::pwrite(fd, data, count, offset);
#else
  using Write = ssize_t (*)(int, const void *, size_t, off_t);
  static const auto original =
      reinterpret_cast<Write>(dlsym(RTLD_NEXT, "pwrite"));
  if (!original)
    std::abort();
  return original(fd, data, count, offset);
#endif
}

} // namespace
#ifdef __APPLE__
__attribute__((used)) static const struct {
  const void *replacement;
  const void *original;
} recording_write_interpose __attribute__((section("__DATA,__interpose"))) = {
    reinterpret_cast<const void *>(&controlled_pwrite),
    reinterpret_cast<const void *>(&pwrite)};
#else
extern "C" ssize_t pwrite(int fd, const void *data, size_t count,
                          off_t offset) {
  return controlled_pwrite(fd, data, count, offset);
}
#endif
