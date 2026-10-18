#include "../inference/persistent_worker.h"
#include <atomic>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>
#include <whisper.h>
using json = nlohmann::json;

std::vector<float> read_audio(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  char header[44];
  input.read(header, 44);
  auto u16 = [&](int i) {
    return unsigned((unsigned char)header[i]) |
           unsigned((unsigned char)header[i + 1]) << 8;
  };
  auto u32 = [&](int i) { return u16(i) | (u16(i + 2) << 16); };
  if (!input || std::string(header, 4) != "RIFF" ||
      std::string(header + 8, 4) != "WAVE" ||
      std::string(header + 12, 4) != "fmt " || u32(16) != 16 || u16(20) != 1 ||
      u16(22) != 1 || u32(24) != 16000 || u16(34) != 16 ||
      std::string(header + 36, 4) != "data" ||
      u32(40) > 16000u * 60 * 60 * 2 * 2 || u32(40) % 2)
    throw std::runtime_error("Expected mono PCM16 16kHz WAV");
  std::vector<float> pcm;
  pcm.reserve(u32(40) / 2);
  for (unsigned i = 0; i < u32(40) / 2; ++i) {
    unsigned char bytes[2];
    input.read((char *)bytes, 2);
    if (!input)
      throw std::runtime_error("Truncated WAV");
    pcm.push_back(int16_t(unsigned(bytes[0]) | unsigned(bytes[1]) << 8) /
                  32768.0f);
  }
  return pcm;
}
int main(int argc, char **argv) {
  try {
    std::string model;
    bool cpu = false;
    int device = 0;
    for (int i = 1; i < argc; ++i) {
      std::string arg = argv[i];
      if (arg == "--help") {
        std::cout << "Persistent Whisper worker: --model MODEL --serve "
                     "[--backend cpu] [--device N]\n";
        return 0;
      }
      if (arg == "--model" && i + 1 < argc)
        model = argv[++i];
      else if (arg == "--backend" && i + 1 < argc)
        cpu = std::string(argv[++i]) == "cpu";
      else if (arg == "--device" && i + 1 < argc)
        device = std::stoi(argv[++i]);
    }
    if (model.empty())
      throw std::runtime_error("Missing speech model");
    auto config = whisper_context_default_params();
    config.use_gpu = !cpu;
    config.gpu_device = device;
    auto context = std::unique_ptr<whisper_context, decltype(&whisper_free)>(
        whisper_init_from_file_with_params(model.c_str(), config),
        whisper_free);
    if (!context)
      throw std::runtime_error("Cannot load speech model");
    std::atomic<bool> cancelled = false;
    foresight::persistent_worker(
        std::cin, std::cout,
        [&](const json &request, std::istream &, std::ostream &output,
            const std::function<bool(void *)> &registration) {
          auto pcm = read_audio(request.at("prompt").get<std::string>());
          cancelled = false;
          if (registration(&cancelled))
            throw std::runtime_error("Transcription cancelled");
          struct Clear {
            const std::function<bool(void *)> &registration;
            ~Clear() {
              registration(nullptr);
            }
          } clear{registration};
          auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
          params.n_threads = 4;
          params.language = "auto";
          params.no_timestamps = true;
          params.print_realtime = false;
          params.print_progress = false;
          params.print_timestamps = false;
          params.print_special = false;
          params.abort_callback = [](void *value) {
            return static_cast<std::atomic<bool> *>(value)->load();
          };
          params.abort_callback_user_data = &cancelled;
          if (whisper_full(context.get(), params, pcm.data(),
                           int(pcm.size())) != 0)
            throw std::runtime_error("Whisper transcription failed");
          std::string text;
          for (int i = 0; i < whisper_full_n_segments(context.get()); ++i)
            text += whisper_full_get_segment_text(context.get(), i);
          output << "text " << json(text).dump() << std::endl;
        },
        [](void *value) {
          static_cast<std::atomic<bool> *>(value)->store(true);
        });
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
