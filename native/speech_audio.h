#pragma once
#include <cstdlib>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace foresight {

// Mirrors packages/foresight_core/lib/src/profile_paths.dart data resolution.
inline std::filesystem::path profile_data_directory() {
  const char *home = std::getenv("HOME");
  if (!home || !*home)
    throw std::runtime_error("HOME must identify the user profile");
  if (const char *data = std::getenv("FORESIGHT_DATA"); data && *data)
    return data;
#if defined(__APPLE__)
  return std::filesystem::path(home) / "Library" / "Application Support" /
         "Open Foresight";
#else
  if (const char *xdg = std::getenv("XDG_DATA_HOME"); xdg && *xdg)
    return std::filesystem::path(xdg) / "open-foresight";
  return std::filesystem::path(home) / ".local" / "share" / "open-foresight";
#endif
}

// Unlinks the staged WAV unless the process exits without running destructors.
struct SpeechAudio {
  std::string path;
  int fd = -1;
  SpeechAudio() = default;
  SpeechAudio(const SpeechAudio &) = delete;
  SpeechAudio &operator=(const SpeechAudio &) = delete;
  SpeechAudio(SpeechAudio &&other) noexcept
      : path(std::move(other.path)), fd(other.fd) {
    other.fd = -1;
    other.path.clear();
  }
  SpeechAudio &operator=(SpeechAudio &&other) noexcept {
    if (this != &other) {
      if (fd >= 0)
        close(fd);
      if (!path.empty())
        unlink(path.c_str());
      path = std::move(other.path);
      fd = other.fd;
      other.fd = -1;
      other.path.clear();
    }
    return *this;
  }
  ~SpeechAudio() {
    if (fd >= 0)
      close(fd);
    if (!path.empty())
      unlink(path.c_str());
  }
};

inline SpeechAudio create_speech_audio() {
  const auto directory = profile_data_directory() / "speech";
  std::filesystem::create_directories(directory);
  if (chmod(directory.c_str(), 0700) != 0)
    throw std::runtime_error("Cannot protect speech audio directory");
  const std::string pattern = (directory / "foresight-asr-XXXXXX").string();
  std::vector<char> tmpl(pattern.begin(), pattern.end());
  tmpl.push_back('\0');
  const int fd = mkstemp(tmpl.data());
  if (fd < 0)
    throw std::runtime_error("Cannot create speech audio file");
  SpeechAudio audio;
  audio.fd = fd;
  audio.path.assign(tmpl.data());
  return audio;
}

} // namespace foresight
