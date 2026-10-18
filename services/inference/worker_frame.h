#pragma once
#include <nlohmann/json.hpp>
#include <string>

namespace foresight {
// Runtime and exception strings may contain malformed bytes. Preserve the
// frame, replacing those bytes with U+FFFD instead of dropping the utterance.
inline std::string frame_json(const nlohmann::json &value) {
  return value.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}
} // namespace foresight
