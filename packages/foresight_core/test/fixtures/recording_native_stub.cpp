// Deterministic acquisition/ASR ABI fixture. It never accesses audio devices.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
struct Handle {
  bool speech;
  int channel;
  int marker = 0;
  std::deque<std::string> events;
  bool processed = false;
};
static Handle *channels[2] = {};
static uint64_t next_owner = 1;
static std::map<uint64_t, Handle *> owners;
static std::map<uint64_t, uint64_t> retirements;
static Handle *resolve(uint64_t owner) {
  const auto found = owners.find(owner);
  return found == owners.end() ? nullptr : found->second;
}
static uint64_t publish(void *pointer) {
  if (!pointer)
    return 0;
  const auto owner = next_owner++;
  owners.emplace(owner, static_cast<Handle *>(pointer));
  return owner;
}
static int fail_channel = -1;
static std::string speech_event;
static bool hold_speech = false;
static bool queue_speech = false;
static int speech_creations = 0, speech_requests = 0, capture_creations = 0;
static int speech_admissions_polled = 0;
static std::string speech_runtime;
extern "C" {
const char *fixture_speech_runtime() {
  return speech_runtime.c_str();
}
int fixture_speech_creations() {
  return speech_creations;
}
int fixture_speech_requests() {
  return speech_requests;
}
int fixture_speech_admissions_polled() {
  return speech_admissions_polled;
}
void fixture_hold_speech(int hold) {
  hold_speech = hold != 0;
}
void fixture_queue_speech(int queued) {
  queue_speech = queued != 0;
}
void fixture_admit_speech(uint64_t owner, int complete) {
  auto *handle = resolve(owner);
  if (!handle)
    return;
  handle->events.push_back("{\"type\":\"state\",\"phase\":\"speech_running\"}");
  if (complete) {
    handle->events.push_back("{\"type\":\"transcript\",\"text\":\"marker_" +
                             std::to_string(handle->marker) + "\"}");
    handle->events.push_back("{\"type\":\"done\",\"status\":\"completed\"}");
  }
}
void fixture_speech_event(const char *event) {
  speech_event = event;
}
void fixture_fail_channel(int channel) {
  fail_channel = channel;
}
int fixture_emit(int channel, const char *event) {
  if (!channels[channel])
    return 0;
  channels[channel]->events.emplace_back(event);
  return 1;
}
void *fs_capture_start(const char *, int channel, int) {
  if (channel == fail_channel)
    return nullptr;
  ++capture_creations;
  auto *handle = new Handle{false, channel};
  channels[channel] = handle;
  return handle;
}
int fs_capture_set_echo_cancellation(void *pointer, int enabled) {
  auto *handle = static_cast<Handle *>(pointer);
  if (!handle || handle->channel != 0)
    return 0;
  handle->events.push_back(
      std::string(
          "{\"type\":\"echo_cancellation\",\"supported\":true,\"requested\":") +
      (enabled ? "true" : "false") +
      ",\"active\":" + (enabled && handle->processed ? "true" : "false") +
      ",\"restart_required\":" +
      (enabled && !handle->processed ? "true" : "false") +
      ",\"fallback_status\":0}");
  return 1;
}
void *fs_capture_start_with_options(const char *target, int channel, int rate,
                                    int echo) {
  auto *handle = static_cast<Handle *>(fs_capture_start(target, channel, rate));
  if (handle && channel == 0) {
    handle->processed = echo != 0;
    fs_capture_set_echo_cancellation(handle, echo);
  }
  return handle;
}
void fs_capture_finish(void *) {}
void fs_capture_stop(void *pointer) {
  auto *handle = static_cast<Handle *>(pointer);
  if (channels[handle->channel] == handle)
    channels[handle->channel] = nullptr;
  delete handle;
}
void *fs_speech_create(const char *runtime, const char *) {
  speech_runtime = runtime;
  ++speech_creations;
  return new Handle{true, -1};
}
void fs_speech_destroy(void *handle) {
  delete static_cast<Handle *>(handle);
}
int fs_speech_push(void *pointer, const int16_t *samples, size_t count, int) {
  if (count)
    static_cast<Handle *>(pointer)->marker = samples[0];
  return 0;
}
int fs_speech_finish(void *pointer, const char *) {
  ++speech_requests;
  auto *handle = static_cast<Handle *>(pointer);
  if (queue_speech) {
    handle->events.push_back(
        "{\"type\":\"state\",\"phase\":\"speech_queued\"}");
    return 0;
  }
  handle->events.push_back(speech_event.empty()
                               ? "{\"type\":\"transcript\",\"text\":\"marker_" +
                                     std::to_string(handle->marker) + "\"}"
                               : speech_event);
  handle->events.push_back("{\"type\":\"done\",\"status\":\"completed\"}");
  return 0;
}
char *fs_event_poll(void *pointer, int) {
  auto *handle = static_cast<Handle *>(pointer);
  if (handle->speech && hold_speech)
    return nullptr;
  if (handle->events.empty())
    return nullptr;
  auto event = handle->events.front();
  handle->events.pop_front();
  if (handle->speech &&
      event == "{\"type\":\"state\",\"phase\":\"speech_running\"}")
    ++speech_admissions_polled;
  return strdup(event.c_str());
}
void fs_string_free(char *text) {
  free(text);
}
}

// Controlled completion capability for Dart owner/ordering tests. These tokens
// emulate the public contract only; actual worker/poll/reap semantics are
// tested against native/foresight_native.cpp in native_owned_handles.
#include <map>
struct FixtureOperation {
  Handle *handle;
  int kind;
  bool completed = false;
};
static uint64_t next_operation = 1;
static std::map<uint64_t, FixtureOperation> operations;
static bool unconfirmed_retirement = false;
static bool hold_retirement = false, hold_finish = false,
            hold_speech_join = false;
extern "C" {
int fs_abi_version() {
  return 1;
}
int fs_lifetime_version() {
  return 2;
}
int fixture_capture_creations() {
  return capture_creations;
}
int fixture_pending_retirements() {
  int count = 0;
  for (const auto &[token, operation] : operations)
    if (!operation.completed && (operation.kind == 1 || operation.kind == 3))
      ++count;
  return count;
}
void fixture_unconfirmed_retirement(int value) {
  unconfirmed_retirement = value != 0;
}
void fixture_hold_retirement(int value) {
  hold_retirement = value != 0;
}
void fixture_hold_finish(int value) {
  hold_finish = value != 0;
}
void fixture_hold_speech_join(int value) {
  hold_speech_join = value != 0;
}
uint64_t fs_owned_engine_create(const char *, const char *, int, int) {
  return 0;
}
uint64_t fs_owned_conversation_create(uint64_t) {
  return 0;
}
char *fs_owned_engine_state(uint64_t) {
  return nullptr;
}
int fs_owned_generate_options(uint64_t, const char *, const char *,
                              const char *, int) {
  return -1;
}
int fs_owned_generate_tools(uint64_t, const char *, const char *, const char *,
                            int) {
  return -1;
}
int fs_owned_generation_tool_reply(uint64_t, const char *, const char *) {
  return -1;
}
int fs_owned_generation_cancel(uint64_t) {
  return -1;
}
uint64_t fs_owned_capture_start(const char *target, int channel, int rate,
                                int echo) {
  return publish(fs_capture_start_with_options(target, channel, rate, echo));
}
uint64_t fs_owned_speech_create(const char *runtime, const char *model) {
  return publish(fs_speech_create(runtime, model));
}
int fs_owned_capture_set_echo_cancellation(uint64_t owner, int value) {
  return fs_capture_set_echo_cancellation(resolve(owner), value);
}
int fs_owned_speech_push(uint64_t owner, const int16_t *samples, size_t count,
                         int rate) {
  return fs_speech_push(resolve(owner), samples, count, rate);
}
int fs_owned_speech_finish(uint64_t owner, const char *id) {
  return fs_speech_finish(resolve(owner), id);
}
int fs_owned_speech_cancel(uint64_t) {
  return 0;
}
char *fs_owned_event_poll(uint64_t owner, int timeout) {
  auto *handle = resolve(owner);
  return handle ? fs_event_poll(handle, timeout) : nullptr;
}
uint64_t fs_engine_probe_async(uint64_t) {
  return 0;
}
uint64_t fs_engine_retire(uint64_t) {
  return 0;
}
uint64_t fs_conversation_retire(uint64_t) {
  return 0;
}
uint64_t fixture_operation(uint64_t owner, int kind) {
  auto *handle = resolve(owner);
  if (!handle)
    return 0;
  if (kind == 1 || kind == 3) {
    const auto found = retirements.find(owner);
    if (found != retirements.end())
      return found->second;
  }
  const auto token = next_operation++;
  operations.emplace(token, FixtureOperation{handle, kind});
  if (kind == 1 || kind == 3)
    retirements.emplace(owner, token);
  return token;
}
uint64_t fs_speech_retire(uint64_t owner) {
  return fixture_operation(owner, 1);
}
uint64_t fs_speech_join_async(uint64_t owner) {
  return fixture_operation(owner, 4);
}
uint64_t fs_capture_finish_async(uint64_t owner) {
  return fixture_operation(owner, 2);
}
uint64_t fs_capture_retire(uint64_t owner) {
  return fixture_operation(owner, 3);
}
int fs_operation_status(uint64_t token) {
  auto found = operations.find(token);
  if (found == operations.end())
    return -1;
  auto &operation = found->second;
  if (operation.completed)
    return 1;
  if (unconfirmed_retirement && (operation.kind == 1 || operation.kind == 3))
    return 3;
  if (operation.kind == 2 ? hold_finish : hold_retirement)
    return 0;
  if ((operation.kind == 4 || operation.kind == 1) && hold_speech_join)
    return 0;
  if (operation.kind == 1)
    fs_speech_destroy(operation.handle);
  if (operation.kind == 3)
    fs_capture_stop(operation.handle);
  operation.completed = true;
  return 1;
}
int fs_owner_release(uint64_t owner) {
  const auto found = retirements.find(owner);
  if (found == retirements.end())
    return -1;
  auto operation = operations.find(found->second);
  if (operation == operations.end() || !operation->second.completed)
    return -1;
  operations.erase(operation);
  retirements.erase(found);
  owners.erase(owner);
  return 0;
}
int fs_operation_release(uint64_t token) {
  const auto found = operations.find(token);
  if (found == operations.end() || !found->second.completed)
    return -1;
  operations.erase(found);
  return 0;
}
}
