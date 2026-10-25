#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../../native/foresight_native.cpp"

#include <array>
#include <cassert>
#include <cstdio>

int main(int argc, char **argv) {
  assert(argc >= 1);
  // Fixture-only executable route, installed before any native worker starts.
  // This exercises actual capture-thread lifecycle, not audio/device access.
  assert(setenv("FORESIGHT_CAPTURE_RUNTIME", "/usr/bin/false", 1) == 0);
  uint64_t token = 0;
  assert(fs_diagnostic_open(1, sizeof(fs_diagnostic_record), &token) == 0);
  std::array<fs_diagnostic_record, 64> records{};
  fs_diagnostic_batch batch{};
  auto drain = [&] {
    assert(fs_diagnostic_drain(token, 1, sizeof(fs_diagnostic_record),
                               records.data(), records.size(), 0, &batch,
                               sizeof(batch)) == 0);
  };
  Worker worker;
  uint64_t sequence = 0;
  failure(worker, "private-request-canary", sequence, "runtime_failure",
          "private-vendor-canary");
  drain();
  assert(batch.count == 0); // Logging is off before explicit configuration.
  assert(worker.events.size() == 1 && sequence == 1);
  assert(fs_set_runtime_environment("FORESIGHT_LOG_LEVEL", "invalid") == -1);
  assert(fs_set_runtime_environment("UNREGISTERED_LOG_KEY", "info") == -1);
  assert(fs_set_runtime_environment("FORESIGHT_LOG_LEVEL", "info") == 0);
  failure(worker, "private-request-canary", sequence, "tool_protocol",
          "private-vendor-canary");
  drain();
  assert(batch.count == 1);
  const auto &failure_record = records[0];
  assert(failure_record.event == FS_DIAGNOSTIC_WORKER_FAILED);
  assert(failure_record.component == 5 && failure_record.category == 6 &&
         failure_record.outcome == 3);
  assert(failure_record.status == 0 && failure_record.signal == 0 &&
         failure_record.bytes == 0 && failure_record.dropped == 0 &&
         failure_record.duration_us == 0 && failure_record.queued == 0 &&
         failure_record.active == 0);
  // The existing business event still has its complete protocol identity and
  // error payload; diagnostics never copies those free-text fields.
  assert(worker.events.size() == 2 && sequence == 2);
  assert(worker.events.back().find("private-vendor-canary") !=
         std::string::npos);

  // A real engine handle seals configuration without starting model work.
  auto *engine = fs_engine_create("/fixture-runtime-never-started", argv[0]);
  assert(engine != nullptr);
  assert(fs_set_runtime_environment("FORESIGHT_LOG_LEVEL", "info") == 0);
  assert(fs_set_runtime_environment("FORESIGHT_LOG_LEVEL", "off") == -1);
  assert(fs_set_runtime_environment("FORESIGHT_LOG_LEVEL", "invalid") == -1);
  failure(worker, "private-request-canary", sequence, "runtime_failure",
          "private-vendor-canary");
  drain();
  assert(batch.count == 1 && records[0].category == 10);
  assert(fs_engine_destroy(engine) == 0);
  auto *capture = fs_capture_start("auto", 0, 8000);
  assert(capture != nullptr);
  fs_capture_finish(capture);
  fs_capture_stop(capture);
  drain();
  bool capture_started = false, capture_stopped = false;
  for (uint32_t at = 0; at < batch.count; ++at) {
    const auto &record = records[at];
    if (record.event != FS_DIAGNOSTIC_CAPTURE_STATE)
      continue;
    capture_started |= record.outcome == 0 && record.active == 1;
    capture_stopped |= record.outcome == 4 && record.active == 0;
  }
  assert(capture_started && capture_stopped);
  assert(fs_diagnostic_close(token) == 0);
  std::puts(
      "native diagnostic producer and sealed configuration contract passed");
}
