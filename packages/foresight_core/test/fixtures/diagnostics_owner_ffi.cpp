// Controlled FFI ownership backend only. No OS child or production storage is
// created: these calls hold the actual writer/spawn isolate until explicit
// release, so a returned result cannot stand in for that isolate's VM exit.
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>

namespace {
std::atomic<int> state{1}, spawn_calls{0}, append_calls{0};
int reply_type = 1;
bool delayed_retire = false;
uint64_t reply_id = 0;
std::string root, mode;
void hold() {
  auto entered = root + ".entered";
  if (auto *file = std::fopen(entered.c_str(), "w")) {
    std::fputs("entered", file);
    std::fclose(file);
  }
  auto release = root + ".release";
  while (::access(release.c_str(), F_OK) != 0)
    ::usleep(1000);
}
} // namespace

extern "C" {
uint64_t fs_diag_parent_reserve(const char *, const char *, const char *,
                                const uint8_t *arguments, uint32_t bytes,
                                uint32_t count) {
  if (count != 6 || bytes > 2048)
    return 0;
  uint32_t offset = 0;
  for (uint32_t index = 0; index < count; ++index) {
    if (offset >= bytes)
      return 0;
    auto *text = reinterpret_cast<const char *>(arguments + offset);
    auto length = ::strnlen(text, bytes - offset);
    if (!length || length == bytes - offset)
      return 0;
    if (index == 4)
      root.assign(text, length);
    if (index == 5)
      mode.assign(text, length);
    offset += static_cast<uint32_t>(length) + 1;
  }
  return offset == bytes ? 1 : 0;
}
int fs_diag_parent_prepare(uint64_t) {
  if (mode == "prepare")
    hold();
  state.fetch_or(2);
  return 2;
}
int fs_diag_parent_spawn(uint64_t) {
  ++spawn_calls;
  if (mode == "spawn")
    hold();
  state.fetch_or(8 | 256);
  return 8;
}
int fs_diag_parent_poll(uint64_t) {
  return state.load();
}
int fs_diag_parent_force(uint64_t) {
  state.fetch_or(64);
  return 64;
}
int fs_diag_parent_heartbeat(uint64_t) {
  return 0;
}
int fs_diag_parent_exit_class(uint64_t) {
  return 0;
}
uint64_t fs_diag_child_arm(int64_t, const char *, const char *, const char *) {
  return 0;
}
int fs_diag_child_watch(uint64_t) {
  return -1;
}
int fs_diag_child_map(uint64_t) {
  return -1;
}
int fs_diag_child_operation(uint64_t, int) {
  return -1;
}
// This backend is parent-role only; the child-only operation must reject it.
int fs_diag_child_finish(uint64_t, int) {
  return -1;
}
int fs_diag_support_send(uint64_t, uint8_t type, uint64_t id, uint32_t,
                         const uint8_t *, uint32_t) {
  if (mode != "ack-exit" && mode != "ack-exit-race")
    return -1;
  reply_type = type == 8 ? 9 : 3;
  reply_id = id;
  if (type == 6)
    ++append_calls;
  if (type == 8 && mode == "ack-exit")
    state.fetch_or(16); // Final RETIRED is published before observed exit.
  return 2;
}
int fs_diag_support_receive(uint64_t, uint8_t *bytes, uint32_t,
                            uint32_t *copied, uint8_t *type, uint64_t *id,
                            uint32_t *total) {
  if (mode != "ack-exit" && mode != "ack-exit-race")
    return -1;
  *copied = *total = 0;
  if (!reply_type)
    return 0;
  if (reply_type == 9 && mode == "ack-exit-race" && !delayed_retire) {
    delayed_retire = true;
    // Emulate publication+exit after an EMPTY receive, before the next poll.
    state.fetch_or(16);
    return 0;
  }
  *type = static_cast<uint8_t>(reply_type);
  *id = reply_id;
  if (reply_type == 3 || reply_type == 9) {
    const uint8_t response[] = {
        1, 0, static_cast<uint8_t>(reply_type == 9 ? 7 : 0), 5};
    std::memcpy(bytes, response, sizeof(response));
    *copied = *total = sizeof(response);
  }
  reply_type = 0;
  return 2;
}
int fs_diag_fixture_append_calls() {
  return append_calls.load();
}
int fs_diag_fixture_spawn_calls() {
  return spawn_calls.load();
}
}
