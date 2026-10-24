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
  auto *engine_handle = fs_engine_create(argv[0], "/dev/null");
  if (!engine_handle)
    return 10;
  auto &engine = *static_cast<Engine *>(engine_handle);
  auto *conversation_handle = fs_conversation_create(engine_handle);
  if (!conversation_handle)
    return 11;
  auto &conversation = *static_cast<Conversation *>(conversation_handle);
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
  auto *speech_handle = fs_speech_create(argv[0], "/dev/null");
  if (!speech_handle)
    return 12;
  auto &speech = *static_cast<Speech *>(speech_handle);
  speech.samples = {1, 2, 3};
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "speech", 1);
  if (fs_speech_finish(&speech, "speech") != -1 || speech.active ||
      !speech.events.empty() ||
      speech.samples != std::vector<int16_t>({1, 2, 3}))
    return 4;
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
  const auto handles = poll_registry.size();
  setenv("FORESIGHT_TEST_THREAD_FAILURE", "capture", 1);
  if (fs_capture_start_with_options("auto", 0, 16000, 0) ||
      poll_registry.size() != handles)
    return 5;
  unsetenv("FORESIGHT_TEST_THREAD_FAILURE");
  fs_speech_destroy(speech_handle);
  if (fs_conversation_destroy(conversation_handle, 1) != 0 ||
      fs_engine_destroy(engine_handle) != 0)
    return 13;
  return 0;
}
