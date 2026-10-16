// Process ownership fixture. It deliberately performs no model inference.
#include <csignal>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 3 || std::string(argv[1]) != "--embedding")
    return 2;
  if (const char *log = std::getenv("FORESIGHT_FIXTURE_PID_LOG")) {
    std::ofstream stream(log, std::ios::app);
    stream << getpid() << '\n';
  }
  bool stubborn = std::filesystem::path(argv[2]).filename() == "stubborn";
  if (stubborn)
    signal(SIGTERM, SIG_IGN);
  using json = nlohmann::json;
  std::cout << json({{"ready", true},
                     {"dimensions", 4},
                     {"digest", "fixture"},
                     {"tokenizer_digest", "fixture"},
                     {"preprocessing", "fixture"},
                     {"backend", "onnx-bert-cpu"}})
                   .dump()
            << std::endl;
  std::string line;
  while (std::getline(std::cin, line)) {
    try {
      std::cerr << "fixture progress" << std::endl;
      auto request = json::parse(line);
      json result;
      if (request.at("op") == "encode") {
        std::vector<int> ids;
        for (unsigned char c : request.at("text").get<std::string>())
          ids.push_back(c);
        result = ids;
      } else if (request.at("op") == "decode") {
        std::string s;
        for (int c : request.at("tokens").get<std::vector<int>>())
          s += static_cast<char>(c);
        result = s;
      } else
        result = std::vector<double>{1, 0, 0, 0};
      std::cout << json({{"result", result}}).dump() << std::endl;
    } catch (const std::exception &e) {
      std::cout << json({{"error", e.what()}}).dump() << std::endl;
    }
  }
  if (stubborn)
    for (;;)
      pause();
}
