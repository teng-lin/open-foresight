// Test-only main for the libatspi helper, used by zoom_observer_bus. It is the
// production AtspiDesktop and shared core with two test controls the production
// main does not have:
//   ZOOM_BUS_TEST_EXECUTABLE  the process name to treat as Zoom (default: one
//   no
//                             machine runs, so a real Zoom cannot interfere);
//   ZOOM_BUS_TEST_RULES=1     synthetic enabled rules (default: the shipped,
//                             empty rules).
#include "zoom_atspi_desktop.h"

#include <csignal>
#include <cstdlib>
#include <cstring>

int main(int argc, char **argv) {
  using namespace foresight::zoom;
  if (argc != 3 || std::strcmp(argv[1], "--protocol") != 0 ||
      std::strcmp(argv[2], "1") != 0)
    return 64;
  std::signal(SIGPIPE, SIG_IGN);
  g_log_set_default_handler(log_glib, nullptr);
  const char *executable = std::getenv("ZOOM_BUS_TEST_EXECUTABLE");
  AtspiDesktop desktop(
      executable && *executable ? executable : "zoom-observer-ctest-absent");
  RuleSet rules = validated_rules();
  const char *synthetic = std::getenv("ZOOM_BUS_TEST_RULES");
  if (synthetic && std::strcmp(synthetic, "1") == 0) {
    rules.zoom_versions = {"0.0.0-bus-test"};
    rules.roster = {true, {"frame", ""}, {"list", ""}, "list item", "", ""};
    rules.speaker = {true, "selected"};
  }
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
