#if defined(FORESIGHT_FIXTURE_LEGACY)
extern "C" int fs_abi_version() {
  return 1;
}
#else
#include "diagnostic_queue.cpp"

namespace {
int pin_calls = 0, pin_result = 1, lifetime_version = 2;
}
extern "C" int fs_abi_version() {
  return 1;
}
extern "C" int fs_lifetime_version() {
  return lifetime_version;
}
extern "C" void fs_test_pin_version(int value) {
  lifetime_version = value;
}
// Fixture-only pin observation; actual NOLOAD pinning is qualified separately.
extern "C" int fs_lifetime_admission() {
  ++pin_calls;
  return pin_result;
}
extern "C" int fs_test_pin_calls() {
  return pin_calls;
}
extern "C" void fs_test_pin_result(int value) {
  pin_result = value;
}
extern "C" void fs_test_configure() {
  foresight::diagnostics::configure(foresight::diagnostics::Level::info);
}
extern "C" int fs_test_enqueue(int priority) {
  return priority ? foresight::diagnostics::worker_failed(10, 3, -1, 9, 12, 3)
                  : foresight::diagnostics::capture_state(0, 1, 4, true, 123);
}
extern "C" void fs_test_gate(int held) {
  if (held)
    queue.gate.test_and_set();
  else
    queue.gate.clear();
}
extern "C" void fs_test_malformed() {
  fs_diagnostic_record record{};
  record.sequence = ++queue.sequence;
  record.monotonic_us = 1;
  record.event = FS_DIAGNOSTIC_CAPTURE_STATE;
  record.component = 6;
  record.category = 12; // Outside the closed native/Dart catalog.
  queue.general.append(record);
}
extern "C" void fs_test_high_sequence() {
  queue.sequence = uint64_t{1} << 63;
}
extern "C" void fs_test_saturated_drops() {
  queue.dropped_priority = UINT64_MAX;
  queue.counter_saturated = true;
}
extern "C" void fs_test_clamped_drops() {
  queue.dropped_general = uint64_t{1} << 31;
}
extern "C" void fs_test_bad_sequence(int priority, int mode) {
  const auto previous = queue.sequence;
  fs_test_enqueue(priority);
  const auto invalid = mode == 0 ? previous : mode == 1 ? previous - 1 : 1;
  if (priority) {
    auto &ring = queue.priority;
    ring.records[(ring.head + ring.count - 1) % priority_capacity].sequence =
        invalid;
  } else {
    auto &ring = queue.general;
    ring.records[(ring.head + ring.count - 1) % general_capacity].sequence =
        invalid;
  }
}
#endif
