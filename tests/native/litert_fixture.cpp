#include <cstdio>
#include <cstdlib>
__attribute__((constructor)) static void loaded() {
  if (const char *marker = std::getenv("FORESIGHT_LITERT_LOADED_MARKER")) {
    if (auto *file = std::fopen(marker, "w"))
      std::fclose(file);
  }
}
extern "C" int litert_lm_test() {
  return 123;
}
