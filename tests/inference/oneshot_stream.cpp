#include "oneshot_stream.h"
#include <iostream>
#include <stdexcept>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

int main() {
  try {
    REQUIRE(foresight::stream_chunk_completes(false, true));
    REQUIRE(foresight::stream_chunk_completes(true, false));
    REQUIRE(!foresight::stream_chunk_completes(false, false));

    foresight::OneShotStreamState state;
    state.decode = [](const char *raw) { return std::string(raw); };
    state.on_chunk(foresight::OneShotChunk{"partial", nullptr, false}, {});
    REQUIRE(!state.done);
    REQUIRE(state.text == "partial");
    REQUIRE(state.error.empty());

    state.on_chunk(foresight::OneShotChunk{nullptr, "generation failed", false},
                   {});
    REQUIRE(state.done);
    REQUIRE(state.error == "generation failed");
    REQUIRE(state.text == "partial");

    state.on_chunk(foresight::OneShotChunk{"late", nullptr, true}, {});
    REQUIRE(state.text == "partial");
    REQUIRE(state.done);
    std::cout << "one-shot error chunk completes the stream\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
