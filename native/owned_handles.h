#pragma once
// Included after the resource definitions in foresight_native.cpp. Object
// addresses never leave their original native mapping; callers observe only
// monotonic operation tokens after revocation.
using NativeOperation = foresight::OwnedOperation;
enum class NativeKind { engine, conversation, speech, capture };
struct NativeControl {
  NativeKind kind;
  std::shared_ptr<void> object;
  std::shared_ptr<NativeControl> parent;
  std::atomic<bool> closing{false};
  size_t users = 0;
  std::mutex users_mutex;
  std::condition_variable users_changed;
  uint64_t retire = 0, probe = 0, finish = 0;
  NativeControl(NativeKind type, std::shared_ptr<void> value)
      : kind(type), object(std::move(value)) {}
};
struct NativeHandles {
  foresight::OwnedOperations operations;
  std::mutex mutex;
  std::unordered_map<void *, std::shared_ptr<NativeControl>> handles;
  // Actions use this registry. Join the executor before destroying the map or
  // its mutex, including a process exit with unacknowledged requests.
  ~NativeHandles() {
    operations.shutdown();
  }
};
NativeHandles &native_handles() {
  static NativeHandles handles;
  return handles;
}
struct NativeUse {
  std::shared_ptr<NativeControl> control;
  NativeUse(void *handle, NativeKind kind) {
    auto &registry = native_handles();
    std::lock_guard lock(registry.mutex);
    const auto found = registry.handles.find(handle);
    if (found != registry.handles.end() && found->second->kind == kind &&
        !found->second->closing) {
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
NativeOperation::Result native_finish(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  auto &capture = *static_cast<Capture *>(control.object.get());
  capture.stop();
  capture.join();
  return NativeOperation::Result::succeeded;
}
NativeOperation::Result native_speech_join(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  {
    std::unique_lock lock(control.users_mutex);
    control.users_changed.wait(lock, [&] { return control.users == 0; });
  }
  static_cast<Speech *>(control.object.get())->join();
  return NativeOperation::Result::succeeded;
}
void discard_idle_operations(const std::shared_ptr<NativeControl> &control);
NativeOperation::Result native_retire(NativeOperation &operation) {
  auto &control = *static_cast<NativeControl *>(operation.context);
  {
    std::unique_lock lock(control.users_mutex);
    control.users_changed.wait(lock, [&] { return control.users == 0; });
  }
  for (auto token : {control.probe, control.finish}) {
    if (auto idle = native_handles().operations.find(token))
      native_handles().operations.discard(idle);
  }
  auto *object = control.object.get();
  if (control.kind != NativeKind::engine) {
    auto &worker = *static_cast<Worker *>(
        control.kind == NativeKind::conversation
            ? static_cast<Worker *>(static_cast<Conversation *>(object))
        : control.kind == NativeKind::speech
            ? static_cast<Worker *>(static_cast<Speech *>(object))
            : static_cast<Worker *>(static_cast<Capture *>(object)));
    worker.stop();
    worker.join();
    retire_events(&worker);
    if (control.kind == NativeKind::conversation) {
      auto &engine = *static_cast<Conversation *>(object)->engine;
      std::lock_guard lock(engine.mu);
      --engine.refs;
    }
  }
  {
    auto &registry = native_handles();
    std::lock_guard lock(registry.mutex);
    registry.handles.erase(object);
  }
  // Complete only after object destruction, not after the cancellation/join
  // request. A shared parent keeps its actual mapping/model alive throughout.
  control.object.reset();
  control.parent.reset();
  return NativeOperation::Result::succeeded;
}
void discard_idle_operations(const std::shared_ptr<NativeControl> &control) {
  auto &operations = native_handles().operations;
  for (auto token : {control->retire, control->probe, control->finish})
    if (token)
      if (auto operation = operations.find(token))
        operations.discard(operation);
}
template <class T>
T *publish_native(std::unique_ptr<T> resource, NativeKind kind,
                  std::shared_ptr<NativeControl> parent = nullptr) {
  auto &registry = native_handles();
  auto control = std::make_shared<NativeControl>(
      kind, std::shared_ptr<T>(std::move(resource)));
  control->parent = std::move(parent);
  foresight::ScopeExit rollback([&] { discard_idle_operations(control); });
  control->retire =
      registry.operations.create(native_retire, control.get())->token;
  if (kind == NativeKind::engine)
    control->probe =
        registry.operations.create(native_probe, control.get())->token;
  if (kind == NativeKind::capture)
    control->finish =
        registry.operations.create(native_finish, control.get())->token;
  auto *value = static_cast<T *>(control->object.get());
  std::lock_guard lock(registry.mutex);
  if (control->parent && control->parent->closing)
    return nullptr;
  registry.handles.emplace(value, control);
  if constexpr (std::is_base_of_v<Worker, T>)
    value->owner_closing = &control->closing;
  rollback.release();
  return value;
}
// registry.mutex held; no worker/event/process lock is acquired here.
void request_native_retirement(const std::shared_ptr<NativeControl> &control) {
  if (control->closing.exchange(true))
    return;
  if (control->kind != NativeKind::engine) {
    auto *object = control->object.get();
    auto *worker =
        control->kind == NativeKind::conversation
            ? static_cast<Worker *>(static_cast<Conversation *>(object))
        : control->kind == NativeKind::speech
            ? static_cast<Worker *>(static_cast<Speech *>(object))
            : static_cast<Worker *>(static_cast<Capture *>(object));
    worker->cancel = true;
    revoke_events(worker);
  }
  auto &operations = native_handles().operations;
  // Unused preallocated work is removed without publishing phantom jobs.
  for (auto token : {control->probe, control->finish})
    if (token)
      if (auto operation = operations.find(token))
        operations.discard(operation);
  operations.submit(operations.find(control->retire), control);
}
uint64_t retire_native(void *handle, NativeKind kind) {
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  const auto found = registry.handles.find(handle);
  if (found == registry.handles.end() || found->second->kind != kind)
    return 0;
  const auto control = found->second;
  if (kind == NativeKind::engine) {
    // Revoke the parent before inspecting children. New admissions use this
    // same lock; every existing conversation is enqueued before its engine.
    control->closing = true;
    for (const auto &[address, child] : registry.handles)
      if (child->parent == control)
        request_native_retirement(child);
    registry.operations.submit(registry.operations.find(control->retire),
                               control);
    if (auto probe = registry.operations.find(control->probe))
      registry.operations.discard(probe);
  } else {
    request_native_retirement(control);
  }
  return control->retire;
}
bool prepare_native_speech_join(const std::shared_ptr<NativeControl> &control) {
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  if (control->closing)
    return false;
  if (auto previous = registry.operations.find(control->finish))
    registry.operations.discard(previous);
  control->finish =
      registry.operations.create(native_speech_join, control.get())->token;
  return true;
}
uint64_t request_native_work(void *handle, NativeKind kind, bool probe) {
  auto &registry = native_handles();
  std::lock_guard lock(registry.mutex);
  const auto found = registry.handles.find(handle);
  if (found == registry.handles.end() || found->second->kind != kind ||
      found->second->closing)
    return 0;
  const auto &control = found->second;
  const auto token = probe ? control->probe : control->finish;
  if (auto operation = registry.operations.find(token)) {
    if (!probe && kind == NativeKind::capture)
      static_cast<Capture *>(handle)->cancel = true;
    registry.operations.submit(operation, control);
    return token;
  }
  return 0;
}
void await_native_operation(uint64_t token) {
  if (auto operation = native_handles().operations.find(token)) {
    operation->wait();
    native_handles().operations.release(token);
  }
}
