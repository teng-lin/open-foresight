#include "macos_audio.h"
#include <chrono>
#include <iostream>
#include <thread>
int main(int argc, char **argv) {
  std::string action = argc > 1 ? argv[1] : "--capabilities";
  if (action == "--list-devices") std::cout << fs_macos_devices() << '\n';
  else if (action == "--capabilities") std::cout << fs_macos_capabilities() << '\n';
  else if (action == "--request-system") {
    std::cout << fs_macos_request_system(30000) << '\n';
  }
  else if (action == "--request-microphone") {
    bool granted = fs_macos_request_microphone();
    std::cout << "{\"granted\":" << (granted ? "true" : "false") << "}\n";
    return granted ? 0 : 1;
  } else if (action == "--probe" && argc >= 3 && (std::string(argv[2]) == "microphone" || std::string(argv[2]) == "system")) {
    std::atomic<bool> cancel{false};
    uint64_t bytes = 0, nonzero = 0; bool failed = false;
    std::thread deadline([&] { std::this_thread::sleep_for(std::chrono::seconds(3)); cancel = true; });
    fs_macos_capture(argc > 3 ? argv[3] : "auto", std::string(argv[2]) == "system", 48000, cancel,
      [&](const auto &pcm) { bytes += pcm.size(); for (auto b : pcm) if (b) ++nonzero; },
      [&](const auto &event) { std::cerr << event << '\n'; if (event.find("failed") != std::string::npos) failed = true; });
    deadline.join();
    std::cout << "{\"pcm_bytes\":" << bytes << ",\"nonzero_bytes\":" << nonzero << ",\"failed\":" << (failed ? "true" : "false") << "}\n";
    return failed || !bytes ? 1 : 0;
  } else { std::cerr << "Usage: foresight-audio --list-devices|--capabilities|--request-microphone|--request-system|--probe microphone|system [device-uid]\n"; return 2; }
}
