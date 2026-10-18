#include "../../services/inference/litert.h"
#include <iostream>
int main() {
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
