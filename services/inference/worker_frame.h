#pragma once
#include <nlohmann/json.hpp>
#include <string>

namespace foresight {
// Runtime and exception strings may contain malformed bytes. Preserve the
// frame, replacing those bytes with U+FFFD instead of dropping the utterance.
inline std::string frame_json(const nlohmann::json &value) {
  return value.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}
inline std::string error_frame_json(const char *message) noexcept {
  try {
    return frame_json(nlohmann::json(message));
  } catch (...) {
    return {}; // Default construction cannot allocate or throw.
  }
}
} // namespace foresight
