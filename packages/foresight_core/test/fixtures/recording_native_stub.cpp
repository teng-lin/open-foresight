// Deterministic acquisition/ASR ABI fixture. It never accesses audio devices.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
struct Handle {
  bool speech;
  int channel;
  int marker = 0;
  std::deque<std::string> events;
  bool processed = false;
};
static Handle *channels[2] = {};
static int fail_channel = -1;
static std::string speech_event;
static bool hold_speech = false;
static bool queue_speech = false;
static int speech_creations = 0;
static std::string speech_runtime;
extern "C" {
const char *fixture_speech_runtime() {
  return speech_runtime.c_str();
}
int fixture_speech_creations() {
  return speech_creations;
}
void fixture_hold_speech(int hold) {
  hold_speech = hold != 0;
}
void fixture_queue_speech(int queued) {
  queue_speech = queued != 0;
}
void fixture_admit_speech(void *pointer, int complete) {
  auto *handle = static_cast<Handle *>(pointer);
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
  return strdup(event.c_str());
}
void fs_string_free(char *text) {
  free(text);
}
}
