#define FORESIGHT_ENABLE_TEST_HOOKS 1
#include "../../native/foresight_native.cpp"
#include <filesystem>
#include <iostream>

int main(int argc, char **argv) {
  const int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  if (argc > 1) {
    std::cout << "ok" << std::flush;
    return 0;
  }
  setenv("FORESIGHT_HELPER", argv[0], 1);
  Engine engine;
  engine.runtime = argv[0];
  engine.model = "fixture";
  Conversation conversation;
  conversation.engine = &engine;
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "generation", 1);
  if (fs_generate(&conversation, "retry", "prompt") != -1 || engine.busy ||
      conversation.active || conversation.requests.count("retry"))
    return 1;
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
  if (fs_generate(&conversation, "retry", "prompt") != 0)
    return 2;
  conversation.join();
  if (engine.busy || conversation.active || engine.state != "ready")
    return 3;
  Speech speech;
  speech.runtime = argv[0];
  speech.model = "fixture";
  speech.samples = {1, 2, 3};
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "speech", 1);
  if (fs_speech_finish(&speech, "speech") != -1 || speech.active ||
      speech.samples != std::vector<int16_t>({1, 2, 3}))
    return 4;
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
  const auto handles = poll_registry.size();
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "capture", 1);
  if (fs_capture_start_with_options("auto", 0, 16000, 0) ||
      poll_registry.size() != handles)
    return 5;
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
  return 0;
}
