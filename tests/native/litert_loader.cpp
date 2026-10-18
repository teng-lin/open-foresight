#include "../../services/inference/litert.h"
#include <iostream>
int main(int argc, char **argv) {
  if (argc == 4 && std::string(argv[1]) == "--manifest-path") {
    std::cout << foresight::runtime_manifest_path(
                     argv[3], std::string(argv[2]) == "macos")
                     .lexically_normal()
                     .string()
              << '\n';
    return 0;
  }
  try {
    LiteRt runtime;
    const auto first = runtime.symbol<int (*)()>("litert_lm_test");
    const auto second = runtime.symbol<int (*)()>("litert_lm_test");
    if (first != second || first() != 123 ||
        runtime.supports_native_stop_tokens() ||
        runtime.supports_native_stop_tokens())
      return 2;
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
