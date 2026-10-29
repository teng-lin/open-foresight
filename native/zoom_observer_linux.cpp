// zoom_observer_linux: reads Zoom's accessibility tree through libatspi and
// speaks the meeting speaker observer protocol on stdin/stdout
// (docs/architecture/speaker-observer-protocol.md) on the shared observer core.
// It never uses Python, never prompts, and changes desktop settings only on an
// explicit `setup` (see enable_accessibility, the only place that sets
// anything).
#include "zoom_atspi_collect.h"
#include "zoom_linux_proc.h"

#include <algorithm>
#include <atspi/atspi.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <gio/gio.h>
#include <glib.h>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#ifndef FORESIGHT_ZOOM_OBSERVER_EXECUTABLE
// Basename of the Zoom client's main process. Overridden only by smoke tests
// that point the reader at another accessible application.
#define FORESIGHT_ZOOM_OBSERVER_EXECUTABLE "zoom"
#endif

namespace foresight::zoom {
namespace {

constexpr int kDBusTimeoutMs = 1000;
constexpr int kConnectTimeoutMs = 1000;
constexpr int kMaxNotes = 32;
constexpr int64_t kInitRetryBaseMs = 1000;
constexpr int64_t kInitRetryMaxMs = 60000;

// Bounded stderr diagnostics, as in the shared core: stable tokens only, never
// accessible names, paths or message text.
void note(const char *token) {
  static int count = 0;
  if (count >= kMaxNotes)
    return;
  ++count;
  std::cerr << "zoom_observer: " << token << '\n';
}

void note_error(const char *where, const GError *error) {
  static int count = 0;
  if (!error || count >= kMaxNotes)
    return;
  ++count;
  std::cerr << "zoom_observer: " << where << " "
            << g_quark_to_string(error->domain) << ":" << error->code << '\n';
}

struct Owned {
  GError *error = nullptr;
  ~Owned() {
    g_clear_error(&error);
  }
  GError **out() {
    g_clear_error(&error);
    return &error;
  }
};

uint64_t clock_ms() {
  timespec ts{};
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
  return static_cast<uint64_t>(ts.tv_sec) * 1000 +
         static_cast<uint64_t>(ts.tv_nsec) / 1000000;
}

// The session bus address without D-Bus autolaunch, which could start a bus.
std::string session_bus_address() {
  if (const char *address = std::getenv("DBUS_SESSION_BUS_ADDRESS");
      address && *address)
    return address;
  if (const char *runtime = std::getenv("XDG_RUNTIME_DIR");
      runtime && *runtime) {
    const std::string path = std::string(runtime) + "/bus";
    struct stat info{};
    if (stat(path.c_str(), &info) == 0 && S_ISSOCK(info.st_mode))
      return "unix:path=" + path;
  }
  return "";
}

void log_glib(const gchar *domain, GLogLevelFlags level, const gchar *,
              gpointer) {
  // Library messages can name accessible objects; keep only their origin.
  static int count = 0;
  if (count >= kMaxNotes)
    return;
  ++count;
  std::cerr << "zoom_observer: glib " << (domain ? domain : "-") << " level "
            << static_cast<int>(level) << '\n';
}

// g_dbus_connection_new_for_address_sync has no timeout, so connect
// asynchronously on a private context and cancel after `timeout_ms`.
GDBusConnection *connect_bounded(const std::string &address, int timeout_ms) {
  struct State {
    GMainLoop *loop;
    GCancellable *cancel;
    GDBusConnection *connection = nullptr;
  };
  GMainContext *context = g_main_context_new();
  g_main_context_push_thread_default(context);
  State state{g_main_loop_new(context, FALSE), g_cancellable_new()};
  g_dbus_connection_new_for_address(
      address.c_str(),
      static_cast<GDBusConnectionFlags>(
          G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, state.cancel,
      [](GObject *, GAsyncResult *result, gpointer data) {
        auto *self = static_cast<State *>(data);
        Owned error;
        self->connection =
            g_dbus_connection_new_for_address_finish(result, error.out());
        g_main_loop_quit(self->loop);
      },
      &state);
  GSource *timeout = g_timeout_source_new(static_cast<guint>(timeout_ms));
  g_source_set_callback(
      timeout,
      [](gpointer data) -> gboolean {
        g_cancellable_cancel(static_cast<State *>(data)->cancel);
        return G_SOURCE_REMOVE;
      },
      &state, nullptr);
  g_source_attach(timeout, context);
  g_main_loop_run(state.loop);
  g_source_destroy(timeout);
  g_source_unref(timeout);
  g_main_context_pop_thread_default(context);
  g_object_unref(state.cancel);
  g_main_loop_unref(state.loop);
  g_main_context_unref(context);
  return state.connection;
}

std::string bounded_copy(const char *text) {
  return text ? std::string(text, strnlen(text, kMaxCollectedBytes)) : "";
}

std::string bounded(gchar *text) {
  std::string value = bounded_copy(text);
  g_free(text);
  return value;
}

// One libatspi accessible behind the traversal interface.
class AtspiNode final : public AccessibleNode {
public:
  // Takes a reference.
  explicit AtspiNode(AtspiAccessible *accessible) : accessible_(accessible) {}
  ~AtspiNode() override {
    g_object_unref(accessible_);
  }

  NodeProps read() override {
    NodeProps props;
    Owned error;
    AtspiObject *object = ATSPI_OBJECT(accessible_);
    const char *bus =
        object->app && object->app->bus_name ? object->app->bus_name : "";
    props.identity = std::string(bus) + (object->path ? object->path : "");
    props.name = bounded(atspi_accessible_get_name(accessible_, error.out()));
    note_failure(error, props);
    props.description =
        bounded(atspi_accessible_get_description(accessible_, error.out()));
    note_failure(error, props);
    const AtspiRole role = atspi_accessible_get_role(accessible_, error.out());
    note_failure(error, props);
    props.role = bounded(atspi_role_get_name(role));
    read_states(props);
    read_attributes(props);
    const gint count =
        atspi_accessible_get_child_count(accessible_, error.out());
    props.child_count = error.error || count < 0 ? -1 : count;
    note_failure(error, props);
    return props;
  }

  std::unique_ptr<AccessibleNode> child(int index) override {
    Owned error;
    AtspiAccessible *child =
        atspi_accessible_get_child_at_index(accessible_, index, error.out());
    if (!child) {
      note_error("child", error.error);
      return nullptr;
    }
    return std::make_unique<AtspiNode>(child);
  }

  void drop_cache() override {
    // libatspi caches names, states and children per application and only keeps
    // them current through event listeners, which this helper does not
    // register. Read live state on every poll instead.
    atspi_accessible_set_cache_mask(accessible_, ATSPI_CACHE_NONE);
    atspi_accessible_clear_cache(accessible_);
  }

private:
  static void note_failure(const Owned &error, NodeProps &props) {
    if (!error.error)
      return;
    note_error("node", error.error);
    props.failed = true;
  }

  void read_states(NodeProps &props) {
    AtspiStateSet *states = atspi_accessible_get_state_set(accessible_);
    if (!states) {
      props.failed = true;
      return;
    }
    if (GArray *list = atspi_state_set_get_states(states)) {
      GEnumClass *klass = G_ENUM_CLASS(g_type_class_ref(ATSPI_TYPE_STATE_TYPE));
      for (guint i = 0; i < list->len; ++i) {
        const GEnumValue *value =
            g_enum_get_value(klass, g_array_index(list, AtspiStateType, i));
        if (!value)
          continue;
        if (props.states.size() >= kMaxStatesPerNode) {
          props.failed = true; // more states than any real element has
          break;
        }
        props.states.insert(value->value_nick);
      }
      g_type_class_unref(klass);
      g_array_free(list, TRUE);
    } else {
      props.failed = true;
    }
    g_object_unref(states);
    // A state set that holds only `defunct` is what libatspi returns when the
    // call timed out or the object is gone: never evidence of a quiet element.
    if (props.states.size() == 1 && props.states.count("defunct"))
      props.failed = true;
  }

  void read_attributes(NodeProps &props) {
    Owned error;
    GHashTable *attributes =
        atspi_accessible_get_attributes(accessible_, error.out());
    if (!attributes) {
      props.failed = true; // NULL means the call failed, not "no attributes"
      note_error("attributes", error.error);
      return;
    }
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, attributes);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
      if (props.attributes.size() >= kMaxAttributesPerNode) {
        props.failed = true;
        break;
      }
      props.attributes[bounded_copy(static_cast<const char *>(key))] =
          bounded_copy(static_cast<const char *>(value));
    }
    g_hash_table_unref(attributes);
  }

  AtspiAccessible *accessible_;
};

class AtspiDesktop final : public LinuxDesktop, public AccessibleDesktop {
public:
  ~AtspiDesktop() override {
    teardown_atspi();
    if (bus_)
      g_object_unref(bus_);
  }

  BusStatus bus_status() override {
    if (lost_) {
      // The registry went away during a read: drop libatspi's connection and
      // say so for this poll; the next poll reconnects with a fresh init.
      lost_ = false;
      teardown_atspi();
      return BusStatus::BusLost;
    }
    const BusStatus connected = connect_session_bus();
    if (connected != BusStatus::Ready)
      return connected;
    // Read-only, and never activating a service.
    Owned error;
    GVariant *owner = g_dbus_connection_call_sync(
        bus_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner",
        g_variant_new("(s)", "org.a11y.Bus"), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, kDBusTimeoutMs, nullptr, error.out());
    if (!owner) {
      note_error("name_has_owner", error.error);
      drop_session_bus(); // reconnect next time
      return BusStatus::SessionBusUnreachable;
    }
    gboolean present = FALSE;
    g_variant_get(owner, "(b)", &present);
    g_variant_unref(owner);
    if (!present) {
      if (!atspi_ready_)
        return BusStatus::A11yBusAbsent;
      teardown_atspi();
      return BusStatus::BusLost;
    }
    GVariant *enabled = g_dbus_connection_call_sync(
        bus_, "org.a11y.Bus", "/org/a11y/bus",
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.a11y.Status", "IsEnabled"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, kDBusTimeoutMs,
        nullptr, error.out());
    if (!enabled) {
      note_error("is_enabled", error.error);
      return BusStatus::StatusUnreadable;
    }
    GVariant *inner = nullptr;
    g_variant_get(enabled, "(v)", &inner);
    const bool boolean =
        inner && g_variant_is_of_type(inner, G_VARIANT_TYPE_BOOLEAN);
    const bool on = boolean && g_variant_get_boolean(inner);
    if (inner)
      g_variant_unref(inner);
    g_variant_unref(enabled);
    if (!boolean)
      return BusStatus::StatusUnreadable;
    if (!on)
      return BusStatus::Disabled;
    return ensure_atspi();
  }

  // The only function that sets anything on the desktop.
  void enable_accessibility() override {
    if (connect_session_bus() != BusStatus::Ready)
      return;
    // org.a11y.Status.IsEnabled is the desktop-neutral switch toolkits read.
    // at-spi-bus-launcher mirrors it into GSettings where that exists.
    Owned error;
    GVariant *reply = g_dbus_connection_call_sync(
        bus_, "org.a11y.Bus", "/org/a11y/bus",
        "org.freedesktop.DBus.Properties", "Set",
        g_variant_new("(ssv)", "org.a11y.Status", "IsEnabled",
                      g_variant_new_boolean(TRUE)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, kDBusTimeoutMs, nullptr, error.out());
    if (reply) {
      g_variant_unref(reply);
    } else {
      note("setup_failed");
      note_error("setup", error.error);
    }
  }

  // A Flatpak or snap Zoom runs in another pid namespace, so its pid never
  // matches the accessibility registry: it is reported as not exposed.
  ProcessScan zoom_processes() override {
    return scan_zoom_processes("/proc", FORESIGHT_ZOOM_OBSERVER_EXECUTABLE,
                               geteuid());
  }

  TreeRead read_tree(int pid, int budget_ms,
                     const std::function<bool()> &cancelled) override {
    // Second argument: no startup grace, or libatspi stretches the per-call
    // timeout of a freshly seen application to many seconds.
    atspi_set_timeout(kLinuxCallTimeoutMs, -1);
    CollectLimits limits;
    limits.budget_ms = budget_ms;
    return read_zoom_tree(*this, pid, limits, registry_, cancelled);
  }

  uint64_t monotonic_ms() override {
    return clock_ms();
  }

  Lookup
  applications(int pid, const std::function<bool()> &cancelled,
               const std::function<bool()> &out_of_time,
               std::vector<std::unique_ptr<AccessibleNode>> &out) override {
    AtspiAccessible *desktop = atspi_get_desktop(0);
    if (!desktop)
      return Lookup::Failed;
    Owned error;
    const gint count = atspi_accessible_get_child_count(desktop, error.out());
    if (error.error || count < 0) {
      note_error("desktop_count", error.error);
      g_object_unref(desktop);
      return registry_lost();
    }
    Lookup result = Lookup::Ok;
    for (gint i = 0; i < count; ++i) {
      if (cancelled()) {
        result = Lookup::Cancelled;
        break;
      }
      if (out_of_time()) {
        result = Lookup::Failed;
        break;
      }
      AtspiAccessible *child =
          atspi_accessible_get_child_at_index(desktop, i, error.out());
      if (!child) {
        note_error("desktop_child", error.error);
        result =
            Lookup::Failed; // one application failing is not the registry gone
        break;
      }
      const guint child_pid =
          atspi_accessible_get_process_id(child, error.out());
      if (error.error) {
        note_error("process_id", error.error);
        g_object_unref(child);
        result = Lookup::Failed;
        break;
      }
      if (child_pid == static_cast<guint>(pid))
        out.push_back(std::make_unique<AtspiNode>(child));
      else
        g_object_unref(child);
    }
    g_object_unref(desktop);
    if (result != Lookup::Ok)
      out.clear();
    return result;
  }

private:
  Lookup registry_lost() {
    lost_ = true;
    return Lookup::BusLost;
  }

  void drop_session_bus() {
    if (bus_)
      g_object_unref(bus_);
    bus_ = nullptr;
  }

  BusStatus connect_session_bus() {
    if (bus_ && !g_dbus_connection_is_closed(bus_))
      return BusStatus::Ready;
    drop_session_bus();
    const std::string address = session_bus_address();
    if (address.empty())
      return BusStatus::NoSessionBus;
    bus_ = connect_bounded(address, kConnectTimeoutMs);
    if (!bus_)
      return BusStatus::SessionBusUnreachable;
    return BusStatus::Ready;
  }

  // libatspi must never be asked for the desktop after a failed init: that
  // aborts the process. Fetch the address with a bounded call (libatspi's own
  // lookup has no timeout), hand it over through AT_SPI_BUS_ADDRESS, check
  // atspi_init's result, and retry a failure only after a growing delay.
  BusStatus ensure_atspi() {
    if (atspi_ready_)
      return BusStatus::Ready;
    const int64_t now = static_cast<int64_t>(clock_ms());
    if (now < next_init_ms_)
      return BusStatus::AtspiUnreachable;
    Owned error;
    GVariant *reply = g_dbus_connection_call_sync(
        bus_, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
        nullptr, G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NO_AUTO_START,
        kDBusTimeoutMs, nullptr, error.out());
    bool ok = false;
    if (reply) {
      const char *address = nullptr;
      g_variant_get(reply, "(&s)", &address);
      if (address && *address) {
        const char *current = std::getenv("AT_SPI_BUS_ADDRESS");
        if (!current || std::strcmp(current, address) != 0)
          setenv("AT_SPI_BUS_ADDRESS", address, 1);
        // 0 or 1 is connected; 2 means the accessibility bus is unreachable.
        const int rc = atspi_init();
        ok = rc == 0 || rc == 1;
        if (!ok)
          atspi_exit(); // a failed init still reports "already initialized"
                        // next time
      }
      g_variant_unref(reply);
    } else {
      note_error("get_address", error.error);
    }
    if (ok) {
      atspi_ready_ = true;
      init_failures_ = 0;
      return BusStatus::Ready;
    }
    note("atspi_init_failed");
    const int64_t delay = std::min<int64_t>(
        kInitRetryMaxMs, kInitRetryBaseMs << std::min(init_failures_, 6));
    ++init_failures_;
    next_init_ms_ = now + delay;
    return BusStatus::AtspiUnreachable;
  }

  void teardown_atspi() {
    if (!atspi_ready_)
      return;
    atspi_exit();
    atspi_ready_ = false;
    next_init_ms_ = 0;
  }

  GDBusConnection *bus_ = nullptr;
  bool atspi_ready_ = false;
  bool lost_ = false;
  int init_failures_ = 0;
  int64_t next_init_ms_ = 0;
  ElementRegistry registry_;
};

} // namespace
} // namespace foresight::zoom

int main(int argc, char **argv) {
  using namespace foresight::zoom;
  if (argc != 3 || std::strcmp(argv[1], "--protocol") != 0 ||
      std::strcmp(argv[2], "1") != 0) {
    std::cerr << "usage: zoom_observer_linux --protocol 1\n";
    return 64;
  }
  std::signal(SIGPIPE, SIG_IGN);
  g_log_set_default_handler(log_glib, nullptr);
  AtspiDesktop desktop;
  // Connect while the process is still single-threaded where possible: the
  // address handover to libatspi (setenv) races other threads' getenv.
  (void)desktop.bus_status();
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
