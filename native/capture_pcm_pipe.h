#pragma once
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace foresight {
// pw-record diagnostics are not PCM. The FIFO has one operation owner, and its
// private parent remains anchored until capture is reaped and drained.
struct CapturePcmPipe {
  std::string directory, path, name;
  int fd = -1, error = 0, parent = -1, owned_directory = -1;
  explicit CapturePcmPipe(bool enabled) {
    if (!enabled)
      return;
    const char *configured = std::getenv("TMPDIR");
#ifdef __APPLE__
    constexpr const char *fallback = "/private/var/tmp";
#else
    constexpr const char *fallback = "/var/tmp";
#endif
    const std::string base = configured ? configured : fallback;
    if (base.empty() || base[0] != '/' || base.size() > PATH_MAX - 64) {
      error = EINVAL;
      return;
    }
    // Refuse symlinks and untrusted writable ancestors instead of following a
    // path that another user can swap between validation and child startup.
    parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    size_t begin = 1;
    while (parent >= 0 && begin < base.size()) {
      const size_t end = base.find('/', begin);
      const auto component = base.substr(begin, end - begin);
      begin = end == std::string::npos ? base.size() : end + 1;
      if (component.empty() || component == ".")
        continue;
      if (component == "..") {
        error = EINVAL;
        return;
      }
      int next = openat(parent, component.c_str(),
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (next < 0) {
        error = errno;
        return;
      }
      close(parent);
      parent = next;
      struct stat info{};
      if (fstat(parent, &info) ||
          (info.st_uid != getuid() && info.st_uid != 0) ||
          ((info.st_mode & 0022) &&
           !(info.st_uid == 0 && (info.st_mode & S_ISVTX)))) {
        error = EACCES;
        return;
      }
    }
    if (parent < 0) {
      error = errno;
      return;
    }
    // mkdtemp provides exclusive, unpredictable 0700 creation. The validated
    // ancestor chain prevents another user from moving that owned directory.
    std::string pattern = base + "/foresight-capture-XXXXXX";
    std::vector<char> buffer(pattern.begin(), pattern.end());
    buffer.push_back('\0');
    const char *created = mkdtemp(buffer.data());
    if (!created) {
      error = errno;
      return;
    }
    directory = created;
    name = directory.substr(directory.find_last_of('/') + 1);
    owned_directory = openat(parent, name.c_str(),
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (owned_directory < 0) {
      error = errno;
      return;
    }
    struct stat info{};
    if (fstat(owned_directory, &info) || info.st_uid != getuid() ||
        (info.st_mode & 0777) != 0700) {
      error = EACCES;
      return;
    }
    path = directory + "/audio.raw";
    if (mkfifoat(owned_directory, "audio.raw", 0600) < 0) {
      error = errno;
      return;
    }
    // Keep a nonblocking writer alive so a slow child open does not look like
    // EOF. The writer belongs to this capture, not an unrelated process.
    fd = openat(owned_directory, "audio.raw",
                O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
      error = errno;
  }
  CapturePcmPipe(const CapturePcmPipe &) = delete;
  CapturePcmPipe &operator=(const CapturePcmPipe &) = delete;
  ~CapturePcmPipe() {
    if (fd >= 0)
      close(fd);
    if (owned_directory >= 0) {
      unlinkat(owned_directory, "audio.raw", 0);
      close(owned_directory);
    }
    if (parent >= 0) {
      if (!name.empty())
        unlinkat(parent, name.c_str(), AT_REMOVEDIR);
      close(parent);
    }
  }
};
} // namespace foresight
