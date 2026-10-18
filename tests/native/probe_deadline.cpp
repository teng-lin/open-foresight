#include "foresight_native.h"
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc.h>
#endif
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;
void check(bool value) {
  if (!value)
    throw std::runtime_error("Probe deadline assertion failed");
}
// A killed descendant can briefly remain a zombie until the system reaps it.
// The supervisor reaps the direct worker; descendants must no longer execute.
bool dead(pid_t pid) {
  if (kill(pid, 0) == -1 && errno == ESRCH)
    return true;
#ifdef __APPLE__
  proc_bsdinfo info{};
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) ==
             sizeof(info) &&
         info.pbi_status == SZOMB;
#else
  std::ifstream input("/proc/" + std::to_string(pid) + "/stat");
  std::string line;
  std::getline(input, line);
  const auto end = line.find_last_of(')');
  return end != std::string::npos && line[end + 2] == 'Z';
#endif
}
int main(int argc, char **argv) {
  const fs::path root = std::getenv("FORESIGHT_PROBE_FIXTURE_ROOT")
                            ? std::getenv("FORESIGHT_PROBE_FIXTURE_ROOT")
                            : "";
  if (argc > 1 && std::string(argv[1]) == "--model") {
    if (fs::exists(root / "succeed"))
      return 0;
    const pid_t child = fork();
    if (child < 0)
      return 2;
    if (child == 0)
      for (;;)
        pause();
    std::ofstream(root / "pids") << getpid() << ' ' << child << std::endl;
    // Exercise the wait-for-exit path after stdout closes as well as read
    // polling.
    close(STDOUT_FILENO);
    for (;;)
      pause();
  }
  const char *scratch = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
  const auto directory = fs::path(scratch ? scratch : "/tmp") /
                         ("probe-deadline-" + std::to_string(getpid()));
  void *engine = nullptr;
  try {
    fs::create_directories(directory);
    setenv("FORESIGHT_PROBE_FIXTURE_ROOT", directory.c_str(), 1);
    setenv("FORESIGHT_PROBE_TIMEOUT_MS", "250", 1);
    std::ofstream(directory / "model") << "fixture";
    engine = fs_engine_create_backend(fs::absolute(argv[0]).c_str(),
                                      (directory / "model").c_str(), 1);
    check(engine);
    const auto start = std::chrono::steady_clock::now();
    check(fs_engine_probe(engine) == -1);
    const auto elapsed = std::chrono::steady_clock::now() - start;
    check(elapsed >= std::chrono::milliseconds(200));
    check(elapsed < std::chrono::seconds(2));
    char *raw = fs_engine_state(engine);
    check(raw);
    const auto state = nlohmann::json::parse(raw);
    fs_string_free(raw);
    check(state.at("state") == "failed");
    check(state.at("error").get<std::string>().find("timed out") !=
          std::string::npos);
    pid_t worker = -1, child = -1;
    std::ifstream(directory / "pids") >> worker >> child;
    check(worker > 0 && child > 0);
    check(kill(worker, 0) == -1 && errno == ESRCH);
    check(dead(child));
    std::ofstream(directory / "succeed") << "ready";
    check(fs_engine_probe(engine) == 0);
    check(fs_engine_destroy(engine) == 0);
    engine = nullptr;
    fs::remove_all(directory);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    if (engine)
      fs_engine_destroy(engine);
    fs::remove_all(directory);
    return 1;
  }
}
