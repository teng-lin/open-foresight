#pragma once
#include <string>
#include <vector>

namespace foresight {

inline std::string quote(const std::string &s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c == '\n')
      out += "\\n";
    else if (c == '\r')
      out += "\\r";
    else if (c == '\t')
      out += "\\t";
    else if (c < 32) {
      const char *h = "0123456789abcdef";
      out += "\\u00";
      out += h[c >> 4];
      out += h[c & 15];
    } else
      out += c;
  }
  return out + '"';
}

struct OneShotLaunch {
  std::vector<std::string> arguments;
  std::string standard_input;
};

// One-shot generation feeds the prompt on stdin. The prompt text is not an
// argv element. Tool launches keep their own argv and are not built here.
inline OneShotLaunch one_shot_launch(int backend, const std::string &runtime,
                                     const std::string &model,
                                     const std::string &prompt,
                                     int max_output_tokens, int model_type,
                                     const std::string &json_schema) {
  OneShotLaunch launch;
  const auto budget = std::to_string(max_output_tokens);
  if (backend == 1) {
    launch.arguments = {runtime, "--model", model, "--max-output-tokens",
                        budget};
    if (model_type) {
      launch.arguments.push_back("--model-type");
      launch.arguments.push_back(std::to_string(model_type));
    }
    launch.standard_input = "{\"prompt\":" + quote(prompt) +
                            ",\"max_output_tokens\":" + budget + "}\n";
  } else {
    launch.arguments = {runtime,       "-m",          model,
                        "-n",          budget,        "-c",
                        "4096",        "--temp",      "0",
                        "-t",          "4",           "--no-display-prompt",
                        "--simple-io", "--no-warmup", "-no-cnv"};
    launch.standard_input = prompt;
    if (launch.standard_input.empty() || launch.standard_input.back() != '\n')
      launch.standard_input.push_back('\n');
  }
  if (!json_schema.empty()) {
    launch.arguments.push_back("--json-schema");
    launch.arguments.push_back(json_schema);
  }
  return launch;
}

} // namespace foresight
