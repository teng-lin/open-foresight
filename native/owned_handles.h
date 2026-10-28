#pragma once
// Internal resource addresses stay in this mapping. Only the separately
// negotiated owned API exposes non-reused integer identities to new callers.
using NativeOperation = foresight::OwnedOperation;
#if FORESIGHT_ENABLE_TEST_HOOKS
// Mapping-local controlled backend capability; no environment or public export.
foresight::PcmOutput::BackendFactory pcm_output_factory_for_testing = nullptr;
#endif
// Mapping-local, constant initialized and allocation-free. It survives every
// Dart isolate that opens this same image and is never reset by cleanup.
std::atomic<bool> &native_quarantine_state() noexcept {
  static std::atomic<bool> value{false};
  return value;
}
enum class NativeKind { engine, conversation, speech, capture, media, output };
struct NativeControl {
  NativeKind kind;
  std::shared_ptr<void> object;
  std::shared_ptr<NativeControl> parent;
  std::atomic<bool> closing{false}, speech_joined{true};
  size_t users = 0, group = 0;
  uint64_t identity = 0, operation_owner = 0, retire = 0, probe = 0, finish = 0;
  foresight::OwnedOperations *private_operations = nullptr;
  bool legacy_async_started = false;
  bool graph_released = false;
#if FORESIGHT_ENABLE_TEST_HOOKS
  bool fail_cleanup_for_testing = false;
#endif
  void *address = nullptr;
  std::mutex users_mutex;
  std::condition_variable users_changed;
  NativeControl(NativeKind type, std::shared_ptr<void> value)
      : kind(type), object(std::move(value)) {}
};
struct NativeHandles {
  foresight::OwnedOperations operations{4096, false,
                                        &native_quarantine_state()};
  std::mutex mutex;
  std::unordered_map<void *, std::shared_ptr<NativeControl>> handles;
  std::unordered_map<uint64_t, std::shared_ptr<NativeControl>> owners;
  uint64_t next_owner = 1;
  std::atomic<bool> process_lifetime{false};
  ~NativeHandles() {
    operations.shutdown();
  }
};
// Process finalization never waits for abandoned work or destroys its owners.
// A completed legacy thread can, however, release its pthread join bookkeeping.
// Keep the complete resource graph alive even after detaching: this is not an
// owned-v2 retirement acknowledgement or permission to unload its image.
void finalize_legacy_threads(NativeHandles &state) noexcept {
  try {
    std::unique_lock registry(state.mutex, std::try_to_lock);
    if (!registry.owns_lock())
      return;
    for (const auto &[address, control] : state.handles) {
      if (control->identity || control->private_operations ||
          control->closing || control->kind == NativeKind::engine ||
          control->kind == NativeKind::output ||
          control->kind == NativeKind::media || !control->object)
        continue;
      std::unique_lock users(control->users_mutex, std::try_to_lock);
      if (!users.owns_lock() || control->users)
        continue;
      auto *object = control->object.get();
      auto *worker =
          control->kind == NativeKind::conversation
              ? static_cast<Worker *>(static_cast<Conversation *>(object))
          : control->kind == NativeKind::speech
              ? static_cast<Worker *>(static_cast<Speech *>(object))
              : static_cast<Worker *>(static_cast<Capture *>(object));
      std::unique_lock life(worker->life, std::try_to_lock);
      if (!life.owns_lock() || !worker->thread_finished.load() ||
          !worker->thread.joinable())
        continue;
      worker->thread.detach();
      control->closing = true;
    }
  } catch (...) {
    // Retain all authority if the platform refuses the bookkeeping release.
  }
}
NativeHandles &native_handles() {
  // Trivial pointer storage stays valid while process-finalization callbacks
  // run. Never access a destroyed C++ Holder from a still-owned actor.
  static NativeHandles *const value = [] {
    auto registry = std::make_unique<NativeHandles>();
    if (std::atexit([] {
          auto &state = native_handles();
          finalize_legacy_threads(state);
          // Legacy-only users can unload after local synchronous cleanup.
          // Owned groups/quarantined authority end only with OS cleanup.
          bool empty = false;
          {
            std::lock_guard lock(state.mutex);
            empty = state.handles.empty() && state.owners.empty();
          }
          if (!state.process_lifetime && empty)
            delete &state;
        }) != 0)
      throw std::runtime_error("Native lifecycle registration failed");
    return registry.release();
  }();
  return *value;
}
// Owner execution groups are process-lifetime infrastructure. Pin their actual
// image once before admission, using NOLOAD only: a replaced pathname can never
// load replacement code or acquire authority over an old object. The symbol's
// resolved image must match this internal function's image. Main-executable
// fixtures already have an irrevocable process-lifetime mapping.
bool pin_native_mapping() {
  static const bool pinned = foresight::retain_native_image(
      reinterpret_cast<const void *>(&native_handles), "fs_lifetime_version");
  return pinned;
}

#ifdef __APPLE__
foresight::OwnedOperations &legacy_capture_operations() {
  static auto *value =
      new foresight::OwnedOperations(64, false, &native_quarantine_state());
  return *value;
}
#endif
foresight::OwnedOperations &control_operations(const NativeControl &control) {
  return control.private_operations ? *control.private_operations
                                    : native_handles().operations;
}
thread_local bool creating_owned_native = false;
thread_local NativeControl *owned_native_bridge = nullptr;
struct NativeCreation {
  bool previous = creating_owned_native;
  NativeCreation() {
    if (native_quarantine_state().load(std::memory_order_acquire))
      throw std::runtime_error("Native ownership unconfirmed; restart process");
    if (!pin_native_mapping())
      throw std::runtime_error("Native mapping identity unavailable");
    native_handles().process_lifetime = true;
    creating_owned_native = true;
  }
  ~NativeCreation() {
    creating_owned_native = previous;
  }
};
struct NativeUse {
  std::shared_ptr<NativeControl> control;
  NativeUse(void *handle, NativeKind kind) {
    auto &registry = native_handles();
    std::lock_guard lock(registry.mutex);
    const auto found = registry.handles.find(handle);
    if (found != registry.handles.end() && found->second->kind == kind &&
        !found->second->closing &&
        (!found->second->identity ||
         owned_native_bridge == found->second.get())) {
      control = found->second;
      std::lock_guard users(control->users_mutex);
      ++control->users;
    }
  }
  NativeUse(const NativeUse &) = delete;
  ~NativeUse() {
    if (control) {
      std::lock_guard lock(control->users_mutex);
      --control->users;
      control->users_changed.notify_all();
    }
  }
  explicit operator bool() const {
    return bool(control);
  }
};
// A bridge is a synchronous, mapping-local lease. It cannot be transferred to
// another thread/isolate and no pointer is returned through the public API.
struct NativeOwnerUse {
  std::shared_ptr<NativeControl> control;
  NativeControl *previous = owned_native_bridge;
  NativeOwnerUse(uint64_t identity, NativeKind kind, bool any_event = false,
                 bool new_work = false) {
    auto &registry = native_handles();
    std::lock_guard lock(registry.mutex);
    if (new_work && native_quarantine_state().load(std::memory_order_acquire))
      return;
    const auto found = registry.owners.find(identity);
    if (found != registry.owners.end() &&
        (found->second->kind == kind ||
         (any_event && found->second->kind != NativeKind::engine &&
          found->second->kind != NativeKind::media &&
          found->second->kind != NativeKind::output)) &&
        !found->second->closing && found->second->object) {
      control = found->second;
      std::lock_guard users(control->users_mutex);
      ++control->users;
      owned_native_bridge = control.get();
    }
  }
  ~NativeOwnerUse() {
    owned_native_bridge = previous;
    if (control) {
      std::lock_guard lock(control->users_mutex);
      --control->users;
      control->users_changed.notify_all();
    }
  }
  void *get() const {
    return control ? control->object.get() : nullptr;
  }
  explicit operator bool() const {
    return bool(control);
  }
};
int probe_engine(Engine &engine, const std::atomic<bool> *closing);
NativeOperation::Result native_probe(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  if (control.closing)
    return NativeOperation::Result::failed;
  return probe_engine(*static_cast<Engine *>(control.object.get()),
                      &control.closing) == 0
             ? NativeOperation::Result::succeeded
             : NativeOperation::Result::failed;
}
NativeOperation::Result native_media_execute(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  return static_cast<foresight::MediaOwner *>(control.object.get())->execute();
}
NativeOperation::Result native_finish(NativeOperation &operation) {
  auto &capture = *static_cast<Capture *>(
      static_cast<NativeControl *>(operation.context)->object.get());
  if (!capture.recording_recovery)
    capture.stop();
  capture.join();
  capture.finish_recording();
#ifdef __APPLE__
  fs_macos_capture_close(capture.macos);
#endif
  return NativeOperation::Result::succeeded;
}
struct CaptureReservationRequest {
  std::shared_ptr<NativeControl> control;
  std::vector<foresight::RecordingWriter::Identity> identities;
};
NativeOperation::Result native_capture_reserve(NativeOperation &operation) {
  auto &request = *static_cast<CaptureReservationRequest *>(operation.context);
  auto &control = *request.control;
  if (control.closing || !control.object)
    return NativeOperation::Result::failed;
  auto &capture = *static_cast<Capture *>(control.object.get());
  std::shared_ptr<foresight::RecordingWriter> writer;
  {
    std::unique_lock lock(capture.recording_mutex);
    while (!capture.recording_prepared && !capture.cancel && !control.closing)
      capture.recording_changed.wait_for(lock, std::chrono::milliseconds(50));
    if (capture.cancel || control.closing)
      return NativeOperation::Result::failed;
    writer = capture.recording_writer;
  }
  if (!writer || request.identities.size() >
                     foresight::RecordingWriter::reservation_limit -
                         writer->pressure().outstanding_chunks)
    return NativeOperation::Result::failed;
  for (const auto &id : request.identities) {
    if (capture.cancel || control.closing || !writer->reserve(id))
      return NativeOperation::Result::failed;
  }
  return NativeOperation::Result::succeeded;
}
NativeOperation::Result native_speech_join(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  auto &speech = *static_cast<Speech *>(control.object.get());
  {
    // Only finish publication needs joining here. Polls keep their separate
    // lifetime lease and may wait for a future event without delaying exit.
    std::lock_guard publication(speech.life);
  }
  speech.join();
  control.speech_joined = true;
  return NativeOperation::Result::succeeded;
}
NativeOperation::Result native_output_start(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  return static_cast<foresight::PcmOutput *>(control.object.get())->start()
             ? NativeOperation::Result::succeeded
             : NativeOperation::Result::failed;
}
NativeOperation::Result native_output_finish(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  return static_cast<foresight::PcmOutput *>(control.object.get())->finish()
             ? NativeOperation::Result::succeeded
             : NativeOperation::Result::unsettled;
}
struct PcmOutputRequest {
  std::shared_ptr<NativeControl> control;
  uint64_t generation = 0;
  bool flush = false;
};
NativeOperation::Result native_output_control(NativeOperation &operation) {
  auto &request = *static_cast<PcmOutputRequest *>(operation.context);
  auto &control = *request.control;
  if (control.closing || !control.object)
    return NativeOperation::Result::failed;
  auto &output = *static_cast<foresight::PcmOutput *>(control.object.get());
  try {
    const bool success = request.flush ? output.pause_flush(request.generation)
                                       : output.resume(request.generation);
    return success ? NativeOperation::Result::succeeded
                   : NativeOperation::Result::failed;
  } catch (...) {
    output.fail(foresight::PcmOutput::Error::backend_failure);
    throw;
  }
}
void discard_idle_operations(const std::shared_ptr<NativeControl> &control);
void revoke_native(const std::shared_ptr<NativeControl> &control) {
  control->closing = true;
  if (control->kind == NativeKind::output && control->object) {
    static_cast<foresight::PcmOutput *>(control->object.get())->revoke();
  } else if (control->kind == NativeKind::media && control->object) {
    static_cast<foresight::MediaOwner *>(control->object.get())->cancel = true;
  } else if (control->kind != NativeKind::engine && control->object) {
    auto *worker = control->kind == NativeKind::conversation
                       ? static_cast<Worker *>(
                             static_cast<Conversation *>(control->object.get()))
                   : control->kind == NativeKind::speech
                       ? static_cast<Worker *>(
                             static_cast<Speech *>(control->object.get()))
                       : static_cast<Worker *>(
                             static_cast<Capture *>(control->object.get()));
    worker->cancel = true;
#ifdef __APPLE__
    if (control->kind == NativeKind::capture)
      fs_macos_capture_revoke(
          static_cast<Capture *>(control->object.get())->macos);
#endif
    revoke_events(worker);
  }
}
NativeOperation::Result cleanup_native(NativeControl &control) {
#if FORESIGHT_ENABLE_TEST_HOOKS
  if (control.fail_cleanup_for_testing)
    throw std::bad_alloc{};
#endif
  {
    std::unique_lock lock(control.users_mutex);
    control.users_changed.wait(lock, [&] { return control.users == 0; });
  }
  if (control.object && control.kind == NativeKind::engine) {
    // Queue order is insufficient: each child has its own independent lane.
    // A failed child retains both its actual engine and this parent's
    // authority.
    for (;;) {
      bool pending = false;
      {
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        for (const auto &[identity, child] : registry.owners) {
          if (child->parent.get() != &control)
            continue;
          const auto status = registry.operations.status(child->retire);
          if (status == 3 || status == -1)
            return NativeOperation::Result::unsettled;
          pending = true;
        }
      }
      if (!pending)
        break;
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    auto &engine = *static_cast<Engine *>(control.object.get());
    {
      std::lock_guard lock(engine.mu);
      if (engine.refs)
        return NativeOperation::Result::unsettled;
    }
    shutdown_persistent(engine);
  } else if (control.object && control.kind == NativeKind::output) {
    if (!static_cast<foresight::PcmOutput *>(control.object.get())->finish())
      return NativeOperation::Result::unsettled;
  } else if (control.object && control.kind == NativeKind::media) {
    auto &media = *static_cast<foresight::MediaOwner *>(control.object.get());
    media.cancel = true;
    if (!media.ready_to_destroy())
      return NativeOperation::Result::unsettled;
  } else if (control.object) {
    auto *object = control.object.get();
    auto &worker = *static_cast<Worker *>(
        control.kind == NativeKind::conversation
            ? static_cast<Worker *>(static_cast<Conversation *>(object))
        : control.kind == NativeKind::speech
            ? static_cast<Worker *>(static_cast<Speech *>(object))
            : static_cast<Worker *>(static_cast<Capture *>(object)));
    // Join callbacks/polls independently of a held physical worker.
    retire_events(&worker);
    worker.stop();
    worker.join();
    if (control.kind == NativeKind::capture)
      static_cast<Capture *>(object)->finish_recording();
#ifdef __APPLE__
    if (control.kind == NativeKind::capture)
      fs_macos_capture_close(static_cast<Capture *>(object)->macos);
#endif
    if (control.kind == NativeKind::speech) {
      auto &speech = *static_cast<Speech *>(object);
      bool last = false;
      if (speech.worker_engine) {
        std::lock_guard lock(speech_engines_mutex());
        if (speech.worker_engine && speech.worker_engine.use_count() == 1) {
          speech.worker_engine->retiring = true;
          // Remove weak admission before releasing the lock. A new creator
          // must not borrow a dying model and delay its actual destruction
          // beyond the closing owner's completion.
          for (auto it = speech_engines().begin();
               it != speech_engines().end();)
            if (!it->second.owner_before(speech.worker_engine) &&
                !speech.worker_engine.owner_before(it->second))
              it = speech_engines().erase(it);
            else
              ++it;
          last = true;
        } else {
          // Drop a non-last reference under the same lock used for admission
          // and last-reference election. Two concurrent closes cannot both
          // elect somebody else to join the shared worker.
          speech.worker_engine.reset();
        }
      }
      if (last) {
        shutdown_persistent(speech.worker_engine->engine);
        speech.worker_engine.reset();
      }
    }
  }
  // Hold the real parent object through child destruction, not just metadata.
  const auto parent = control.parent;
  // The still-published child/refs prevents parent cleanup from resetting the
  // object. Do not copy a shared Engine lease past child unpublication: that
  // could make parent completion precede actual Engine destruction.
  auto *parent_engine =
      parent ? static_cast<Engine *>(parent->object.get()) : nullptr;
  auto *address = control.address;
  {
    auto &registry = native_handles();
    std::lock_guard lock(registry.mutex);
    const auto old = registry.handles.find(address);
    if (old != registry.handles.end() && old->second.get() == &control)
      registry.handles.erase(old);
  }
  // Remove raw-address admission before freeing storage. Child graph ownership
  // remains in owners/parent until after actual destruction and ref release.
  control.object.reset();
  if (parent && !control.graph_released) {
    auto &engine = *parent_engine;
    std::lock_guard lock(engine.mu);
    --engine.refs;
    control.graph_released = true;
  }
  {
    auto &registry = native_handles();
    std::lock_guard lock(registry.mutex);
    control.parent.reset();
  }
  return NativeOperation::Result::succeeded;
}
NativeOperation::Result native_retire(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  for (auto token : {control.probe, control.finish})
    if (auto idle = control_operations(control).find(token))
      control_operations(control).discard(idle);
  return cleanup_native(control);
}
void discard_idle_operations(const std::shared_ptr<NativeControl> &control) {
  auto &operations = control_operations(*control);
  for (auto token : {control->retire, control->probe, control->finish})
    if (token)
      if (auto operation = operations.find(token))
        operations.discard(operation);
}
template <class T>
T *publish_native(std::unique_ptr<T> resource, NativeKind kind,
                  std::shared_ptr<NativeControl> parent = nullptr) {
  auto &registry = native_handles();
  if (creating_owned_native &&
      native_quarantine_state().load(std::memory_order_acquire))
    throw std::runtime_error("Native ownership unconfirmed; restart process");
  auto control = std::make_shared<NativeControl>(
      kind, std::shared_ptr<T>(std::move(resource)));
  control->parent = std::move(parent);
  foresight::ScopeExit rollback([&] {
    discard_idle_operations(control);
    if (control->group)
      control_operations(*control).release_group(control->group);
  });
  bool asynchronous = creating_owned_native;
#ifdef __APPLE__
  if constexpr (std::is_same_v<T, Capture>) {
    if (!creating_owned_native && control->object &&
        static_cast<Capture *>(control->object.get())->macos) {
      asynchronous = true;
      control->private_operations = &legacy_capture_operations();
      registry.process_lifetime = true;
    }
  }
#endif
  if (asynchronous) {
    {
      std::lock_guard lock(registry.mutex);
      if (registry.next_owner > static_cast<uint64_t>(INT64_MAX))
        throw std::overflow_error("Native owner identity exhausted");
      control->operation_owner = registry.next_owner++;
      if (creating_owned_native)
        control->identity = control->operation_owner;
    }
    auto &operations = control_operations(*control);
    control->group = operations.reserve_group();
    auto operation = operations.create(
        native_retire, control.get(), control->group, control->operation_owner);
    operation->releases_group = true;
    operation->automatic_release = control->private_operations != nullptr;
    control->retire = operation->token;
    if (kind == NativeKind::output) {
      control->probe = operations
                           .create(native_output_start, control.get(),
                                   control->group, control->operation_owner)
                           ->token;
      control->finish = operations
                            .create(native_output_finish, control.get(),
                                    control->group, control->operation_owner)
                            ->token;
    }
    if (kind == NativeKind::media)
      control->finish = operations
                            .create(native_media_execute, control.get(),
                                    control->group, control->operation_owner)
                            ->token;
    if (kind == NativeKind::capture)
      control->finish = operations
                            .create(native_finish, control.get(),
                                    control->group, control->operation_owner)
                            ->token;
  }
  auto *value = static_cast<T *>(control->object.get());
  control->address = value;
  std::lock_guard lock(registry.mutex);
  if (control->parent && control->parent->closing)
    return nullptr;
  if (creating_owned_native) {
    registry.owners.emplace(control->identity, control);
  }
  foresight::ScopeExit rollback_identity(
      [&] { registry.owners.erase(control->identity); });
  registry.handles.emplace(value, control);
  if constexpr (std::is_base_of_v<Worker, T>)
    value->owner_closing = &control->closing;
  if constexpr (std::is_same_v<T, Conversation>)
    value->engine_owner =
        std::static_pointer_cast<Engine>(control->parent->object);
  rollback_identity.release();
  rollback.release();
  return value;
}
// Creation uses this rollback only before any physical thread or shared-model
// lease is acquired. All fallible metadata is prepared before that commit.
void rollback_unpublished_native(void *address) {
  auto &registry = native_handles();
  std::shared_ptr<NativeControl> control;
  {
    std::lock_guard lock(registry.mutex);
    const auto found = registry.handles.find(address);
    if (found == registry.handles.end())
      return;
    control = found->second;
    revoke_native(control);
  }
  cleanup_native(*control);
  discard_idle_operations(control);
  if (control->identity) {
    std::lock_guard lock(registry.mutex);
    registry.owners.erase(control->identity);
    control_operations(*control).release_group(control->group);
  } else if (control->private_operations) {
    control_operations(*control).release_group(control->group);
  }
}
// registry.mutex held; requests acquire no worker/event/process mutex.
bool request_native_retirement(const std::shared_ptr<NativeControl> &control) {
  auto &operations = control_operations(*control);
  auto operation = operations.find(control->retire);
  if (!operation)
    return false;
  const auto state = operation->state.load(std::memory_order_acquire);
  if (state != NativeOperation::State::idle &&
      state != NativeOperation::State::unconfirmed)
    return state != NativeOperation::State::discarded;
  // An acquire of unconfirmed makes partial cleanup state safe to retry. Never
  // read/reset object while an already running cleanup may be destroying it.
  revoke_native(control);
  for (auto token : {control->probe, control->finish})
    if (token)
      if (auto idle = operations.find(token))
        operations.discard(idle);
  return operations.submit(operation, control);
}

uint64_t retire_native(uint64_t identity, NativeKind kind) {
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  const auto found = registry.owners.find(identity);
  if (found == registry.owners.end() || found->second->kind != kind)
    return 0;
  const auto control = found->second;
  const auto status = registry.operations.status(control->retire);
  auto retirement = registry.operations.find(control->retire);
  if (!retirement)
    return 0;
  if (control->closing && status != 3 &&
      retirement->state.load(std::memory_order_acquire) !=
          NativeOperation::State::idle)
    return status >= 0 ? control->retire : 0;
  if (kind == NativeKind::engine) {
    control->closing = true;
    for (const auto &[child_id, child] : registry.owners)
      if (child->parent == control && !request_native_retirement(child))
        return 0;
  }
  return request_native_retirement(control) ? control->retire : 0;
}
bool legacy_capture_work(const std::shared_ptr<NativeControl> &control,
                         bool retire) {
#ifdef __APPLE__
  if (!control->private_operations)
    return false;
  auto &capture = *static_cast<Capture *>(control->object.get());
  capture.cancel = true;
  const bool pending = fs_macos_capture_close_pending(capture.macos);
  if (!pending && !control->legacy_async_started)
    return false;
  control->legacy_async_started = true;
  if (retire) {
    if (!request_native_retirement(control))
      throw std::runtime_error("Capture cleanup unavailable");
  } else {
    auto &operations = control_operations(*control);
    auto finish = operations.find(control->finish);
    if (!finish)
      throw std::runtime_error("Capture finish unavailable");
    const auto state = finish->state.load(std::memory_order_acquire);
    if ((state == NativeOperation::State::idle ||
         state == NativeOperation::State::unconfirmed) &&
        !operations.submit(finish, control))
      throw std::runtime_error("Capture finish unavailable");
  }
  return true;
#else
  (void)control;
  (void)retire;
  return false;
#endif
}
bool retire_legacy(void *handle, NativeKind kind) {
  auto &registry = native_handles();
  std::shared_ptr<NativeControl> control;
  {
    std::lock_guard lock(registry.mutex);
    const auto found = registry.handles.find(handle);
    if (found == registry.handles.end() || found->second->kind != kind ||
        found->second->identity)
      return false;
    control = found->second;
    if (kind == NativeKind::capture && legacy_capture_work(control, true))
      return true;
    revoke_native(control);
  }
  try {
    const bool success =
        cleanup_native(*control) == NativeOperation::Result::succeeded;
    if (!success)
      registry.process_lifetime = true;
    if (success && control->private_operations) {
      discard_idle_operations(control);
      control_operations(*control).release_group(control->group);
    }
    return success;
  } catch (...) {
    // Preserve unconfirmed ownership through OS cleanup rather than implicitly
    // destroying it from a DSO/static finalizer after returning the sentinel.
    registry.process_lifetime = true;
    throw;
  }
}
bool legacy_closing(void *handle, NativeKind kind) {
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  const auto found = registry.handles.find(handle);
  return found != registry.handles.end() && found->second->kind == kind &&
         !found->second->identity && found->second->closing;
}
bool speech_request_available(const std::shared_ptr<NativeControl> &control) {
  return !control->identity ||
         control->speech_joined.load(std::memory_order_acquire);
}
bool prepare_native_speech_join(const std::shared_ptr<NativeControl> &control) {
  if (!control->identity)
    return true;
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  if (control->closing || !speech_request_available(control))
    return false;
  control->finish = registry.operations
                        .create(native_speech_join, control.get(),
                                control->group, control->identity)
                        ->token;
  control->speech_joined = false;
  return true;
}
uint64_t request_native_work(uint64_t identity, NativeKind kind, bool probe,
                             bool cancel_capture = true) {
  if (probe && native_quarantine_state().load(std::memory_order_acquire))
    return 0;
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  const auto found = registry.owners.find(identity);
  if (found == registry.owners.end() || found->second->kind != kind ||
      found->second->closing)
    return 0;
  const auto &control = found->second;
  auto &token = probe ? control->probe : control->finish;
  if (probe) {
    auto previous = registry.operations.find(token);
    if (!previous || previous->terminal())
      token = registry.operations
                  .create(native_probe, control.get(), control->group,
                          control->identity)
                  ->token;
  }
  auto operation = registry.operations.find(token);
  if (!operation)
    return 0;
  if (!probe && kind == NativeKind::capture && cancel_capture) {
    auto &capture = *static_cast<Capture *>(control->object.get());
    capture.cancel = true;
#ifdef __APPLE__
    fs_macos_capture_revoke(capture.macos);
#endif
  }
  const auto state = operation->state.load(std::memory_order_acquire);
  if (state == NativeOperation::State::queued ||
      state == NativeOperation::State::running || operation->terminal())
    return token;
  return registry.operations.submit(operation, control) ? token : 0;
}
uint64_t native_identity(void *handle) {
  if (!handle)
    return 0;
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  const auto found = registry.handles.find(handle);
  return found == registry.handles.end() ? 0 : found->second->identity;
}
