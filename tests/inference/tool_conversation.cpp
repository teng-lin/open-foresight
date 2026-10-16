#include "../../services/inference/tool_conversation.h"
#include <sstream>
#include <vector>
#include <iostream>
using json = nlohmann::json;
void check(bool value) { if (!value) throw std::runtime_error("Tool protocol assertion failed"); }
int main() {
  try {
    const auto calls = json::array({{{"function", {{"name", "google_search"}, {"arguments", "{\"query\":\"nested\"}"}}}}});
    const auto reply = json({{"role", "user"}, {"content", {{{"type", "text"}, {"text", "Result 中文"}}}}});
    std::istringstream input(reply.dump() + "\n");
    std::ostringstream output;
    std::vector<json> messages;
    auto result = foresight::tool_conversation([&](const std::string &message) {
      messages.push_back(json::parse(message));
      return messages.size() == 1 ? json({{"tool_calls", calls}}) :
          json({{"role", "assistant"}, {"content", "Answer [Source:1]"}});
    }, json({{"role", "user"}, {"content", "Question"}}).dump(), input, output);
    check(messages.size() == 2 && messages[1] == reply);
    check(json::parse(result)["content"] == "Answer [Source:1]");
    check(output.str().starts_with("tool " + calls.dump() + "\nanswer "));
    auto wrapped = foresight::wrap_tools(json::array({{{"name", "google_search"}}}));
    check(wrapped[0]["type"] == "function" && wrapped[0]["function"]["name"] == "google_search");
    check(foresight::wrap_tools(wrapped) == wrapped);
    auto options = foresight::parse_tool_request({{"tools", wrapped}, {"system_message", "Original instructions"}});
    check(options.tools == wrapped && options.system_message == "Original instructions");
    check(foresight::parse_tool_request(wrapped).tools == wrapped);
    auto history = json::array({{{"role", "user"}, {"content", "Earlier query"}},
                                {{"role", "assistant"}, {"content", "Earlier answer [Source:8]"}}});
    auto replay = foresight::parse_tool_request({{"tools", wrapped}, {"system_message", "Instructions"}, {"messages", history}});
    check(replay.messages == history);
    bool bad_history = false;
    try {
      foresight::parse_tool_request({{"tools", wrapped}, {"system_message", "Instructions"},
                                     {"messages", {{{"role", "system"}, {"content", "Invalid history role"}}}}});
    } catch (const std::exception &) { bad_history = true; }
    check(bad_history);
    std::istringstream delegated_input(json({{"message", reply}}).dump() + "\n{\"finish\":true}\n");
    std::ostringstream delegated_output;
    int delegated_turns = 0;
    auto delegated_answer = foresight::tool_conversation([&](const std::string &message) {
      if (++delegated_turns == 1)
        return json({{"content", {{{"type", "text"}, {"text", "textual tool request"}}}}});
      check(json::parse(message) == reply);
      return json({{"content", "Final answer"}});
    }, "{}", delegated_input, delegated_output, true);
    check(delegated_turns == 2 && json::parse(delegated_answer)["content"] == "Final answer");
    check(delegated_output.str().starts_with("model "));
    std::istringstream finish_error("{\"finish\":true,\"error\":\"Max turns reached after tool call detection\"}\n");
    std::ostringstream error_output;
    auto delegated_error = foresight::tool_conversation([](const std::string &) {
      return json({{"content", "pending call"}});
    }, "{}", finish_error, error_output, true);
    check(json::parse(delegated_error).contains("error"));
    for (auto invalid : {json::object(), json({{"tools", wrapped}, {"system_message", 123}})}) {
      bool rejected = false;
      try { foresight::parse_tool_request(invalid); } catch (const std::exception &) { rejected = true; }
      check(rejected);
    }
    std::string replies;
    for (int i=0; i<19; ++i) replies += reply.dump() + "\n";
    std::istringstream repeated_input(replies);
    std::ostringstream repeated_output;
    int turns = 0;
    auto limit = foresight::tool_conversation([&](const std::string &) {
      ++turns; return json({{"tool_calls", calls}});
    }, "{}", repeated_input, repeated_output);
    check(turns == 20);
    check(json::parse(limit)["error"] == "Max turns reached after tool call detection");
    for (const std::string reply_text : {"", "{}\n"}) {
      std::istringstream bad_input(reply_text);
      std::ostringstream bad_output;
      bool failed = false;
      try {
        foresight::tool_conversation([&](const std::string &) {
          return json({{"tool_calls", calls}});
        }, "{}", bad_input, bad_output);
      } catch (const std::runtime_error &) { failed = true; }
      check(failed);
    }
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n'; return 1;
  }
}
