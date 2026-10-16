#pragma once
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <string>

namespace foresight {
// Pinned LiteRT conversation callbacks contain message deltas. Native tools are
// delivered as complete calls when stream_tool_calls remains disabled.
class ConversationStreamMessage {
  using json = nlohmann::json;
  json value_ = json::object();

public:
  void append(const json &chunk) {
    if (!chunk.is_object())
      throw std::runtime_error("Invalid streamed conversation message");
    for (auto item = chunk.begin(); item != chunk.end(); ++item) {
      const auto &key = item.key();
      const auto &value = item.value();
      if (key == "content") {
        if (value.is_string() &&
            (!value_.contains(key) || value_[key].is_string())) {
          value_[key] = value_.value(key, std::string()) + value.get<std::string>();
          continue;
        }
        if (!value.is_string() && !value.is_array())
          throw std::runtime_error("Invalid streamed conversation content");
        if (!value_.contains(key)) value_[key] = json::array();
        if (value_[key].is_string())
          value_[key] = json::array({{{"type", "text"}, {"text", value_[key]}}});
        auto &parts = value_[key];
        const auto incoming = value.is_string()
            ? json::array({{{"type", "text"}, {"text", value}}}) : value;
        for (const auto &part : incoming) {
          bool text = part.is_object() && part.value("type", "") == "text" &&
                      part.contains("text") && part["text"].is_string();
          if (text && !parts.empty() && parts.back().is_object() &&
              parts.back().value("type", "") == "text" &&
              parts.back().contains("text") && parts.back()["text"].is_string()) {
            auto a = part, b = parts.back();
            a.erase("text"); b.erase("text");
            if (a == b) {
              parts.back()["text"] = parts.back()["text"].get<std::string>() +
                                      part["text"].get<std::string>();
              continue;
            }
          }
          parts.push_back(part);
        }
      } else if (key == "tool_calls") {
        if (value.is_null()) continue;
        if (!value.is_array())
          throw std::runtime_error("Invalid streamed tool calls");
        if (!value_.contains(key)) value_[key] = json::array();
        for (const auto &call : value) value_[key].push_back(call);
      } else if (key == "channels") {
        if (!value.is_object())
          throw std::runtime_error("Invalid streamed conversation channels");
        if (!value_.contains(key)) value_[key] = json::object();
        for (auto channel = value.begin(); channel != value.end(); ++channel) {
          if (!channel.value().is_string())
            throw std::runtime_error("Invalid streamed conversation channels");
          value_[key][channel.key()] = value_[key].value(channel.key(), std::string()) +
                                      channel.value().get<std::string>();
        }
      } else {
        value_[key] = value;
      }
    }
  }
  json value() const {
    return value_.empty() ? json({{"role", "assistant"}, {"content", json::array()}}) : value_;
  }
};

inline nlohmann::json parse_conversation_stream_chunk(const char *raw) {
  try {
    return nlohmann::json::parse(raw);
  } catch (const nlohmann::json::parse_error &) {
    return {{"role", "assistant"},
            {"content", {{{"type", "text"}, {"text", raw}}}}};
  }
}
}
