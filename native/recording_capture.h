#pragma once
#include "recording_writer.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <nlohmann/json.hpp>
#include <set>
#include <stdexcept>

namespace foresight {
inline int64_t recording_monotonic_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
struct RecordingCaptureOptions {
  std::string directory;
  RecordingWriter::Identity identity;
  uint64_t span = 0, source_sample = 0;
  int64_t origin_us = 0;
  std::vector<RecordingWriter::Identity> identities;
};
inline nlohmann::json recording_json(const char *input) {
  constexpr size_t maximum = 32768;
  if (!input || strnlen(input, maximum + 1) > maximum)
    throw std::runtime_error("recording options exceed bounded schema");
  bool quoted = false, escape = false;
  unsigned depth = 0;
  for (const char *p = input; *p; ++p) {
    if (quoted) {
      if (escape)
        escape = false;
      else if (*p == '\\')
        escape = true;
      else if (*p == '\"')
        quoted = false;
    } else if (*p == '\"')
      quoted = true;
    else if (*p == '{' || *p == '[') {
      if (++depth > 8)
        throw std::runtime_error("recording options nesting exceeds schema");
    } else if (*p == '}' || *p == ']') {
      if (!depth)
        throw std::runtime_error("invalid recording options");
      --depth;
    }
  }
  try {
    return nlohmann::json::parse(input);
  } catch (...) {
    throw std::runtime_error("invalid recording options JSON");
  }
}
inline void recording_keys(const nlohmann::json &value,
                           const std::set<std::string> &keys) {
  if (!value.is_object() || value.size() != keys.size())
    throw std::runtime_error("invalid recording schema fields");
  for (auto &key : keys)
    if (!value.contains(key))
      throw std::runtime_error("missing recording schema field");
}
inline std::array<char, 37> recording_uuid(const nlohmann::json &value) {
  if (!value.is_string())
    throw std::runtime_error("invalid recording identity");
  const auto &text = value.get_ref<const std::string &>();
  if (text.size() != 36)
    throw std::runtime_error("invalid recording identity");
  for (size_t i = 0; i < 36; ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (text[i] != '-')
        throw std::runtime_error("invalid recording identity");
    } else if (!((text[i] >= '0' && text[i] <= '9') ||
                 (text[i] >= 'a' && text[i] <= 'f')))
      throw std::runtime_error("invalid recording identity");
  }
  std::array<char, 37> result{};
  std::copy(text.begin(), text.end(), result.begin());
  return result;
}
inline uint64_t recording_integer(const nlohmann::json &value) {
  if (!value.is_number_integer() ||
      (!value.is_number_unsigned() && value.get<int64_t>() < 0))
    throw std::runtime_error("invalid recording integer");
  auto result = value.get<uint64_t>();
  if (result > uint64_t(std::numeric_limits<int64_t>::max()))
    throw std::runtime_error("recording integer exceeds supported range");
  return result;
}
inline std::vector<RecordingWriter::Identity>
recording_identities(const nlohmann::json &value,
                     const RecordingWriter::Identity &base) {
  if (!value.is_array() || value.empty() ||
      value.size() > RecordingWriter::reservation_limit)
    throw std::runtime_error("invalid recording reservation count");
  std::vector<RecordingWriter::Identity> result;
  result.reserve(value.size());
  std::set<std::array<char, 37>> ids;
  std::set<uint64_t> sequences;
  for (auto &item : value) {
    recording_keys(item, {"id", "sequence"});
    auto id = base;
    id.chunk = recording_uuid(item.at("id"));
    id.sequence = recording_integer(item.at("sequence"));
    if (!ids.insert(id.chunk).second || !sequences.insert(id.sequence).second)
      throw std::runtime_error("duplicate recording reservation");
    result.push_back(id);
  }
  return result;
}
inline std::shared_ptr<const RecordingCaptureOptions>
recording_options(const char *input, bool playback) {
  auto value = recording_json(input);
  recording_keys(value, {"directory", "session_id", "generation", "span",
                         "origin_us", "source_sample", "chunk_ids"});
  auto options = std::make_shared<RecordingCaptureOptions>();
  options->directory = value.at("directory").get<std::string>();
  if (options->directory.empty() || options->directory.size() > 4096 ||
      options->directory.front() != '/' ||
      options->directory.find('\0') != std::string::npos)
    throw std::runtime_error("invalid recording directory");
  options->identity.session = recording_uuid(value.at("session_id"));
  options->identity.generation = recording_uuid(value.at("generation"));
  options->identity.source = playback ? 1 : 0;
  options->span = recording_integer(value.at("span"));
  options->source_sample = recording_integer(value.at("source_sample"));
  options->origin_us =
      static_cast<int64_t>(recording_integer(value.at("origin_us")));
  if (options->origin_us > recording_monotonic_us())
    throw std::runtime_error("recording origin is in the future");
  options->identities =
      recording_identities(value.at("chunk_ids"), options->identity);
  return options;
}
inline std::shared_ptr<const RecordingCaptureOptions>
recording_recovery_options(const char *input, int source) {
  if (source < 0 || source > 1)
    throw std::runtime_error("invalid recording source");
  auto value = recording_json(input);
  recording_keys(value, {"directory", "session_id", "generation", "chunk_ids"});
  value["span"] = 0;
  value["origin_us"] = recording_monotonic_us();
  value["source_sample"] = 0;
  return recording_options(value.dump().c_str(), source != 0);
}
inline nlohmann::json
recording_chunk_json(const RecordingWriter::Chunk &chunk) {
  return {{"chunk_id", chunk.identity.chunk.data()},
          {"session_id", chunk.identity.session.data()},
          {"generation", chunk.identity.generation.data()},
          {"source", chunk.identity.source},
          {"sequence", chunk.identity.sequence},
          {"span", chunk.span},
          {"source_sample", chunk.source_sample},
          {"frames", chunk.frames},
          {"sample_rate", 48000},
          {"channels", 1},
          {"capture_start_us", chunk.capture_start_us},
          {"bytes", chunk.bytes},
          {"relative_path", chunk.relative_path},
          {"interrupted", chunk.interrupted},
          {"gap_before", chunk.gap_before},
          {"contents_synced", chunk.contents_synced},
          {"directory_synced", chunk.directory_synced}};
}
} // namespace foresight
