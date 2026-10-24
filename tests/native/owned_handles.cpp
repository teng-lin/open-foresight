#include "../../native/foresight_native.cpp"
#include <filesystem>
#include <iostream>
#include <stdexcept>

void check(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
template <class Predicate> void until(Predicate predicate) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!predicate()) {
    check(std::chrono::steady_clock::now() < deadline,
          "bounded owner settlement");
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
}
struct HeldWorker {
  struct Gate {
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false, released = false;
  };
  const std::shared_ptr<Gate> gate = std::make_shared<Gate>();
  std::thread start() {
    return std::thread([owned = gate] {
      std::unique_lock lock(owned->mutex);
      owned->entered = true;
      owned->changed.notify_all();
      owned->changed.wait(lock, [&] { return owned->released; });
    });
  }
  void ready() {
    std::unique_lock lock(gate->mutex);
    check(gate->changed.wait_for(lock, std::chrono::seconds(2),
                                 [&] { return gate->entered; }),
          "worker entered");
  }
  void release() {
    std::lock_guard lock(gate->mutex);
    gate->released = true;
    gate->changed.notify_all();
  }
  ~HeldWorker() {
    release();
  }
};

void generation(const char *executable) {
  auto *engine = fs_engine_create(executable, "/dev/null");
  check(engine, "engine created");
  auto *conversation =
      static_cast<Conversation *>(fs_conversation_create(engine));
  check(conversation, "conversation created");
  auto lifetime = conversation->poll_lifetime;
  HeldWorker held;
  conversation->active = true;
  conversation->thread = held.start();
  held.ready();
  std::thread poll([&] { fs_string_free(fs_event_poll(conversation, 60000)); });
  foresight::ScopeExit cleanup([&] {
    held.release();
    // Revoke/wake even on an earlier assertion failure.
    fs_engine_retire(engine);
    if (poll.joinable())
      poll.join();
  });
  until([&] {
    if (lifetime->gate.try_lock()) {
      lifetime->gate.unlock();
      return false;
    }
    return true;
  });
  const auto start = std::chrono::steady_clock::now();
  const auto engine_token = fs_engine_retire(engine);
  const auto child_token = fs_conversation_retire(conversation);
  check(engine_token && child_token, "native tokens returned");
  check(std::chrono::steady_clock::now() - start <
            std::chrono::milliseconds(100),
        "retirement request must not join held worker/poll");
  check(fs_engine_retire(engine) == engine_token &&
            fs_conversation_retire(conversation) == child_token,
        "repeated close joins one identity");
  check(fs_conversation_create(engine) == nullptr, "parent admission revoked");
  check(fs_generation_cancel(conversation) == -1, "child admission revoked");
  check(fs_event_poll(conversation, 0) == nullptr, "late poll rejected");
  check(fs_operation_status(child_token) == 0 &&
            fs_operation_status(engine_token) == 0 &&
            fs_operation_release(child_token) == -1,
        "held destruction cannot publish or release completion");
  held.release();
  poll.join();
  until([&] { return fs_operation_status(engine_token) == 1; });
  check(fs_operation_status(child_token) == 1, "child cleanup precedes parent");
  // No caller retained a pointer-bearing work packet or worker acknowledgement.
  check(fs_operation_release(child_token) == 0 &&
            fs_operation_release(engine_token) == 0 &&
            fs_operation_status(child_token) == -1,
        "late token observation and exact release");
}
void media() {
  auto speech = std::make_unique<Speech>();
  HeldWorker speech_worker;
  speech->thread = speech_worker.start();
  speech_worker.ready();
  auto *speech_handle = publish_native(std::move(speech), NativeKind::speech);
  const auto speech_token = fs_speech_retire(speech_handle);
  check(speech_token && fs_operation_status(speech_token) == 0,
        "speech retirement retains held worker");
  speech_worker.release();
  until([&] { return fs_operation_status(speech_token) == 1; });
  check(fs_operation_release(speech_token) == 0, "speech completion released");

  auto capture = std::make_unique<Capture>();
  HeldWorker capture_worker;
  capture->thread = capture_worker.start();
  capture_worker.ready();
  capture->emit("final-pcm");
  auto *capture_handle =
      publish_native(std::move(capture), NativeKind::capture);
  const auto finish_token = fs_capture_finish_async(capture_handle);
  check(finish_token && fs_operation_status(finish_token) == 0,
        "capture finish retains held callback");
  capture_worker.release();
  until([&] { return fs_operation_status(finish_token) == 1; });
  auto *frame = fs_event_poll(capture_handle, 0);
  check(frame && std::string(frame) == "final-pcm",
        "finished capture retains final PCM");
  fs_string_free(frame);
  const auto retire_token = fs_capture_retire(capture_handle);
  check(retire_token && fs_event_poll(capture_handle, 0) == nullptr,
        "capture retirement revokes polling");
  until([&] { return fs_operation_status(retire_token) == 1; });
  check(fs_operation_release(finish_token) == 0 &&
            fs_operation_release(retire_token) == 0,
        "capture finish and actual destruction are separate");
}
void speech_exit() {
  auto speech = std::make_unique<Speech>();
  HeldWorker held;
  speech->thread = held.start();
  held.ready();
  auto *handle = publish_native(std::move(speech), NativeKind::speech);
  {
    NativeUse use(handle, NativeKind::speech);
    check(bool(use) && prepare_native_speech_join(use.control),
          "speech join prepared");
  }
  static_cast<Speech *>(handle)->emit("done-before-thread-exit");
  fs_string_free(fs_event_poll(handle, 0));
  const auto start = std::chrono::steady_clock::now();
  const auto joined = fs_speech_join_async(handle);
  check(joined && std::chrono::steady_clock::now() - start <
                      std::chrono::milliseconds(100),
        "speech join request must not block the caller");
  until([&] {
    const auto operation = native_handles().operations.find(joined);
    return operation->state.load() == NativeOperation::State::running ||
           operation->terminal();
  });
  check(fs_operation_status(joined) == 0, "done receipt is not worker exit");
  const auto retired = fs_speech_retire(handle);
  check(retired && fs_operation_status(retired) == 0,
        "speech handle remains owned through actual worker exit");
  held.release();
  until([&] { return fs_operation_status(retired) == 1; });
  check(fs_operation_status(joined) == 1,
        "join completion precedes destruction");
  check(fs_operation_release(joined) == 0 && fs_operation_release(retired) == 0,
        "speech join and destruction acknowledge independently");
}
void held_api(const char *executable) {
  auto *engine = fs_engine_create(executable, "/dev/null");
  check(engine, "leased engine created");
  uint64_t token = 0;
  {
    NativeUse held(engine, NativeKind::engine);
    check(bool(held), "actual API lease admitted");
    token = fs_engine_retire(engine);
    check(token && fs_operation_status(token) == 0,
          "retirement cannot destroy an admitted API call");
    check(fs_engine_state(engine) == nullptr, "later API lease refused");
  }
  until([&] { return fs_operation_status(token) == 1; });
  check(fs_operation_release(token) == 0, "API lease settlement joined");
}
int main(int argc, char **argv) {
  const int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  if (argc > 1 && std::string(argv[1]) == "--model") {
    std::ofstream(std::getenv("FORESIGHT_OWNED_PROBE_MARKER"))
        << getpid() << std::endl;
    close(STDOUT_FILENO);
    for (;;)
      pause();
  }
  setenv("FORESIGHT_HELPER", argv[0], 1);
  try {
    check(fs_abi_version() == 1 && fs_lifetime_version() == 1,
          "separate ABI negotiation");
    generation(argv[0]);
    media();
    speech_exit();
    held_api(argv[0]);
    const char *scratch = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
    check(scratch, "private fixture root required");
    const auto marker = std::filesystem::path(scratch) /
                        ("owned-probe-" + std::to_string(getpid()));
    foresight::ScopeExit cleanup([&] { std::filesystem::remove(marker); });
    setenv("FORESIGHT_OWNED_PROBE_MARKER", marker.c_str(), 1);
    auto *engine = fs_engine_create_backend(argv[0], "/dev/null", 1);
    check(engine, "probe engine created");
    const auto probe = fs_engine_probe_async(engine);
    until([&] { return std::filesystem::exists(marker); });
    pid_t child = -1;
    std::ifstream(marker) >> child;
    check(child > 0, "actual probe child admitted");
    const auto retire = fs_engine_retire(engine);
    until([&] { return fs_operation_status(retire) == 1; });
    check(fs_operation_status(probe) == 2, "cancelled native probe settles");
    check(kill(child, 0) == -1 && errno == ESRCH,
          "probe child actually reaped");
    check(fs_operation_release(probe) == 0 && fs_operation_release(retire) == 0,
          "probe ownership independent of initiating acknowledgement");
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
