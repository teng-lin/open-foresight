#define FORESIGHT_ENABLE_TEST_HOOKS 1
#include "../../native/foresight_native.cpp"
#include <filesystem>
#include <future>
#include <iostream>
#include <stdexcept>
// Force one Engine address to be reused while its old ID/token is still live.
// Other allocations remain ordinary; no production allocator hook is added.
std::atomic<void *> capture_engine_free{nullptr}, reusable_engine{nullptr};
std::atomic<bool> hold_engine_delete{false};
void *operator new(std::size_t size) {
  if (size == sizeof(Engine))
    if (auto *value = reusable_engine.exchange(nullptr))
      return value;
  if (auto *value = std::malloc(size ? size : 1))
    return value;
  throw std::bad_alloc{};
}
void operator delete(void *value) noexcept {
  if (!value)
    return;
  auto *expected = value;
  if (capture_engine_free.compare_exchange_strong(expected, nullptr)) {
    reusable_engine = value;
    while (hold_engine_delete)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return;
  }
  std::free(value);
}
void operator delete(void *value, std::size_t) noexcept {
  ::operator delete(value);
}
using namespace std::chrono_literals;
void check(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
template <class Predicate> void until(Predicate predicate) {
  const auto deadline = std::chrono::steady_clock::now() + 5s;
  while (!predicate()) {
    check(std::chrono::steady_clock::now() < deadline,
          "bounded owner settlement");
    std::this_thread::sleep_for(2ms);
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
    check(gate->changed.wait_for(lock, 2s, [&] { return gate->entered; }),
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
std::shared_ptr<NativeControl> control(uint64_t id) {
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  return registry.owners.at(id);
}
void release_owner(uint64_t id, uint64_t token) {
  until([&] { return fs_operation_status(token) == 1; });
  check(fs_operation_release(token) == -1,
        "retire acknowledgement belongs to owner");
  check(fs_owner_release(id) == 0 && fs_operation_status(token) == -1,
        "owner release acknowledges completion metadata exactly once");
}
void run_owner_subprocess(const char *executable, const char *mode) {
  pid_t child = -1;
  char *args[] = {const_cast<char *>(executable), const_cast<char *>(mode),
                  nullptr};
  check(posix_spawn(&child, executable, nullptr, nullptr, args, environ) == 0,
        "legacy exit subprocess started");
  int status = 0;
  check(
      waitpid(child, &status, 0) == child && WIFEXITED(status) &&
          WEXITSTATUS(status) == 0,
      std::strcmp(mode, "--live-legacy-exit") == 0
          ? "exit with a live legacy generation must not destroy joinable "
            "workers"
      : std::strcmp(mode, "--retire-admission-failure") == 0
          ? "retirement refusal must not advertise an idle parent token"
          : "mapping quarantine controls preserve refusal and actual cleanup");
}
void live_legacy_exit(const char *executable) {
  run_owner_subprocess(executable, "--live-legacy-exit");
}
void held_legacy_finalization(const char *executable) {
  auto *engine = fs_engine_create(executable, "/dev/null");
  auto *conversation = fs_conversation_create(engine);
  check(conversation, "legacy finalization fixture admitted");
  auto &worker = *static_cast<Conversation *>(conversation);
  HeldWorker held;
  worker.thread_finished = false;
  worker.thread = held.start();
  held.ready();
  // active/done is deliberately insufficient: finalization must use the
  // thread wrapper's terminal publication, without waiting for held work.
  worker.active = false;
  finalize_legacy_threads(native_handles());
  check(worker.thread.joinable(),
        "finalization retains unfinished legacy work");
  held.release();
  worker.join();
  worker.thread_finished = true;
  check(fs_conversation_destroy(conversation, 1) == 0 &&
            fs_engine_destroy(engine) == 0,
        "held legacy authority still supports actual cleanup");
}
void owned_finalization(const char *executable) {
  const auto engine = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  const auto conversation = fs_owned_conversation_create(engine);
  check(conversation, "owned finalization fixture admitted");
  auto owner = control(conversation);
  auto &worker = *static_cast<Conversation *>(owner->object.get());
  worker.thread = start_worker_thread(worker, "finalization-fixture", [] {});
  until([&] { return worker.thread_finished.load(); });
  finalize_legacy_threads(native_handles());
  check(worker.thread.joinable() && !owner->closing,
        "process finalization cannot acknowledge owned-v2 cleanup");
  release_owner(conversation, fs_conversation_retire(conversation));
  release_owner(engine, fs_engine_retire(engine));
}
void retirement_admission_failure(const char *executable) {
  run_owner_subprocess(executable, "--retire-admission-failure");
}
void legacy_failure(const char *executable) {
  auto *engine = fs_engine_create(executable, "/dev/null");
  check(engine && !native_handles().process_lifetime,
        "legacy-only admission has no asynchronous owners");
  auto owner = native_handles().handles.at(engine);
  owner->fail_cleanup_for_testing = true;
  check(fs_engine_destroy(engine) == -1 && owner->object &&
            native_handles().process_lifetime && !fs_engine_state(engine),
        "legacy cleanup exception returns sentinel and retains unconfirmed "
        "authority");
  owner->fail_cleanup_for_testing = false;
  check(fs_engine_destroy(engine) == 0 && !owner->object,
        "serialized legacy retry completes original cleanup");
  engine = fs_engine_create(executable, "/dev/null");
  auto *conversation = fs_conversation_create(engine);
  owner = native_handles().handles.at(conversation);
  owner->fail_cleanup_for_testing = true;
  check(fs_conversation_destroy(conversation, 1) == -1 &&
            fs_engine_destroy(engine) == -1,
        "failed child cleanup preserves legacy engine reference refusal");
  owner->fail_cleanup_for_testing = false;
  check(fs_conversation_destroy(conversation, 1) == 0 &&
            fs_engine_destroy(engine) == 0,
        "legacy child retry actually releases parent reference");
}
void generation(const char *executable) {
  auto engine = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  auto conversation = fs_owned_conversation_create(engine);
  check(engine && conversation, "owned generation created");
  auto child_control = control(conversation);
  auto *child = static_cast<Conversation *>(child_control->object.get());
  auto lifetime = child->poll_lifetime;
  HeldWorker held;
  child->active = true;
  child->thread = held.start();
  held.ready();
  std::atomic<bool> polled{false};
  poll_wait_boundary.pause = true;
  poll_wait_boundary.entered = false;
  poll_wait_boundary.release = false;
  std::thread poll([&] {
    fs_string_free(fs_owned_event_poll(conversation, 60000));
    polled = true;
  });
  foresight::ScopeExit cleanup([&] {
    poll_wait_boundary.pause = false;
    poll_wait_boundary.release = true;
    fs_engine_retire(engine);
    if (poll.joinable()) {
      {
        std::lock_guard lock(child->mu);
        child->cv.notify_all();
      }
      poll.join();
    }
    held.release();
  });
  until([&] { return poll_wait_boundary.entered.load(); });
  const auto start = std::chrono::steady_clock::now();
  const auto parent = fs_engine_retire(engine),
             child_token = fs_conversation_retire(conversation);
  check(parent && child_token &&
            std::chrono::steady_clock::now() - start < 100ms,
        "retire revokes without joining held worker inline");
  check(fs_engine_retire(engine) == parent &&
            fs_conversation_retire(conversation) == child_token,
        "repeat retire recovers native identity");
  check(!fs_owned_conversation_create(engine) &&
            fs_owned_generation_cancel(conversation) == -1 &&
            fs_owned_event_poll(conversation, 0) == nullptr,
        "late admission rejected");
  // The revocation notification was delivered before the waiter actually
  // waits. Only independent bounded rechecks can settle this owned poll.
  poll_wait_boundary.release = true;
  const auto poll_deadline = std::chrono::steady_clock::now() + 1s;
  while (!polled && std::chrono::steady_clock::now() < poll_deadline)
    std::this_thread::sleep_for(2ms);
  check(polled,
        "lost notification cannot strand owned poll behind its own cleanup");
  check(
      fs_operation_status(parent) == 0 && fs_operation_status(child_token) == 0,
      "poll wakes before physical held worker exit; completion stays pending");
  held.release();
  poll.join();
  until([&] { return fs_operation_status(parent) == 1; });
  check(!child_control->object && !child_control->parent &&
            !control(engine)->object,
        "completed metadata retains no physical authority");
  check(fs_conversation_retire(conversation) == child_token,
        "lost completion recovered after destruction");
  release_owner(conversation, child_token);
  release_owner(engine, parent);
  // Repeated stale IDs can never address a later owner, irrespective of address
  // reuse.
  auto next = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  auto *next_state = fs_owned_engine_state(next);
  check(next > engine && !fs_engine_retire(engine) && next_state,
        "stale owner ID never aliases new object");
  fs_string_free(next_state);
  release_owner(next, fs_engine_retire(next));
}
void independent_speech(const char *executable) {
  const auto speech = fs_owned_speech_create(executable, "/dev/null");
  check(speech && fs_owned_speech_finish(speech, "accepted") == 0,
        "real exported speech finish accepted");
  auto owner = control(speech);
  auto &worker = *static_cast<Speech *>(owner->object.get());
  until([&] { return !worker.active; });
  worker.join();
  // Hold the accepted request's post-done physical thread boundary. The real
  // exported finish prepared its immutable join node; the fixture never does.
  HeldWorker held;
  worker.thread = held.start();
  held.ready();
  const auto accepted = owner->finish;
  int16_t pcm[] = {1, 2};
  check(fs_owned_speech_push(speech, pcm, 2, 16000) == -1 &&
            fs_owned_speech_finish(speech, "before-join") == -1 &&
            owner->finish == accepted,
        "idle accepted join blocks reuse without replacing token");
  struct QueueGate {
    std::atomic<bool> entered{false}, release{false};
  };
  auto queue = std::make_shared<QueueGate>();
  foresight::ScopeExit release_queue([&] { queue->release = true; });
  auto &operations = native_handles().operations;
  auto blocker = operations.create(
      [](NativeOperation &op) {
        auto &gate = *static_cast<QueueGate *>(op.context);
        gate.entered = true;
        while (!gate.release)
          std::this_thread::sleep_for(1ms);
        return NativeOperation::Result::succeeded;
      },
      queue.get(), owner->group);
  check(operations.submit(blocker, queue), "hold exact owner queue");
  until([&] { return queue->entered.load(); });
  const auto joined = fs_speech_join_async(speech);
  check(operations.find(joined)->state == NativeOperation::State::queued &&
            fs_owned_speech_finish(speech, "queued-join") == -1 &&
            owner->finish == accepted,
        "queued join refuses reuse without changing accepted token");
  queue->release = true;
  until([&] { return operations.status(blocker->token) == 1; });
  check(operations.release(blocker->token), "fixture queue owner released");
  until([&] {
    return operations.find(joined)->state == NativeOperation::State::running;
  });
  check(fs_owned_speech_finish(speech, "during-join") == -1 &&
            owner->finish == accepted,
        "running join refuses finish and preserves exact generation");
  auto *legacy = fs_engine_create(executable, "/dev/null");
  auto closed =
      std::async(std::launch::async, [&] { return fs_engine_destroy(legacy); });
  check(closed.wait_for(1s) == std::future_status::ready && closed.get() == 0,
        "held async join never blocks legacy local close");
  uint64_t capture_id;
  void *capture;
  {
    NativeCreation owned;
    capture = publish_native(std::make_unique<Capture>(), NativeKind::capture);
    capture_id = native_identity(capture);
  }
  auto *legacy_capture =
      publish_native(std::make_unique<Capture>(), NativeKind::capture);
  auto capture_closed =
      std::async(std::launch::async, [&] { fs_capture_stop(legacy_capture); });
  const bool closed_promptly =
      capture_closed.wait_for(1s) == std::future_status::ready;
  if (!closed_promptly)
    held.release();
  check(closed_promptly, "held speech join cannot block legacy capture stop");
  capture_closed.get();
  auto finished = fs_capture_finish_async(capture_id);
  until([&] { return fs_operation_status(finished) == 1; });
  check(fs_operation_status(joined) == 0,
        "independent capture finishes while speech remains held");
  fs_capture_stop(
      capture); // legacy mixed call must not consume an owned token.
  check(fs_operation_status(finished) == 1 &&
            fs_operation_release(finished) == 0,
        "legacy raw call cannot acknowledge owned completion");
  release_owner(capture_id, fs_capture_retire(capture_id));
  held.release();
  until([&] { return fs_operation_status(joined) == 1; });
  check(fs_operation_release(joined) == 0 &&
            fs_owned_speech_push(speech, pcm, 2, 16000) == 0,
        "actual join permits reuse even after token acknowledgement");
  check(fs_owned_speech_finish(speech, "next-generation") == 0 &&
            owner->finish != accepted,
        "next generation owns a new join token");
  const auto next_join = fs_speech_join_async(speech);
  until([&] { return fs_operation_status(next_join) == 1; });
  check(fs_operation_release(next_join) == 0,
        "next request joined independently");
  release_owner(speech, fs_speech_retire(speech));
}
std::atomic<bool> fail_child{false};
NativeOperation::Result child_fault(NativeOperation &op) {
  if (fail_child)
    throw std::runtime_error("fixture child cleanup failed");
  return native_retire(op);
}
void child_failure(const char *executable) {
  auto healthy = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  auto healthy_child = fs_owned_conversation_create(healthy);
  auto healthy_speech = fs_owned_speech_create(executable, "/dev/null");
  check(healthy && healthy_child && healthy_speech,
        "healthy owners precede quarantine");
  auto engine = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  auto child = fs_owned_conversation_create(engine);
  auto parent_control = control(engine), child_control = control(child);
  std::weak_ptr<void> physical_engine = parent_control->object;
  auto &operations = native_handles().operations;
  check(operations.discard(operations.find(child_control->retire)),
        "replace unpublished fault node");
  auto replacement = operations.create(child_fault, child_control.get(),
                                       child_control->group, child);
  replacement->releases_group = true;
  child_control->retire = replacement->token;
  fail_child = true;
  auto retired = fs_engine_retire(engine);
  until([&] { return fs_operation_status(retired) != 0; });
  check(fs_operation_status(retired) == 3 &&
            fs_operation_status(child_control->retire) == 3 &&
            !physical_engine.expired() && child_control->object &&
            fs_owner_release(engine) == -1 &&
            fs_operation_release(retired) == -1,
        "unconfirmed child retains actual engine and observable authority");
  check(fs_lifetime_admission() == 0 &&
            fs_owned_engine_create(executable, "/dev/null", 0, 0) == 0 &&
            fs_owned_conversation_create(healthy) == 0 &&
            fs_owned_speech_create(executable, "/dev/null") == 0 &&
            fs_owned_capture_start("auto", 0, 16000, 0) == 0 &&
            fs_engine_probe_async(healthy) == 0 &&
            fs_owned_generate_options(healthy_child, "rejected", "fixture",
                                      nullptr, 16) == -1 &&
            fs_owned_speech_finish(healthy_speech, "rejected") == -1,
        "status3 refuses every new owned producer before physical admission");
  char *state = fs_owned_engine_state(healthy);
  check(state && !fs_owned_event_poll(healthy_child, 0) &&
            fs_owned_generation_cancel(healthy_child) == 0 &&
            fs_owned_speech_cancel(healthy_speech) == 0,
        "quarantine preserves state, poll and cancellation");
  fs_string_free(state);
  auto *legacy = fs_engine_create(executable, "/dev/null");
  check(legacy && fs_engine_destroy(legacy) == 0,
        "unconfirmed async exception cannot hang legacy destruction");
  fail_child = false;
  check(fs_engine_retire(engine) == retired,
        "explicit retry reuses cleanup identity");
  until([&] { return fs_operation_status(retired) == 1; });
  check(physical_engine.expired() && !child_control->object &&
            !child_control->parent,
        "retry actually destroys child before parent and drops authority");
  release_owner(child, child_control->retire);
  release_owner(engine, retired);
  auto healthy_retirement = fs_engine_retire(healthy);
  until([&] { return fs_operation_status(healthy_retirement) == 1; });
  release_owner(healthy_child, control(healthy_child)->retire);
  release_owner(healthy, healthy_retirement);
  release_owner(healthy_speech, fs_speech_retire(healthy_speech));
  check(fs_lifetime_admission() == 0,
        "actual cleanup never resets mapping quarantine");
}
void explicit_quarantine(const char *executable) {
  auto owner = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  check(owner && fs_lifetime_admission() == 1, "initial mapping admission");
  fs_lifetime_quarantine();
  check(fs_lifetime_admission() == 0 &&
            !fs_owned_engine_create(executable, "/dev/null", 0, 0),
        "acknowledgement uncertainty refuses new native ownership");
  release_owner(owner, fs_engine_retire(owner));
  check(fs_lifetime_admission() == 0, "quarantine persists after cleanup");
}
void speech_join_with_poll(const char *executable) {
  auto speech = fs_owned_speech_create(executable, "/dev/null");
  check(speech && fs_owned_speech_finish(speech, "poll-independent") == 0,
        "speech accepted before poll");
  auto *worker = static_cast<Speech *>(control(speech)->object.get());
  until([&] { return !worker->active; });
  worker->join();
  {
    std::lock_guard lock(worker->mu);
    worker->events.clear();
  }
  auto lifetime = worker->poll_lifetime;
  std::thread poll([&] { fs_string_free(fs_owned_event_poll(speech, 60000)); });
  until([&] {
    if (lifetime->gate.try_lock()) {
      lifetime->gate.unlock();
      return false;
    }
    return true;
  });
  auto joined = fs_speech_join_async(speech);
  const auto deadline = std::chrono::steady_clock::now() + 1s;
  while (fs_operation_status(joined) == 0 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(2ms);
  const bool independent = fs_operation_status(joined) == 1;
  worker->emit("release-future-event-poll");
  poll.join();
  until([&] { return fs_operation_status(joined) == 1; });
  check(fs_operation_release(joined) == 0,
        "speech poll fixture owns its result");
  release_owner(speech, fs_speech_retire(speech));
  check(independent, "speech join must not wait for a future event poll");
}
void owned_rollback(const char *executable) {
  auto speech = fs_owned_speech_create(executable, "/dev/null");
  check(speech, "owned rollback speech admitted");
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "speech", 1);
  check(fs_owned_speech_finish(speech, "rollback") == -1 &&
            control(speech)->speech_joined &&
            fs_owned_event_poll(speech, 0) == nullptr,
        "failed thread restores admission and queue event");
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
  check(fs_owned_speech_finish(speech, "retry") == 0,
        "failed request can be retried");
  release_owner(speech, fs_speech_retire(speech));
  auto handles = native_handles().handles.size(),
       owners = native_handles().owners.size(), polls = poll_registry().size();
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "capture", 1);
  check(!fs_owned_capture_start("auto", 0, 16000, 0) &&
            native_handles().handles.size() == handles &&
            native_handles().owners.size() == owners &&
            poll_registry().size() == polls,
        "owned capture thread failure releases every unpublished authority");
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
}
void bounds(const char *executable) {
  std::vector<uint64_t> owners;
  for (size_t n = 0; n < foresight::OwnedOperations::max_owner_groups; ++n) {
    auto id = fs_owned_engine_create(executable, "/dev/null", 0, 0);
    check(id, "32 independent live owner groups admitted");
    owners.push_back(id);
  }
  const auto handles = native_handles().handles.size(),
             polls = poll_registry().size();
  check(!fs_owned_capture_start("auto", 0, 16000, 0) &&
            native_handles().handles.size() == handles &&
            poll_registry().size() == polls,
        "33rd live owner refuses before physical capture and rolls back all "
        "metadata");
  auto *legacy = fs_engine_create(executable, "/dev/null");
  check(legacy && fs_engine_destroy(legacy) == 0,
        "owner bound cannot poison legacy admission");
  for (auto id : owners)
    release_owner(id, fs_engine_retire(id));
  auto &operations = native_handles().operations;
  std::vector<uint64_t> abandoned;
  for (size_t n = 0; n < 4096; ++n) {
    auto op = operations.create(
        [](NativeOperation &) { return NativeOperation::Result::succeeded; },
        nullptr);
    check(operations.submit(op, nullptr),
          "fill retained async record capacity");
    abandoned.push_back(op->token);
  }
  check(!fs_owned_engine_create(executable, "/dev/null", 0, 0),
        "4096 unacknowledged records refuse new owned admission");
  legacy = fs_engine_create(executable, "/dev/null");
  auto *speech = fs_speech_create(executable, "/dev/null");
  check(legacy && speech && fs_speech_finish(speech, "legacy-capacity") == 0,
        "retained async capacity does not change legacy create/finish");
  fs_speech_destroy(speech);
  check(fs_engine_destroy(legacy) == 0, "legacy cleanup remains local");
  for (auto token : abandoned) {
    until([&] { return operations.status(token) == 1; });
    check(operations.release(token), "release bounded control metadata");
  }
}
void reused_address(const char *executable) {
  auto first = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  auto *address = control(first)->object.get();
  capture_engine_free = address;
  hold_engine_delete = true;
  foresight::ScopeExit release_delete([&] { hold_engine_delete = false; });
  auto retired = fs_engine_retire(first);
  until([&] { return reusable_engine == address; });
  check(fs_operation_status(retired) == 0 &&
            fs_engine_retire(first) == retired && fs_owner_release(first) == -1,
        "retry remains coalesced during actual destruction");
  auto second = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  auto *early_state = fs_owned_engine_state(second);
  check(early_state,
        "new raw admission survives reuse before old destructor returns");
  fs_string_free(early_state);
  hold_engine_delete = false;
  until([&] { return fs_operation_status(retired) == 1; });
  check(control(second)->object.get() == address && second != first,
        "resource address actually reused while old owner metadata survives");
  check(fs_engine_retire(first) == retired,
        "lost token retry resolves old completion at reused address");
  auto *state = fs_owned_engine_state(second);
  check(state && !control(second)->closing,
        "old ID retry cannot revoke new owner");
  fs_string_free(state);
  release_owner(first, retired);
  check(!fs_engine_retire(first), "released stale identity remains unknown");
  release_owner(second, fs_engine_retire(second));
}
void capture_tail() {
  uint64_t id = 0;
  {
    NativeCreation owned;
    id = native_identity(
        publish_native(std::make_unique<Capture>(), NativeKind::capture));
  }
  auto *capture = static_cast<Capture *>(control(id)->object.get());
  HeldWorker held;
  capture->thread = held.start();
  held.ready();
  capture->emit("final-pcm");
  auto finished = fs_capture_finish_async(id);
  check(finished && fs_operation_status(finished) == 0,
        "capture finish joins held callback");
  held.release();
  until([&] { return fs_operation_status(finished) == 1; });
  auto *frame = fs_owned_event_poll(id, 0);
  check(frame && std::string(frame) == "final-pcm",
        "physical finish retains final PCM for drain");
  fs_string_free(frame);
  auto retired = fs_capture_retire(id);
  check(!fs_owned_event_poll(id, 0),
        "retirement separately revokes final queue");
  check(fs_operation_release(finished) == 0,
        "finish result independent from retire acknowledgement");
  release_owner(id, retired);
}
void shared_model_handoff(const char *executable) {
  setenv("FORESIGHT_WHISPER_WORKER", executable, 1);
  foresight::ScopeExit clear_override(
      [&] { unsetenv("FORESIGHT_WHISPER_WORKER"); });
  const auto first = fs_owned_speech_create(executable, "/dev/null");
  check(first, "persistent speech owner admitted");
  auto &speech = *static_cast<Speech *>(control(first)->object.get());
  auto *model = speech.worker_engine.get();
  std::weak_ptr<SpeechEngine> physical_model = speech.worker_engine;
  check(model, "shared speech model owned");
  model->engine.persistent = std::make_unique<PersistentGeneration>();
  HeldWorker held;
  model->engine.persistent->thread = held.start();
  held.ready();
  auto retired = fs_speech_retire(first);
  until([&] {
    std::lock_guard lock(speech_engines_mutex());
    return model->retiring;
  });
  const auto second = fs_owned_speech_create(executable, "/dev/null");
  check(second && static_cast<Speech *>(control(second)->object.get())
                          ->worker_engine.get() != model,
        "new admission never borrows a model whose final owner is retiring");
  release_owner(second, fs_speech_retire(second));
  check(fs_operation_status(retired) == 0 && !physical_model.expired(),
        "old model remains held until actual last physical worker join");
  held.release();
  release_owner(first, retired);
  check(physical_model.expired(),
        "last owner completion retains no shared model authority");
}
void independent_acknowledgements() {
  uint64_t capture;
  {
    NativeCreation owned;
    capture = native_identity(
        publish_native(std::make_unique<Capture>(), NativeKind::capture));
  }
  const auto finish = fs_capture_finish_async(capture),
             retired = fs_capture_retire(capture);
  until([&] { return fs_operation_status(retired) == 1; });
  check(
      fs_owner_release(capture) == 0 && fs_operation_status(finish) == 1,
      "owner retirement acknowledgement cannot erase finish subscriber result");
  check(fs_operation_release(finish) == 0,
        "late finish subscriber acknowledges its own result");
}
void held_api(const char *executable) {
  auto engine = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  uint64_t retired;
  {
    NativeOwnerUse call(engine, NativeKind::engine);
    check(bool(call), "actual owned API lease acquired");
    retired = fs_engine_retire(engine);
    check(retired && fs_operation_status(retired) == 0 &&
              !fs_owned_engine_state(engine),
          "close revokes new calls and retains admitted API lease");
  }
  release_owner(engine, retired);
}
void probes(const char *executable) {
  auto engine = fs_owned_engine_create(executable, "/dev/null", 1, 0);
  const auto first = fs_engine_probe_async(engine);
  until([&] { return fs_operation_status(first) == 1; });
  auto second = fs_engine_probe_async(engine);
  check(second && second != first, "completed probe starts actual fresh work");
  until([&] { return fs_operation_status(second) == 1; });
  check(fs_operation_release(first) == 0 && fs_operation_release(second) == 0,
        "probe results acknowledge independently");
  release_owner(engine, fs_engine_retire(engine));
  const char *root = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
#ifdef __APPLE__
  if (!root)
    root = "/private/var/tmp";
#else
  if (!root)
    root = "/var/tmp";
#endif
  auto scratch =
      (std::filesystem::canonical(root) / "owned-probe-v2-XXXXXX").string();
  check(mkdtemp(scratch.data()), "private probe fixture root required");
  auto marker = std::filesystem::path(scratch) / "child";
  foresight::ScopeExit cleanup([&] {
    unsetenv("FORESIGHT_OWNED_PROBE_MARKER");
    std::filesystem::remove(marker);
    std::filesystem::remove(scratch);
  });
  setenv("FORESIGHT_OWNED_PROBE_MARKER", marker.c_str(), 1);
  engine = fs_owned_engine_create(executable, "/dev/null", 1, 0);
  auto probe = fs_engine_probe_async(engine);
  until([&] { return std::filesystem::exists(marker); });
  check(fs_engine_probe_async(engine) == probe,
        "pending probe coalesces exact work");
  pid_t child = -1;
  std::ifstream(marker) >> child;
  check(child > 0, "real held probe process admitted");
  auto other = fs_owned_engine_create(executable, "/dev/null", 0, 0);
  release_owner(other, fs_engine_retire(other));
  check(fs_operation_status(probe) == 0,
        "unrelated cleanup completes while probe stays held");
  auto retired = fs_engine_retire(engine);
  until([&] { return fs_operation_status(retired) == 1; });
  check(fs_operation_status(probe) == 2 && kill(child, 0) == -1 &&
            errno == ESRCH,
        "probe cancellation after closed stdout settles and actually reaps "
        "child");
  check(fs_operation_release(probe) == 0,
        "probe result retains independent acknowledgement");
  release_owner(engine, retired);
}
int main(int argc, char **argv) {
  const int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  if (argc == 2 && (std::string(argv[1]) == "--mapping-quarantine" ||
                    std::string(argv[1]) == "--ack-quarantine")) {
    setenv("FORESIGHT_HELPER", argv[0], 1);
    try {
      if (std::string(argv[1]) == "--mapping-quarantine")
        child_failure(argv[0]);
      else
        explicit_quarantine(argv[0]);
      return 0;
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return 1;
    }
  }
  if (argc == 2 && std::string(argv[1]) == "--retire-admission-failure") {
    auto engine = fs_owned_engine_create(argv[0], "/dev/null", 0, 0);
    auto child = fs_owned_conversation_create(engine);
    if (!engine || !child)
      return 2;
    native_handles()
        .operations.shutdown(); // Controlled producer submission refusal.
    if (fs_engine_retire(engine) != 0 || fs_engine_retire(engine) != 0)
      return 3;
    return 0; // Retained owners end with this isolated process, never an idle
              // positive token.
  }
  if (argc == 2 && std::string(argv[1]) == "--live-legacy-exit") {
    setenv("FORESIGHT_HELPER", argv[0], 1);
    auto *engine = fs_engine_create(argv[0], "/dev/null");
    auto *conversation = fs_conversation_create(engine);
    if (!conversation ||
        fs_generate(conversation, "exit-generation", "fixture") != 0)
      return 2;
    bool done = false;
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (!done && std::chrono::steady_clock::now() < deadline) {
      if (auto *message = fs_event_poll(conversation, 100)) {
        done =
            std::string(message).find("\"type\":\"done\"") != std::string::npos;
        fs_string_free(message);
      }
    }
    // Deliberately retain both legacy handles and the joinable finished thread.
    if (done)
      until([&] {
        return static_cast<Conversation *>(conversation)
            ->thread_finished.load();
      });
    return done ? 0 : 3;
  }
  if (argc > 1) {
    if (const char *marker = std::getenv("FORESIGHT_OWNED_PROBE_MARKER");
        marker && std::string(argv[1]) == "--model") {
      std::ofstream(marker) << getpid() << std::endl;
      close(STDOUT_FILENO);
      for (;;)
        pause();
    }
    return 0; // deterministic process fixture only, no model claim.
  }
  setenv("FORESIGHT_HELPER", argv[0], 1);
  try {
    check(fs_abi_version() == 1 && fs_lifetime_version() == 2,
          "separate owned v2 capability");
    std::cerr << "CASE live_legacy_exit\n";
    live_legacy_exit(argv[0]);
    std::cerr << "CASE held_legacy_finalization\n";
    held_legacy_finalization(argv[0]);
    std::cerr << "CASE retirement_admission_failure\n";
    retirement_admission_failure(argv[0]);
    std::cerr << "CASE legacy_failure\n";
    legacy_failure(argv[0]);
    std::cerr << "CASE owned_finalization\n";
    owned_finalization(argv[0]);
    std::cerr << "CASE generation\n";
    generation(argv[0]);
    std::cerr << "CASE independent_speech\n";
    independent_speech(argv[0]);
    std::cerr << "CASE child_failure\n";
    run_owner_subprocess(argv[0], "--mapping-quarantine");
    run_owner_subprocess(argv[0], "--ack-quarantine");
    std::cerr << "CASE probes\n";
    probes(argv[0]);
    std::cerr << "CASE reused_address\n";
    reused_address(argv[0]);
    std::cerr << "CASE capture_tail\n";
    capture_tail();
    std::cerr << "CASE shared_model_handoff\n";
    shared_model_handoff(argv[0]);
    std::cerr << "CASE independent_acknowledgements\n";
    independent_acknowledgements();
    std::cerr << "CASE held_api\n";
    held_api(argv[0]);
    std::cerr << "CASE speech_join_with_poll\n";
    speech_join_with_poll(argv[0]);
    std::cerr << "CASE owned_rollback\n";
    owned_rollback(argv[0]);
    std::cerr << "CASE bounds\n";
    bounds(argv[0]);
    check(native_handles().handles.empty() && native_handles().owners.empty(),
          "all physical and metadata owners released");
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
