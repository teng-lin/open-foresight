#pragma once
#include <istream>
#include <ostream>
#include <stdexcept>
#include <string>
#include <nlohmann/json.hpp>

namespace foresight {
struct ToolRequest {
  nlohmann::json tools;
  std::string system_message = "Follow the requested task faithfully. Do not invent facts.";
};

inline nlohmann::json wrap_tools(const nlohmann::json &tools) {
  if (!tools.is_array() || tools.empty())
    throw std::runtime_error("Tool definitions must be a nonempty array");
  auto result = nlohmann::json::array();
  for (auto &tool : tools) {
    if (!tool.is_object()) throw std::runtime_error("Tool definition must be an object");
    result.push_back(tool.contains("function") ? tool :
                     nlohmann::json({{"type", "function"}, {"function", tool}}));
  }
  return result;
}

// A legacy array retains the default system message. The application uses the
// object form so system instructions never become part of user content.
inline ToolRequest parse_tool_request(const nlohmann::json &value) {
  ToolRequest result;
  if (value.is_object()) {
    result.tools = wrap_tools(value.at("tools"));
    result.system_message = value.at("system_message").get<std::string>();
  } else {
    result.tools = wrap_tools(value);
  }
  return result;
}

// send retains its native conversation across all callback round trips.
template <class Send>
std::string tool_conversation(Send &&send, std::string message,
                              std::istream &input, std::ostream &output) {
  using json = nlohmann::json;
  for (int turn = 0; turn < 20; ++turn) {
    auto value = send(message);
    if (!value.is_object()) throw std::runtime_error("Invalid tool generation response");
    auto calls = value.value("tool_calls", json::array());
    if (calls.is_null() || calls.empty()) {
      output << "answer " << value.dump() << std::endl;
      return value.dump();
    }
    if (!calls.is_array()) throw std::runtime_error("Invalid tool calls");
    if (turn == 19) {
      auto error = json({{"error", "Max turns reached after tool call detection"}}).dump();
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
}
