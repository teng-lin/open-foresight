#include "model.h"
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc.h>
#endif
#include <chrono>
#include <iostream>
#include <memory>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

static bool dead(pid_t pid) {
#ifdef __APPLE__
  proc_bsdinfo info{};
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_status == SZOMB;
#else
  std::ifstream status("/proc/" + std::to_string(pid) + "/stat");
  std::string line;
  std::getline(status, line);
  if (line.empty())
    return true;
  auto state = line.find_last_of(')');
  return state != std::string::npos && line[state + 2] == 'Z';
#endif
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
#ifdef __APPLE__
  int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0) return supervised;
  setenv("FORESIGHT_HELPER", foresight::executable_path().c_str(), 1);
#endif
  std::string directory =
      (fs::temp_directory_path().string()+"/foresight-model-lifetime-") + std::to_string(getpid());
  fs::create_directories(directory + "/stubborn");
  try {
    REQUIRE(argc == 2);
    setenv("FORESIGHT_MODEL_WORKER", argv[1], 1);
    std::unique_ptr<Model> model;
    std::thread request(
        [&] { model = std::make_unique<Model>(directory, false); });
    request.join();
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    REQUIRE(model->available());
    REQUIRE(model->embed("after creator request thread retired").size() == 4);
    REQUIRE(model->decode(model->encode("hello")) == "hello");

    // Closing the frontend's stderr reader must not break persistent inference.
    int broken[2];
    REQUIRE(foresight::cloexec_pipe(broken) == 0);
    close(broken[0]);
    int saved = dup(STDERR_FILENO);
    REQUIRE(saved >= 0);
    REQUIRE(dup2(broken[1], STDERR_FILENO) >= 0);
    close(broken[1]);
    auto independent = std::make_unique<Model>(directory, false);
    REQUIRE(dup2(saved, STDERR_FILENO) >= 0);
    close(saved);
    REQUIRE(independent->embed("former stderr reader is gone").size() == 4);
    independent.reset();

    pid_t worker = model->worker_pid();
    REQUIRE(worker > 0);
    REQUIRE(kill(worker, SIGKILL) == 0);
    for (int i = 0; i < 100 && model->available(); i++)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    REQUIRE(!model->available());
    bool rejected = false;
    try {
      model->embed("must reject dead worker");
    } catch (const std::exception &) {
      rejected = true;
    }
    REQUIRE(rejected);
    model.reset();

    auto stubborn = std::make_unique<Model>(directory + "/stubborn", false);
    pid_t stubborn_pid = stubborn->worker_pid();
    auto before = std::chrono::steady_clock::now();
    stubborn.reset();
    REQUIRE(std::chrono::steady_clock::now() - before <
            std::chrono::seconds(3));
    REQUIRE(dead(stubborn_pid));

    // Killing the entire helper still terminates the adapter, even though the
    // transient thread that requested the model has already returned.
    int report[2];
    REQUIRE(foresight::cloexec_pipe(report) == 0);
    pid_t owner = fork();
    REQUIRE(owner >= 0);
    if (owner == 0) {
      close(report[0]);
      std::unique_ptr<Model> child;
      std::thread create(
          [&] { child = std::make_unique<Model>(directory, false); });
      create.join();
      pid_t adapter = child->worker_pid();
      if (write(report[1], &adapter, sizeof(adapter)) != sizeof(adapter))
        _exit(2);
      close(report[1]);
      for (;;)
        pause();
    }
    close(report[1]);
    pid_t adapter = -1;
    REQUIRE(read(report[0], &adapter, sizeof(adapter)) == sizeof(adapter));
    close(report[0]);
    REQUIRE(adapter > 0);
    kill(owner, SIGKILL);
    waitpid(owner, nullptr, 0);
    for (int i = 0; i < 100 && !dead(adapter); i++)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    REQUIRE(dead(adapter));
#ifdef __APPLE__
    // Kill owners throughout launch, including before supervisor exec and
    // before adapter readiness. Every fixture that starts records its PID.
    const auto launch_log = directory + "/launch-pids";
    setenv("FORESIGHT_FIXTURE_PID_LOG", launch_log.c_str(), 1);
    for (int delay : {0, 1, 3, 8, 15, 30, 60, 250}) {
      pid_t racing = fork();
      REQUIRE(racing >= 0);
      if (racing == 0) {
        try { Model launching(directory + "/stubborn", false); for (;;) pause(); }
        catch (...) { _exit(2); }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(delay));
      kill(racing, SIGKILL);
      waitpid(racing, nullptr, 0);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    std::ifstream launches(launch_log);
    pid_t launched = -1;
    int observed = 0;
    while (launches >> launched) {
      ++observed;
      for (int i = 0; i < 100 && !dead(launched); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      REQUIRE(dead(launched));
    }
    REQUIRE(observed > 0);
    unsetenv("FORESIGHT_FIXTURE_PID_LOG");
#endif
    fs::remove_all(directory);
    std::cout << "model ownership, dead-worker detection and bounded cleanup "
                 "passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << "\n";
    fs::remove_all(directory);
    return 1;
  }
}
