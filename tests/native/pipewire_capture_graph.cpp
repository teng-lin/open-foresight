#include "../../native/foresight_native.h"
#include "../../native/pipewire_capture.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <thread>
#include <unistd.h>

namespace {
using Json = nlohmann::json;
void check(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
void await(uint64_t token) {
  check(token, "operation admission failed");
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  int status = 0;
  while ((status = fs_operation_status(token)) == 0 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  check(status == 1, "owned operation did not join successfully");
}
Json poll(uint64_t owner) {
  char *raw = fs_owned_capture_recording_poll(owner);
  check(raw, "metadata poll unavailable");
  std::string text(raw);
  fs_string_free(raw);
  return Json::parse(text);
}
int retained_recording(const std::string &target) {
  const auto *base = getenv("FORESIGHT_TEST_TEMP_ROOT");
  std::string pattern =
      std::filesystem::canonical(base ? base : "/var/tmp").string() +
      "/pipewire-recording-XXXXXX";
  std::vector<char> name(pattern.begin(), pattern.end());
  name.push_back(0);
  check(mkdtemp(name.data()), "private fixture directory unavailable");
  const std::string directory(name.data());
  std::cout << "retained fixture directory=" << directory << '\n';
  const auto id = [](unsigned value) {
    char text[37];
    std::snprintf(text, sizeof(text), "00000000-0000-4000-8000-%012u", value);
    return std::string(text);
  };
  Json ids = Json::array();
  for (unsigned i = 1; i <= 4; ++i)
    ids.push_back({{"id", id(i)}, {"sequence", i}});
  const Json options{{"directory", directory},
                     {"session_id", id(101)},
                     {"generation", id(102)},
                     {"span", 1},
                     {"origin_us", fs_recording_monotonic_us()},
                     {"source_sample", 0},
                     {"chunk_ids", ids}};
  const auto owner = fs_owned_recording_capture_start(target.c_str(), 1, 0,
                                                      options.dump().c_str());
  check(owner, "production durable capture admission failed");
  Json chunks = Json::array(), snapshot;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  do {
    snapshot = poll(owner);
    for (const auto &chunk : snapshot.at("chunks"))
      chunks.push_back(chunk);
    check(snapshot.at("error").is_null(),
          "production recording reports capture failure");
    if (snapshot.at("source_sample").get<uint64_t>() >= 288000)
      break;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  } while (std::chrono::steady_clock::now() < deadline);
  const auto finish = fs_capture_finish_async(owner);
  await(finish);
  check(fs_operation_release(finish) == 0, "finish acknowledgement failed");
  snapshot = poll(owner);
  for (const auto &chunk : snapshot.at("chunks"))
    chunks.push_back(chunk);
  check(snapshot.at("state") == "sealed" && snapshot.at("error").is_null(),
        "recording did not seal cleanly");
  check(snapshot.at("clock_quality") == "pipewire_graph_time" &&
            snapshot.at("uncertainty_us").is_null(),
        "synthetic graph falsely claims physical alignment");
  uint64_t saved = 0;
  for (const auto &chunk : chunks) {
    const auto frames = chunk.at("frames").get<uint64_t>();
    saved += frames;
    check(chunk.at("contents_synced") == true &&
              chunk.at("directory_synced") == true,
          "unsynced native publication");
    const auto path =
        directory + "/" + chunk.at("relative_path").get<std::string>();
    check(std::filesystem::file_size(path) == 196 + frames * 2,
          "published WAV extent mismatch");
    std::ifstream input(path, std::ios::binary);
    input.seekg(196);
    char sample;
    while (input.get(sample))
      check(sample == 0, "null-sink silence changed in durable storage");
  }
  check(saved == snapshot.at("source_sample").get<uint64_t>() &&
            saved >= 288000 && chunks.size() >= 2,
        "capture/stop fence lost retained frames");
  await(fs_capture_retire(owner));
  check(fs_owner_release(owner) == 0, "retirement acknowledgement failed");
  std::cout << "production retained graph frames=" << saved
            << " chunks=" << chunks.size()
            << " all PCM/sync/stop-fence checks passed\n";
  return 0;
}
} // namespace

// Run ONLY against a private synthetic graph. This deliberately does not
// autoconnect to a developer's microphone or desktop audio. A graph harness
// creates the named null sink before starting this probe.
int main(int argc, char **argv) {
  if (argc != 3 || !std::string(argv[1]).starts_with("foresight_test_")) {
    std::cerr << "private foresight_test_* sink and "
                 "smoke|overflow|dual|recording required\n";
    return 2;
  }
  const std::string target(argv[1]), mode(argv[2]);
  if (mode == "recording") {
    try {
      return retained_recording(target);
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return 1;
    }
  }
  if (mode != "smoke" && mode != "overflow" && mode != "dual")
    return 2;
  const auto source_count = mode == "dual" ? 2 : 1;
  std::atomic<bool> cancel{false};
  std::atomic<uint64_t> frames[2]{};
  std::vector<int64_t> stamps[2];
  foresight::PipeWireCaptureResult results[2];
  auto run = [&](int source) {
    results[source] = foresight::capture_pipewire_timed(
        target, true, cancel,
        [&](const auto &pcm, int64_t stamp,
            foresight::PipeWireCaptureBuffer::Clock clock, bool gap_before) {
          if (gap_before)
            throw std::runtime_error("null sink graph lost samples");
          if (clock != foresight::PipeWireCaptureBuffer::Clock::graph_cycle)
            throw std::runtime_error(
                "null sink unexpectedly claims source PTS");
          if (!stamps[source].empty() && stamp < stamps[source].back())
            throw std::runtime_error("backward graph timestamp");
          stamps[source].push_back(stamp);
          frames[source] += pcm.size() / 2;
          if (mode == "overflow" && stamps[source].size() == 1)
            std::this_thread::sleep_for(std::chrono::seconds(2));
          if (mode == "smoke" && frames[source] >= 48000)
            cancel = true;
        });
  };
  std::thread first([&] { run(0); });
  std::thread second;
  if (source_count == 2)
    second = std::thread([&] { run(1); });
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!cancel && std::chrono::steady_clock::now() < deadline) {
    if (mode == "dual" && frames[0] >= 96000 && frames[1] >= 96000)
      break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  cancel = true;
  first.join();
  if (second.joinable())
    second.join();
  for (int i = 0; i < source_count; ++i)
    std::cout << "source=" << i << " error=" << int(results[i].error)
              << " message=" << results[i].message
              << " blocks=" << stamps[i].size() << " frames=" << frames[i]
              << '\n';
  if (mode == "overflow")
    return results[0].error == foresight::PipeWireCaptureError::overflow &&
                   frames[0] > 0
               ? 0
               : 1;
  for (int i = 0; i < source_count; ++i)
    if (results[i].error != foresight::PipeWireCaptureError::none ||
        frames[i] < 48000)
      return 1;
  if (source_count == 2) {
    size_t matches = 0;
    for (const auto stamp : stamps[0]) {
      const auto other =
          std::lower_bound(stamps[1].begin(), stamps[1].end(), stamp - 1);
      if (other != stamps[1].end() && *other <= stamp + 1)
        ++matches;
    }
    std::cout << "shared null-sink graph cycles matching within1us=" << matches
              << '\n';
    if (matches < 20)
      return 1;
  }
  return 0;
}
