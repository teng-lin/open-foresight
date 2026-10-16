// Opt-in real-runtime probe. Supply a local model and an already prepared raw
// prompt. It does not download a model or establish dedicated-model parity.
#include "../../services/inference/raw_query_detector.h"
#include "../../services/inference/fd_stream.h"
#include <iostream>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3 && argc != 4) return 2;
  const int fd = dup(STDOUT_FILENO);
  if (fd < 0 || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 1;
  FdStreamBuffer buffer(fd);
  std::ostream protocol(&buffer);
  try {
    const int context = argc == 4 ? std::stoi(argv[3]) : 512;
    if (context < 1 || context > 4096) return 2;
    LiteRt lm;
    auto settings = handle(LM(engine_settings_create)(argv[1], "cpu", nullptr, "cpu"),
                           LM(engine_settings_delete));
    LM(engine_settings_set_max_num_tokens)(settings.get(), context);
    LM(engine_settings_set_num_threads)(settings.get(), 4);
    auto engine = handle(LM(engine_create)(settings.get()), LM(engine_delete));
    protocol << raw_query_detector(lm, engine.get(), argv[2]) << std::flush;
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
