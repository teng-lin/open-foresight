#pragma once

#include <chrono>
#include <exception>
#include <filesystem>
#include <functional>
#include <iostream>
#include <string>
#include <thread>

namespace foresight {
using StartupWarning = std::function<void(const std::string &)>;
using CacheSleep = std::function<void(std::chrono::milliseconds)>;

inline void startup_warning(const std::string &message) {
  std::cerr << message << std::endl;
}

// Failed deletion is best effort. It must not prevent the fresh initializer.
inline bool delete_model_cache_file(
    const std::filesystem::path &path,
    const CacheSleep &sleep =
        [](std::chrono::milliseconds delay) {
          std::this_thread::sleep_for(delay);
        },
    const StartupWarning &warn = startup_warning,
    const std::function<bool(const std::filesystem::path &)> &exists =
        [](const auto &candidate) {
          return std::filesystem::exists(candidate);
        },
    const std::function<void(const std::filesystem::path &)> &unlink =
        [](const auto &candidate) { std::filesystem::remove(candidate); }) {
  for (int attempt = 1; attempt <= 5; ++attempt) {
    try {
      if (!exists(path))
        return true;
      unlink(path);
      return true;
    } catch (const std::exception &error) {
      if (attempt == 5) {
        warn("Cannot delete model cache file " + path.string() + ": " +
             error.what());
        return false;
      }
      sleep(std::chrono::milliseconds(100 * attempt));
    }
  }
  return false;
}

inline void clear_model_cache(
    const std::filesystem::path &model, const std::filesystem::path &cache,
    const StartupWarning &warn = startup_warning,
    const std::function<void(const std::filesystem::path &)> &remove = {}) {
  const auto name = model.filename().string();
  const auto stem = model.stem().string();
  const auto matches = [&](const std::filesystem::path &path) {
    const auto basename = path.filename().string();
    return basename.rfind(name, 0) == 0 || basename.rfind(stem, 0) == 0;
  };
  const auto erase = [&](const std::filesystem::path &path) {
    if (remove)
      remove(path);
    else
      delete_model_cache_file(
          path,
          [](std::chrono::milliseconds delay) {
            std::this_thread::sleep_for(delay);
          },
          warn);
  };
  try {
    const auto model_absolute =
        std::filesystem::absolute(model).lexically_normal();
    const auto is_model = [&](const std::filesystem::path &path) {
      return std::filesystem::absolute(path).lexically_normal() ==
             model_absolute;
    };
    // Only the worker's configured cache is owned here. Never walk support
    // directories belonging to another application, or recurse into folders.
    if (std::filesystem::exists(cache)) {
      for (const auto &entry : std::filesystem::directory_iterator(cache)) {
        if (!is_model(entry.path()) && entry.is_regular_file() &&
            matches(entry.path()))
          erase(entry.path());
      }
    }
    for (const auto &entry :
         std::filesystem::directory_iterator(model_absolute.parent_path())) {
      const auto basename = entry.path().filename().string();
      if (!is_model(entry.path()) && entry.is_regular_file() &&
          matches(entry.path()) &&
          (basename.find("_mldrift_") != std::string::npos ||
           basename.find(".xnnpack_cache") != std::string::npos))
        erase(entry.path());
    }
  } catch (const std::filesystem::filesystem_error &error) {
    // The original helper abandons the whole scan on a listing error.
    warn("Cannot clear model cache for " + model.string() + ": " +
         error.what());
  }
}

// Only initialization is inside this retry boundary. Inference failures must
// propagate to the caller without initializing another model.
template <typename Initialize, typename Clear, typename EnsureCache,
          typename Shutdown>
void initialize_generation_engine(
    bool query_detector, Initialize initialize, Clear clear,
    EnsureCache ensure_cache, Shutdown shutdown,
    const StartupWarning &warn = startup_warning, bool vision_enabled = false,
    const std::function<void()> &disable_vision = {}) {
  if (query_detector) {
    initialize();
    return;
  }
  try {
    initialize();
    return;
  } catch (const std::exception &error) {
    warn(std::string(
             "Model initialization failed; clearing its cache before retry: ") +
         error.what());
  }
  try {
    clear();
    ensure_cache();
  } catch (...) {
    shutdown();
    throw;
  }
  shutdown();
  try {
    initialize();
    return;
  } catch (...) {
    shutdown();
    if (!vision_enabled || !disable_vision)
      throw;
  }
  warn("Vision initialization failed twice; retrying with vision disabled");
  disable_vision();
  try {
    initialize();
  } catch (...) {
    shutdown();
    throw;
  }
}
} // namespace foresight
