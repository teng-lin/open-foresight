#pragma once
#include <chrono>
#include <fcntl.h>
#include <fstream>
#include <string>
#include <thread>
#include <unistd.h>

// Only the dedicated synthetic worker links this barrier. The production
// supervisor and shipped worker have no test scheduling controls.
inline std::string media_exit_input_path() {
  char path[4096]{};
#ifdef __APPLE__
  if (fcntl(3, F_GETPATH, path) < 0)
    _exit(90);
#else
  auto size = readlink("/proc/self/fd/3", path, sizeof(path) - 1);
  if (size < 0)
    _exit(90);
  path[size] = 0;
#endif
  return path;
}
inline void media_exit_publish(const std::string &path,
                               const std::string &value) {
  int fd = open(path.c_str(),
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0)
    _exit(91);
  auto count = write(fd, value.data(), value.size());
  if (close(fd) || count != static_cast<ssize_t>(value.size()))
    _exit(92);
}
inline void media_exit_wait(const std::string &path) {
  auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (access(path.c_str(), F_OK) && std::chrono::steady_clock::now() < end)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  if (access(path.c_str(), F_OK))
    _exit(93);
}
inline std::string media_exit_mode(const std::string &path) {
  std::ifstream file(path + ".exit-mode");
  std::string mode;
  file >> mode;
  if (mode != "success" && mode != "overflow" && mode != "descendant")
    _exit(94);
  return mode;
}
