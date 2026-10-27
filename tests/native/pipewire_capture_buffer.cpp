#include "../../native/pipewire_capture_buffer.h"
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace {
using Buffer = foresight::PipeWireCaptureBuffer;
void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}
void pcm_bounds_and_silence() {
  Buffer ring;
  const unsigned char bytes[]{1, 2, 3, 4, 5, 6, 7, 8};
  Buffer::Block block;
  require(ring.push(bytes, sizeof(bytes), 6, 6, false, 1001,
                    Buffer::Clock::header_pts),
          "wrapped block admitted");
  require(ring.pop(block) && block.size == 6 && block.pcm[0] == 7 &&
              block.pcm[1] == 8 && block.pcm[2] == 1 && block.pcm[5] == 4 &&
              block.timestamp_us == 1001 &&
              block.clock == Buffer::Clock::header_pts,
          "wrapped PCM extent and acquisition metadata preserved");
  require(ring.push(nullptr, 8, 7, 8, true, 2001, Buffer::Clock::graph_cycle),
          "empty graph block admitted as silence");
  require(ring.pop(block) && block.size == 8 && block.timestamp_us == 2001 &&
              block.clock == Buffer::Clock::graph_cycle,
          "graph provenance remains distinct");
  for (size_t i = 0; i < block.size; ++i)
    require(block.pcm[i] == 0, "silence is retained");
  require(
      !ring.push(bytes, 8, 0, 3, false, 0, Buffer::Clock::graph_cycle) &&
          !ring.push(bytes, 8, 0, 10, false, 0, Buffer::Clock::graph_cycle) &&
          !ring.push(nullptr, 8, 0, 8, false, 0, Buffer::Clock::graph_cycle) &&
          !ring.push(bytes, 0, 0, 0, false, 0, Buffer::Clock::graph_cycle),
      "invalid mappings and non-PCM extents refused");
  require(!ring.pop(block), "refused frames never enter queue");
}
void saturation_preserves_prefix() {
  Buffer ring;
  std::array<unsigned char, Buffer::block_bytes> bytes{};
  for (size_t i = 0; i < Buffer::capacity; ++i) {
    bytes[0] = static_cast<unsigned char>(i);
    require(ring.push(bytes.data(), bytes.size(), 0, bytes.size(), false,
                      static_cast<int64_t>(i * 100000),
                      Buffer::Clock::graph_cycle),
            "bounded prefix admitted");
  }
  require(!ring.push(bytes.data(), bytes.size(), 0, bytes.size(), false, 999,
                     Buffer::Clock::graph_cycle),
          "overflow refused explicitly");
  Buffer::Block block;
  for (size_t i = 0; i < Buffer::capacity; ++i)
    require(ring.pop(block) && block.size == bytes.size() &&
                block.pcm[0] == i &&
                block.timestamp_us == static_cast<int64_t>(i * 100000),
            "overflow cannot replace previously accepted samples");
  require(!ring.pop(block), "only accepted prefix drained");
}
void graph_tick_outages() {
  using Clock = foresight::PipeWireCaptureClock;
  Clock graph;
  require(graph.observe(1024, 1, 48000, 1024) == Clock::Result::continuous &&
              graph.observe(2048, 1, 48000, 1024) == Clock::Result::continuous,
          "continuous graph samples retained");
  require(graph.observe(4096, 1, 48000, 1024) == Clock::Result::gap,
          "one missing quantum cannot hide inside phase tolerance");
  require(graph.observe(5120, 1, 48000, 1024) == Clock::Result::continuous,
          "gap establishes next contiguous graph boundary");
  require(graph.observe(5120, 1, 48000, 1024) == Clock::Result::invalid &&
              graph.observe(5000, 1, 48000, 1024) == Clock::Result::invalid &&
              graph.observe(6144, 1, 44100, 1024) == Clock::Result::invalid,
          "duplicate/backward/rate-changing graph time refused");
  Clock resampled;
  require(
      resampled.observe(1024, 1, 44100, 1115) == Clock::Result::continuous &&
          resampled.observe(2048, 1, 44100, 1114) == Clock::Result::continuous,
      "rational graph rate accepts canonical resampler rounding");
}
void concurrent_handoff() {
  Buffer ring;
  constexpr uint64_t count = 20000;
  std::atomic<bool> done{false};
  std::thread producer([&] {
    for (uint64_t i = 0; i < count; ++i) {
      std::array<unsigned char, 8> bytes{};
      for (size_t j = 0; j < bytes.size(); ++j)
        bytes[j] = static_cast<unsigned char>(i >> (j * 8));
      while (!ring.push(bytes.data(), bytes.size(), 0, bytes.size(), false,
                        static_cast<int64_t>(i), Buffer::Clock::header_pts))
        std::this_thread::yield();
    }
    done = true;
  });
  uint64_t consumed = 0;
  Buffer::Block block;
  while (consumed != count) {
    if (!ring.pop(block)) {
      std::this_thread::yield();
      continue;
    }
    uint64_t value = 0;
    for (size_t j = 0; j < 8; ++j)
      value |= uint64_t(block.pcm[j]) << (j * 8);
    if (value != consumed || block.size != 8 ||
        block.timestamp_us != static_cast<int64_t>(consumed))
      std::abort();
    ++consumed;
  }
  producer.join();
  require(done && !ring.pop(block),
          "concurrent producer published every block exactly once");
}
} // namespace
int main() {
  try {
    pcm_bounds_and_silence();
    saturation_preserves_prefix();
    graph_tick_outages();
    concurrent_handoff();
    std::cout << "4 PipeWire bounded handoff scenarios passed; 0 skipped\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
