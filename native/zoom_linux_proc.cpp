#include "zoom_linux_proc.h"

#include <cerrno>
#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>

namespace foresight::zoom {
namespace {

std::string version_beside(const std::string &executable) {
  const auto slash = executable.rfind('/');
  if (slash == std::string::npos)
    return "";
  std::ifstream input(executable.substr(0, slash) + "/version.txt");
  std::string line;
  std::getline(input, line);
  if (line.size() > 64 || line.find_first_of("\r\n\t") != std::string::npos)
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

} // namespace foresight::zoom
