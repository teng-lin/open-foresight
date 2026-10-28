#include "../../native/foresight_native.cpp"
#include <filesystem>
#include <iostream>

namespace {
void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
using Json = nlohmann::json;
constexpr uint64_t fixture_blocks = 640, credit_blocks = 16,
                   fixture_block_frames = 1920;
struct Credits {
  std::string path;
  int descriptor = -1;
  explicit Credits(const std::string &target) : path(target + ".credits") {
    require(mkfifo(path.c_str(), 0600) == 0, "cannot create capture credits");
    descriptor =
        open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    require(descriptor >= 0, "cannot open capture credits");
  }
  ~Credits() {
    if (descriptor >= 0)
      close(descriptor);
    unlink(path.c_str());
  }
  void grant() {
    const char credit = 1;
    ssize_t count;
    do {
      count = write(descriptor, &credit, 1);
    } while (count < 0 && errno == EINTR);
    require(count == 1, "capture credit was not delivered");
  }
};
struct Fixture {
  std::string root;
  Fixture() {
    const char *base = getenv("FORESIGHT_TEST_TEMP_ROOT");
    std::string pattern =
        std::filesystem::canonical(base ? base : "/var/tmp").string() +
        "/recording-capture-XXXXXX";
    std::vector<char> path(pattern.begin(), pattern.end());
    path.push_back(0);
    auto created = mkdtemp(path.data());
    require(created, "cannot allocate test directory");
    root = created;
  }
};
std::string id(unsigned sequence) {
  char result[37];
  std::snprintf(result, sizeof(result), "00000000-0000-4000-8000-%012u",
                sequence);
  return result;
}
Json options(const std::string &directory, unsigned count = 16) {
  Json ids = Json::array();
  for (unsigned i = 1; i <= count; ++i)
    ids.push_back({{"id", id(i)}, {"sequence", i}});
  return {{"directory", directory},
          {"session_id", id(101)},
          {"generation", id(102)},
          {"span", 1},
          {"origin_us", fs_recording_monotonic_us()},
          {"source_sample", 0},
          {"chunk_ids", ids}};
}
Json poll(uint64_t owner) {
  char *raw = fs_owned_capture_recording_poll(owner);
  require(raw, "recording poll missing");
  std::string text(raw);
  fs_string_free(raw);
  return Json::parse(text);
}
void await(uint64_t token) {
  require(token, "operation not admitted");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  int status = 0;
  while ((status = fs_operation_status(token)) == 0 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  require(status == 1, "operation failed or did not finish");
}
void finish(uint64_t owner) {
  auto token = fs_capture_finish_async(owner);
  await(token);
  require(fs_operation_release(token) == 0, "finish acknowledgement failed");
}
void retire(uint64_t owner) {
  await(fs_capture_retire(owner));
  require(fs_owner_release(owner) == 0, "owner acknowledgement failed");
}
void estimatedFirstBlock(const std::string &directory, int64_t origin,
                         uint64_t span, uint64_t source_sample) {
  auto config = options(directory, 1);
  config["origin_us"] = origin;
  config["span"] = span;
  config["source_sample"] = source_sample;
  Capture estimated;
  estimated.recording =
      foresight::recording_options(config.dump().c_str(), false);
  estimated.recording_source_sample = source_sample;
  const auto before_admission = foresight::recording_monotonic_us();
  require(estimated.prepare_recording(), "estimate fixture did not prepare");
  const auto after_admission = foresight::recording_monotonic_us();
  std::vector<unsigned char> pcm(1920 * 2, 0);
  for (size_t i = 0; i < 1920; ++i) {
    pcm[i * 2] = 0x9b;
    pcm[i * 2 + 1] = 1;
  }
  // Exactly one millisecond of drain time for a forty-millisecond block,
  // regardless of filesystem scheduling. The real audio_frame/writer boundary
  // must retain this PCM without presenting an estimate as acquisition proof.
  recording_drain_clock_us = before_admission + 1000;
  audio_frame(estimated, pcm);
  recording_drain_clock_us = -1;
  estimated.finish_recording();
  const auto chunks = estimated.recording_writer->drainPublished();
  require(!estimated.cancel && estimated.recording_error.empty() &&
              estimated.recording_source_sample.load() ==
                  source_sample + 1920 &&
              chunks.size() == 1 && chunks[0].source_sample == source_sample &&
              chunks[0].span == span &&
              chunks[0].capture_start_us >= before_admission - origin &&
              chunks[0].capture_start_us <= after_admission - origin &&
              chunks[0].frames == 1920,
          "early drain estimate rejected or shifted acquired PCM");
  require(estimated.recording_clock_quality == "pipe_drain_estimate" &&
              estimated.recording_acquired_through_us.load() == -1,
          "bounded drain estimate invented acquisition evidence");
  std::ifstream input(directory + "/" + chunks[0].relative_path,
                      std::ios::binary);
  input.seekg(196);
  const std::vector<unsigned char> saved(std::istreambuf_iterator<char>(input),
                                         {});
  require(saved == pcm, "bounded drain estimate changed PCM bytes");
  unsigned identity = 31;
  for (const auto *quality :
       {"hardware_host_time", "pipewire_pts", "pipewire_graph_time"}) {
    auto explicit_config = config;
    explicit_config["chunk_ids"] =
        Json::array({{{"id", id(identity)}, {"sequence", identity}}});
    ++identity;
    Capture supplied;
    supplied.recording =
        foresight::recording_options(explicit_config.dump().c_str(), false);
    supplied.recording_source_sample = source_sample;
    require(supplied.prepare_recording(), "supplied clock fixture not ready");
    audio_frame(supplied, pcm, origin - 18878, true, quality);
    supplied.finish_recording();
    require(supplied.cancel && !supplied.recording_error.empty() &&
                supplied.recording_source_sample.load() == source_sample &&
                supplied.recording_acquired_through_us.load() == -1 &&
                supplied.recording_writer->drainPublished().empty(),
            "supplied pre-origin clock was clamped into valid audio");
  }
}
void captureAndBackpressure(const std::string &directory) {
  auto config = options(directory);
  auto marker = directory + "/device-started";
  Credits credits(marker);
  auto owner = fs_owned_recording_capture_start(marker.c_str(), 0, 0,
                                                config.dump().c_str());
  require(owner, "durable capture did not start");
  uint64_t frames = 0;
  Json chunks = Json::array();
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  bool reserved = false;
  uint64_t granted_batches = 0;
  while (std::chrono::steady_clock::now() < deadline) {
    auto state = poll(owner);
    if (!state.at("error").is_null()) {
      std::cerr << "capture state=" << state.at("state")
                << " error=" << state.at("error")
                << " source_sample=" << state.at("source_sample")
                << " queued_frames=" << state.at("queued_frames")
                << " reserved_chunks=" << state.at("reserved_chunks")
                << " clock_quality=" << state.at("clock_quality") << '\n';
      throw std::runtime_error("capture storage failed");
    }
    require(state.at("uncertainty_us").is_null(),
            "raw FIFO falsely claimed clock accuracy");
    frames = state.at("source_sample").get<uint64_t>();
    for (auto &chunk : state.at("chunks"))
      chunks.push_back(chunk);
    if (state.at("ready") == true && !reserved) {
      auto ids = Json{
          {"chunk_ids", Json::array({{{"id", id(17)}, {"sequence", 17}},
                                     {{"id", id(18)}, {"sequence", 18}}})}};
      auto token = fs_owned_capture_reserve_async(owner, ids.dump().c_str());
      await(token);
      require(fs_operation_release(token) == 0,
              "reservation acknowledgement failed");
      reserved = true;
    }
    // Saturate the legacy event queue, not the independent durable writer.
    // A credit admits at most sixteen blocks; the next batch waits for every
    // prior sample to be accounted for and for the actual writer queue to
    // drain.
    if (state.at("ready") == true &&
        frames == granted_batches * credit_blocks * fixture_block_frames &&
        state.at("queued_frames") == 0 &&
        granted_batches < fixture_blocks / credit_blocks) {
      credits.grant();
      ++granted_batches;
    }
    if (frames == fixture_blocks * fixture_block_frames)
      break;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  finish(owner);
  auto state = poll(owner);
  for (auto &chunk : state.at("chunks"))
    chunks.push_back(chunk);
  require(state.at("state") == "sealed" && state.at("capture_active") == false,
          "finished capture still active");
  require(state.at("current_volume") == 0 && state.at("peak_volume") == 0 &&
              state.at("last_voice_capture_us").is_null(),
          "silent capture reported voice activity");
  require(state.at("acquired_through_us").is_null(),
          "raw FIFO drain was mislabeled acquisition progress");
  require(state.at("clock_quality") == "pipe_drain_estimate",
          "fake FIFO timestamp mislabeled hardware acquisition");
  require(frames == fixture_blocks * fixture_block_frames && reserved &&
              granted_batches == fixture_blocks / credit_blocks,
          "synthetic input did not finish");
  uint64_t saved = 0;
  for (auto &chunk : chunks) {
    saved += chunk.at("frames").get<uint64_t>();
    require(chunk.at("sample_rate") == 48000 && chunk.at("channels") == 1,
            "canonical PCM metadata changed");
    require(chunk.at("contents_synced") == true &&
                chunk.at("directory_synced") == true,
            "unsynced chunk published");
    auto file = directory + "/" + chunk.at("relative_path").get<std::string>();
    std::ifstream input(file, std::ios::binary);
    input.seekg(196);
    char value;
    while (input.get(value))
      require(value == 0, "silent captured PCM changed");
  }
  require(saved == frames && chunks.size() == 6,
          "legacy event backpressure lost retained audio");
  {
    NativeOwnerUse use(owner, NativeKind::capture);
    require(bool(use), "owner retired before metadata drain");
    require(static_cast<Capture *>(use.get())->dropped > 0,
            "fixture did not saturate legacy PCM events");
  }
  retire(owner);
}
void recoverWithoutDevices(const std::string &directory) {
  auto config = options(directory, 6);
  config.erase("span");
  config.erase("origin_us");
  config.erase("source_sample");
  auto owner = fs_owned_recording_recover_start(0, config.dump().c_str());
  require(owner, "recovery owner not admitted");
  auto token = fs_owned_recording_recover_join_async(owner);
  await(token);
  require(fs_operation_release(token) == 0,
          "recovery join acknowledgement failed");
  auto state = poll(owner);
  require(state.at("ready") == true && state.at("state") == "sealed" &&
              state.at("capture_active") == false,
          "recovery acquired devices or did not seal");
  require(state.at("clock_quality") == "unavailable",
          "recovery invented historical acquisition quality");
  require(state.at("ready_chunks") == 6 && state.at("reserved_chunks") == 0,
          "recovery metadata counts incorrect");
  uint64_t saved = 0;
  for (auto &chunk : state.at("chunks")) {
    saved += chunk.at("frames").get<uint64_t>();
    require(chunk.at("contents_synced") == true &&
                chunk.at("directory_synced") == true,
            "recovered media was not re-synced");
  }
  require(saved == 640 * 1920 && poll(owner).at("ready_chunks") == 0,
          "recovery lost/duplicated publication notices");
  retire(owner);
  auto missing = config;
  missing["generation"] = id(777);
  owner = fs_owned_recording_recover_start(0, missing.dump().c_str());
  require(owner, "mismatched recovery owner not admitted");
  token = fs_owned_recording_recover_join_async(owner);
  await(token);
  require(fs_operation_release(token) == 0,
          "failed-recovery join acknowledgement failed");
  state = poll(owner);
  require(state.at("state") == "failed" && state.at("chunks").empty(),
          "mismatched generation adopted media");
  retire(owner);
}
void cancelQueuedRecoveryJoin(const std::string &directory) {
  auto config = options(directory, 6);
  config.erase("span");
  config.erase("origin_us");
  config.erase("source_sample");
  recording_prepare_hold = true;
  recording_prepare_entered = false;
  auto owner = fs_owned_recording_recover_start(0, config.dump().c_str());
  require(owner, "cancellable recovery owner not admitted");
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!recording_prepare_entered &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::yield();
  require(recording_prepare_entered, "recovery hold boundary not reached");
  auto join = fs_owned_recording_recover_join_async(owner);
  require(join, "recovery join did not queue");
  auto cancel = fs_capture_finish_async(owner);
  require(cancel == join, "cancel lost existing recovery join identity");
  {
    NativeOwnerUse use(owner, NativeKind::capture);
    require(bool(use) && static_cast<Capture *>(use.get())->cancel,
            "pending recovery join suppressed cancellation");
  }
  recording_prepare_hold = false;
  await(join);
  require(fs_operation_release(join) == 0,
          "cancelled recovery acknowledgement failed");
  auto state = poll(owner);
  require(state.at("chunks").empty() && state.at("ready") == false &&
              state.at("capture_active") == false,
          "cancelled recovery continued into authorized files");
  retire(owner);
}
void clockGaps(const std::string &directory) {
  auto config = options(directory);
  Capture microphone, playback;
  microphone.recording =
      foresight::recording_options(config.dump().c_str(), false);
  auto second = config;
  for (size_t i = 0; i < second["chunk_ids"].size(); ++i)
    second["chunk_ids"][i]["id"] = id(static_cast<unsigned>(i + 31));
  playback.recording =
      foresight::recording_options(second.dump().c_str(), true);
  require(microphone.prepare_recording() && playback.prepare_recording(),
          "clock fixture did not prepare");
  std::vector<unsigned char> pcm(960 * 2, 0);
  for (size_t i = 0; i < 960; ++i) {
    pcm[i * 2] = 0xe8;
    pcm[i * 2 + 1] = 3;
  }
  auto origin = config.at("origin_us").get<int64_t>();
  audio_frame(microphone, pcm, origin + 1000, true);
  audio_frame(playback, pcm, origin + 11000, true);
  audio_frame(microphone, pcm, origin + 21000, true);
  audio_frame(playback, pcm, origin + 31000, true);
  audio_frame(microphone, pcm, origin + 621000, true);
  audio_frame(playback, pcm, origin + 631000, true);
  require(microphone.recording_volume.load() > 0.003 &&
              microphone.recording_peak.load() > 0.003 &&
              microphone.recording_last_voice_us.load() == 641000 &&
              playback.recording_last_voice_us.load() == 651000,
          "captured voice meter or shared timeline changed");
  require(microphone.recording_acquired_through_us.load() == 641000 &&
              playback.recording_acquired_through_us.load() == 651000,
          "accepted acquisition progress lost source offset or gap");
  microphone.finish_recording();
  playback.finish_recording();
  auto mic = microphone.recording_writer->drainPublished(),
       system = playback.recording_writer->drainPublished();
  require(mic.size() == 2 && system.size() == 2,
          "acquisition gap did not split chunks");
  require(mic[0].frames == 1920 && mic[1].frames == 960 &&
              mic[1].source_sample == 1920,
          "gap condensed source samples");
  require(!mic[0].gap_before && mic[1].gap_before && system[1].gap_before,
          "gap identity was not preserved");
  require(mic[0].capture_start_us == 1000 &&
              system[0].capture_start_us == 11000 &&
              mic[1].capture_start_us == 621000 &&
              system[1].capture_start_us == 631000,
          "shared two-source clock offsets changed");
  require(mic[1].capture_start_us -
                  (mic[0].capture_start_us +
                   static_cast<int64_t>(mic[0].frames * 1000000 / 48000)) ==
              580000,
          "recording silently removed acquisition outage");
  auto recovered = foresight::RecordingWriter::recover(
      directory, {mic[0].identity, mic[1].identity});
  require(recovered.size() == 2 && recovered[1].gap_before,
          "gap marker did not survive recovery");
  auto bad = config;
  bad["chunk_ids"] = Json::array({{{"id", id(80)}, {"sequence", 80}}});
  Capture backwards;
  backwards.recording = foresight::recording_options(bad.dump().c_str(), false);
  require(backwards.prepare_recording(), "backward fixture did not prepare");
  audio_frame(backwards, pcm, origin + 1000, true);
  audio_frame(backwards, pcm, origin + 21000, true);
  audio_frame(backwards, pcm, origin + 100, true);
  backwards.finish_recording();
  auto prefix = backwards.recording_writer->drainPublished();
  require(backwards.cancel && !backwards.recording_error.empty() &&
              prefix.size() == 1 && prefix[0].frames == 1920,
          "backward clock published overlapping audio");
}
void cancelPreparation(const std::string &directory) {
  recording_prepare_hold = true;
  recording_prepare_entered = false;
  auto config = options(directory);
  auto marker = directory + "/device-started";
  auto owner = fs_owned_recording_capture_start(marker.c_str(), 0, 0,
                                                config.dump().c_str());
  require(owner, "preparation capture not admitted");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!recording_prepare_entered &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::yield();
  require(recording_prepare_entered, "preparation boundary not reached");
  auto state = poll(owner);
  require(state.at("ready") == false && state.at("capture_active") == false,
          "preparation presented active capture");
  auto token = fs_capture_finish_async(owner);
  require(token && fs_operation_status(token) == 0,
          "finish did not retain preparation owner");
  recording_prepare_hold = false;
  await(token);
  require(fs_operation_release(token) == 0,
          "cancel finish acknowledgement failed");
  require(!std::filesystem::exists(marker),
          "cancelled preparation acquired capture devices");
  state = poll(owner);
  require(state.at("state") == "sealed" && state.at("ready") == false,
          "cancelled preparation falsely ready");
  retire(owner);
}
void failureAndSchema(const std::string &directory) {
  auto config = options(directory, 65);
  require(
      !fs_owned_recording_capture_start("auto", 0, 0, config.dump().c_str()),
      "unbounded ID batch accepted");
  config = options(directory);
  config["unknown"] = 1;
  require(
      !fs_owned_recording_capture_start("auto", 0, 0, config.dump().c_str()),
      "unknown schema field accepted");
  config = options(directory);
  config["origin_us"] = std::numeric_limits<int64_t>::max();
  require(
      !fs_owned_recording_capture_start("auto", 0, 0, config.dump().c_str()),
      "future session clock accepted");
  config = options(directory);
  chmod(directory.c_str(), 0755);
  auto marker = directory + "/device-started";
  auto owner = fs_owned_recording_capture_start(marker.c_str(), 0, 0,
                                                config.dump().c_str());
  require(owner, "failed preparation lost owned handle");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  Json state;
  do {
    state = poll(owner);
    if (state.at("state") == "failed")
      break;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  } while (std::chrono::steady_clock::now() < deadline);
  require(state.at("state") == "failed" && !state.at("error").is_null(),
          "storage error did not latch");
  finish(owner);
  require(!poll(owner).at("error").is_null(),
          "finish overwrote storage warning");
  require(!std::filesystem::exists(marker),
          "unsafe directory acquired devices before storage");
  retire(owner);
  chmod(directory.c_str(), 0700);
}
} // namespace
int main(int argc, char **argv) {
  auto supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  if (argc == 2 && std::string(argv[1]) == "--publish-estimate") {
    try {
      // Test-only bounded operation: a real SQL authority supplies the private
      // reservation; this executable never ships with the application.
      std::array<char, 32769> input{};
      std::cin.getline(input.data(), input.size());
      require(bool(std::cin), "bounded publication probe request required");
      auto request = Json::parse(input.data());
      const auto drained = request.at("drained_override_us").get<int64_t>();
      request.erase("drained_override_us");
      Capture capture;
      capture.recording =
          foresight::recording_options(request.dump().c_str(), false);
      capture.recording_source_sample = capture.recording->source_sample;
      require(capture.prepare_recording(),
              "publication probe preparation failed");
      recording_drain_clock_us = drained;
      audio_frame(capture, std::vector<unsigned char>(3840, 0));
      recording_drain_clock_us = -1;
      capture.finish_recording();
      const auto chunks = capture.recording_writer->drainPublished();
      require(!capture.cancel && chunks.size() == 1,
              "publication probe capture failed");
      std::cout << Json{{"notice", foresight::recording_chunk_json(chunks[0])},
                        {"clock_quality", capture.recording_clock_quality},
                        {"acquired_through_us",
                         capture.recording_acquired_through_us.load()}}
                       .dump()
                << '\n';
      return 0;
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return 1;
    }
  }
  if (argc > 1 && std::string(argv[1]) == "--format") {
    std::string target;
    for (int i = 1; i + 1 < argc; ++i)
      if (std::string(argv[i]) == "--target") {
        target = argv[i + 1];
        int fd = open(argv[i + 1], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0)
          return 3;
        close(fd);
      }
    const int credits =
        open((target + ".credits").c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat metadata{};
    if (target.empty() || credits < 0 || fstat(credits, &metadata) ||
        !S_ISFIFO(metadata.st_mode))
      return 5;
    std::array<unsigned char, 3840> pcm{};
    for (unsigned i = 0; i < fixture_blocks; ++i) {
      if (i % credit_blocks == 0) {
        char credit;
        ssize_t count;
        do {
          count = read(credits, &credit, 1);
        } while (count < 0 && errno == EINTR);
        if (count != 1 || credit != 1)
          return 6;
      }
      size_t offset = 0;
      while (offset < pcm.size()) {
        auto n = write(STDOUT_FILENO, pcm.data() + offset, pcm.size() - offset);
        if (n <= 0)
          return 4;
        offset += static_cast<size_t>(n);
      }
    }
    close(credits);
    for (;;)
      pause();
  }
  Fixture fixture;
  try {
    setenv("FORESIGHT_CAPTURE_RUNTIME", argv[0], 1);
    setenv("FORESIGHT_HELPER", argv[0], 1);
    for (auto name :
         {"estimate", "resume", "capture", "cancel", "failure", "clock"})
      require(!mkdir((fixture.root + "/" + name).c_str(), 0700),
              "cannot create session fixture");
    const auto session_origin = foresight::recording_monotonic_us() - 1000000;
    estimatedFirstBlock(fixture.root + "/estimate", session_origin, 1, 0);
    estimatedFirstBlock(fixture.root + "/resume", session_origin, 2, 1920);
    captureAndBackpressure(fixture.root + "/capture");
    recoverWithoutDevices(fixture.root + "/capture");
    cancelQueuedRecoveryJoin(fixture.root + "/capture");
    clockGaps(fixture.root + "/clock");
    cancelPreparation(fixture.root + "/cancel");
    failureAndSchema(fixture.root + "/failure");
    std::filesystem::remove_all(fixture.root);
    std::cout << "8 durable capture ABI scenarios passed;0 skipped\n";
    return 0;
  } catch (const std::exception &e) {
    recording_prepare_hold = false;
    std::cerr << e.what() << ";fixture preserved at " << fixture.root << '\n';
    return 1;
  }
}
