#include "../../native/diagnostic_queue.cpp"

#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

using namespace foresight::diagnostics;

int main() {
  static_assert(sizeof(Queue) <= 262144);
  static_assert(sizeof(fs_diagnostic_record) == 64);
  assert(fs_diagnostic_abi_version() == 1);
  uint64_t token = 0;
  assert(fs_diagnostic_open(2, 64, &token) == FS_DIAGNOSTIC_INVALID);
  assert(token == 0);
  assert(fs_diagnostic_open(1, 63, &token) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_open(1, 64, nullptr) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_open(1, 64, &token) == FS_DIAGNOSTIC_OK);
  const auto first_token = token;
  uint64_t other = 99;
  assert(fs_diagnostic_open(1, 64, &other) == FS_DIAGNOSTIC_UNAVAILABLE);
  assert(other == 99);
  std::array<fs_diagnostic_record, 64> records{};
  fs_diagnostic_batch batch{};
  auto drain = [&](uint32_t flags = 0) {
    return fs_diagnostic_drain(token, 1, 64, records.data(), records.size(),
                               flags, &batch, sizeof(batch));
  };
  assert(!capture_state(0, 1, 0, true)); // Off by default.
  assert(!worker_failed(0, 3, -1, 0));
  assert(drain() == 0 && batch.count == 0);
  configure(Level::error);
  assert(!capture_state(0, 1, 0, true));
  assert(worker_failed(0, 3, -1, 0));
  assert(drain() == 0 && batch.count == 1);
  assert(records[0].event == FS_DIAGNOSTIC_WORKER_FAILED);
  assert(records[0].status == -1 && records[0].component == 5);
  configure(Level::info);
  assert(!capture_state(12, 1, 0, true));
  assert(!capture_state(0, 9, 0, true));
  assert(!capture_state(0, 1, 0, true, maximum_number + 1));
  assert(!worker_failed(0, 3, 0, 0, maximum_number + 1));
  assert(drain() == 0 && batch.count == 0);

  // Invalid calls are transactional: no outputs/counters/records change.
  assert(capture_state(0, 1, 12, true, 34));
  const auto unchanged_records = records;
  const auto unchanged_batch = batch;
  for (const auto capacity : {0u, 65u}) {
    assert(fs_diagnostic_drain(token, 1, 64, records.data(), capacity, 0,
                               &batch, sizeof(batch)) == FS_DIAGNOSTIC_INVALID);
  }
  assert(fs_diagnostic_drain(token, 2, 64, records.data(), 64, 0, &batch,
                             sizeof(batch)) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_drain(token, 1, 63, records.data(), 64, 0, &batch,
                             sizeof(batch)) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_drain(token, 1, 64, records.data(), 64, 2, &batch,
                             sizeof(batch)) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_drain(token, 1, 64, records.data(), 64, 0, &batch,
                             sizeof(batch) - 1) == FS_DIAGNOSTIC_INVALID);
  assert(std::memcmp(records.data(), unchanged_records.data(),
                     sizeof(records)) == 0);
  assert(std::memcmp(&batch, &unchanged_batch, sizeof(batch)) == 0);
  assert(drain() == 0 && batch.count == 1);
  assert(records[0].queued == 12 && records[0].active == 1 &&
         records[0].duration_us == 34);

  // Full normal lane cannot consume the priority reserve.
  for (size_t i = 0; i < general_capacity; ++i)
    assert(capture_state(0, 1, i, true));
  assert(!capture_state(0, 1, 0, true));
  for (size_t i = 0; i < priority_capacity; ++i)
    assert(worker_failed(0, 3, i, 0));
  assert(!worker_failed(0, 3, 0, 0));
  assert(drain(FS_DIAGNOSTIC_PRIORITY_ONLY) == 0 && batch.count == 64);
  const auto overtaking_sequence = records[0].sequence;
  assert(batch.dropped_general == 1 && batch.dropped_priority == 1);
  for (uint32_t i = 0; i < batch.count; ++i)
    assert(records[i].event == FS_DIAGNOSTIC_WORKER_FAILED);
  size_t priority_drained = batch.count;
  while (true) {
    assert(drain(FS_DIAGNOSTIC_PRIORITY_ONLY) == 0);
    assert(batch.dropped_general == 0 && batch.dropped_priority == 0);
    priority_drained += batch.count;
    if (batch.count == 0)
      break;
  }
  assert(priority_drained == priority_capacity);
  uint64_t previous_sequence = 0, previous_time = 0;
  size_t normal_drained = 0;
  while (true) {
    assert(drain() == 0);
    normal_drained += batch.count;
    for (uint32_t i = 0; i < batch.count; ++i) {
      assert(records[i].event == FS_DIAGNOSTIC_CAPTURE_STATE);
      assert(records[i].sequence > previous_sequence);
      if (normal_drained == batch.count && i == 0)
        assert(records[i].sequence < overtaking_sequence);
      assert(records[i].monotonic_us >= previous_time);
      previous_sequence = records[i].sequence;
      previous_time = records[i].monotonic_us;
    }
    if (batch.count == 0)
      break;
  }
  assert(normal_drained == general_capacity);

  // Without restricted credits the two lanes merge in original admission
  // order. Older ordinary records remain valid after priority overtook them.
  assert(capture_state(0, 1, 1, true));
  assert(worker_failed(0, 3, 1, 0));
  assert(capture_state(0, 1, 2, true));
  assert(worker_failed(0, 3, 2, 0));
  assert(drain() == 0 && batch.count == 4);
  for (unsigned i = 0; i < 4; ++i) {
    assert(records[i].event ==
           (i % 2 ? FS_DIAGNOSTIC_WORKER_FAILED : FS_DIAGNOSTIC_CAPTURE_STATE));
    if (i != 0)
      assert(records[i].sequence > records[i - 1].sequence);
  }

  // A held gate never waits/spins in a producer, consumer or lifecycle call.
  {
    TryGuard hold;
    assert(hold.acquired);
    assert(!worker_failed(0, 3, 0, 0));
    assert(drain() == FS_DIAGNOSTIC_BUSY);
    assert(fs_diagnostic_close(token) == FS_DIAGNOSTIC_BUSY);
    assert(fs_diagnostic_open(1, 64, &other) == FS_DIAGNOSTIC_BUSY);
  }
  assert(drain() == 0 && batch.count == 0);
  assert(batch.flags == FS_DIAGNOSTIC_PRECISION_LOST);
  assert(drain() == 0 && batch.flags == 0);

  // Independently scheduled producers contend with one bounded consumer.
  std::atomic<unsigned> running{4};
  std::vector<std::thread> producers;
  for (unsigned thread = 0; thread < 4; ++thread)
    producers.emplace_back([&] {
      for (unsigned i = 0; i < 20000; ++i)
        worker_failed(0, 3, i, 0);
      running.fetch_sub(1);
    });
  size_t concurrent_count = 0;
  previous_sequence = 0;
  while (true) {
    const bool finished = running.load() == 0;
    const auto result = drain();
    if (result == FS_DIAGNOSTIC_BUSY)
      continue;
    assert(result == 0);
    concurrent_count += batch.count;
    for (uint32_t i = 0; i < batch.count; ++i) {
      assert(records[i].sequence > previous_sequence);
      assert(records[i].event == FS_DIAGNOSTIC_WORKER_FAILED);
      previous_sequence = records[i].sequence;
    }
    if (finished && batch.count == 0)
      break;
  }
  for (auto &producer : producers)
    producer.join();
  assert(concurrent_count > 0 && concurrent_count <= 80000);

  // Saturation is explicit and monotonic identifiers never wrap/reuse.
  queue.dropped_priority = std::numeric_limits<uint64_t>::max();
  queue.sequence = std::numeric_limits<uint64_t>::max();
  assert(!worker_failed(0, 3, 0, 0));
  assert(drain() == 0 && batch.count == 0);
  assert(batch.dropped_priority == std::numeric_limits<uint64_t>::max());
  assert(batch.flags == FS_DIAGNOSTIC_COUNTER_SATURATED);
  assert(fs_diagnostic_close(token) == 0);
  assert(fs_diagnostic_close(token) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_open(1, 64, &token) == 0);
  assert(token > first_token);
  assert(fs_diagnostic_drain(first_token, 1, 64, records.data(), 64, 0, &batch,
                             sizeof(batch)) == FS_DIAGNOSTIC_INVALID);
  assert(fs_diagnostic_close(token) == 0);
  queue.next_token = std::numeric_limits<uint64_t>::max();
  assert(fs_diagnostic_open(1, 64, &token) == FS_DIAGNOSTIC_UNAVAILABLE);
  std::printf("queue contract passed; state=%zu bytes; record=%zu bytes; "
              "capacity=3000+1000; concurrent attempted=80000\n",
              sizeof(Queue), sizeof(fs_diagnostic_record));
}
