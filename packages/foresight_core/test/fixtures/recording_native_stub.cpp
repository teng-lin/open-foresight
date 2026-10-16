// Deterministic acquisition/ASR ABI fixture. It never accesses audio devices.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
struct Handle { bool speech; int channel; int marker = 0; std::deque<std::string> events; };
static Handle* channels[2] = {};
static int fail_channel = -1;
static std::string speech_event;
extern "C" {
void fixture_speech_event(const char* event) { speech_event = event; }
void fixture_fail_channel(int channel) { fail_channel = channel; }
int fixture_emit(int channel, const char* event) {
  if (!channels[channel]) return 0;
  channels[channel]->events.emplace_back(event);
  return 1;
}
void* fs_capture_start(const char*, int channel, int) {
  if (channel == fail_channel) return nullptr;
  auto* handle = new Handle{false, channel};
  channels[channel] = handle;
  return handle;
}
void fs_capture_finish(void*) {}
void fs_capture_stop(void* pointer) {
  auto* handle = static_cast<Handle*>(pointer);
  if (channels[handle->channel] == handle) channels[handle->channel] = nullptr;
  delete handle;
}
void* fs_speech_create(const char*, const char*) { return new Handle{true, -1}; }
void fs_speech_destroy(void* handle) { delete static_cast<Handle*>(handle); }
int fs_speech_push(void* pointer, const int16_t* samples, size_t count, int) {
  if (count) static_cast<Handle*>(pointer)->marker = samples[0];
  return 0;
}
int fs_speech_finish(void* pointer, const char*) {
  auto* handle = static_cast<Handle*>(pointer);
  handle->events.push_back(speech_event.empty()
      ? "{\"type\":\"transcript\",\"text\":\"marker_" + std::to_string(handle->marker) + "\"}"
      : speech_event);
  handle->events.push_back("{\"type\":\"done\",\"status\":\"completed\"}");
  return 0;
}
char* fs_event_poll(void* pointer, int) {
  auto* handle = static_cast<Handle*>(pointer);
  if (handle->events.empty()) return nullptr;
  auto event = handle->events.front();
  handle->events.pop_front();
  return strdup(event.c_str());
}
void fs_string_free(char* text) { free(text); }
}
