#include "model_startup.h"
#include "generation_model_config.h"
#include <fstream>
#include <stdexcept>
#include <vector>

namespace fs = std::filesystem;

void check(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}

struct Fixture {
  fs::path root;
  Fixture() {
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    root = fs::temp_directory_path() / ("foresight-startup-" + std::to_string(stamp));
    fs::create_directories(root);
  }
  ~Fixture() {
    std::error_code error;
    fs::remove_all(root, error);
  }
  fs::path file(const fs::path &relative) {
    const auto path = root / relative;
    fs::create_directories(path.parent_path());
    std::ofstream(path) << "fixture";
    return path;
  }
};

void cache_scope() {
  Fixture fixture;
  const auto model = fixture.file("models/note.litertlm");
  const auto cache = fixture.root / "owned-cache/gpu";
  const auto full_prefix = fixture.file("owned-cache/gpu/note.litertlm.compiled");
  const auto stem_prefix = fixture.file("owned-cache/gpu/note-other.bin");
  const auto unrelated = fixture.file("owned-cache/gpu/other.xnnpack_cache");
  const auto nested = fixture.file("owned-cache/gpu/note-folder/note.compiled");
  const auto adjacent_drift = fixture.file("models/note_mldrift_cache.extra");
  const auto adjacent_xnn = fixture.file("models/note.litertlm.xnnpack_cache.extra");
  const auto weights = fixture.file("models/note-weights.bin");
  const auto unrelated_adjacent = fixture.file("models/other_mldrift_cache");
  const auto other_backend = fixture.file("owned-cache/cpu/note.compiled");
  const auto outside_target = fixture.file("outside/target");
  const auto link = cache / "note-linked-cache";
  fs::create_symlink(outside_target, link);
  foresight::clear_model_cache(model, cache);
  for (const auto &path : {full_prefix, stem_prefix, adjacent_drift, adjacent_xnn, link})
    check(!fs::exists(path), "eligible cache file survived");
  for (const auto &path : {model, unrelated, nested, weights, unrelated_adjacent,
                           other_backend, outside_target})
    check(fs::exists(path), "unrelated file or symlink target removed");
}

void listing_failure_stops_scan() {
  Fixture fixture;
  const auto model = fixture.file("models/note.litertlm");
  const auto adjacent = fixture.file("models/note_mldrift_cache");
  const auto cache_file = fixture.file("not-a-directory");
  int warnings = 0;
  foresight::clear_model_cache(model, cache_file,
      [&](const std::string &) { ++warnings; });
  check(warnings == 1, "listing failure did not warn once");
  check(fs::exists(adjacent), "scan continued after first listing failure");
}

void deletion_retry() {
  std::vector<int> delays;
  int attempts = 0, warnings = 0;
  const auto sleep = [&](std::chrono::milliseconds delay) {
    delays.push_back(static_cast<int>(delay.count()));
  };
  const auto warn = [&](const std::string &) { ++warnings; };
  const auto exists = [](const fs::path &) { return true; };
  check(!foresight::delete_model_cache_file("cache", sleep, warn, exists,
      [&](const fs::path &) { ++attempts; throw std::runtime_error("busy"); }),
      "terminal deletion failure succeeded");
  check(attempts == 5 && warnings == 1, "wrong deletion attempts or warnings");
  check(delays == std::vector<int>({100, 200, 300, 400}), "wrong deletion backoff");
  delays.clear(); attempts = 0; warnings = 0;
  check(foresight::delete_model_cache_file("cache", sleep, warn, exists,
      [&](const fs::path &) {
        if (++attempts < 3) throw std::runtime_error("busy");
      }), "transient deletion did not recover");
  check(attempts == 3 && warnings == 0 && delays == std::vector<int>({100, 200}),
      "transient deletion did not stop at success");
  delays.clear(); attempts = 0;
  check(foresight::delete_model_cache_file("missing", sleep, warn,
      [](const fs::path &) { return false; },
      [&](const fs::path &) { ++attempts; }), "missing file did not succeed");
  check(attempts == 0 && delays.empty(), "missing file was deleted or delayed");
}

void retry_order_and_settings() {
  Fixture fixture;
  const auto model = fixture.file("models/note.litertlm");
  const auto cache = fixture.root / "cache/gpu";
  const auto stale = fixture.file("cache/gpu/note.cache");
  std::vector<std::string> events;
  const std::string requested_backend = "gpu";
  std::vector<const std::string *> backends;
  int attempts = 0;
  foresight::initialize_generation_engine(false,
      [&] {
        events.push_back("initialize");
        backends.push_back(&requested_backend);
        if (++attempts == 1) throw std::runtime_error("first");
        check(fs::is_directory(cache), "retry cache directory missing");
        check(!fs::exists(stale), "retry preceded cache clearing");
      },
      [&] {
        events.push_back("clear");
        foresight::clear_model_cache(model, cache);
        fs::remove(cache);
      },
      [&] { events.push_back("mkdir"); fs::create_directories(cache); },
      [&] {
        events.push_back("shutdown");
        check(fs::is_directory(cache), "shutdown preceded mkdir");
      }, [](const std::string &) {});
  check(events == std::vector<std::string>({"initialize", "clear", "mkdir",
                                           "shutdown", "initialize"}),
        "wrong startup recovery ordering");
  check(backends.size() == 2 && backends[0] == backends[1], "backend settings changed");
}

void second_failure_and_query_bypass() {
  int attempts = 0, clears = 0, mkdirs = 0, shutdowns = 0;
  const auto initialize = [&] {
    ++attempts;
    throw std::runtime_error(attempts == 1 ? "first" : "second");
  };
  const auto clear = [&] { ++clears; };
  const auto mkdir = [&] { ++mkdirs; };
  const auto shutdown = [&] { ++shutdowns; };
  try {
    foresight::initialize_generation_engine(false, initialize, clear, mkdir, shutdown,
                                           [](const std::string &) {});
    check(false, "second failure was swallowed");
  } catch (const std::runtime_error &error) {
    check(std::string(error.what()) == "second", "wrong initialization error propagated");
  }
  check(attempts == 2 && clears == 1 && mkdirs == 1 && shutdowns == 2,
        "second failure attempted fallback or omitted shutdown");
  attempts = clears = mkdirs = shutdowns = 0;
  try {
    foresight::initialize_generation_engine(true, initialize, clear, mkdir, shutdown);
    check(false, "query failure was swallowed");
  } catch (const std::runtime_error &error) {
    check(std::string(error.what()) == "first", "query error changed");
  }
  check(attempts == 1 && clears == 0 && mkdirs == 0 && shutdowns == 0,
        "query detector entered recovery");
}

void inference_not_retried() {
  int attempts = 0, recovery = 0;
  try {
    foresight::initialize_generation_engine(false, [&] { ++attempts; },
        [&] { ++recovery; }, [&] { ++recovery; }, [&] { ++recovery; });
    throw std::runtime_error("inference failed");
  } catch (const std::runtime_error &error) {
    check(std::string(error.what()) == "inference failed", "inference error changed");
  }
  check(attempts == 1 && recovery == 0, "inference failure retried initialization");
}

void vision_fallback() {
  for (bool final_failure : {false, true}) {
    bool vision = true;
    int attempts = 0, clears = 0, closes = 0;
    std::vector<bool> observed;
    try {
      foresight::initialize_generation_engine(false, [&] {
        observed.push_back(vision);
        if (++attempts <= 2 || final_failure) throw std::runtime_error("startup");
      }, [&] { ++clears; }, [] {}, [&] { ++closes; }, [](const auto &) {},
      true, [&] { vision = false; });
      check(!final_failure, "final fallback failure swallowed");
    } catch (const std::runtime_error &) {
      check(final_failure, "successful text-only fallback rejected");
    }
    check(observed == std::vector<bool>({true, true, false}), "wrong vision attempts");
    check(clears == 1 && closes == (final_failure ? 3 : 2), "wrong fallback cleanup");
  }
  for (int type : {8, 9, 10, 14, 15}) {
    const auto c = foresight::generation_model_config(type);
    check(c.vision && std::string(c.vision_backend) == "gpu" &&
          std::string(c.audio_backend) == "cpu" && c.visual_tokens == 280, "wrong small model config");
  }
  for (int type : {12, 16}) {
    const auto c = foresight::generation_model_config(type);
    check(c.vision && std::string(c.audio_backend) == "gpu" && c.visual_tokens == 560, "wrong large model config");
  }
  for (int type : {8, 9, 10, 12, 14, 15, 16}) {
    const auto reference = foresight::generation_model_config(type);
    const auto cpu = foresight::generation_model_config(type, true);
    check(cpu.vision && std::string(cpu.vision_backend) == "cpu" &&
          std::string(cpu.audio_backend) == "cpu", "CPU model retained a GPU modality");
    check(cpu.visual_tokens == reference.visual_tokens, "CPU selection changed model token configuration");
  }
  const auto cpu_unknown = foresight::generation_model_config(0, true);
  check(!cpu_unknown.vision && cpu_unknown.vision_backend == nullptr &&
        std::string(cpu_unknown.audio_backend) == "cpu", "CPU selection enabled an unknown vision model");
  check(!foresight::generation_model_config(0).vision, "unknown model enabled vision");
}

int main() {
  vision_fallback();
  cache_scope();
  listing_failure_stops_scan();
  deletion_retry();
  retry_order_and_settings();
  second_failure_and_query_bypass();
  inference_not_retried();
}
