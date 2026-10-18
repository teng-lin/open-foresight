#pragma once
#include <cstdint>
#include <istream>
#include <limits>
#include <nlohmann/json.hpp>
#include <ostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace foresight {
struct ToolRequest {
  nlohmann::json tools;
  std::string system_message =
      "Follow the requested task faithfully. Do not invent facts.";
  bool delegate_tool_detection = false;
  nlohmann::json messages = nlohmann::json::array();
  std::vector<std::vector<int32_t>> stop_token_ids;
  bool use_default_output_limit = false;
};

inline nlohmann::json wrap_tools(const nlohmann::json &tools) {
  if (!tools.is_array() || tools.empty())
    throw std::runtime_error("Tool definitions must be a nonempty array");
  auto result = nlohmann::json::array();
  for (auto &tool : tools) {
    if (!tool.is_object())
      throw std::runtime_error("Tool definition must be an object");
    result.push_back(
        tool.contains("function")
            ? tool
            : nlohmann::json({{"type", "function"}, {"function", tool}}));
  }
  return result;
}

// A legacy array retains the default system message. The application uses the
// object form so system instructions never become part of user content.
inline ToolRequest parse_tool_request(const nlohmann::json &value) {
  ToolRequest result;
  if (value.is_object()) {
    const auto &definitions = value.at("tools");
    result.tools = definitions.is_array() && definitions.empty()
                       ? definitions
                       : wrap_tools(definitions);
    result.system_message = value.at("system_message").get<std::string>();
    result.delegate_tool_detection =
        value.value("delegate_tool_detection", false);
    result.use_default_output_limit =
        value.value("use_default_output_limit", false);
    if (result.use_default_output_limit && !result.tools.empty())
      throw std::runtime_error(
          "Default output limit requires a plain conversation");
    if (value.contains("stop_token_ids")) {
      const auto &sequences = value.at("stop_token_ids");
      if (!sequences.is_array())
        throw std::runtime_error("Stop token sequences must be an array");
      for (const auto &sequence : sequences) {
        if (!sequence.is_array())
          throw std::runtime_error("Stop token sequence must be an array");
        std::vector<int32_t> ids;
        for (const auto &id : sequence) {
          if (!id.is_number_integer() ||
              (id.is_number_unsigned() && id.get<uint64_t>() > INT32_MAX) ||
              (!id.is_number_unsigned() && (id.get<int64_t>() < INT32_MIN ||
                                            id.get<int64_t>() > INT32_MAX)))
            throw std::runtime_error(
                "Stop token IDs must be signed 32-bit integers");
          ids.push_back(id.get<int32_t>());
        }
        if (!ids.empty())
          result.stop_token_ids.push_back(std::move(ids));
      }
    }
    result.messages = value.value("messages", nlohmann::json::array());
    if (!result.messages.is_array())
      throw std::runtime_error("Conversation messages must be an array");
    for (const auto &message : result.messages) {
      if (!message.is_object() || !message.contains("content") ||
          (message.value("role", "") != "user" &&
           message.value("role", "") != "assistant"))
        throw std::runtime_error("Invalid conversation history message");
    }
  } else {
    result.tools = wrap_tools(value);
  }
  return result;
}

// send retains its native conversation across all callback round trips.
template <class Send>
std::string tool_conversation(Send &&send, std::string message,
                              std::istream &input, std::ostream &output,
                              bool delegate_tool_detection = false) {
  using json = nlohmann::json;
  for (int turn = 0; turn < 20; ++turn) {
    auto value = send(message);
    if (!value.is_object())
      throw std::runtime_error("Invalid tool generation response");
    if (delegate_tool_detection) {
      // The Dart application applies the original native/text extraction rules.
      output << "model " << value.dump() << std::endl;
      std::string control_text;
      if (!std::getline(input, control_text))
        throw std::runtime_error("Tool conversation owner disconnected");
      auto control = json::parse(control_text);
      if (control.value("finish", false)) {
        auto result = control.contains("error")
                          ? json({{"error", control.at("error")}})
                          : value;
        output << "answer " << result.dump() << std::endl;
        return result.dump();
      }
      if (turn == 19) {
        auto error =
            json({{"error", "Max turns reached after tool call detection"}})
                .dump();
        output << "answer " << error << std::endl;
        return error;
      }
      auto reply = control.at("message");
      if (!reply.is_object() || reply.value("role", "") != "user")
        throw std::runtime_error("Invalid tool response message");
      message = reply.dump();
      continue;
    }
    auto calls = value.value("tool_calls", json::array());
    if (calls.is_null() || calls.empty()) {
      output << "answer " << value.dump() << std::endl;
      return value.dump();
    }
    if (!calls.is_array())
      throw std::runtime_error("Invalid tool calls");
    if (turn == 19) {
      auto error =
          json({{"error", "Max turns reached after tool call detection"}})
              .dump();
      output << "answer " << error << std::endl;
      return error;
    }
    output << "tool " << calls.dump() << std::endl;
    if (!std::getline(input, message))
      throw std::runtime_error("Tool conversation owner disconnected");
    auto reply = json::parse(message);
    if (!reply.is_object() || reply.value("role", "") != "user")
      throw std::runtime_error("Invalid tool response message");
  }
  throw std::runtime_error("Max turns reached in sendMessage");
}
} // namespace foresight
