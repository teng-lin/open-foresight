#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace foresight {
// Graph-tick continuity is separate from CLOCK_MONOTONIC phase jitter. A
// missing quantum must remain a gap even when graph-cycle phase is uncertain.
class PipeWireCaptureClock {
public:
  enum class Result { continuous, gap, invalid };
  Result observe(uint64_t ticks, uint32_t numerator, uint32_t denominator,
                 size_t frames) noexcept {
    if (!numerator || !denominator || !frames || frames > 4800)
      return Result::invalid;
    auto result = Result::continuous;
    if (seen_) {
      if (numerator != numerator_ || denominator != denominator_ ||
          ticks < ticks_)
        return Result::invalid;
      const auto elapsed_us = static_cast<long double>(ticks - ticks_) *
                              numerator * 1000000 / denominator;
      const auto expected_us =
          static_cast<long double>(frames_) * 1000000 / 48000;
      // One graph tick plus one canonical sample plus integer conversion.
      const auto tolerance_us =
          static_cast<long double>(numerator) * 1000000 / denominator + 23;
      if (elapsed_us < expected_us - tolerance_us)
        return Result::invalid;
      if (elapsed_us > expected_us + tolerance_us)
        result = Result::gap;
    }
    seen_ = true;
    ticks_ = ticks;
    frames_ = frames;
    numerator_ = numerator;
    denominator_ = denominator;
    return result;
  }

private:
  bool seen_ = false;
  uint64_t ticks_ = 0;
  size_t frames_ = 0;
  uint32_t numerator_ = 0, denominator_ = 0;
};

// Single PipeWire process producer / owning service-worker consumer. Capacity
// and allocation are fixed before stream connection. Returning false is a
// visible storage-boundary failure, never an instruction to drop and continue.
class PipeWireCaptureBuffer {
  static_assert(std::atomic<uint64_t>::is_always_lock_free);

public:
  static constexpr size_t block_bytes = 4800 * 2;
  static constexpr size_t capacity = 64;
  enum class Clock { header_pts, graph_cycle };
  struct Block {
    std::array<unsigned char, block_bytes> pcm{};
    size_t size = 0;
    int64_t timestamp_us = 0;
    Clock clock = Clock::graph_cycle;
    bool gap_before = false;
  };
  bool push(const void *data, size_t mapped_bytes, size_t offset, size_t bytes,
            bool empty, int64_t timestamp_us, Clock clock,
            bool gap_before = false) noexcept {
    if (!bytes || bytes > block_bytes || bytes > mapped_bytes || (bytes & 1) ||
        !mapped_bytes || (!empty && !data))
      return false;
    const auto write = write_.load(std::memory_order_relaxed);
    if (write - read_.load(std::memory_order_acquire) == capacity)
      return false;
    auto &block = blocks_[write % capacity];
    block.size = bytes;
    block.timestamp_us = timestamp_us;
    block.clock = clock;
    block.gap_before = gap_before;
    if (empty) {
      std::memset(block.pcm.data(), 0, bytes);
    } else {
      offset %= mapped_bytes;
      const auto first =
          bytes < mapped_bytes - offset ? bytes : mapped_bytes - offset;
      std::memcpy(block.pcm.data(),
                  static_cast<const unsigned char *>(data) + offset, first);
      if (first != bytes)
        std::memcpy(block.pcm.data() + first, data, bytes - first);
    }
    write_.store(write + 1, std::memory_order_release);
    return true;
  }
  bool pop(Block &block) noexcept {
    const auto read = read_.load(std::memory_order_relaxed);
    if (read == write_.load(std::memory_order_acquire))
      return false;
    block = blocks_[read % capacity];
    read_.store(read + 1, std::memory_order_release);
    return true;
  }

private:
  std::array<Block, capacity> blocks_{};
  alignas(64) std::atomic<uint64_t> write_{0};
  alignas(64) std::atomic<uint64_t> read_{0};
};
} // namespace foresight
