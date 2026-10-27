#include "pcm_output.h"
#include <chrono>
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <thread>
namespace foresight {
namespace {
class PipeWirePcmOutput final : public PcmOutputBackend {
  PcmOutput &owner_;
  const std::string target_;
  pw_thread_loop *loop_ = nullptr;
  pw_stream *stream_ = nullptr;
  spa_hook listener_{};
  bool loop_started_ = false;
  std::atomic<bool> format_ready_{false};
  std::atomic<pw_stream_state> state_{PW_STREAM_STATE_UNCONNECTED};
  static void state(void *data, pw_stream_state previous, pw_stream_state next,
                    const char *) noexcept {
    auto &self = *static_cast<PipeWirePcmOutput *>(data);
    self.state_ = next;
    if (next == PW_STREAM_STATE_ERROR ||
        (next == PW_STREAM_STATE_UNCONNECTED &&
         previous != PW_STREAM_STATE_UNCONNECTED && !self.owner_.stopping()))
      self.owner_.fail(PcmOutput::Error::device_lost);
  }
  static void param(void *data, uint32_t id, const spa_pod *value) noexcept {
    if (id != SPA_PARAM_Format || !value)
      return;
    auto &self = *static_cast<PipeWirePcmOutput *>(data);
    spa_audio_info_raw format{};
    if (spa_format_audio_raw_parse(value, &format) < 0 ||
        format.format != SPA_AUDIO_FORMAT_S16_LE || format.rate != 48000 ||
        format.channels != 2) {
      self.owner_.fail(PcmOutput::Error::format);
    } else {
      self.format_ready_ = true;
    }
  }
  static void process(void *data) noexcept {
    auto &self = *static_cast<PipeWirePcmOutput *>(data);
    auto *buffer = pw_stream_dequeue_buffer(self.stream_);
    if (!buffer)
      return;
    auto *spa = buffer->buffer;
    if (!spa || spa->n_datas != 1 || !spa->datas || !spa->datas[0].data ||
        !spa->datas[0].chunk || spa->datas[0].maxsize < 4 ||
        !self.format_ready_) {
      self.owner_.fail(PcmOutput::Error::format);
      pw_stream_queue_buffer(self.stream_, buffer);
      return;
    }
    auto &plane = spa->datas[0];
    // PipeWire >=1.0.5 requested is graph frames; the mapped extent remains the
    // independent hard bound. Never use requested samples as a byte length.
    const auto capacity = plane.maxsize / 4;
    const auto frames = buffer->requested
                            ? std::min(uint64_t(capacity), buffer->requested)
                            : uint64_t(capacity);
    self.owner_.render(static_cast<int16_t *>(plane.data), size_t(frames));
    plane.chunk->offset = 0;
    plane.chunk->stride = 4;
    plane.chunk->size = uint32_t(frames * 4);
    buffer->size = frames;
    pw_stream_queue_buffer(self.stream_, buffer);
  }
  void active(bool value) {
    pw_thread_loop_lock(loop_);
    const auto result = pw_stream_set_active(stream_, value);
    pw_thread_loop_unlock(loop_);
    if (result < 0)
      throw std::runtime_error("output_stream_control_failed");
  }

public:
  PipeWirePcmOutput(PcmOutput &owner, const std::string &target)
      : owner_(owner), target_(target) {}
  ~PipeWirePcmOutput() override {
    if (loop_ || stream_)
      std::terminate();
  }
  void start() override {
    static std::once_flag initialized;
    std::call_once(initialized, [] { pw_init(nullptr, nullptr); });
    loop_ = pw_thread_loop_new("foresight-output", nullptr);
    if (!loop_)
      throw std::runtime_error("output_loop_failed");
    auto *properties =
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY,
                          "Playback", PW_KEY_MEDIA_ROLE, "Music",
                          PW_KEY_NODE_NAME, "foresight.saved-output", nullptr);
    if (!target_.empty() && target_ != "default" && target_ != "auto")
      pw_properties_set(properties, PW_KEY_TARGET_OBJECT, target_.c_str());
    if (!target_.empty() && target_ != "default" && target_ != "auto") {
      pw_properties_set(properties, "node.dont-fallback", "true");
      pw_properties_set(properties, "node.dont-reconnect", "true");
    }
    static const pw_stream_events events = [] {
      pw_stream_events result{};
      result.version = PW_VERSION_STREAM_EVENTS;
      result.state_changed = state;
      result.param_changed = param;
      result.process = process;
      return result;
    }();
    stream_ = pw_stream_new_simple(pw_thread_loop_get_loop(loop_),
                                   "Foresight saved meeting", properties,
                                   &events, this);
    if (!stream_)
      throw std::runtime_error("output_stream_failed");
    uint8_t storage[1024];
    spa_pod_builder builder = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
    spa_audio_info_raw format{};
    format.format = SPA_AUDIO_FORMAT_S16_LE;
    format.rate = 48000;
    format.channels = 2;
    format.position[0] = SPA_AUDIO_CHANNEL_FL;
    format.position[1] = SPA_AUDIO_CHANNEL_FR;
    const spa_pod *parameters[]{
        spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &format)};
    if (pw_stream_connect(stream_, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                          pw_stream_flags(PW_STREAM_FLAG_AUTOCONNECT |
                                          PW_STREAM_FLAG_MAP_BUFFERS |
                                          PW_STREAM_FLAG_RT_PROCESS |
                                          PW_STREAM_FLAG_INACTIVE),
                          parameters, 1) < 0)
      throw std::runtime_error("output_connect_failed");
    if (pw_thread_loop_start(loop_) < 0)
      throw std::runtime_error("output_thread_failed");
    loop_started_ = true;
    // Paused is a negotiated, linked graph fact, not a hardware-audible ACK.
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!owner_.stopping() && state_ != PW_STREAM_STATE_ERROR &&
           state_ != PW_STREAM_STATE_PAUSED &&
           state_ != PW_STREAM_STATE_STREAMING &&
           std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    if (owner_.stopping() || (state_ != PW_STREAM_STATE_PAUSED &&
                              state_ != PW_STREAM_STATE_STREAMING))
      throw std::runtime_error("output_negotiation_failed");
  }
  void resume() override {
    active(true);
  }
  void pause() override {
    active(false);
    // Loop lock serializes against all process callbacks before queue reset.
    pw_thread_loop_lock(loop_);
    if (pw_stream_flush(stream_, false) < 0) {
      pw_thread_loop_unlock(loop_);
      throw std::runtime_error("output_flush_failed");
    }
    pw_thread_loop_unlock(loop_);
  }
  void stop() override {
    if (loop_started_) {
      pw_thread_loop_stop(loop_);
      loop_started_ = false;
    }
    if (stream_) {
      pw_stream_disconnect(stream_);
      pw_stream_destroy(stream_);
      stream_ = nullptr;
    }
    if (loop_) {
      pw_thread_loop_destroy(loop_);
      loop_ = nullptr;
    }
  }
};
} // namespace
std::unique_ptr<PcmOutputBackend>
make_pcm_output_backend(PcmOutput &owner, const std::string &target) {
  return std::make_unique<PipeWirePcmOutput>(owner, target);
}
} // namespace foresight
