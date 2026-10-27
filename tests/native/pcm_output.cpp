#include "../../native/foresight_native.cpp"
#include <iostream>
#include <numeric>
#ifdef __APPLE__
namespace foresight {
bool pcm_output_macos_offline_self_test();
}
#endif
namespace {
void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
void eventually(const std::function<bool()> &predicate) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!predicate()) {
    require(std::chrono::steady_clock::now() < deadline, "test wait expired");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}
using Output = foresight::PcmOutput;
using Queue = foresight::PcmOutputQueue;
struct Control {
  std::atomic<bool> held_start{false}, entered_start{false}, held_stop{false};
  std::atomic<bool> entered_stop{false}, failed_start{false};
  std::atomic<bool> held_pause{false}, entered_pause{false};
  std::atomic<bool> paused{true};
  Output *owner = nullptr;
};
Control *current;
class FakeBackend final : public foresight::PcmOutputBackend {
  Control &control_;

public:
  FakeBackend(Output &owner) : control_(*current) {
    control_.owner = &owner;
  }
  void start() override {
    control_.entered_start = true;
    eventually([&] { return !control_.held_start; });
    if (control_.failed_start)
      throw std::runtime_error("controlled start failure");
  }
  void pause() override {
    control_.entered_pause = true;
    eventually([&] { return !control_.held_pause; });
    control_.paused = true;
  }
  void resume() override {
    control_.paused = false;
  }
  void stop() override {
    control_.entered_stop = true;
    eventually([&] { return !control_.held_stop; });
    control_.paused = true;
    control_.owner = nullptr;
  }
};
std::unique_ptr<foresight::PcmOutputBackend> factory(Output &owner,
                                                     const std::string &) {
  return std::make_unique<FakeBackend>(owner);
}
nlohmann::json poll(uint64_t owner) {
  auto *raw = fs_owned_pcm_output_poll(owner);
  require(raw, "missing output snapshot");
  const auto result = nlohmann::json::parse(raw);
  fs_string_free(raw);
  return result;
}
int wait(uint64_t token) {
  require(token != 0, "missing operation token");
  eventually([&] { return fs_operation_status(token) != 0; });
  return fs_operation_status(token);
}
void release(uint64_t token) {
  require(fs_operation_release(token) == 0, "token not released");
}
void retire(uint64_t owner) {
  const auto token = fs_pcm_output_retire(owner);
  require(wait(token) == 1, "retirement not confirmed");
  require(fs_owner_release(owner) == 0, "owner not released");
}
std::vector<int16_t> samples(size_t count, int base = 1) {
  std::vector<int16_t> data(count * 2);
  for (size_t i = 0; i < count; ++i) {
    data[i * 2] = int16_t(base + i % 1000);
    data[i * 2 + 1] = -data[i * 2];
  }
  return data;
}
void queue_prefix_wrap() {
  Queue queue;
  const auto input = samples(4800);
  for (size_t i = 0; i < 16; ++i)
    require(queue.push(input.data(), 4800) == 4800,
            "bounded queue lost initial input");
  require(queue.queued() == 76800 && queue.push(input.data(), 1) == 0,
          "queue capacity not enforced");
  require(queue.consume(123,
                        [&](size_t i, int16_t l, int16_t r) noexcept {
                          require(l == input[i * 2] && r == input[i * 2 + 1],
                                  "queue channel/order mismatch");
                        }) == 123,
          "queue short consume");
  require(queue.push(input.data(), 4800) == 123,
          "exact partial prefix not returned");
  size_t seen = 0;
  queue.consume(76800, [&](size_t, int16_t l, int16_t r) noexcept {
    const size_t at = seen++;
    const size_t expected = at < 76677 ? (at + 123) % 4800 : at - 76677;
    require(l == input[expected * 2] && r == input[expected * 2 + 1],
            "wrapped PCM sequence corrupt");
  });
  require(seen == 76800 && queue.queued() == 0, "queue drain count mismatch");
}
void concurrent_queue() {
  Queue queue;
  constexpr size_t total = 2000000;
  std::atomic<bool> failed{false};
  std::thread producer([&] {
    size_t position = 0;
    auto block = samples(4800);
    while (position < total) {
      const auto wanted = std::min(size_t(4800), total - position);
      for (size_t i = 0; i < wanted; ++i) {
        block[i * 2] = int16_t((position + i) % 30000);
        block[i * 2 + 1] = int16_t(-block[i * 2]);
      }
      position += queue.push(block.data(), wanted);
      std::this_thread::yield();
    }
  });
  size_t position = 0;
  while (position < total) {
    queue.consume(733, [&](size_t, int16_t l, int16_t r) noexcept {
      if (l != int16_t(position % 30000) || r != -l)
        failed = true;
      ++position;
    });
    std::this_thread::yield();
  }
  producer.join();
  require(!failed && position == total,
          "concurrent PCM producer/consumer corrupted frames");
}
void paused_generation() {
  Control control;
  current = &control;
  Output output(1, "", factory);
  require(output.start(), "fake backend preparation failed");
  auto input = samples(4800);
  std::vector<int16_t> result(9600, 88);
  require(output.push(1, input.data(), 4800) == 4800, "prefill rejected");
  output.render(result.data(), 4800);
  require(
      std::all_of(result.begin(), result.end(), [](auto x) { return x == 0; }),
      "paused output consumed PCM");
  require(output.snapshot().rendered_frames == 0 &&
              output.snapshot().queued_frames == 4800,
          "paused counters advanced");
  require(output.resume(1), "resume failed");
  output.render(result.data(), 4800);
  require(result == input && output.snapshot().rendered_frames == 4800,
          "rendered PCM mismatch");
  output.render(result.data(), 4800);
  require(output.snapshot().rendered_frames == 4800 &&
              output.snapshot().underruns == 1 && output.snapshot().buffering,
          "underrun advanced position");
  require(output.push(1, input.data(), 4800) == 4800,
          "second prefill rejected");
  require(output.request_flush(2), "flush admission failed");
  require(output.push(1, input.data(), 1) == -2 &&
              output.push(2, input.data(), 1) == -2,
          "pending flush admitted PCM");
  require(output.pause_flush(2), "flush failed");
  require(output.snapshot().generation == 2 &&
              output.snapshot().queued_frames == 0 &&
              output.snapshot().rendered_frames == 0,
          "generation reset mismatch");
  require(output.push(1, input.data(), 1) == -2, "stale generation admitted");
  require(output.push(2, input.data(), 4800) == 4800,
          "new generation rejected");
  require(output.resume(2), "new generation resume failed");
  std::array<float, 4800> left{}, right{};
  output.render(left.data(), right.data(), 4800);
  require(left[0] == float(input[0]) / 32768 &&
              right[0] == float(input[1]) / 32768,
          "mac float conversion mismatch");
  require(output.finish() && output.snapshot().stopped, "stop fence failed");
}
void callback_flush_fence() {
  Control control;
  current = &control;
  Output output(1, "", factory);
  require(output.start() && output.resume(1), "start failed");
  auto input = samples(4800);
  std::atomic<bool> done{false};
  std::thread callback([&] {
    std::array<int16_t, 128 * 2> target{};
    while (!done)
      output.render(target.data(), 128);
  });
  for (uint64_t generation = 2; generation < 100; ++generation) {
    output.push(generation - 1, input.data(), 4800);
    require(output.request_flush(generation) && output.pause_flush(generation),
            "concurrent flush failed");
    const auto value = output.snapshot();
    require(value.generation == generation && value.rendered_frames == 0 &&
                value.queued_frames == 0,
            "old RT PCM crossed flush ACK");
    require(output.push(generation - 1, input.data(), 1) == -2,
            "stale RT generation accepted");
    require(output.resume(generation), "concurrent resume failed");
  }
  done = true;
  callback.join();
  output.finish();
}
void owned_contract() {
  Control control;
  current = &control;
  pcm_output_factory_for_testing = factory;
  require(
      fs_owned_pcm_output_create_async("{\"version\":1,\"generation\":0}") == 0,
      "zero generation accepted");
  require(fs_owned_pcm_output_create_async(
              "{\"version\":1,\"generation\":1,\"argv\":[]}") == 0,
          "unknown creation option accepted");
  const auto owner =
      fs_owned_pcm_output_create_async("{\"version\":1,\"generation\":1}");
  require(owner, "owned create failed");
  const auto start = poll(owner).at("start_token").get<uint64_t>();
  require(wait(start) == 1, "owned start failed");
  release(start);
  require(!fs_owned_event_poll(owner, 0), "output admitted legacy event cast");
  auto input = samples(4800);
  require(fs_owned_pcm_output_push(owner, 1, input.data(), 4801) == -1,
          "oversized frame push admitted");
  require(fs_owned_pcm_output_push(owner, 1, input.data(), 4800) == 4800,
          "owned prefill failed");
  auto resume = fs_owned_pcm_output_resume_async(owner, 1);
  require(wait(resume) == 1, "owned resume failed");
  release(resume);
  std::vector<int16_t> result(9600);
  control.owner->render(result.data(), 4800);
  require(result == input && poll(owner).at("rendered_frames") == 4800,
          "owned backend consumption mismatch");
  auto flush = fs_owned_pcm_output_pause_flush_async(owner, 2);
  require(wait(flush) == 1, "owned flush failed");
  release(flush);
  require(fs_owned_pcm_output_push(owner, 1, input.data(), 1) == -2,
          "owned stale generation admitted");
  require(fs_owned_pcm_output_push(owner, 2, input.data(), 4800) == 4800,
          "owned new generation failed");
  auto finish = fs_pcm_output_finish_async(owner);
  require(finish == fs_pcm_output_finish_async(owner),
          "duplicate finish changed identity");
  require(wait(finish) == 1, "owned finish failed");
  release(finish);
  require(poll(owner).at("stopped") == true, "owned final snapshot missing");
  retire(owner);
  require(fs_owned_pcm_output_push(owner, 2, input.data(), 1) == -1 &&
              !fs_owned_pcm_output_poll(owner),
          "retired owner admitted stale work");
}
void start_cancel_retire() {
  Control control;
  current = &control;
  pcm_output_factory_for_testing = factory;
  control.held_start = true;
  auto owner =
      fs_owned_pcm_output_create_async("{\"version\":1,\"generation\":9}");
  require(owner, "held create failed");
  const auto start = poll(owner).at("start_token").get<uint64_t>();
  eventually([&] { return control.entered_start.load(); });
  auto finish = fs_pcm_output_finish_async(owner);
  auto retirement = fs_pcm_output_retire(owner);
  require(fs_operation_status(finish) == 0 &&
              fs_operation_status(retirement) == 0,
          "held start lost lifecycle ownership");
  control.held_start = false;
  require(wait(start) == 2, "cancelled startup falsely succeeded");
  release(start);
  require(wait(finish) == 1 && wait(retirement) == 1,
          "cancelled startup did not join/retire");
  release(finish);
  require(fs_owner_release(owner) == 0, "cancelled startup owner not released");
}
void queued_control_stop_retire() {
  Control control;
  current = &control;
  pcm_output_factory_for_testing = factory;
  const auto owner =
      fs_owned_pcm_output_create_async("{\"version\":1,\"generation\":1}");
  const auto start = poll(owner).at("start_token").get<uint64_t>();
  require(wait(start) == 1, "queued lifecycle start failed");
  release(start);
  auto input = samples(4800);
  require(fs_owned_pcm_output_push(owner, 1, input.data(), 4800) == 4800,
          "queued lifecycle prefill failed");
  auto resumed = fs_owned_pcm_output_resume_async(owner, 1);
  require(wait(resumed) == 1, "queued lifecycle resume failed");
  release(resumed);
  control.held_pause = true;
  control.held_stop = true;
  auto flush = fs_owned_pcm_output_pause_flush_async(owner, 2);
  eventually([&] { return control.entered_pause.load(); });
  auto finish = fs_pcm_output_finish_async(owner);
  auto retirement = fs_pcm_output_retire(owner);
  require(fs_operation_status(flush) == 0 && fs_operation_status(finish) == 0 &&
              fs_operation_status(retirement) == 0,
          "queued controls falsely joined held callbacks");
  require(fs_owned_pcm_output_push(owner, 2, input.data(), 1) == -1,
          "retiring output admitted PCM");
  control.held_pause = false;
  eventually([&] { return control.entered_stop.load(); });
  require(fs_operation_status(finish) == 0 &&
              fs_operation_status(retirement) == 0,
          "held backend stop lost ownership");
  Control independent;
  current = &independent;
  const auto other =
      fs_owned_pcm_output_create_async("{\"version\":1,\"generation\":3}");
  const auto other_start = poll(other).at("start_token").get<uint64_t>();
  require(wait(other_start) == 1,
          "held backend blocked another owned execution group");
  release(other_start);
  retire(other);
  control.held_stop = false;
  require(wait(flush) == 1 && wait(finish) == 1 && wait(retirement) == 1,
          "queued controls did not finish after actual backend stop");
  release(flush);
  release(finish);
  require(fs_owner_release(owner) == 0, "queued lifecycle owner not released");
}
void failed_start() {
  Control control;
  current = &control;
  pcm_output_factory_for_testing = factory;
  control.failed_start = true;
  auto owner =
      fs_owned_pcm_output_create_async("{\"version\":1,\"generation\":1}");
  auto start = poll(owner).at("start_token").get<uint64_t>();
  require(wait(start) == 2, "failed backend reported prepared");
  release(start);
  auto state = poll(owner);
  require(state.at("error") == "output_backend_failed" &&
              state.at("stopped") == true,
          "failed backend owner not fenced");
  retire(owner);
}
} // namespace
int main() {
  try {
    queue_prefix_wrap();
    concurrent_queue();
    paused_generation();
    callback_flush_fence();
    owned_contract();
    start_cancel_retire();
    queued_control_stop_retire();
    failed_start();
#ifdef __APPLE__
    require(foresight::pcm_output_macos_offline_self_test(),
            "actual macOS offline render failed");
    std::cout << "macOS offline AVAudioSourceNode:1 scenario passed;0 skipped "
                 "(no physical device)\n";
#endif
    std::cout << "PCM output:8 scenarios passed;0 skipped (controlled backend, "
                 "no physical audio)\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
