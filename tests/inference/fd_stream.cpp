#include "fd_stream.h"
#include <csignal>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <string>
#define REQUIRE(x)                                                             \
  do {                                                                         \
    if (!(x))                                                                  \
      throw std::runtime_error(#x);                                            \
  } while (0)
int main() {
  try {
    FILE *file = tmpfile();
    REQUIRE(file);
    const std::string payload =
        "{\"result\":\"" + std::string(100000, 'x') + "\"}\n";
    {
      FdStreamBuffer buffer(dup(fileno(file)));
      std::ostream stream(&buffer);
      stream << payload << std::flush;
      REQUIRE(stream.good());
    }
    REQUIRE(fseek(file, 0, SEEK_SET) == 0);
    std::string readback(payload.size(), '\0');
    REQUIRE(fread(readback.data(), 1, readback.size(), file) ==
            readback.size());
    REQUIRE(readback == payload);
    fclose(file);
    signal(SIGPIPE, SIG_IGN);
    int pipefd[2];
    REQUIRE(pipe(pipefd) == 0);
    close(pipefd[0]);
    FdStreamBuffer broken(pipefd[1]);
    std::ostream output(&broken);
    output << "closed reader" << std::flush;
    REQUIRE(output.bad());
    std::cout
        << "Portable protocol descriptor ownership and failure checks passed\n";
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
