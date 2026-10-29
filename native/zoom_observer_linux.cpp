// zoom_observer_linux: reads Zoom's accessibility tree through libatspi and
// speaks the meeting speaker observer protocol on stdin/stdout
// (docs/architecture/speaker-observer-protocol.md) on the shared observer core.
// It never uses Python, never prompts, and changes desktop settings only on an
// explicit `setup` (see AtspiDesktop::enable_accessibility, the only place that
// sets anything).
#include "zoom_atspi_desktop.h"

#include <csignal>
#include <cstring>
#include <iostream>

int main(int argc, char **argv) {
  using namespace foresight::zoom;
  if (argc != 3 || std::strcmp(argv[1], "--protocol") != 0 ||
      std::strcmp(argv[2], "1") != 0) {
    std::cerr << "usage: zoom_observer_linux --protocol 1\n";
    return 64;
  }
  std::signal(SIGPIPE, SIG_IGN);
  g_log_set_default_handler(log_glib, nullptr);
  AtspiDesktop desktop("zoom");
  const RuleSet &rules = validated_rules();
  LinuxSource source(desktop, rules);
  ObserverConfig config;
  config.helper = "zoom_observer_linux";
  config.platform = "linux";
  config.parser_version = kLinuxParserVersion;
  config.parse = [&rules](const AxSnapshot &snapshot) {
    return parse_atspi_snapshot(snapshot, rules);
  };
  return run_observer(source, config);
}
