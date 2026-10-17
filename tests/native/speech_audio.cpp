#include "speech_audio.h"
#include <dirent.h>
#include <iostream>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

static bool under_tmp(const std::string &path) {
  return path == "/tmp" || path.rfind("/tmp/", 0) == 0;
}

static int count_tmp_asr() {
  int count = 0;
  DIR *directory = opendir("/tmp");
  if (!directory)
    return 0;
  while (const dirent *entry = readdir(directory)) {
    const std::string name = entry->d_name;
    if (name.rfind("foresight-asr-", 0) == 0)
      ++count;
  }
  closedir(directory);
  return count;
}

int main() {
  const std::string root =
      "/home/blackmyth/src/open-foresight-issue52/build/issue52-home";
  const std::string profile = root + "/profile";
  try {
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    REQUIRE(setenv("HOME", root.c_str(), 1) == 0);
    REQUIRE(setenv("FORESIGHT_DATA", profile.c_str(), 1) == 0);
    unsetenv("XDG_DATA_HOME");
    const int before = count_tmp_asr();
    std::string leaked;
    {
      auto audio = foresight::create_speech_audio();
      REQUIRE(!audio.path.empty());
      REQUIRE(!under_tmp(audio.path));
      REQUIRE(audio.path.find("/speech/foresight-asr-") != std::string::npos);
      struct stat info {};
      const auto speech = std::filesystem::path(audio.path).parent_path();
      REQUIRE(stat(speech.c_str(), &info) == 0);
      REQUIRE((info.st_mode & 0777) == 0700);
      REQUIRE(count_tmp_asr() == before);
      const pid_t child = fork();
      REQUIRE(child >= 0);
      if (child == 0) {
        auto abandoned = foresight::create_speech_audio();
        abandoned.fd = -1;
        abandoned.path.clear();
        _exit(0);
      }
      int status = 0;
      REQUIRE(waitpid(child, &status, 0) == child);
      REQUIRE(WIFEXITED(status) && WEXITSTATUS(status) == 0);
      REQUIRE(count_tmp_asr() == before);
      for (const auto &entry : std::filesystem::directory_iterator(speech)) {
        if (entry.path() != audio.path)
          leaked = entry.path().string();
      }
      REQUIRE(!leaked.empty());
      REQUIRE(!under_tmp(leaked));
    }
    REQUIRE(std::filesystem::exists(leaked));
    std::filesystem::remove_all(root);
    REQUIRE(count_tmp_asr() == before);
    std::cout << "speech audio stays out of /tmp\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    std::filesystem::remove_all(root);
    return 1;
  }
}
