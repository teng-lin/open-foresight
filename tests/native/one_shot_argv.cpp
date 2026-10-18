#include "one_shot_launch.h"
#include <iostream>
#include <stdexcept>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

static void require_prompt_absent(const foresight::OneShotLaunch &launch,
                                  const std::string &prompt) {
  for (const auto &argument : launch.arguments) {
    REQUIRE(argument != "--prompt");
    REQUIRE(argument != "-p");
    REQUIRE(argument.find(prompt) == std::string::npos);
  }
  REQUIRE(launch.standard_input.find(prompt) != std::string::npos);
}

int main() {
  try {
    REQUIRE(foresight::quote("中文🧪") == "\"中文🧪\"");
    REQUIRE(foresight::quote(std::string("\xff", 1)) == "\"\\ufffd\"");
    REQUIRE(foresight::quote(std::string("\xed\xa0\x80", 3)) ==
            "\"\\ufffd\\ufffd\\ufffd\"");
    REQUIRE(foresight::quote(std::string("\xf0\x9f", 2)) ==
            "\"\\ufffd\\ufffd\"");
    const std::string prompt = "unique-one-shot-prompt-52";
    const auto llama = foresight::one_shot_launch(0, "llama-cli", "model.gguf",
                                                  prompt, 32, 0, "");
    require_prompt_absent(llama, prompt);
    REQUIRE(llama.standard_input == prompt + "\n");

    const std::string schema = "{\"type\":\"object\"}";
    const auto litert = foresight::one_shot_launch(
        1, "litert-runner", "model.litertlm", prompt, 32, 3, schema);
    require_prompt_absent(litert, prompt);
    REQUIRE(litert.standard_input.find("\"prompt\":") != std::string::npos);
    bool saw_schema = false;
    bool saw_type = false;
    for (size_t i = 0; i < litert.arguments.size(); ++i) {
      if (litert.arguments[i] == "--json-schema" &&
          i + 1 < litert.arguments.size())
        saw_schema = litert.arguments[i + 1] == schema;
      if (litert.arguments[i] == "--model-type" &&
          i + 1 < litert.arguments.size())
        saw_type = litert.arguments[i + 1] == "3";
    }
    REQUIRE(saw_schema);
    REQUIRE(saw_type);
    std::cout << "one-shot prompt stays off argv\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
