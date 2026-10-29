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
using foresight::zoom::kLinuxExitRegistryLost;

namespace {

const char *helper_path = nullptr;

struct Daemon {
  pid_t pid = -1;
  std::string address, directory;
  ~Daemon() {
    stop();
    if (!directory.empty()) {
      unlink((directory + "/bus").c_str());
      unlink((directory + "/bus.conf").c_str());
      unlink((directory + "/services/org.a11y.Bus.service").c_str());
      rmdir((directory + "/services").c_str());
      unlink(marker().c_str());
      rmdir(directory.c_str());
    }
  }
  // Kills the daemon: every client connection to it drops.
  void stop() {
    if (pid > 0) {
      kill(pid, SIGTERM);
      waitpid(pid, nullptr, 0);
    }
    pid = -1;
  }
  std::string marker() const {
    return directory + "/activated";
  }
  // Did the daemon ever activate the org.a11y.Bus service? Its Exec creates the
  // marker, so a helper that auto-starts the accessibility bus leaves it
  // behind.
  bool activated() const {
    return access(marker().c_str(), F_OK) == 0;
  }
};

bool dbus_daemon_in_path() {
  const char *path = std::getenv("PATH");
  std::string list = path ? path : "/usr/bin:/bin";
  for (size_t start = 0; start <= list.size();) {
    size_t end = list.find(':', start);
    if (end == std::string::npos)
      end = list.size();
    const std::string candidate =
        list.substr(start, end - start) + "/dbus-daemon";
    if (access(candidate.c_str(), X_OK) == 0)
      return true;
    start = end + 1;
  }
  return false;
}

bool spawn_daemon(Daemon &daemon);

// False when the daemon could not be started. The caller has already checked
// that dbus-daemon exists, so a failure here is a test failure, not a skip.
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
  // A service that would start the accessibility bus if anything activated it:
  // its Exec leaves a marker file the tests look for.
  mkdir((daemon.directory + "/services").c_str(), 0700);
  {
    std::ofstream service(daemon.directory + "/services/org.a11y.Bus.service");
    service << "[D-BUS Service]\nName=org.a11y.Bus\nExec=/usr/bin/env touch "
            << daemon.marker() << "\n";
  }
  const std::string config = daemon.directory + "/bus.conf";
  {
    std::ofstream out(config);
    out << "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-Bus Bus "
           "Configuration 1.0//EN\" "
           "\"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">\n"
           "<busconfig><type>session</type><listen>unix:path="
        << daemon.directory << "/bus</listen><auth>EXTERNAL</auth>"
        << "<servicedir>" << daemon.directory << "/services</servicedir>"
        << "<policy context=\"default\">"
           "<allow send_destination=\"*\" eavesdrop=\"true\"/><allow "
           "eavesdrop=\"true\"/>"
           "<allow own=\"*\"/></policy></busconfig>\n";
  }
  return spawn_daemon(daemon);
}

// Starts dbus-daemon on the daemon's config; also used to restart one at the
// same address after stop().
bool spawn_daemon(Daemon &daemon) {
  const std::string config = daemon.directory + "/bus.conf";
  int address_pipe[2];
  if (pipe(address_pipe) != 0)
    return false;
  daemon.pid = fork();
  if (daemon.pid == 0) {
    close(address_pipe[0]);
    // A sanitizer run preloads its runtime into every process CTest starts; the
    // system dbus-daemon (and what it activates) must not inherit that.
    unsetenv("LD_PRELOAD");
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
  // What the fake does with a Set of IsEnabled: take it, refuse it with an
  // error reply (a live owner that says no), or answer too late for the caller.
  enum class SetBehavior { Accept, Refuse, Stall };
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
  std::atomic<SetBehavior> set_behavior{SetBehavior::Accept};
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
                               GError **error, gpointer data) {
    auto *self = static_cast<FakeA11y *>(data);
    ++self->sets;
    switch (self->set_behavior.load()) {
    case SetBehavior::Refuse:
      g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_ACCESS_DENIED,
                          "refused");
      return FALSE;
    case SetBehavior::Stall:
      // Longer than the helper's 1 s call timeout, shorter than the test's
      // wait.
      std::this_thread::sleep_for(std::chrono::milliseconds(1300));
      g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_FAILED, "late");
      return FALSE; // the caller gave up long ago, and nothing changed
    case SetBehavior::Accept:
      break;
    }
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

bool check_started(Daemon &daemon) {
  const bool started = start_daemon(daemon);
  check(started, "the private dbus-daemon starts");
  return started;
}

json capabilities(Helper &h, int id) {
  h.send({{"type", "capabilities"}, {"id", id}});
  return h.expect("capabilities");
}

void expect_state(const json &caps, const char *state, const char *reason,
                  const std::string &what) {
  // value(): a helper that answered with something else (or died) fails this
  // check instead of aborting the test on a missing key.
  const json got_state = caps.value("state", json("<none>"));
  const json got_reason = caps.value("reason", json("<none>"));
  check(got_state == state && got_reason == reason,
        what + " (got " + got_state.dump() + "/" + got_reason.dump() + ")");
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
  check(
      !daemon.activated(),
      "no call activated the org.a11y.Bus service (its marker never appeared)");
  // The setup above reached no bus, so a bus that appears later, disabled, is a
  // first run and not a failed setup.
  FakeA11y late(daemon.address, FakeA11y::Status::Boolean, false, "x");
  expect_state(capabilities(h, 4), "needs_setup", "accessibility_disabled",
               "a setup that reached no bus is not blamed on a later one");
  check(late.sets == 0, "and nothing was set");
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

// A second daemon plays the accessibility bus (as on a real desktop, where it
// is separate from the session bus); the registry lives on it.
struct A11yWorld {
  Daemon bus;
  std::unique_ptr<FakeA11y> status;
  std::unique_ptr<FakeRegistry> registry;
  bool start(const Daemon &session) {
    if (!start_daemon(bus))
      return false;
    // The address handed to libatspi has no `guid=`: like a real accessibility
    // bus address, it names a socket, not one particular daemon, so a new
    // daemon at the same path can be reconnected to.
    std::string address = bus.address;
    const auto guid = address.find(",guid=");
    if (guid != std::string::npos)
      address.resize(guid);
    status = std::make_unique<FakeA11y>(
        session.address, FakeA11y::Status::Boolean, true, address);
    registry = std::make_unique<FakeRegistry>(bus.address);
    return true;
  }
};

// Sends capabilities and expects the helper's terminal error instead of a
// reply, then exit status 4.
void expect_fatal_loss(Helper &h, int id, const std::string &what) {
  h.send({{"type", "capabilities"}, {"id", id}});
  const json error = h.expect("error");
  check(error["code"] == "atspi_bus_lost" && error["id"] == id,
        what + ": a terminal error carries the request id and reason: " +
            error.dump());
  check(h.wait_exit(5000) == kLinuxExitRegistryLost,
        what + ": the helper exits with status 4");
}

// A registry that stalls or restarts is not the end of libatspi's connection:
// the read fails, the helper stays up, and it recovers when the registry is
// back. No session runs during the recovery (its polls would interleave
// unsolicited frames); a second helper shows a session reports the outage
// without ending.
void registry_blip_is_not_fatal(const Daemon &session) {
  SelfAsZoom zoom;
  A11yWorld world;
  if (!world.start(session)) {
    check(false, "the accessibility daemon starts");
    return;
  }
  Helper h = launch(session, zoom.env_with_rules);
  h.expect("hello");
  // The read reaches the real desktop: init, then the registry's child count.
  expect_state(capabilities(h, 1), "unavailable", "zoom_not_exposed",
               "a desktop read before the blip (no application for Zoom)");
  check(world.registry->queries >= 1,
        "the fake registry was queried by libatspi");

  world.registry.reset(); // the registry goes away; the accessibility bus stays
  expect_state(capabilities(h, 2), "unavailable", "ax_read_failed",
               "a registry that is gone for a moment");
  {
    Helper watcher = launch(session, zoom.env_with_rules);
    watcher.expect("hello");
    watcher.send({{"type", "start"},
                  {"id", 3},
                  {"session", "s"},
                  {"poll_ms", 100},
                  {"deadline_ms", 1000}});
    watcher.expect("started");
    check(watcher.expect("unavailable")["reason"] == "ax_read_failed",
          "a session reports the outage as an ordinary failed read");
    watcher.send({{"type", "stop"}, {"id", 4}});
    watcher.expect("stopped");
    check(watcher.wait_exit() == 0, "and it ends cleanly on stop");
  }

  world.registry = std::make_unique<FakeRegistry>(world.bus.address);
  // libatspi reattaches when the well-known name returns; the helper follows.
  // Every wait is a request/reply round trip, and the loop ends as soon as the
  // helper answers or dies, so nothing here depends on elapsed time.
  json again = json::object();
  for (int attempt = 0; attempt < 200; ++attempt) {
    auto frame = h.try_capabilities(100 + attempt);
    if (!frame)
      break;
    again = *frame;
    if (again["reason"] == "zoom_not_exposed")
      break;
  }
  expect_state(again, "unavailable", "zoom_not_exposed",
               "recovered after the registry returned");
  h.send({{"type", "stop"}, {"id", 5}});
  h.expect("stopped", 10000);
}

// libatspi cannot reach a new registry once its connection to the accessibility
// bus is gone (its application table survives atspi_exit): that is fatal,
// reported in a terminal error, and the supervisor restarts the helper.
void bus_connection_drop_is_fatal(const Daemon &session) {
  SelfAsZoom zoom;
  A11yWorld world;
  if (!world.start(session)) {
    check(false, "the accessibility daemon starts");
    return;
  }
  Helper h = launch(session, zoom.env_with_rules);
  h.expect("hello");
  expect_state(capabilities(h, 1), "unavailable", "zoom_not_exposed",
               "a desktop read before the drop");
  world.registry.reset();
  world.bus
      .stop(); // the accessibility bus daemon dies: libatspi's connection drops
  expect_fatal_loss(h, 2, "accessibility bus gone");
}

// The accessibility bus dies and a new one listens at the same address:
// libatspi keeps calling through its dead connection. The check must look at
// that connection, not reconnect and report "alive".
void bus_restart_at_the_same_address_is_fatal(const Daemon &session) {
  SelfAsZoom zoom;
  A11yWorld world;
  if (!world.start(session)) {
    check(false, "the accessibility daemon starts");
    return;
  }
  Helper h = launch(session, zoom.env_with_rules);
  h.expect("hello");
  expect_state(capabilities(h, 1), "unavailable", "zoom_not_exposed",
               "a desktop read before the restart");
  world.registry.reset();
  world.bus.stop();
  check(spawn_daemon(world.bus),
        "a new accessibility daemon starts at the address");
  expect_fatal_loss(h, 2, "accessibility bus restarted");
}

// Setup outcomes: a live bus that refuses is an attempt that did not take; one
// that answers too late is not an attempt at all.
void setup_refused_counts_as_attempted(const Daemon &session) {
  FakeA11y fake(session.address, FakeA11y::Status::Boolean, false, "x");
  fake.set_behavior = FakeA11y::SetBehavior::Refuse;
  Helper h = launch(session);
  h.expect("hello");
  expect_state(capabilities(h, 1), "needs_setup", "accessibility_disabled",
               "disabled before setup");
  h.send({{"type", "setup"}, {"id", 2}});
  expect_state(h.expect("capabilities"), "permission_denied",
               "setup_not_effective", "a refused setup was attempted");
  check(fake.sets == 1 && !fake.enabled(), "the refusal changed nothing");
}

void setup_timeout_is_not_an_attempt(const Daemon &session) {
  FakeA11y fake(session.address, FakeA11y::Status::Boolean, false, "x");
  fake.set_behavior = FakeA11y::SetBehavior::Stall;
  Helper h = launch(session);
  h.expect("hello");
  h.send({{"type", "setup"}, {"id", 1}});
  expect_state(h.expect("capabilities", 10000), "needs_setup",
               "accessibility_disabled",
               "a setup that timed out is not counted as an attempt");
}

// A different owner of org.a11y.Bus than the one libatspi connected through is
// a restarted accessibility bus: also fatal.
void bus_owner_loss_is_fatal(const Daemon &session) {
  SelfAsZoom zoom;
  A11yWorld world;
  if (!world.start(session)) {
    check(false, "the accessibility daemon starts");
    return;
  }
  Helper h = launch(session, zoom.env_with_rules);
  h.expect("hello");
  expect_state(capabilities(h, 1), "unavailable", "zoom_not_exposed",
               "a desktop read before the owner goes");
  world.status.reset(); // org.a11y.Bus loses its owner; the daemon stays up
  expect_fatal_loss(h, 2, "org.a11y.Bus owner gone");
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: zoom_observer_bus_test HELPER\n";
    return 2;
  }
  helper_path = argv[1];
  std::signal(SIGPIPE, SIG_IGN);
  if (!dbus_daemon_in_path()) {
    std::cerr << "SKIP: dbus-daemon is not installed\n";
    return 77;
  }
  const std::vector<void (*)(const Daemon &)> scenarios = {
      no_accessibility_bus,           disabled_then_setup,
      unreadable_and_mistyped,        no_libatspi_without_a_rule,
      unreachable_registry,           registry_blip_is_not_fatal,
      bus_connection_drop_is_fatal,   bus_restart_at_the_same_address_is_fatal,
      bus_owner_loss_is_fatal,        setup_refused_counts_as_attempted,
      setup_timeout_is_not_an_attempt};
  for (auto scenario : scenarios) {
    Daemon daemon;
    // dbus-daemon is installed, so a daemon that will not start is a failure
    // that must not hide earlier ones behind a skip.
    if (!check_started(daemon))
      continue;
    scenario(daemon);
  }
  std::cout << "zoom_observer_bus: " << checks << " checks, " << failures
            << " failures\n";
  return failures == 0 ? 0 : 1;
}
