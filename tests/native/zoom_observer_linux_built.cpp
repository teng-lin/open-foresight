// CTest `zoom_observer_linux_built`: makes the presence of the libatspi helper
// visible in test output. With the helper's path it starts the real binary once
// (stdin at end of file, empty environment), checks that it greets with `hello`
// and exits 0; with --not-built it reports Skipped (exit 77).
//
// This is our own executable on purpose: sanitizer runs preload their runtime
// into every process CTest starts, and an uninstrumented system binary such as
// cmake or sh can crash with it.
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <poll.h>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

namespace {

int checks = 0, failures = 0;

void check(bool value, const char *what) {
  ++checks;
  if (!value) {
    ++failures;
    std::cerr << "FAIL: " << what << '\n';
  }
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::strcmp(argv[1], "--not-built") == 0) {
    std::cerr << "SKIP: atspi-2, gio-2.0 or dbus-1 development files are "
                 "missing, so zoom_observer_linux was not built\n";
    return 77;
  }
  if (argc != 2) {
    std::cerr
        << "usage: zoom_observer_linux_built_check (HELPER | --not-built)\n";
    return 2;
  }
  int out[2];
  if (pipe(out) != 0)
    return 2;
  const pid_t child = fork();
  if (child == 0) {
    const int null = open("/dev/null", O_RDONLY);
    dup2(null, 0);
    dup2(out[1], 1);
    close(out[0]);
    close(out[1]);
    char *const arguments[] = {argv[1], const_cast<char *>("--protocol"),
                               const_cast<char *>("1"), nullptr};
    char *const environment[] = {nullptr};
    execve(argv[1], arguments, environment);
    _exit(127);
  }
  close(out[1]);
  std::string output;
  pollfd descriptor{out[0], POLLIN, 0};
  while (output.find('\n') == std::string::npos &&
         poll(&descriptor, 1, 5000) > 0) {
    char chunk[512];
    const ssize_t n = read(out[0], chunk, sizeof(chunk));
    if (n <= 0)
      break;
    output.append(chunk, static_cast<size_t>(n));
  }
  // Keep the read end open until the helper has exited: closing it earlier is a
  // hang-up the helper rightly answers with exit 3.
  int status = 0;
  bool exited = false;
  for (int waited_ms = 0; waited_ms < 5000 && !exited; waited_ms += 10) {
    exited = waitpid(child, &status, WNOHANG) == child;
    if (!exited)
      usleep(10000);
  }
  if (!exited) {
    kill(child, SIGKILL);
    waitpid(child, &status, 0);
  }
  close(out[0]);
  check(output.find("\"type\":\"hello\"") != std::string::npos &&
            output.find("\"helper\":\"zoom_observer_linux\"") !=
                std::string::npos,
        "the helper starts and greets with hello");
  check(exited && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "and exits 0 at end of input");
  std::cout << "zoom_observer_linux_built: " << checks << " checks, "
            << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
