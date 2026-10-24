#include "../../native/capture_pcm_pipe.h"
#include <cstring>
#include <iostream>
#include <stdexcept>

void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}
int main() {
  try {
    const char *selected = getenv("TMPDIR");
    std::string pattern =
        std::string(selected ? selected : "/var/tmp") + "/capture-test-XXXXXX";
    std::vector<char> buffer(pattern.begin(), pattern.end());
    buffer.push_back(0);
    const char *created = mkdtemp(buffer.data());
    require(created, "cannot create test root");
    const std::string root = created;
    setenv("TMPDIR", root.c_str(), 1);
    std::string owned;
    {
      foresight::CapturePcmPipe pipe(true);
      require(!pipe.error && pipe.fd >= 0, "capture did not honor TMPDIR");
      owned = pipe.directory;
      require(owned.find(root + "/") == 0, "capture escaped TMPDIR");
      struct stat info{};
      require(!lstat(owned.c_str(), &info) && (info.st_mode & 0777) == 0700,
              "capture directory was public");
      require(!lstat(pipe.path.c_str(), &info) && S_ISFIFO(info.st_mode) &&
                  (info.st_mode & 0777) == 0600,
              "capture FIFO contract changed");
      require(fcntl(pipe.fd, F_GETFD) & FD_CLOEXEC, "FIFO leaked to children");
      const int writer = open(pipe.path.c_str(), O_WRONLY | O_NONBLOCK);
      require(writer >= 0, "child could not open FIFO");
      require(write(writer, "PCM", 3) == 3, "child could not write PCM");
      char pcm[3];
      require(read(pipe.fd, pcm, sizeof(pcm)) == 3 && !memcmp(pcm, "PCM", 3),
              "FIFO changed PCM bytes");
      close(writer);
    }
    require(access(owned.c_str(), F_OK) != 0, "capture directory leaked");
    const std::string link = root + "/alias";
    require(!symlink(root.c_str(), link.c_str()), "cannot create alias");
    for (const auto &bad : {std::string("relative"), std::string(""), link,
                            root + "/missing", root + "/../escape"}) {
      setenv("TMPDIR", bad.c_str(), 1);
      foresight::CapturePcmPipe pipe(true);
      require(pipe.error && pipe.fd < 0, "unsafe TMPDIR accepted");
    }
    unlink(link.c_str());
    rmdir(root.c_str());
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
