#include "../../native/foresight_native.h"
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <nlohmann/json.hpp>
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <stdexcept>
#include <thread>
namespace {
void check(bool okay, const char *message) {
  if (!okay)
    throw std::runtime_error(message);
}
template <class F> void eventually(F predicate) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!predicate()) {
    check(std::chrono::steady_clock::now() < deadline,
          "private output graph deadline");
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
}
void await(uint64_t token) {
  check(token, "missing output operation");
  eventually([&] { return fs_operation_status(token) != 0; });
  check(fs_operation_status(token) == 1, "output operation did not succeed");
  check(fs_operation_release(token) == 0, "output operation ACK not released");
}
nlohmann::json poll(uint64_t owner) {
  char *raw = fs_owned_pcm_output_poll(owner);
  check(raw, "missing output poll");
  const auto value = nlohmann::json::parse(raw);
  fs_string_free(raw);
  if (!value.at("error").is_null())
    std::cerr << value.dump() << '\n';
  check(value.at("error").is_null(), "output backend error");
  return value;
}
struct Monitor {
  pw_thread_loop *loop = nullptr;
  pw_stream *stream = nullptr;
  std::atomic<uint64_t> first{0}, second{0}, frames{0};
  std::atomic<bool> failed{false};
  static void process(void *opaque) noexcept {
    auto &self = *static_cast<Monitor *>(opaque);
    auto *buffer = pw_stream_dequeue_buffer(self.stream);
    if (!buffer)
      return;
    auto *data = buffer->buffer;
    if (!data || data->n_datas != 1 || !data->datas || !data->datas[0].data ||
        !data->datas[0].chunk || !data->datas[0].maxsize)
      self.failed = true;
    else {
      auto &plane = data->datas[0];
      if (plane.chunk->size > plane.maxsize || plane.chunk->size % 4)
        self.failed = true;
      else {
        const auto *pcm = static_cast<const uint8_t *>(plane.data);
        for (uint32_t at = 0; at < plane.chunk->size; at += 4) {
          int16_t pair[2];
          for (unsigned byte = 0; byte < 4; ++byte)
            reinterpret_cast<uint8_t *>(pair)[byte] =
                pcm[(plane.chunk->offset + at + byte) % plane.maxsize];
          if (std::abs(int(pair[0]) - 6000) <= 2 &&
              std::abs(int(pair[1]) + 3000) <= 2)
            ++self.first;
          if (std::abs(int(pair[0]) - 9000) <= 2 &&
              std::abs(int(pair[1]) - 4500) <= 2)
            ++self.second;
          ++self.frames;
        }
      }
    }
    pw_stream_queue_buffer(self.stream, buffer);
  }
  explicit Monitor(const char *target) {
    pw_init(nullptr, nullptr);
    loop = pw_thread_loop_new("private-output-monitor", nullptr);
    check(loop, "monitor loop unavailable");
    static const pw_stream_events events = [] {
      pw_stream_events value{};
      value.version = PW_VERSION_STREAM_EVENTS;
      value.state_changed = [](void *, pw_stream_state, pw_stream_state state,
                               const char *error) noexcept {
        std::cerr << "monitor state=" << pw_stream_state_as_string(state)
                  << " error=" << (error ? error : "") << '\n';
      };
      value.process = process;
      return value;
    }();
    auto *properties = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Communication", PW_KEY_NODE_NAME,
        "foresight-output-monitor", PW_KEY_STREAM_CAPTURE_SINK, "true",
        PW_KEY_TARGET_OBJECT, target, "node.dont-fallback", "true",
        "node.dont-reconnect", "true", nullptr);
    stream = pw_stream_new_simple(pw_thread_loop_get_loop(loop),
                                  "private-output-monitor", properties, &events,
                                  this);
    check(stream, "monitor stream unavailable");
    uint8_t bytes[1024];
    spa_pod_builder builder = SPA_POD_BUILDER_INIT(bytes, sizeof(bytes));
    spa_audio_info_raw format{};
    format.format = SPA_AUDIO_FORMAT_S16_LE;
    format.rate = 48000;
    format.channels = 2;
    format.position[0] = SPA_AUDIO_CHANNEL_FL;
    format.position[1] = SPA_AUDIO_CHANNEL_FR;
    const spa_pod *params[]{
        spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &format)};
    check(pw_stream_connect(stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                            pw_stream_flags(PW_STREAM_FLAG_AUTOCONNECT |
                                            PW_STREAM_FLAG_MAP_BUFFERS |
                                            PW_STREAM_FLAG_RT_PROCESS),
                            params, 1) >= 0,
          "monitor connect failed");
    check(pw_thread_loop_start(loop) >= 0, "monitor start failed");
  }
  ~Monitor() {
    if (loop)
      pw_thread_loop_stop(loop);
    if (stream) {
      pw_stream_disconnect(stream);
      pw_stream_destroy(stream);
    }
    if (loop)
      pw_thread_loop_destroy(loop);
  }
};
} // namespace
int main(int argc, char **argv) {
  uint64_t owner = 0;
  try {
    check(argc == 2 &&
              std::string(argv[1]).starts_with("foresight_output_fixture_") &&
              std::getenv("FORESIGHT_TEST_OUTPUT_GRAPH"),
          "manual private null-sink fixture only");
    Monitor monitor(argv[1]);
    std::cerr << "monitor created; preparing output\n";
    check(!monitor.failed, "monitor format invalid");
    auto options =
        nlohmann::json{{"version", 1}, {"generation", 1}, {"target", argv[1]}}
            .dump();
    owner = fs_owned_pcm_output_create_async(options.c_str());
    check(owner, "output owner not admitted");
    await(poll(owner).at("start_token"));
    std::cerr << "output prepared paused\n";
    std::array<int16_t, 9600> pcm{};
    for (size_t i = 0; i < 4800; ++i) {
      pcm[i * 2] = 6000;
      pcm[i * 2 + 1] = -3000;
    }
    for (unsigned i = 0; i < 16; ++i)
      check(fs_owned_pcm_output_push(owner, 1, pcm.data(), 4800) == 4800,
            "real paused prefill lost frames");
    check(fs_owned_pcm_output_push(owner, 1, pcm.data(), 4800) == 0,
          "real queue did not bound memory");
    check(poll(owner).at("rendered_frames") == 0 && monitor.first == 0,
          "paused graph consumed PCM");
    await(fs_owned_pcm_output_resume_async(owner, 1));
    std::cerr << "first generation resumed\n";
    unsigned turns = 0;
    eventually([&] {
      const auto snapshot = poll(owner);
      if (++turns % 500 == 0)
        std::cerr << "progress=" << snapshot.dump()
                  << " monitor_frames=" << monitor.frames
                  << " first=" << monitor.first << " second=" << monitor.second
                  << '\n';
      return snapshot.at("rendered_frames").get<uint64_t>() >= 12000 &&
             monitor.first >= 4800;
    });
    std::cerr << "first generation reached monitor\n";
    const auto old = poll(owner).at("rendered_frames").get<uint64_t>();
    check(old < 76800, "fixture failed to leave old-generation tail");
    await(fs_owned_pcm_output_pause_flush_async(owner, 2));
    std::cerr << "old generation software flush acknowledged\n";
    const auto flushed = poll(owner);
    check(flushed.at("queued_frames") == 0 &&
              flushed.at("rendered_frames") == 0,
          "real software flush retained old PCM");
    check(fs_owned_pcm_output_push(owner, 1, pcm.data(), 1) == -2,
          "stale real graph generation admitted");
    for (size_t i = 0; i < 4800; ++i) {
      pcm[i * 2] = 9000;
      pcm[i * 2 + 1] = 4500;
    }
    for (unsigned i = 0; i < 3; ++i)
      check(fs_owned_pcm_output_push(owner, 2, pcm.data(), 4800) == 4800,
            "new real graph prefill rejected");
    await(fs_owned_pcm_output_resume_async(owner, 2));
    std::cerr << "second generation resumed\n";
    eventually([&] {
      return poll(owner).at("rendered_frames") == 14400 &&
             monitor.second >= 10000;
    });
    eventually([&] { return poll(owner).at("underruns").get<uint64_t>() > 0; });
    check(poll(owner).at("rendered_frames") == 14400,
          "real underruns advanced seek position");
    // A large pending tail must not delay Stop until normal playback finishes.
    for (unsigned i = 0; i < 16; ++i)
      fs_owned_pcm_output_push(owner, 2, pcm.data(), 4800);
    const auto before_stop = poll(owner);
    check(before_stop.at("queued_frames").get<uint64_t>() > 4800,
          "forced-stop fixture has no pending tail");
    await(fs_pcm_output_finish_async(owner));
    const auto stopped = poll(owner);
    check(stopped.at("stopped") == true && stopped.at("queued_frames") == 0,
          "real backend stop not acknowledged");
    check(stopped.at("rendered_frames").get<uint64_t>() <
              before_stop.at("rendered_frames").get<uint64_t>() +
                  before_stop.at("queued_frames").get<uint64_t>(),
          "forced stop waited to consume the entire pending tail");
    const auto retirement = fs_pcm_output_retire(owner);
    eventually([&] { return fs_operation_status(retirement) != 0; });
    check(fs_operation_status(retirement) == 1 && fs_owner_release(owner) == 0,
          "real backend owner not retired");
    owner = 0;
    check(!monitor.failed, "monitor failed during output");
    std::cout << "private PipeWire stereo loopback passed: first="
              << monitor.first << " second=" << monitor.second
              << " frames=" << monitor.frames << " old_consumed=" << old
              << ";softwareflush+stalegeneration+underrun+forcedstop;"
              << "no physical audibility/latency bound claimed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    if (owner)
      fs_pcm_output_finish_async(owner);
    return 1;
  }
}
