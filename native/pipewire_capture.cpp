#include "pipewire_capture.h"
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <mutex>
#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/buffers.h>
#include <spa/pod/builder.h>
#include <time.h>

namespace foresight {
namespace {
constexpr uint32_t maximum_pcm_bytes = 4800 * 2;
static_assert(std::atomic<PipeWireCaptureError>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
struct Session {
  pw_main_loop *loop = nullptr;
  pw_stream *stream = nullptr;
  std::atomic<bool> &cancel;
  const std::function<void(const std::vector<unsigned char> &, int64_t,
                           PipeWireCaptureBuffer::Clock, bool)> &pcm;
  std::atomic<PipeWireCaptureError> error{PipeWireCaptureError::none};
  PipeWireCaptureBuffer handoff;
  PipeWireCaptureClock graph_clock;
  int64_t monotonic_offset_us = 0;
  std::atomic<bool> format_ready{false};
  bool seen_connection = false, seen_pcm = false;
  PipeWireCaptureBuffer::Clock first_clock =
      PipeWireCaptureBuffer::Clock::graph_cycle;
  std::chrono::steady_clock::time_point last_pcm =
      std::chrono::steady_clock::now();
  Session(std::atomic<bool> &closing,
          const std::function<void(const std::vector<unsigned char> &, int64_t,
                                   PipeWireCaptureBuffer::Clock, bool)> &output)
      : cancel(closing), pcm(output) {}
  ~Session() {
    if (stream) {
      pw_stream_disconnect(stream);
      pw_stream_destroy(stream);
    }
    if (loop)
      pw_main_loop_destroy(loop);
  }
  void fail(PipeWireCaptureError error) noexcept {
    auto expected = PipeWireCaptureError::none;
    this->error.compare_exchange_strong(expected, error);
  }
  static void state_changed(void *opaque, pw_stream_state,
                            pw_stream_state state, const char *) noexcept {
    auto &self = *static_cast<Session *>(opaque);
    if (state >= PW_STREAM_STATE_PAUSED)
      self.seen_connection = true;
    if (state == PW_STREAM_STATE_ERROR ||
        (state == PW_STREAM_STATE_UNCONNECTED && self.seen_connection &&
         !self.cancel))
      self.fail(PipeWireCaptureError::unavailable);
  }
  static void param_changed(void *opaque, uint32_t id,
                            const spa_pod *param) noexcept {
    auto &self = *static_cast<Session *>(opaque);
    if (id != SPA_PARAM_Format || !param)
      return;
    spa_audio_info_raw format{};
    if (spa_format_audio_raw_parse(param, &format) < 0 ||
        format.format != SPA_AUDIO_FORMAT_S16_LE || format.rate != 48000 ||
        format.channels != 1)
      self.fail(PipeWireCaptureError::format);
    else
      self.format_ready = true;
  }
  static void process(void *opaque) noexcept {
    auto &self = *static_cast<Session *>(opaque);
    try {
      for (size_t count = 0; count < 64 && !self.cancel &&
                             self.error == PipeWireCaptureError::none;
           ++count) {
        auto *buffer = pw_stream_dequeue_buffer(self.stream);
        if (!buffer)
          return;
        struct ReturnBuffer {
          Session &owner;
          pw_buffer *buffer;
          ~ReturnBuffer() {
            pw_stream_queue_buffer(owner.stream, buffer);
          }
        } returned{self, buffer};
        auto *data = buffer->buffer;
        if (!self.format_ready || !data || data->n_datas != 1 || !data->datas ||
            !data->datas[0].chunk || !data->datas[0].maxsize) {
          self.fail(PipeWireCaptureError::format);
          return;
        }
        auto &plane = data->datas[0];
        const auto size = plane.chunk->size;
        if (!size)
          continue;
        if (size > maximum_pcm_bytes || size > plane.maxsize || (size & 1) ||
            (plane.chunk->stride != 0 && plane.chunk->stride != 2)) {
          self.fail(PipeWireCaptureError::format);
          return;
        }
        auto *metadata =
            static_cast<spa_meta_header *>(spa_buffer_find_meta_data(
                data, SPA_META_Header, sizeof(spa_meta_header)));
        pw_time timing{};
        // Header.pts can be absent after graph adapters/mixing, even when
        // requested. Since PipeWire1.0.5 pw_buffer.time carries the graph cycle
        // CLOCK_MONOTONIC stamp assigned BEFORE dequeue. Preserve that distinct
        // provenance; it is not a physical-device acquisition claim.
        // https://docs.pipewire.org/structpw__buffer.html
        // https://docs.pipewire.org/structpw__time.html
        if (pw_stream_get_time_n(self.stream, &timing, sizeof(timing)) < 0 ||
            timing.now <= 0 || buffer->time == 0 ||
            buffer->time > uint64_t(std::numeric_limits<int64_t>::max())) {
          self.fail(PipeWireCaptureError::clock);
          return;
        }
        const auto clock = metadata && metadata->pts > 0
                               ? PipeWireCaptureBuffer::Clock::header_pts
                               : PipeWireCaptureBuffer::Clock::graph_cycle;
        bool gap_before = false;
        if (clock == PipeWireCaptureBuffer::Clock::graph_cycle) {
          // This RT event must have the matching per-buffer snapshot. Never
          // assign a newer graph tick to a buffer left queued in an old cycle.
          if (buffer->time != static_cast<uint64_t>(timing.now)) {
            self.fail(PipeWireCaptureError::clock);
            return;
          }
          const auto continuity = self.graph_clock.observe(
              timing.ticks, timing.rate.num, timing.rate.denom, size / 2);
          if (continuity == PipeWireCaptureClock::Result::invalid) {
            self.fail(PipeWireCaptureError::clock);
            return;
          }
          gap_before = continuity == PipeWireCaptureClock::Result::gap;
        }
        if (self.seen_pcm && clock != self.first_clock) {
          self.fail(PipeWireCaptureError::clock);
          return;
        }
        self.first_clock = clock;
        const auto timestamp_ns =
            clock == PipeWireCaptureBuffer::Clock::header_pts
                ? metadata->pts
                : static_cast<int64_t>(buffer->time);
        constexpr int64_t maximum_domain_difference_ns = 30000000000LL;
        const auto distance =
            timestamp_ns >= timing.now
                ? uint64_t(timestamp_ns) - uint64_t(timing.now)
                : uint64_t(timing.now) - uint64_t(timestamp_ns);
        // Domain sanity only, not an accuracy/latency bound.
        if (distance > uint64_t(maximum_domain_difference_ns)) {
          self.fail(PipeWireCaptureError::clock);
          return;
        }
        if ((plane.chunk->flags & SPA_CHUNK_FLAG_CORRUPTED) ||
            (metadata && ((metadata->flags & SPA_META_HEADER_FLAG_CORRUPTED) ||
                          (self.seen_pcm && (metadata->flags &
                                             SPA_META_HEADER_FLAG_DISCONT))))) {
          self.fail(PipeWireCaptureError::discontinuity);
          return;
        }
        if (!self.handoff.push(
                plane.data, plane.maxsize, plane.chunk->offset, size,
                (plane.chunk->flags & SPA_CHUNK_FLAG_EMPTY) ||
                    (metadata && (metadata->flags & SPA_META_HEADER_FLAG_GAP)),
                timestamp_ns / 1000 + self.monotonic_offset_us, clock,
                gap_before)) {
          self.fail(PipeWireCaptureError::overflow);
          return;
        }
        self.seen_pcm = true;
      }
    } catch (...) {
      self.fail(PipeWireCaptureError::callback);
    }
  }
};
} // namespace
PipeWireCaptureResult capture_pipewire_timed(
    const std::string &target, bool playback, std::atomic<bool> &cancel,
    const std::function<void(const std::vector<unsigned char> &, int64_t,
                             PipeWireCaptureBuffer::Clock, bool)> &pcm) {
  if (cancel)
    return {};
  static std::once_flag initialized;
  std::call_once(initialized, [] { pw_init(nullptr, nullptr); });
  Session session(cancel, pcm);
  // Bind PipeWire's CLOCK_MONOTONIC domain to the same steady-clock domain
  // as fs_recording_monotonic_us. The bracket measures conversion overhead,
  // not physical-device latency. Never make this conversion on the RT path.
  int64_t best_bracket_us = std::numeric_limits<int64_t>::max();
  for (int attempt = 0; attempt < 5; ++attempt) {
    const auto before = std::chrono::steady_clock::now();
    timespec monotonic{};
    if (clock_gettime(CLOCK_MONOTONIC, &monotonic) != 0)
      return {PipeWireCaptureError::clock,
              "PipeWire clock mapping unavailable"};
    const auto after = std::chrono::steady_clock::now();
    const auto bracket =
        std::chrono::duration_cast<std::chrono::microseconds>(after - before)
            .count();
    if (bracket < best_bracket_us) {
      best_bracket_us = bracket;
      const auto midpoint = before + (after - before) / 2;
      const auto steady_us =
          std::chrono::duration_cast<std::chrono::microseconds>(
              midpoint.time_since_epoch())
              .count();
      const auto monotonic_us =
          int64_t(monotonic.tv_sec) * 1000000 + monotonic.tv_nsec / 1000;
      session.monotonic_offset_us = steady_us - monotonic_us;
    }
  }
  session.loop = pw_main_loop_new(nullptr);
  if (!session.loop)
    return {PipeWireCaptureError::unavailable, "PipeWire loop unavailable"};
  auto *properties = pw_properties_new(
      PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
      PW_KEY_MEDIA_ROLE, "Communication", PW_KEY_NODE_NAME,
      playback ? "foresight_recording_playback"
               : "foresight_recording_microphone",
      nullptr);
  if (!properties)
    return {PipeWireCaptureError::unavailable,
            "PipeWire stream properties unavailable"};
  if (!target.empty() && target != "auto") {
    pw_properties_set(properties, PW_KEY_TARGET_OBJECT, target.c_str());
    pw_properties_set(properties, "node.dont-fallback", "true");
    pw_properties_set(properties, "node.dont-reconnect", "true");
  }
  if (playback)
    pw_properties_set(properties, PW_KEY_STREAM_CAPTURE_SINK, "true");
  pw_stream_events events{};
  events.version = PW_VERSION_STREAM_EVENTS;
  events.state_changed = Session::state_changed;
  events.param_changed = Session::param_changed;
  events.process = Session::process;
  session.stream = pw_stream_new_simple(pw_main_loop_get_loop(session.loop),
                                        "Open Foresight recording", properties,
                                        &events, &session);
  if (!session.stream)
    return {PipeWireCaptureError::unavailable, "PipeWire stream unavailable"};
  std::array<unsigned char, 1024> storage{};
  spa_pod_builder builder =
      SPA_POD_BUILDER_INIT(storage.data(), storage.size());
  spa_audio_info_raw format{};
  format.format = SPA_AUDIO_FORMAT_S16_LE;
  format.rate = 48000;
  format.channels = 1;
  format.position[0] = SPA_AUDIO_CHANNEL_MONO;
  const spa_pod *params[3];
  params[0] =
      spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &format);
  params[1] = static_cast<spa_pod *>(spa_pod_builder_add_object(
      &builder, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type,
      SPA_POD_Id(SPA_META_Header), SPA_PARAM_META_size,
      SPA_POD_Int(sizeof(spa_meta_header))));
  params[2] = static_cast<spa_pod *>(spa_pod_builder_add_object(
      &builder, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
      SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(16, 4, 64),
      SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1), SPA_PARAM_BUFFERS_size,
      SPA_POD_CHOICE_RANGE_Int(maximum_pcm_bytes, 2, maximum_pcm_bytes),
      SPA_PARAM_BUFFERS_stride, SPA_POD_Int(2)));
  const auto flags = static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
                                                  PW_STREAM_FLAG_MAP_BUFFERS |
                                                  PW_STREAM_FLAG_RT_PROCESS);
  if (pw_stream_connect(session.stream, PW_DIRECTION_INPUT, PW_ID_ANY, flags,
                        params, 3) < 0)
    return {PipeWireCaptureError::unavailable,
            "PipeWire capture connection unavailable"};
  auto *loop = pw_main_loop_get_loop(session.loop);
  pw_loop_enter(loop);
  auto drain = [&] {
    PipeWireCaptureBuffer::Block block;
    while (session.handoff.pop(block)) {
      std::vector<unsigned char> bytes(block.pcm.begin(),
                                       block.pcm.begin() + block.size);
      session.pcm(bytes, block.timestamp_us, block.clock, block.gap_before);
      session.last_pcm = std::chrono::steady_clock::now();
    }
  };
  while (!cancel && session.error == PipeWireCaptureError::none) {
    if (pw_loop_iterate(loop, 5) < 0) {
      session.fail(PipeWireCaptureError::unavailable);
      break;
    }
    try {
      drain();
    } catch (...) {
      session.fail(PipeWireCaptureError::callback);
      break;
    }
    if (std::chrono::steady_clock::now() - session.last_pcm >
        std::chrono::seconds(15)) {
      session.fail(PipeWireCaptureError::unavailable);
      break;
    }
  }
  pw_loop_leave(loop);
  // Synchronize producer teardown before draining the accepted prefix. No
  // producer callback can race final writer sealing after this function ends.
  pw_stream_disconnect(session.stream);
  pw_stream_destroy(session.stream);
  session.stream = nullptr;
  try {
    drain();
  } catch (...) {
    session.fail(PipeWireCaptureError::callback);
  }
  const auto error = session.error.load();
  switch (error) {
  case PipeWireCaptureError::none:
    return {};
  case PipeWireCaptureError::unavailable:
    return {error, "PipeWire capture unavailable or disconnected"};
  case PipeWireCaptureError::format:
    return {error, "Invalid PipeWire capture PCM format"};
  case PipeWireCaptureError::clock:
    return {error, "PipeWire capture clock unavailable"};
  case PipeWireCaptureError::discontinuity:
    return {error, "PipeWire reported lost capture audio"};
  case PipeWireCaptureError::callback:
    return {error, "PipeWire capture delivery failed"};
  case PipeWireCaptureError::overflow:
    return {error, "PipeWire capture handoff overflow"};
  }
  return {PipeWireCaptureError::unavailable, "PipeWire capture unavailable"};
}
} // namespace foresight
