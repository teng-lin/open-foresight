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
