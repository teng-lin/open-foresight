#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

namespace foresight {
// Exactly one serialized non-RT producer and one RT consumer. Reset is legal
// only after producer exclusion and the callback fence. All counters are PCM
// FRAMES (two int16 samples per frame), never bytes or device-audible position.
class PcmOutputQueue {
public:
  static constexpr size_t channels = 2, rate = 48000;
  static constexpr size_t maximum_push_frames = 4800;
  static constexpr size_t capacity_frames = 16 * maximum_push_frames;
  size_t push(const int16_t *pcm, size_t frames) noexcept {
    const auto write = write_.load(std::memory_order_relaxed);
    const auto read = read_.load(std::memory_order_acquire);
    const auto count = std::min(frames, capacity_frames - size_t(write - read));
    const auto offset = size_t(write % capacity_frames);
    const auto first = std::min(count, capacity_frames - offset);
    if (first)
      std::memcpy(pcm_.data() + offset * channels, pcm,
                  first * channels * sizeof(int16_t));
    if (count > first)
      std::memcpy(pcm_.data(), pcm + first * channels,
                  (count - first) * channels * sizeof(int16_t));
    write_.store(write + count, std::memory_order_release);
    return count;
  }
  template <class Write>
  size_t consume(size_t requested, Write write) noexcept {
    const auto read = read_.load(std::memory_order_relaxed);
    const auto available = write_.load(std::memory_order_acquire) - read;
    const auto count = std::min(requested, size_t(available));
    for (size_t frame = 0; frame < count; ++frame) {
      const auto at = size_t((read + frame) % capacity_frames) * channels;
      write(frame, pcm_[at], pcm_[at + 1]);
    }
    read_.store(read + count, std::memory_order_release);
    return count;
  }
  size_t queued() const noexcept {
    // The producer can advance while the consumer reads; sample read first so
    // a concurrent consume cannot make this independent snapshot underflow.
    const auto read = read_.load(std::memory_order_acquire);
    const auto write = write_.load(std::memory_order_acquire);
    return std::min(capacity_frames, size_t(write - read));
  }
  void reset() noexcept {
    read_ = 0;
    write_ = 0;
  }

private:
  std::array<int16_t, capacity_frames * channels> pcm_{};
  std::atomic<uint64_t> write_{0}, read_{0};
};

class PcmOutput;
class PcmOutputBackend {
public:
  virtual ~PcmOutputBackend() = default;
  virtual void
  start() = 0; // Create a paused device/stream; not an RT callback.
  virtual void pause() = 0;
  virtual void resume() = 0;
  virtual void
  stop() = 0; // Must destroy/disconnect and join callback ownership.
};
std::unique_ptr<PcmOutputBackend> make_pcm_output_backend(PcmOutput &,
                                                          const std::string &);

class PcmOutput {
public:
  enum class Error { none, unavailable, format, device_lost, backend_failure };
  struct Snapshot {
    uint64_t generation, rendered_frames, underruns;
    size_t queued_frames;
    bool ready, paused, stopped, buffering;
    Error error;
  };
  using BackendFactory =
      std::unique_ptr<PcmOutputBackend> (*)(PcmOutput &, const std::string &);
  PcmOutput(uint64_t generation, std::string target,
            BackendFactory factory = make_pcm_output_backend)
      : generation_(generation), target_(std::move(target)), factory_(factory) {
    if (!generation || generation > uint64_t(INT64_MAX) ||
        target_.size() > 1024 || target_.find('\0') != std::string::npos)
      throw std::invalid_argument("invalid_pcm_output_options");
  }
  ~PcmOutput() noexcept;
  // All lifecycle work runs on the owner's serialized executor, never RT/Dart.
  bool start();
  bool pause_flush(uint64_t generation);
  bool resume(uint64_t generation);
  bool finish();
  // Immediately revoke ordinary producer admission before asynchronous work.
  // A callback may finish its current block until the operation ACK.
  void revoke() noexcept;
  bool request_flush(uint64_t next_generation);
  int push(uint64_t generation, const int16_t *, size_t frames);
  Snapshot snapshot() const noexcept;
  void fail(Error error) noexcept;
  static const char *error_name(Error) noexcept;
  // Platform RT entrypoints. Caller supplies already-allocated host buffers.
  // Silence/underruns never advance rendered_frames. No locks/allocation/IO.
  void render(int16_t *interleaved, size_t frames) noexcept;
  void render(float *left, float *right, size_t frames) noexcept;
  bool stopping() const noexcept {
    return closing_.load();
  }

private:
  PcmOutputQueue queue_;
  mutable std::mutex producer_;
  std::unique_ptr<PcmOutputBackend> backend_;
  std::atomic<uint64_t> generation_, rendered_{0}, underruns_{0};
  std::atomic<uint32_t> callbacks_{0};
  std::atomic<bool> render_enabled_{false}, accepting_{false}, closing_{false};
  std::atomic<bool> ready_{false}, paused_{true}, stopped_{false},
      buffering_{false};
  std::atomic<Error> error_{Error::none};
  const std::string target_;
  BackendFactory factory_;
  void callback_fence();
  template <class Write> void consume(size_t frames, Write write) noexcept {
    callbacks_.fetch_add(1, std::memory_order_seq_cst);
    if (render_enabled_.load(std::memory_order_seq_cst) &&
        !closing_.load(std::memory_order_acquire) &&
        error_.load(std::memory_order_acquire) == Error::none) {
      const auto count = queue_.consume(frames, write);
      rendered_.fetch_add(count, std::memory_order_relaxed);
      buffering_.store(count != frames, std::memory_order_relaxed);
      if (count != frames)
        underruns_.fetch_add(1, std::memory_order_relaxed);
    }
    callbacks_.fetch_sub(1, std::memory_order_seq_cst);
  }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<PcmOutput::Error>::is_always_lock_free);
} // namespace foresight
