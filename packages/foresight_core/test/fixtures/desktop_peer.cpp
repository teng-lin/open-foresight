#include <cerrno>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// A dedicated executable for real OS peer-identity tests. Its stdin/stdout are
// the controlled fixture's wire stream; it has no ability to impersonate a
// different executable or override credentials on the accepted Unix socket.
int main(int argc, char **argv) {
  if (argc != 2 || std::strlen(argv[1]) >= sizeof(sockaddr_un::sun_path))
    return 2;
  const int peer = socket(AF_UNIX, SOCK_STREAM, 0);
  if (peer < 0)
    return 3;
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strcpy(address.sun_path, argv[1]);
  if (connect(peer, reinterpret_cast<sockaddr *>(&address), sizeof(address)) !=
      0)
    return 4;
  pollfd streams[2]{{STDIN_FILENO, POLLIN, 0}, {peer, POLLIN, 0}};
  char bytes[16384];
  while (true) {
    if (poll(streams, 2, -1) < 0) {
      if (errno == EINTR)
        continue;
      return 5;
    }
    for (int i = 0; i < 2; ++i) {
      if ((streams[i].revents & (POLLIN | POLLHUP | POLLERR)) == 0)
        continue;
      const auto count = read(streams[i].fd, bytes, sizeof(bytes));
      if (count <= 0) {
        close(peer);
        return 0;
      }
      ssize_t offset = 0;
      const int output = i == 0 ? peer : STDOUT_FILENO;
      while (offset < count) {
        const auto sent = write(output, bytes + offset, count - offset);
        if (sent < 0 && errno == EINTR)
          continue;
        if (sent <= 0)
          return 6;
        offset += sent;
      }
    }
  }
}
