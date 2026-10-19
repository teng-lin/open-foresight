#pragma once
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
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

// Schema contents are request data. Only an owner-readable random filename is
// exposed to the child argv, and the launch owns it until the child is reaped.
class OneShotSchemaFile {
  std::vector<char> filename;

public:
  explicit OneShotSchemaFile(const std::string &schema) {
    const auto pattern =
        (std::filesystem::temp_directory_path() / "foresight-schema-XXXXXX")
            .string();
    filename.assign(pattern.begin(), pattern.end());
    filename.push_back('\0');
    const int fd = mkstemp(filename.data());
    if (fd < 0)
      throw std::runtime_error("Cannot create private schema file");
    try {
      if (fchmod(fd, 0600) || fcntl(fd, F_SETFD, FD_CLOEXEC))
        throw std::runtime_error("Cannot protect private schema file");
      size_t offset = 0;
      while (offset < schema.size()) {
        const auto count =
            write(fd, schema.data() + offset, schema.size() - offset);
        if (count < 0 && errno == EINTR)
          continue;
        if (count <= 0)
          throw std::runtime_error("Cannot write private schema file");
        offset += static_cast<size_t>(count);
      }
    } catch (...) {
      close(fd);
      unlink(filename.data());
      throw;
    }
    if (close(fd)) {
      unlink(filename.data());
      throw std::runtime_error("Cannot finish private schema file");
    }
  }
  OneShotSchemaFile(const OneShotSchemaFile &) = delete;
  OneShotSchemaFile &operator=(const OneShotSchemaFile &) = delete;
  ~OneShotSchemaFile() {
    unlink(filename.data());
  }
  const char *path() const {
    return filename.data();
  }
};

struct OneShotLaunch {
  std::vector<std::string> arguments;
  std::string standard_input;
  std::unique_ptr<OneShotSchemaFile> schema_file;
};

// One-shot generation feeds the prompt on stdin. The prompt text is not an
// argv element. LiteRT schema and tool payloads use the same stdin envelope.
inline OneShotLaunch one_shot_launch(int backend, const std::string &runtime,
                                     const std::string &model,
                                     const std::string &prompt,
                                     int max_output_tokens, int model_type,
                                     const std::string &json_schema,
                                     bool tools = false) {
  if (backend != 1 && (tools || (backend != 0 && !json_schema.empty())))
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
    if (!json_schema.empty()) {
      launch.schema_file = std::make_unique<OneShotSchemaFile>(json_schema);
      launch.arguments.push_back("--json-schema-file");
      launch.arguments.push_back(launch.schema_file->path());
    }
  }
  return launch;
}

} // namespace foresight
