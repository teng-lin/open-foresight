#pragma once
#include <stdexcept>
#include <string>
#include <vector>

namespace foresight {

inline std::string quote(const std::string &s) {
  std::string out = "\"";
  for (size_t i = 0; i < s.size();) {
    const auto c = static_cast<unsigned char>(s[i]);
    if (c >= 0x80) {
      const size_t width = c >= 0xc2 && c <= 0xdf   ? 2
                           : c >= 0xe0 && c <= 0xef ? 3
                           : c >= 0xf0 && c <= 0xf4 ? 4
                                                    : 0;
      bool valid = width && i + width <= s.size();
      for (size_t j = 1; valid && j < width; ++j)
        valid = (static_cast<unsigned char>(s[i + j]) & 0xc0) == 0x80;
      if (valid && width >= 3) {
        const auto second = static_cast<unsigned char>(s[i + 1]);
        valid = !(c == 0xe0 && second < 0xa0) &&
                !(c == 0xed && second >= 0xa0) &&
                !(c == 0xf0 && second < 0x90) && !(c == 0xf4 && second >= 0x90);
      }
      if (valid) {
        out.append(s, i, width);
        i += width;
      } else {
        out += "\\ufffd";
        ++i;
      }
      continue;
    }
    ++i;
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

// Persistent protocol payloads occupy one physical line. JSON whitespace
// containing line separators must be compacted by the caller before framing.
inline bool single_line_json(const std::string &value) {
  return value.find_first_of("\r\n") == std::string::npos;
}

struct OneShotLaunch {
  std::vector<std::string> arguments;
  std::string standard_input;
};

// One-shot generation feeds the prompt on stdin. The prompt text is not an
// argv element. LiteRT schema and tool payloads use the same stdin envelope.
inline OneShotLaunch one_shot_launch(int backend, const std::string &runtime,
                                     const std::string &model,
                                     const std::string &prompt,
                                     int max_output_tokens, int model_type,
                                     const std::string &json_schema,
                                     bool tools = false) {
  if (backend != 1 && (!json_schema.empty() || tools))
    throw std::invalid_argument(
        "Runtime does not support structured stdin requests");
  OneShotLaunch launch;
  const auto budget = std::to_string(max_output_tokens);
  if (backend == 1) {
    launch.arguments = {runtime, "--model", model, "--max-output-tokens",
                        budget};
    if (model_type) {
      launch.arguments.push_back("--model-type");
      launch.arguments.push_back(std::to_string(model_type));
    }
    launch.standard_input =
        "{\"prompt\":" + quote(prompt) + ",\"max_output_tokens\":" + budget +
        (json_schema.empty()
             ? ""
             : (tools ? ",\"tools\":" : ",\"schema\":") + json_schema) +
        "}\n";
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
  return launch;
}

} // namespace foresight
