#include "zoom_linux_proc.h"

#include <cerrno>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace foresight::zoom {
namespace {

// The first line of a small regular file, or "" when it is missing, not a
// regular file (a FIFO must not block the scan), unreadable or malformed.
std::string version_beside(const std::string &executable) {
  const auto slash = executable.rfind('/');
  if (slash == std::string::npos)
    return "";
  const std::string path = executable.substr(0, slash) + "/version.txt";
  const int fd =
      open(path.c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return "";
  struct stat info{};
  char buffer[66];
  ssize_t length = -1;
  if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size <= 4096)
    length = read(fd, buffer, sizeof(buffer) - 1);
  close(fd);
  if (length <= 0)
    return "";
  std::string line(buffer, static_cast<size_t>(length));
  line.resize(line.find('\n') == std::string::npos ? line.size()
                                                   : line.find('\n'));
  if (line.size() > 64 || line.find_first_of("\r\t") != std::string::npos)
    return "";
  return line;
}

} // namespace

ProcessScan scan_zoom_processes(const std::string &proc_root,
                                const std::string &executable_name, uid_t uid) {
  ProcessScan scan;
  DIR *proc = opendir(proc_root.c_str());
  if (!proc) {
    scan.ok = false;
    return scan;
  }
  while (const dirent *entry = readdir(proc)) {
    char *end = nullptr;
    const long pid = std::strtol(entry->d_name, &end, 10);
    if (*end != '\0' || pid <= 0)
      continue;
    const std::string base = proc_root + "/" + entry->d_name;
    struct stat info{};
    if (stat(base.c_str(), &info) != 0 || info.st_uid != uid)
      continue; // gone, or another user's
    char target[4096];
    const ssize_t length =
        readlink((base + "/exe").c_str(), target, sizeof(target) - 1);
    if (length < 0) {
      if (errno != ENOENT && errno != ENOTDIR && errno != ESRCH &&
          errno != EACCES && errno != EPERM)
        scan.ok = false;
      continue;
    }
    if (length == 0)
      continue;
    std::string executable(target, static_cast<std::size_t>(length));
    static const std::string kDeleted = " (deleted)";
    if (executable.size() > kDeleted.size() &&
        executable.compare(executable.size() - kDeleted.size(), kDeleted.size(),
                           kDeleted) == 0)
      executable.resize(executable.size() - kDeleted.size());
    const auto slash = executable.rfind('/');
    if (executable.substr(slash == std::string::npos ? 0 : slash + 1) !=
        executable_name)
      continue;
    scan.processes.push_back(
        {static_cast<int>(pid), version_beside(executable)});
  }
  closedir(proc);
  return scan;
}

std::string safe_session_bus_address(const std::string &configured) {
  std::string kept;
  size_t start = 0;
  while (start <= configured.size()) {
    size_t end = configured.find(';', start);
    if (end == std::string::npos)
      end = configured.size();
    const std::string entry = configured.substr(start, end - start);
    if (entry.compare(0, 5, "unix:") == 0 && entry.size() > 5) {
      if (!kept.empty())
        kept += ';';
      kept += entry;
    }
    start = end + 1;
  }
  return kept;
}

} // namespace foresight::zoom
