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
inline GenerationModelConfig generation_model_config(int type) {
  switch (canonical_generation_model_type(type)) {
    case 14: case 15: return {true, "gpu", "cpu", 280};
    case 16: return {true, "gpu", "gpu", 560};
    default: return {};
  }
}
}  // namespace foresight
