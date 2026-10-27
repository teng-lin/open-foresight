#pragma once
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace foresight {
// Disk I/O and allocation happen outside capture callbacks. Each instance owns
// one conditioned 48 kHz, mono PCM16 source; silence is ordinary PCM.
class RecordingWriter {
public:
  static constexpr uint32_t sample_rate = 48000;
  static constexpr size_t block_frames = 4800;
  static constexpr size_t queue_blocks = 64; // 6.4 s / 614400 PCM bytes.
  static constexpr uint64_t chunk_frames = 240000;
  static constexpr size_t reservation_limit = 64;
  struct Identity {
    std::array<char, 37> session{}, generation{}, chunk{};
    uint32_t source = 0;
    uint64_t sequence = 0;
    bool operator==(const Identity &) const = default;
  };
  struct Chunk {
    Identity identity;
    uint64_t span = 0, source_sample = 0, frames = 0;
    int64_t capture_start_us = 0;
    uint64_t bytes = 0;
    std::string relative_path;
    bool interrupted = false, gap_before = false;
    // Contents: fsync on Linux, F_FULLFSYNC on macOS, with no weaker fallback.
    // Directory: fsync success only; this is not a macOS power-loss assertion.
    bool contents_synced = false, directory_synced = false;
  };
  enum class Result {
    accepted,
    stopped,
    busy,
    overflow,
    no_reservation,
    failed
  };
  enum class Fault {
    none,
    short_write,
    write,
    content_sync,
    rename,
    directory_sync
  };
  struct Options {
    // Inclusive range [block_frames, chunk_frames].
    uint64_t frames_per_chunk = chunk_frames;
    // Best-effort metadata/recovery headroom; external writers and per-user
    // quotas can still cause a later write failure. No sparse file pre-sizing.
    uint64_t minimum_free_bytes = 64ULL * 1024 * 1024;
    // Explicit fixture-only dependency injection, never a global/env override.
    Fault fault = Fault::none;
    // Invoked off realtime after the error latches; owning capture may cancel.
    std::function<void()> on_error;
    std::chrono::milliseconds test_write_delay{0};
    std::function<uint64_t()> test_available_bytes;
  };
  explicit RecordingWriter(const std::string &private_directory);
  RecordingWriter(const std::string &private_directory, Options options);
  ~RecordingWriter();
  RecordingWriter(const RecordingWriter &) = delete;
  RecordingWriter &operator=(const RecordingWriter &) = delete;
  // Blocking, off-callback. Caller must first commit this identity to its live
  // session/media generation. Persists an exclusive, synced adoption intent.
  bool reserve(const Identity &identity);
  // Single capture producer. Lifecycle/reservation calls are serialized by
  // the owning service; stop/destruction may not race each other.
  // Bounded copies, no allocation, mutex or I/O. Atomic SPSC handoff; reserve
  // and drainPublished cannot contend with this producer. busy means another
  // capture producer incorrectly entered concurrently, not disk-worker load.
  // A non-accepted result admits NONE of the supplied frames. Caller must make
  // storage failures visible and fence acquisition rather than dropping audio.
  Result tryAppend(const int16_t *samples, size_t frames, uint64_t span,
                   uint64_t source_sample, int64_t capture_start_us,
                   bool gap_before = false) noexcept;
  // Acquisition must already be fenced by caller. Drains and seals the span;
  // blocks on disk I/O, never call from a capture callback. Resume uses new
  // span.
  bool sealSpan();
  // OS filesystem sync calls have no finite deadline. Run this on the service
  // storage owner, never the capture/control event thread.
  void stop(); // Idempotent submission fence + worker drain + partial seal.
  std::vector<Chunk> drainPublished(); // Bounded metadata, no PCM.
  struct Pressure {
    uint64_t queued_frames = 0, ready_chunks = 0, outstanding_chunks = 0,
             published_chunks = 0;
  };
  Pressure pressure() const noexcept;
  std::string error() const; // Stable until owner is destroyed.
  // Caller supplies only currently admissible, precommitted publication IDs.
  // No directory scanning/adoption by filename. Revoked/deleted generations
  // must be filtered BEFORE this call; this does not replace the DB fence.
  static std::vector<Chunk> recover(const std::string &private_directory,
                                    const std::vector<Identity> &authorized,
                                    const std::atomic<bool> *cancel = nullptr);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
} // namespace foresight
