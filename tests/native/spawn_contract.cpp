#include "../../services/helper/child_process.h"
#include <cstring>
#include <iostream>
#include <stdexcept>

int main(int argc, char **argv) {
  const int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  if (argc == 3 && std::string(argv[1]) == "--check-worker") {
    const int leaked = std::stoi(argv[2]);
    struct sigaction action{};
    sigaction(SIGPIPE, nullptr, &action);
    sigset_t mask;
    pthread_sigmask(SIG_SETMASK, nullptr, &mask);
    const bool valid = fcntl(leaked, F_GETFD) < 0 && errno == EBADF &&
                       action.sa_handler == SIG_DFL &&
                       !sigismember(&mask, SIGUSR1) && getpgrp() == getpid();
    const char *result = valid ? "OK" : "FAIL";
    (void)!write(STDOUT_FILENO, result, strlen(result));
    char byte;
    (void)!read(STDIN_FILENO, &byte, 1);
    return valid ? 0 : 1;
  }
  try {
    const auto executable = foresight::executable_path().string();
    setenv("FORESIGHT_HELPER", executable.c_str(), 1);
    signal(SIGPIPE, SIG_IGN);
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGUSR1);
    pthread_sigmask(SIG_BLOCK, &mask, nullptr);
    int input[2], output[2];
    if (pipe(input) || pipe(output))
      throw std::runtime_error("pipe failed");
    const int host = open("/dev/null", O_RDONLY);
    const int leaked = fcntl(host, F_DUPFD, 80);
    close(host);
    if (leaked < 0)
      throw std::runtime_error("host descriptor failed");
    {
      ChildProcess child(executable, "--check-worker", std::to_string(leaked),
                         input[0], output[1]);
      close(input[0]);
      close(output[1]);
      pollfd ready{output[0], POLLIN, 0};
      if (poll(&ready, 1, 5000) <= 0)
        throw std::runtime_error("child did not report");
      char report[4]{};
      const auto size = read(output[0], report, sizeof(report));
      if (std::string(report, size > 0 ? size : 0) != "OK")
        throw std::runtime_error("child inherited descriptors or signals");
      child.stop();
    }
    close(input[1]);
    close(output[0]);
    close(leaked);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
