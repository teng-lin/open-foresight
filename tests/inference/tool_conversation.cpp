#include "../../services/inference/tool_conversation.h"
#include "../../services/inference/conversation_stream.h"
#include "../../services/inference/persistent_worker.h"
#include <algorithm>
#include <iostream>
#include <sstream>
#include <vector>
using json = nlohmann::json;
void check(bool value) {
  if (!value)
    throw std::runtime_error("Tool protocol assertion failed");
}
int main() {
  try {
    std::ostringstream plain_frames;
    foresight::TextFrameBuffer text_buffer(plain_frames);
    std::ostream plain_text(&text_buffer);
    plain_text << "first λ\n" << std::flush;
    check(plain_frames.str() == "text " + json("first λ\n").dump() + "\n");
    plain_text << "second" << std::flush;
    check(plain_frames.str().ends_with("text " + json("second").dump() + "\n"));
    const json native_default = {{"tools", json::array()},
                                 {"use_default_output_limit", true}};
    check(foresight::valid_output_budget(0, native_default));
    for (const auto &invalid :
         {json(true), json(false), json(-1), json(0.0), json(3073), json("0")})
      check(!foresight::valid_output_budget(invalid, native_default));
    for (const auto &invalid :
         {json(nullptr), json::array(), json::object(),
          json({{"tools", json::array()}}),
          json({{"tools", json::array()}, {"use_default_output_limit", 1}}),
          json({{"tools", {{{"name", "search"}}}},
                {"use_default_output_limit", true}})})
      check(!foresight::valid_output_budget(0, invalid));
    check(foresight::valid_output_budget(1, nullptr));
    check(foresight::valid_output_budget(3072, nullptr));
    const auto calls =
        json::array({{{"function",
                       {{"name", "google_search"},
                        {"arguments", "{\"query\":\"nested\"}"}}}}});
    foresight::ConversationStreamMessage streamed;
    streamed.append({{"role", "assistant"},
                     {"content", "蓝🧭\n"},
                     {"channels", {{"analysis", "first"}}}});
    streamed.append({{"content", {{{"type", "text"}, {"text", "Complete"}}}},
                     {"channels", {{"analysis", " second"}}}});
    streamed.append({{"tool_calls", calls}, {"usage", {{"output_tokens", 2}}}});
    auto assembled = streamed.value();
    check(assembled["content"] ==
          json::array({{{"type", "text"}, {"text", "蓝🧭\nComplete"}}}));
    check(assembled["channels"]["analysis"] == "first second");
    check(assembled["tool_calls"] == calls);
    check(assembled["tool_calls"][0]["function"]["arguments"].is_string());
    check(assembled["usage"]["output_tokens"] == 2);
    check(foresight::ConversationStreamMessage().value() ==
          json({{"role", "assistant"}, {"content", json::array()}}));
    check(foresight::parse_conversation_stream_chunk(
              "plain text")["content"][0]["text"] == "plain text");
    for (const auto &invalid : {json(123), json({{"content", 123}}),
                                json({{"tool_calls", "invalid"}}),
                                json({{"channels", {{"analysis", 123}}}})}) {
      bool rejected = false;
      try {
        foresight::ConversationStreamMessage().append(invalid);
      } catch (const std::exception &) {
        rejected = true;
      }
      check(rejected);
    }
    const auto reply =
        json({{"role", "user"},
              {"content", {{{"type", "text"}, {"text", "Result 中文"}}}}});
    std::istringstream input(reply.dump() + "\n");
    std::ostringstream output;
    std::vector<json> messages;
    auto result = foresight::tool_conversation(
        [&](const std::string &message) {
          messages.push_back(json::parse(message));
          return messages.size() == 1
                     ? json({{"tool_calls", calls}})
                     : json({{"role", "assistant"},
                             {"content", "Answer [Source:1]"}});
        },
        json({{"role", "user"}, {"content", "Question"}}).dump(), input,
        output);
    check(messages.size() == 2 && messages[1] == reply);
    check(json::parse(result)["content"] == "Answer [Source:1]");
    check(output.str().starts_with("tool " + calls.dump() + "\nanswer "));
    auto wrapped =
        foresight::wrap_tools(json::array({{{"name", "google_search"}}}));
    check(wrapped[0]["type"] == "function" &&
          wrapped[0]["function"]["name"] == "google_search");
    check(foresight::wrap_tools(wrapped) == wrapped);
    auto options = foresight::parse_tool_request(
        {{"tools", wrapped}, {"system_message", "Original instructions"}});
    check(options.tools == wrapped &&
          options.system_message == "Original instructions");
    check(foresight::parse_tool_request(wrapped).tools == wrapped);
    auto plain = foresight::parse_tool_request(
        {{"tools", json::array()}, {"system_message", ""}});
    check(plain.tools.empty() && plain.system_message.empty());
    auto stopped = foresight::parse_tool_request(
        {{"tools", json::array()},
         {"system_message", ""},
         {"stop_token_ids", {{101, 202}, json::array(), {303}, {101, 202}}},
         {"use_default_output_limit", true}});
    check(stopped.stop_token_ids ==
          std::vector<std::vector<int32_t>>{{101, 202}, {303}, {101, 202}});
    check(stopped.use_default_output_limit);
    for (const auto &invalid :
         {json(nullptr), json("ids"), json({1}), json({{true}}), json({{1.5}}),
          json({{2147483648LL}}), json({{-2147483649LL}}),
          json({{UINT64_MAX}})}) {
      bool rejected = false;
      try {
        foresight::parse_tool_request({{"tools", json::array()},
                                       {"system_message", ""},
                                       {"stop_token_ids", invalid}});
      } catch (const std::exception &) {
        rejected = true;
      }
      check(rejected);
    }
    for (const auto &invalid : {json({{"tools", wrapped},
                                      {"system_message", ""},
                                      {"use_default_output_limit", true}}),
                                json({{"tools", json::array()},
                                      {"system_message", ""},
                                      {"use_default_output_limit", 1}})}) {
      bool rejected = false;
      try {
        foresight::parse_tool_request(invalid);
      } catch (const std::exception &) {
        rejected = true;
      }
      check(rejected);
    }
    auto history = json::array(
        {{{"role", "user"}, {"content", "Earlier query"}},
         {{"role", "assistant"}, {"content", "Earlier answer [Source:8]"}}});
    auto replay =
        foresight::parse_tool_request({{"tools", wrapped},
                                       {"system_message", "Instructions"},
                                       {"messages", history}});
    check(replay.messages == history);
    bool bad_history = false;
    try {
      foresight::parse_tool_request(
          {{"tools", wrapped},
           {"system_message", "Instructions"},
           {"messages",
            {{{"role", "system"}, {"content", "Invalid history role"}}}}});
    } catch (const std::exception &) {
      bad_history = true;
    }
    check(bad_history);
    std::istringstream delegated_input(json({{"message", reply}}).dump() +
                                       "\n{\"finish\":true}\n");
    std::ostringstream delegated_output;
    int delegated_turns = 0;
    auto delegated_answer = foresight::tool_conversation(
        [&](const std::string &message) {
          if (++delegated_turns == 1)
            return json(
                {{"content",
                  {{{"type", "text"}, {"text", "textual tool request"}}}}});
          check(json::parse(message) == reply);
          return json({{"content", "Final answer"}});
        },
        "{}", delegated_input, delegated_output, true);
    check(delegated_turns == 2 &&
          json::parse(delegated_answer)["content"] == "Final answer");
    check(delegated_output.str().starts_with("model "));
    std::istringstream finish_error("{\"finish\":true,\"error\":\"Max turns "
                                    "reached after tool call detection\"}\n");
    std::ostringstream error_output;
    auto delegated_error = foresight::tool_conversation(
        [](const std::string &) { return json({{"content", "pending call"}}); },
        "{}", finish_error, error_output, true);
    check(json::parse(delegated_error).contains("error"));
    for (auto invalid : {json::object(),
                         json({{"tools", wrapped}, {"system_message", 123}})}) {
      bool rejected = false;
      try {
        foresight::parse_tool_request(invalid);
      } catch (const std::exception &) {
        rejected = true;
      }
      check(rejected);
    }
    std::string replies;
    for (int i = 0; i < 19; ++i)
      replies += reply.dump() + "\n";
    std::istringstream repeated_input(replies);
    std::ostringstream repeated_output;
    int turns = 0;
    auto limit = foresight::tool_conversation(
        [&](const std::string &) {
          ++turns;
          return json({{"tool_calls", calls}});
        },
        "{}", repeated_input, repeated_output);
    check(turns == 20);
    check(json::parse(limit)["error"] ==
          "Max turns reached after tool call detection");
    for (const std::string reply_text : {"", "{}\n"}) {
      std::istringstream bad_input(reply_text);
      std::ostringstream bad_output;
      bool failed = false;
      try {
        foresight::tool_conversation(
            [&](const std::string &) { return json({{"tool_calls", calls}}); },
            "{}", bad_input, bad_output);
      } catch (const std::runtime_error &) {
        failed = true;
      }
      check(failed);
    }

    // A routed reply cannot cross request IDs. Completion is published only
    // after the generator's native lease is closed, including cancellation.
    {
      foresight::ReplyBuffer commands;
      std::istream owner_input(&commands);
      std::vector<std::string> frames, lifecycle;
      bool active = false, closed_before_terminal = true;
      foresight::FrameBuffer capture([&](const std::string &line) {
        frames.push_back(line);
        if (line == "ready 1")
          commands.push("generate 1 {\"prompt\":\"First\",\"tools\":{}}");
        else if (line.starts_with("1 model ")) {
          commands.push("reply 0 {\"finish\":true,\"error\":\"stale\"}");
          commands.push("reply 1 {\"finish\":true}");
        } else if (line == "1 done completed") {
          closed_before_terminal &= !active;
          commands.push("generate 2 {\"prompt\":\"Cancel\",\"tools\":{}}");
        } else if (line.starts_with("2 model "))
          commands.push("cancel 2");
        else if (line == "2 done cancelled") {
          closed_before_terminal &= !active;
          commands.push("generate 3 {\"prompt\":null}");
        } else if (line == "3 done failed")
          commands.push("shutdown");
      });
      std::ostream framed_output(&capture);
      foresight::persistent_worker(
          owner_input, framed_output,
          [&](const json &request, std::istream &control, std::ostream &stream,
              const std::function<bool(void *)> &registration) {
            active = true;
            registration(reinterpret_cast<void *>(42));
            stream << "model {}" << std::endl;
            std::string reply;
            const bool got_reply = bool(std::getline(control, reply));
            registration(nullptr);
            active = false;
            lifecycle.push_back("close");
            if (!got_reply)
              throw std::runtime_error("Owner cancelled");
            check(request.at("prompt") == "First");
            check(json::parse(reply) == json({{"finish", true}}));
            stream << "answer {}" << std::endl;
          },
          [&](void *pointer) {
            check(pointer == reinterpret_cast<void *>(42));
            lifecycle.push_back("cancel");
          });
      check(closed_before_terminal);
      check(lifecycle ==
            std::vector<std::string>({"close", "cancel", "close"}));
      check(std::count(frames.begin(), frames.end(), "1 done completed") == 1);
      check(std::count(frames.begin(), frames.end(), "2 done cancelled") == 1);
      check(std::count(frames.begin(), frames.end(), "3 done failed") == 1);
      check(std::none_of(frames.begin(), frames.end(), [](auto &line) {
        return line.starts_with("2 answer ");
      }));
    }
    // EOF while awaiting a tool reply cancels the owned clone and wakes its
    // control reader; the worker still emits a terminal cleanup
    // acknowledgement.
    {
      foresight::ReplyBuffer commands;
      std::istream owner_input(&commands);
      std::vector<std::string> frames;
      bool cancelled = false, closed = false;
      foresight::FrameBuffer capture([&](const std::string &line) {
        frames.push_back(line);
        if (line == "ready 1")
          commands.push("generate 1 {\"prompt\":\"Disconnect\",\"tools\":{}}");
        if (line.starts_with("1 model "))
          commands.close();
        if (line == "1 done cancelled")
          check(closed);
      });
      std::ostream framed_output(&capture);
      foresight::persistent_worker(
          owner_input, framed_output,
          [&](const json &, std::istream &control, std::ostream &stream,
              const std::function<bool(void *)> &registration) {
            registration(reinterpret_cast<void *>(42));
            stream << "model {}" << std::endl;
            std::string reply;
            check(!std::getline(control, reply));
            registration(nullptr);
            closed = true;
          },
          [&](void *) { cancelled = true; });
      check(cancelled && closed);
      check(frames.back() == "1 done cancelled");
    }
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
