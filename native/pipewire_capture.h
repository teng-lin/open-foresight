#pragma once
#include "pipewire_capture_buffer.h"
#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace foresight {
enum class PipeWireCaptureError {
  none,
  unavailable,
  format,
  clock,
  discontinuity,
  callback,
  overflow
};
struct PipeWireCaptureResult {
  PipeWireCaptureError error = PipeWireCaptureError::none;
  const char *message = "";
};
// RT process only copies bounded PCM/clock metadata to a preallocated SPSC
// ring. The owning non-RT service worker delivers it before legacy events.
// Header PTS and per-buffer graph-cycle timestamps remain distinct provenance;
// neither is replaced with callback/drain arrival time. Graph-cycle timing has
// no claimed physical-device uncertainty until route loopback qualification.
PipeWireCaptureResult capture_pipewire_timed(
    const std::string &target, bool playback, std::atomic<bool> &cancel,
    const std::function<void(const std::vector<unsigned char> &, int64_t,
                             PipeWireCaptureBuffer::Clock, bool)> &pcm);
} // namespace foresight
