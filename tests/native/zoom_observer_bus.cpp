// Drives the built helper against a private `dbus-daemon --session` with a fake
// org.a11y.Bus, so every accessibility-bus state is exercised for real without
// touching the developer's desktop: no accessibility bus, a disabled one, an
// unreadable or mistyped status, an unreachable registry, a working one, and a
// registry that disappears and returns. Counts every property write the helper
// makes: capabilities and start must make none, setup exactly one.
//
// The helper under test is built to look for a process named
// `zoom-observer-ctest-absent`, so a Zoom running on the developer's machine
// cannot change the outcome. Exit status 77 (skipped) when dbus-daemon is
// absent.
#include "zoom_atspi_desktop.h"
#include "zoom_helper_harness.h"

#include <atomic>
#include <cstdlib>
#include <fstream>
#include <future>
#include <gio/gio.h>
#include <sys/stat.h>
#include <thread>

using namespace zoom_harness;
using foresight::zoom::kExitRegistryLost;

namespace {

const char *helper_path = nullptr;

struct Daemon {
  pid_t pid = -1;
  std::string address, directory;
  ~Daemon() {
    if (pid > 0) {
      kill(pid, SIGTERM);
      waitpid(pid, nullptr, 0);
    }
    if (!directory.empty()) {
      unlink((directory + "/bus").c_str());
      unlink((directory + "/bus.conf").c_str());
      rmdir(directory.c_str());
    }
  }
};

// False when dbus-daemon cannot be started (the test is skipped).
bool start_daemon(Daemon &daemon) {
  const char *root = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
  if (!root || !*root)
    root = std::getenv("TMPDIR");
  std::string pattern =
      std::string(root && *root ? root : "/var/tmp") + "/zoomobs.XXXXXX";
  if (!mkdtemp(pattern.data()))
    return false;
  daemon.directory = pattern;
  chmod(pattern.c_str(), 0700);
  const std::string config = daemon.directory + "/bus.conf";
  {
    std::ofstream out(config);
    out << "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-Bus Bus "
           "Configuration 1.0//EN\" "
           "\"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">\n"
           "<busconfig><type>session</type><listen>unix:path="
        << daemon.directory
        << "/bus</listen><auth>EXTERNAL</auth><policy context=\"default\">"
           "<allow send_destination=\"*\" eavesdrop=\"true\"/><allow "
           "eavesdrop=\"true\"/>"
           "<allow own=\"*\"/></policy></busconfig>\n";
  }
  int address_pipe[2];
  if (pipe(address_pipe) != 0)
    return false;
  daemon.pid = fork();
  if (daemon.pid == 0) {
    close(address_pipe[0]);
    const std::string print =
        "--print-address=" + std::to_string(address_pipe[1]);
    const std::string file = "--config-file=" + config;
    execlp("dbus-daemon", "dbus-daemon", file.c_str(), "--nofork",
           print.c_str(), static_cast<char *>(nullptr));
    _exit(127);
  }
  close(address_pipe[1]);
  char buffer[512];
  pollfd fd{address_pipe[0], POLLIN, 0};
  ssize_t n = 0;
  if (poll(&fd, 1, 5000) > 0)
    n = read(address_pipe[0], buffer, sizeof(buffer) - 1);
  close(address_pipe[0]);
  if (n <= 0) {
    waitpid(daemon.pid, nullptr, WNOHANG);
    kill(daemon.pid, SIGKILL);
    waitpid(daemon.pid, nullptr, 0);
    daemon.pid = -1;
    return false;
  }
  daemon.address.assign(buffer, static_cast<size_t>(n));
  while (!daemon.address.empty() &&
         (daemon.address.back() == '\n' || daemon.address.back() == ' '))
    daemon.address.pop_back();
  return !daemon.address.empty();
}

// A fake org.a11y.Bus on its own thread and main context.
class FakeA11y {
public:
  enum class Status { Boolean, Unreadable, NotBoolean };
  FakeA11y(const std::string &bus_address, Status status, bool enabled,
           std::string reply)
      : status_(status), enabled_(enabled), reply_(std::move(reply)) {
    std::promise<void> ready;
    thread_ =
        std::thread([this, &bus_address, &ready] { run(bus_address, ready); });
    ready.get_future().wait();
  }
  ~FakeA11y() {
    stop();
  }
  // Drops the name and the connection (the registry going away).
  void stop() {
    if (!thread_.joinable())
      return;
    g_main_loop_quit(loop_);
    thread_.join();
  }
  std::atomic<int> sets{0}, gets{0}, addresses{0};
  bool enabled() const {
    return enabled_;
  }

private:
  static void method_call(GDBusConnection *, const gchar *, const gchar *,
                          const gchar *, const gchar *, GVariant *,
                          GDBusMethodInvocation *invocation, gpointer data) {
    auto *self = static_cast<FakeA11y *>(data);
    ++self->addresses;
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(s)", self->reply_.c_str()));
  }
  static GVariant *get_property(GDBusConnection *, const gchar *, const gchar *,
                                const gchar *, const gchar *, GError **error,
                                gpointer data) {
    auto *self = static_cast<FakeA11y *>(data);
    ++self->gets;
    switch (self->status_) {
    case Status::Boolean:
      return g_variant_new_boolean(self->enabled_);
    case Status::NotBoolean:
      return g_variant_new_string("yes");
    case Status::Unreadable:
      g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "unreadable");
      return nullptr;
    }
    return nullptr;
  }
  static gboolean set_property(GDBusConnection *, const gchar *, const gchar *,
                               const gchar *, const gchar *, GVariant *value,
                               GError **, gpointer data) {
    auto *self = static_cast<FakeA11y *>(data);
    ++self->sets;
    self->enabled_ = g_variant_get_boolean(value);
    return TRUE;
  }

  void run(const std::string &bus_address, std::promise<void> &ready) {
    GMainContext *context = g_main_context_new();
    g_main_context_push_thread_default(context);
    loop_ = g_main_loop_new(context, FALSE);
    GError *error = nullptr;
    GDBusConnection *connection = g_dbus_connection_new_for_address_sync(
        bus_address.c_str(),
        static_cast<GDBusConnectionFlags>(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, &error);
    g_clear_error(&error);
    const char *type = status_ == Status::NotBoolean ? "s" : "b";
    const std::string xml =
        std::string(
            "<node><interface name='org.a11y.Bus'><method name='GetAddress'>"
            "<arg type='s' direction='out'/></method></interface>"
            "<interface name='org.a11y.Status'><property name='IsEnabled' "
            "type='") +
        type + "' access='readwrite'/></interface></node>";
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(xml.c_str(), nullptr);
    GDBusInterfaceVTable bus_vtable{method_call, nullptr, nullptr, {}};
    GDBusInterfaceVTable status_vtable{nullptr, get_property, set_property, {}};
    g_dbus_connection_register_object(connection, "/org/a11y/bus",
                                      info->interfaces[0], &bus_vtable, this,
                                      nullptr, nullptr);
    g_dbus_connection_register_object(connection, "/org/a11y/bus",
                                      info->interfaces[1], &status_vtable, this,
                                      nullptr, nullptr);
    struct Own {
      std::promise<void> *ready;
    } own{&ready};
    const guint owner = g_bus_own_name_on_connection(
        connection, "org.a11y.Bus", G_BUS_NAME_OWNER_FLAGS_NONE,
        [](GDBusConnection *, const gchar *, gpointer data) {
          static_cast<Own *>(data)->ready->set_value();
        },
        nullptr, &own, nullptr);
    g_main_loop_run(loop_);
    g_bus_unown_name(owner);
    g_dbus_node_info_unref(info);
    g_dbus_connection_close_sync(connection, nullptr, nullptr);
    g_object_unref(connection);
    g_main_loop_unref(loop_);
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
  }

  Status status_;
  std::atomic<bool> enabled_;
  std::string reply_;
  GMainLoop *loop_ = nullptr;
  std::thread thread_;
};

// A fake accessibility registry (org.a11y.atspi.Registry) whose desktop has no
// applications. It is enough for libatspi to read the desktop's child count,
// the first real call the helper makes after initializing.
class FakeRegistry {
public:
  explicit FakeRegistry(const std::string &bus_address) {
    std::promise<void> ready;
    thread_ =
        std::thread([this, &bus_address, &ready] { run(bus_address, ready); });
    ready.get_future().wait();
  }
  ~FakeRegistry() {
    stop();
  }
  void stop() {
    if (!thread_.joinable())
      return;
    g_main_loop_quit(loop_);
    thread_.join();
  }
  std::atomic<int> queries{0};

private:
  static void method_call(GDBusConnection *, const gchar *, const gchar *,
                          const gchar *, const gchar *method, GVariant *,
                          GDBusMethodInvocation *invocation, gpointer data) {
    auto *self = static_cast<FakeRegistry *>(data);
    ++self->queries;
    (void)method;
    g_dbus_method_invocation_return_dbus_error(
        invocation, "org.freedesktop.DBus.Error.Failed", "no applications");
  }
  static GVariant *get_property(GDBusConnection *, const gchar *, const gchar *,
                                const gchar *, const gchar *property, GError **,
                                gpointer data) {
    auto *self = static_cast<FakeRegistry *>(data);
    ++self->queries;
    const std::string name = property;
    if (name == "ChildCount")
      return g_variant_new_int32(0);
    return g_variant_new_string("");
  }

  void run(const std::string &bus_address, std::promise<void> &ready) {
    GMainContext *context = g_main_context_new();
    g_main_context_push_thread_default(context);
    loop_ = g_main_loop_new(context, FALSE);
    GError *error = nullptr;
    GDBusConnection *connection = g_dbus_connection_new_for_address_sync(
        bus_address.c_str(),
        static_cast<GDBusConnectionFlags>(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, &error);
    g_clear_error(&error);
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(
        "<node><interface name='org.a11y.atspi.Accessible'>"
        "<property name='Name' type='s' access='read'/>"
        "<property name='Description' type='s' access='read'/>"
        "<property name='ChildCount' type='i' access='read'/>"
        "<method name='GetChildAtIndex'><arg type='i' direction='in'/>"
        "<arg type='(so)' direction='out'/></method>"
        "</interface></node>",
        nullptr);
    GDBusInterfaceVTable vtable{method_call, get_property, nullptr, {}};
    g_dbus_connection_register_object(
        connection, "/org/a11y/atspi/accessible/root", info->interfaces[0],
        &vtable, this, nullptr, nullptr);
    struct Own {
      std::promise<void> *ready;
    } own{&ready};
    const guint owner = g_bus_own_name_on_connection(
        connection, "org.a11y.atspi.Registry", G_BUS_NAME_OWNER_FLAGS_NONE,
        [](GDBusConnection *, const gchar *, gpointer data) {
          static_cast<Own *>(data)->ready->set_value();
        },
        nullptr, &own, nullptr);
    g_main_loop_run(loop_);
    g_bus_unown_name(owner);
    g_dbus_node_info_unref(info);
    g_dbus_connection_close_sync(connection, nullptr, nullptr);
    g_object_unref(connection);
    g_main_loop_unref(loop_);
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
  }

  GMainLoop *loop_ = nullptr;
  std::thread thread_;
};

json capabilities(Helper &h, int id) {
  h.send({{"type", "capabilities"}, {"id", id}});
  return h.expect("capabilities");
}

void expect_state(const json &caps, const char *state, const char *reason,
                  const std::string &what) {
  check(caps["state"] == state && caps["reason"] == reason,
        what + " (got " + caps["state"].dump() + "/" + caps["reason"].dump() +
            ")");
}

Helper launch(const Daemon &daemon, std::vector<std::string> extra = {}) {
  std::vector<std::string> environment = {"DBUS_SESSION_BUS_ADDRESS=" +
                                          daemon.address};
  environment.insert(environment.end(), extra.begin(), extra.end());
  return Helper(helper_path, {"--protocol", "1"}, environment);
}

// This test binary is "Zoom" for the scenarios that need one: the helper scans
// /proc for it, and reads its version from a version.txt beside it.
struct SelfAsZoom {
  std::string executable, version_file;
  std::vector<std::string> env_with_rules, env_without_rules;
  SelfAsZoom() {
    char path[4096];
    const ssize_t length = readlink("/proc/self/exe", path, sizeof(path) - 1);
    const std::string self(path, length > 0 ? static_cast<size_t>(length) : 0);
    const auto slash = self.rfind('/');
    executable = self.substr(slash + 1);
    version_file = self.substr(0, slash) + "/version.txt";
    std::ofstream(version_file) << "0.0.0-bus-test\n";
    env_without_rules = {"ZOOM_BUS_TEST_EXECUTABLE=" + executable};
    env_with_rules = {"ZOOM_BUS_TEST_EXECUTABLE=" + executable,
                      "ZOOM_BUS_TEST_RULES=1"};
  }
  ~SelfAsZoom() {
    unlink(version_file.c_str());
  }
};

// Does anything own org.a11y.Bus on the private bus right now?
bool a11y_owned(const Daemon &daemon) {
  GError *error = nullptr;
  GDBusConnection *connection = g_dbus_connection_new_for_address_sync(
      daemon.address.c_str(),
      static_cast<GDBusConnectionFlags>(
          G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, nullptr, &error);
  g_clear_error(&error);
  if (!connection)
    return false;
  GVariant *reply = g_dbus_connection_call_sync(
      connection, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner",
      g_variant_new("(s)", "org.a11y.Bus"), G_VARIANT_TYPE("(b)"),
      G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, nullptr, nullptr);
  gboolean owned = FALSE;
  if (reply) {
    g_variant_get(reply, "(b)", &owned);
    g_variant_unref(reply);
  }
  g_object_unref(connection);
  return owned;
}

void no_accessibility_bus(const Daemon &daemon) {
  Helper h = launch(daemon);
  h.expect("hello");
  expect_state(capabilities(h, 1), "needs_setup", "atspi_bus_absent",
               "no accessibility bus");
  h.send({{"type", "start"},
          {"id", 2},
          {"session", "s"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  h.expect("started");
  check(h.expect("unavailable")["reason"] == "atspi_bus_absent",
        "start reports the absent bus");
  h.send({{"type", "setup"}, {"id", 3}});
  expect_state(
      h.expect("capabilities"), "needs_setup", "atspi_bus_absent",
      "setup with no accessibility bus cannot enable it and starts nothing");
  check(!a11y_owned(daemon), "the helper never started the accessibility bus");
}

void disabled_then_setup(const Daemon &daemon) {
  FakeA11y fake(daemon.address, FakeA11y::Status::Boolean, false,
                "unix:path=/nonexistent/zoom-ctest");
  Helper h = launch(daemon);
  h.expect("hello");
  expect_state(capabilities(h, 1), "needs_setup", "accessibility_disabled",
               "disabled");
  expect_state(capabilities(h, 2), "needs_setup", "accessibility_disabled",
               "still disabled");
  h.send({{"type", "start"},
          {"id", 3},
          {"session", "s"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  h.expect("started");
  check(h.expect("unavailable")["reason"] == "accessibility_disabled",
        "start reports disabled");
  check(fake.sets == 0 && !fake.enabled(),
        "capabilities and start never set a property");

  h.send({{"type", "setup"}, {"id", 4}});
  const json after = h.expect("capabilities");
  check(fake.sets == 1 && fake.enabled(), "setup sets IsEnabled exactly once");
  // Enabled now; no Zoom is running, and libatspi is still untouched.
  expect_state(after, "zoom_not_running", "zoom_not_running",
               "enabled after setup");
  check(fake.addresses == 0,
        "libatspi is not initialized while no read is needed");
  h.expect_clock(5);
  check(fake.sets == 1, "nothing writes again");
  h.send({{"type", "stop"}, {"id", 6}});
  h.expect("stopped");
  check(h.wait_exit() == 0, "exit 0");
}

void unreadable_and_mistyped(const Daemon &daemon) {
  {
    FakeA11y fake(daemon.address, FakeA11y::Status::Unreadable, true, "x");
    Helper h = launch(daemon);
    h.expect("hello");
    expect_state(capabilities(h, 1), "unavailable", "atspi_status_unreadable",
                 "IsEnabled that cannot be read");
  }
  {
    FakeA11y fake(daemon.address, FakeA11y::Status::NotBoolean, true, "x");
    Helper h = launch(daemon);
    h.expect("hello");
    expect_state(capabilities(h, 1), "unavailable", "atspi_status_unreadable",
                 "IsEnabled that is not a boolean");
  }
}

void no_libatspi_without_a_rule(const Daemon &daemon) {
  SelfAsZoom zoom;
  FakeA11y fake(daemon.address, FakeA11y::Status::Boolean, true,
                daemon.address);
  Helper h = launch(daemon, zoom.env_without_rules);
  h.expect("hello");
  // Zoom is "running" and accessibility is on, but the shipped rule set is
  // empty: nothing needs a read, so libatspi must never connect or subscribe to
  // signals.
  expect_state(capabilities(h, 1), "unsupported_version", "no_validated_rules",
               "a running Zoom with no validated rule");
  h.send({{"type", "start"},
          {"id", 2},
          {"session", "s"},
          {"poll_ms", 100},
          {"deadline_ms", 1000}});
  h.expect("started");
  check(h.expect("unavailable")["reason"] == "no_validated_rules",
        "start reports it too");
  h.expect_clock(3);
  check(fake.addresses == 0 && fake.sets == 0,
        "libatspi was never asked to connect");
  h.send({{"type", "stop"}, {"id", 4}});
  h.expect("stopped");
}

void unreachable_registry(const Daemon &daemon) {
  SelfAsZoom zoom;
  FakeA11y fake(daemon.address, FakeA11y::Status::Boolean, true,
                "unix:path=/nonexistent/zoom-ctest");
  Helper h = launch(daemon, zoom.env_with_rules);
  h.expect("hello");
  // A rule needs a read, so libatspi is initialized, fails, and the helper
  // reports it (and stays alive) instead of letting libatspi abort the process.
  expect_state(capabilities(h, 1), "unavailable", "atspi_unreachable",
               "unreachable accessibility bus");
  check(fake.addresses >= 1,
        "the address came from the bounded GetAddress call");
  h.expect_clock(2);
  expect_state(capabilities(h, 3), "unavailable", "atspi_unreachable",
               "and it stays reported");
  h.send({{"type", "stop"}, {"id", 4}});
  h.expect("stopped");
  check(h.wait_exit() == 0, "exit 0");
}

// libatspi cannot reach a new registry after the first one is gone (its
// application table survives atspi_exit), so a lost registry is reported once
// and the helper then exits for the supervisor to restart.
void registry_loss_is_fatal(const Daemon &daemon) {
  SelfAsZoom zoom;
  FakeA11y a11y(daemon.address, FakeA11y::Status::Boolean, true,
                daemon.address);
  auto registry = std::make_unique<FakeRegistry>(daemon.address);
  Helper h = launch(daemon, zoom.env_with_rules);
  h.expect("hello");
  // The read reaches the real desktop: init, then the registry's child count.
  expect_state(capabilities(h, 1), "unavailable", "zoom_not_exposed",
               "a desktop read before the loss (no application for Zoom)");
  check(registry->queries >= 1, "the fake registry was queried by libatspi");

  registry.reset(); // the accessibility registry goes away
  expect_state(capabilities(h, 2), "unavailable", "atspi_bus_lost",
               "registry lost");
  h.send({{"type", "capabilities"}, {"id", 3}});
  check(h.wait_exit(5000) == kExitRegistryLost,
        "the helper then exits with the documented code");
  check(h.drain_stderr().find("registry_lost_exit") != std::string::npos,
        "a stable token explains the exit");
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: zoom_observer_bus_test HELPER\n";
    return 2;
  }
  helper_path = argv[1];
  std::signal(SIGPIPE, SIG_IGN);
  const std::vector<void (*)(const Daemon &)> scenarios = {
      no_accessibility_bus,       disabled_then_setup,  unreadable_and_mistyped,
      no_libatspi_without_a_rule, unreachable_registry, registry_loss_is_fatal};
  for (auto scenario : scenarios) {
    Daemon daemon;
    if (!start_daemon(daemon)) {
      std::cerr << "SKIP: dbus-daemon is unavailable\n";
      return 77;
    }
    scenario(daemon);
  }
  std::cout << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
