// Drives the built zoom_observer_linux helper over real pipes. The helper runs
// with a scrubbed environment (no session bus, no display, empty runtime
// directory), so it can neither reach nor change the developer's desktop; the
// states asserted here are the ones the helper must report when the desktop
// accessibility stack is absent. Bus-level behavior is in zoom_observer_bus.
#include "zoom_helper_harness.h"

#include <fstream>
#include <sstream>

using namespace zoom_harness;

namespace {

const char *helper_path = nullptr;

Helper launch(std::vector<std::string> environment = {}) {
  return Helper(helper_path, {"--protocol", "1"}, std::move(environment));
}

void test_without_desktop() {
  Helper h = launch(); // empty environment: no bus, no display, no HOME
  const json hello = h.expect("hello");
  check(hello["v"] == 1 && hello["seq"] == 0 && hello["platform"] == "linux" &&
            hello["helper"] == "zoom_observer_linux" &&
            hello["parser_version"] == "linux-0",
        "hello identifies the Linux helper");

  h.send({{"type", "capabilities"}, {"id", "c1"}});
  const json caps = h.expect("capabilities");
  check(caps["id"] == "c1" && caps["state"] == "unavailable" &&
            caps["reason"] == "no_session_bus" &&
            caps["zoom_version"].is_null() && caps["locale"].is_null(),
        "no session bus is a capability result, not a failure: " + caps.dump());

  h.send({{"type", "setup"}, {"id", "s1"}});
  const json setup = h.expect("capabilities");
  check(setup["id"] == "s1" && setup["state"] == "unavailable" &&
            setup["reason"] == "no_session_bus",
        "setup without a session bus changes nothing and reports capabilities");

  h.send({{"type", "clock"}, {"id", 7}});
  const json clock = h.expect("clock");
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  const std::int64_t now_ms = now.tv_sec * 1000 + now.tv_nsec / 1000000;
  check(clock["id"] == 7 &&
            clock["monotonic_ms"].get<std::int64_t>() <= now_ms &&
            now_ms - clock["monotonic_ms"].get<std::int64_t>() < 5000 &&
            clock["uptime_ms"].is_number_integer(),
        "clock is CLOCK_MONOTONIC milliseconds shared with this process");

  h.send({{"type", "start"},
          {"id", 8},
          {"session", "ctest"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  const json started = h.expect("started");
  check(started["id"] == 8 && started["session"] == "ctest" &&
            started["target"]["pid"].is_null() &&
            started["target"]["zoom_version"].is_null(),
        "start is acknowledged without a target");
  const json unavailable = h.expect("unavailable");
  check(unavailable["session"] == "ctest" &&
            unavailable["reason"] == "no_session_bus" &&
            unavailable["since_ms"].is_number_integer(),
        "start without Zoom is unavailable, not an observation: " +
            unavailable.dump());
  // Let the helper's own clock advance over several poll periods while
  // answering clock requests: an unchanged outage must not produce another
  // `unavailable`, so every reply in between is a `clock` frame.
  const std::int64_t begin = h.expect_clock(100)["monotonic_ms"];
  for (;;) {
    const json clock = h.expect_clock(101);
    if (clock["monotonic_ms"].get<std::int64_t>() - begin >= 450)
      break;
  }
  h.send({{"type", "stop"}, {"id", 9}});
  const json stopped = h.expect("stopped");
  check(stopped["id"] == 9 && stopped["session"] == "ctest",
        "stop echoes id and session");
  check(h.wait_exit() == 0, "stop exits 0");
  check(h.drain_stderr().empty(),
        "an uneventful session writes nothing to stderr");
}

void test_unreachable_bus() {
  Helper h = launch({"DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/"
                     "zoom-observer-ctest-bus"});
  h.expect("hello");
  h.send({{"type", "capabilities"}, {"id", 1}});
  const json caps = h.expect("capabilities");
  check(caps["state"] == "unavailable" &&
            caps["reason"] == "session_bus_unreachable",
        "an unreachable session bus is reported: " + caps.dump());
  h.send({{"type", "stop"}, {"id", 2}});
  h.expect("stopped");
  check(h.wait_exit() == 0, "exit 0");
}

void test_stdin_close() {
  Helper h = launch();
  h.expect("hello");
  h.send({{"type", "start"},
          {"id", 1},
          {"session", "eof"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  h.expect("started");
  h.expect("unavailable");
  h.close_stdin();
  check(h.wait_exit(3000) == 0, "helper exits 0 when stdin closes");
}

void expect_protocol_error(const char *label, const std::string &raw,
                           const char *code) {
  Helper h = launch();
  h.expect("hello");
  h.write_raw(raw);
  const json error = h.expect("error");
  check(error["code"] == code, std::string(label) + ": " + error.dump());
  check(h.wait_exit(3000) == 2, std::string(label) + ": exits 2");
  check(!h.frame(100).has_value(),
        std::string(label) + ": nothing after the error");
}

void test_protocol_errors() {
  expect_protocol_error("malformed", "{not json\n", "malformed_json");
  expect_protocol_error("seq gap",
                        "{\"v\":1,\"type\":\"clock\",\"seq\":3,\"id\":1}\n",
                        "protocol_seq");
  expect_protocol_error("unknown type",
                        "{\"v\":1,\"type\":\"dance\",\"seq\":0,\"id\":1}\n",
                        "protocol_type");
  expect_protocol_error("line bound", std::string(262145, 'x'),
                        "line_too_long");
  expect_protocol_error("line bound with newline",
                        std::string(262145, 'x') + "\n", "line_too_long");
  {
    // A line exactly at the bound is accepted.
    Helper h = launch();
    h.expect("hello");
    std::string line =
        "{\"v\":1,\"type\":\"clock\",\"seq\":0,\"id\":1,\"pad\":\"\"}";
    line.insert(line.size() - 2, std::string(262144 - line.size(), 'p'));
    h.write_raw(line + "\n");
    h.expect("clock");
  }
  {
    // A non-fatal bad argument keeps the session alive.
    Helper h = launch();
    h.expect("hello");
    h.send({{"type", "start"},
            {"id", 1},
            {"session", "s"},
            {"poll_ms", 1},
            {"deadline_ms", 1000}});
    check(h.expect("error")["code"] == "invalid_request",
          "invalid start is rejected");
    h.send({{"type", "clock"}, {"id", 2}});
    h.expect("clock");
  }
}

void test_arguments() {
  for (const std::vector<std::string> &arguments : {std::vector<std::string>{},
                                                    {"--protocol"},
                                                    {"--protocol", "2"},
                                                    {"--protocol", "1", "x"},
                                                    {"--help"}}) {
    Helper h(helper_path, arguments, {});
    check(h.wait_exit(3000) == 64, "bad arguments exit 64");
    check(!h.frame(100).has_value(), "bad arguments write no protocol frames");
    check(h.drain_stderr().find("usage") != std::string::npos,
          "usage goes to stderr");
  }
}

// Stdout hygiene: every byte on stdout is a newline-terminated JSON object.
void test_stdout_hygiene() {
  Helper h = launch();
  h.expect("hello");
  h.send({{"type", "capabilities"}, {"id", 1}});
  h.expect("capabilities");
  h.send({{"type", "stop"}, {"id", 2}});
  h.expect("stopped");
  check(h.wait_exit() == 0, "exit 0");
  check(!h.frame(100).has_value() && h.stdout_remainder().empty(),
        "nothing but newline-terminated JSON frames reach stdout");
}

void test_sigterm() {
  Helper h = launch();
  h.expect("hello");
  h.send({{"type", "start"},
          {"id", 1},
          {"session", "term"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  h.expect("started");
  h.signal_process(SIGTERM);
  const int status = h.wait_exit_status(3000);
  check(status != -1 && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM,
        "SIGTERM ends the helper promptly");
}

void test_stdout_closed_exits_3() {
  Helper h = launch();
  h.expect("hello");
  h.send({{"type", "start"},
          {"id", 1},
          {"session", "pipe"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  h.expect("started");
  h.close_output(); // the reader of the helper's frames goes away
  h.send({{"type", "clock"}, {"id", 2}}); // the reply can no longer be written
  check(h.wait_exit(3000) == 3, "a broken stdout exits 3");
  check(h.drain_stderr().find("stdout_closed") != std::string::npos,
        "a stable token explains the exit");
}

// The helper must stay passive: nothing but the explicit setup sets a property
// and nothing activates a service or acts on Zoom.
void test_source_is_passive(const char *source_path) {
  std::ifstream input(source_path);
  std::stringstream buffer;
  buffer << input.rdbuf();
  const std::string source = buffer.str();
  check(!source.empty(), "the helper source is readable");
  const auto count = [&](const std::string &needle) {
    size_t n = 0;
    for (size_t at = source.find(needle); at != std::string::npos;
         at = source.find(needle, at + 1))
      ++n;
    return n;
  };
  for (const char *forbidden :
       {"atspi_action_", "atspi_component_", "atspi_editable_text",
        "atspi_text_set", "atspi_value_set", "atspi_selection_",
        "atspi_generate_", "atspi_device", "g_settings_", "popen(", "system(",
        "execv", "fork("})
    check(count(forbidden) == 0,
          std::string("the helper never uses ") + forbidden);
  check(count("\"Set\"") == 1,
        "exactly one D-Bus Set call exists (the explicit setup)");
  check(count("G_DBUS_CALL_FLAGS_NONE") == 0,
        "no D-Bus call may activate a service, setup included");
  check(count("G_DBUS_CALL_FLAGS_NO_AUTO_START") >= 4,
        "every D-Bus call forbids service activation");
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 3) {
    std::cerr << "usage: zoom_observer_protocol_test HELPER HELPER_SOURCE\n";
    return 2;
  }
  helper_path = argv[1];
  test_without_desktop();
  test_unreachable_bus();
  test_stdin_close();
  test_protocol_errors();
  test_arguments();
  test_stdout_hygiene();
  test_sigterm();
  test_stdout_closed_exits_3();
  test_source_is_passive(argv[2]);
  std::cout << "zoom_observer_protocol: " << checks << " checks, " << failures
            << " failures\n";
  return failures == 0 ? 0 : 1;
}
