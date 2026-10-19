#include "../../native/foresight_native.cpp"
#include <iostream>

int main(int argc, char **argv) {
  const int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  if (argc > 1 && std::string(argv[1]) == "--callback-worker") {
    std::cout << "output" << std::flush;
    for (;;)
      pause();
  }
  setenv("FORESIGHT_HELPER", argv[0], 1);
  setenv("PATH", "/untrusted/capture-bin", 1);
  if (capture_runtime_command("") != argv[0] ||
      capture_runtime_command("/explicit/capture-runtime") !=
          "/explicit/capture-runtime")
    return 3;
  setenv("FORESIGHT_CAPTURE_RUNTIME", "relative/capture-runtime", 1);
  if (fs_capture_start("auto", 0, 48000) != nullptr)
    return 4;
  unsetenv("FORESIGHT_CAPTURE_RUNTIME");
  Worker worker;
  bool threw = false;
  try {
    run(worker, {capture_runtime_command(""), "--callback-worker"},
        [](const char *, size_t) {
          throw std::runtime_error("callback failure");
        });
  } catch (const std::runtime_error &) {
    threw = true;
  }
  worker.stop(); // Must never dereference an OwnedSpawn from the unwound run.
  if (!threw || worker.owned_process || worker.pid != -1)
    return 1;
  int status;
  if (waitpid(-1, &status, WNOHANG) != -1 || errno != ECHILD)
    return 2;
  return 0;
}
