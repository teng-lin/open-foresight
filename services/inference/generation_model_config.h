#pragma once

namespace foresight {
// Public distribution enum aliases recovered from ModelConfigureManager.
inline int canonical_generation_model_type(int type) {
  switch (type) {
    case 8: case 10: return 15;
    case 9: return 14;
    case 12: return 16;
    default: return type;
  }
}
struct GenerationModelConfig {
  bool vision = false;
  const char *vision_backend = nullptr;
  const char *audio_backend = "cpu";
  int visual_tokens = 0;
};
inline GenerationModelConfig generation_model_config(int type, bool cpu_only = false) {
  GenerationModelConfig config;
  switch (canonical_generation_model_type(type)) {
    case 14: case 15: config = {true, "gpu", "cpu", 280}; break;
    case 16: config = {true, "gpu", "gpu", 560}; break;
    default: break;
  }
  // LiteRT initializes modality executors lazily at conversation creation.
  // A CPU text engine must not retain a hidden GPU dependency for these.
  if (cpu_only) {
    if (config.vision) config.vision_backend = "cpu";
    config.audio_backend = "cpu";
  }
  return config;
}
}  // namespace foresight
