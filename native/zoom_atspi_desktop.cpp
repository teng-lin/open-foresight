// libatspi/GDBus implementation of the Linux desktop interfaces. It never
// prompts, never starts a service, and sets a property only in
// enable_accessibility. libatspi itself is initialized lazily, on the first
// read that a validated rule requires.
#include "zoom_atspi_desktop.h"

#include "zoom_linux_proc.h"

#include <algorithm>
#include <atspi/atspi.h>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <glib.h>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace foresight::zoom {
namespace {

constexpr int kDBusTimeoutMs = 1000;
constexpr int kConnectTimeoutMs = 1000;
constexpr int kMaxNotes = 32;
constexpr int kMaxDrainIterations = 256;
constexpr size_t kMaxIdentityPathBytes = 512;
constexpr int64_t kInitRetryBaseMs = 1000;
constexpr int64_t kInitRetryMaxMs = 60000;

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

void note_error(const char *where, const GError *error) {
  static int count = 0;
  if (!error || count >= kMaxNotes)
    return;
  ++count;
  std::cerr << "zoom_observer: " << where << " "
            << g_quark_to_string(error->domain) << ":" << error->code << '\n';
}

// The session bus address, restricted to `unix:` transports (no autolaunch, no
// unixexec), else the user's runtime-directory bus.
std::string session_bus_address() {
  if (const char *address = std::getenv("DBUS_SESSION_BUS_ADDRESS");
      address && *address) {
    const std::string safe = safe_session_bus_address(address);
    if (!safe.empty())
      return safe;
  }
  if (const char *runtime = std::getenv("XDG_RUNTIME_DIR");
      runtime && *runtime) {
    const std::string path = std::string(runtime) + "/bus";
    struct stat info{};
    if (stat(path.c_str(), &info) == 0 && S_ISSOCK(info.st_mode))
      return "unix:path=" + path;
  }
  return "";
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

  NodeProps read(const std::function<bool()> &interrupted) override {
    NodeProps props;
    Owned error;
    AtspiObject *object = ATSPI_OBJECT(accessible_);
    const char *bus =
        object->app && object->app->bus_name ? object->app->bus_name : "";
    const std::string path = object->path ? object->path : "";
    // An over-long object path is not a usable identity (it could collide once
    // cut); an empty one is reported as missing.
    if (path.size() <= kMaxIdentityPathBytes)
      props.identity = std::string(bus) + path;
    // The budget and cancellation are checked before every remote call, so one
    // slow application overruns by at most a single call's timeout.
    const auto cut = [&] {
      if (!interrupted())
        return false;
      props.failed = true;
      return true;
    };
    if (cut())
      return props;
    props.name = bounded(atspi_accessible_get_name(accessible_, error.out()));
    note_failure(error, props);
    if (cut())
      return props;
    props.description =
        bounded(atspi_accessible_get_description(accessible_, error.out()));
    note_failure(error, props);
    if (cut())
      return props;
    const AtspiRole role = atspi_accessible_get_role(accessible_, error.out());
    note_failure(error, props);
    props.role = bounded(atspi_role_get_name(role));
    if (cut())
      return props;
    read_states(props);
    if (cut())
      return props;
    read_attributes(props);
    if (cut())
      return props;
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
    // libatspi caches names, states and children per application and keeps the
    // cache current from event signals, which this helper does not rely on (it
    // drains them but registers no listener). Read live state on every poll.
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

} // namespace

void note(const char *token) {
  static int count = 0;
  if (count >= kMaxNotes)
    return;
  ++count;
  std::cerr << "zoom_observer: " << token << '\n';
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

AtspiDesktop::AtspiDesktop(std::string executable_name)
    : executable_(std::move(executable_name)) {}

AtspiDesktop::~AtspiDesktop() {
  // atspi_exit is deliberately not called: libatspi's application table
  // survives it, so a later atspi_init() cannot reach a new registry.
  if (a11y_connection_)
    dbus_connection_unref(a11y_connection_);
  drop_session_bus();
}

void AtspiDesktop::drain_events() {
  // atspi_init hooks the default GLib context and subscribes to the registry's
  // cache and event signals. libatspi hands them to its handlers from that
  // context; nothing else iterates it, so without this the deferred work grows
  // in memory for as long as the process lives.
  if (!atspi_ready_)
    return;
  for (int i = 0;
       i < kMaxDrainIterations && g_main_context_iteration(nullptr, FALSE);
       ++i) {
  }
}

bool AtspiDesktop::a11y_connection_alive() const {
  return a11y_connection_ && dbus_connection_get_is_connected(a11y_connection_);
}

void AtspiDesktop::drop_session_bus() {
  if (bus_)
    g_object_unref(bus_);
  bus_ = nullptr;
}

BusStatus AtspiDesktop::connect_session_bus() {
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

BusStatus AtspiDesktop::bus_status() {
  drain_events();
  // The accessibility bus connection libatspi opened at init has dropped (the
  // bus died or restarted): libatspi keeps calling through it and its
  // application table is stale, so this is unrecoverable in-process.
  if (atspi_ready_ && !a11y_connection_alive())
    return BusStatus::BusLost;
  const BusStatus connected = connect_session_bus();
  if (connected != BusStatus::Ready)
    return connected;
  // Read-only, and never activating a service.
  Owned error;
  GVariant *owner = g_dbus_connection_call_sync(
      bus_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "GetNameOwner",
      g_variant_new("(s)", "org.a11y.Bus"), G_VARIANT_TYPE("(s)"),
      G_DBUS_CALL_FLAGS_NO_AUTO_START, kDBusTimeoutMs, nullptr, error.out());
  if (!owner) {
    if (!g_error_matches(error.error, G_DBUS_ERROR,
                         G_DBUS_ERROR_NAME_HAS_NO_OWNER)) {
      note_error("get_name_owner", error.error);
      drop_session_bus(); // reconnect next time
      return BusStatus::SessionBusUnreachable;
    }
    if (!atspi_ready_)
      return BusStatus::A11yBusAbsent;
    return BusStatus::BusLost;
  }
  const char *unique = nullptr;
  g_variant_get(owner, "(&s)", &unique);
  const std::string current_owner = unique ? unique : "";
  g_variant_unref(owner);
  // A different owner than when libatspi connected is a restarted accessibility
  // bus: our connection and its cached applications are stale.
  if (atspi_ready_ && current_owner != a11y_owner_)
    return BusStatus::BusLost;
  owner_seen_ = current_owner;

  GVariant *enabled = g_dbus_connection_call_sync(
      bus_, "org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties",
      "Get", g_variant_new("(ss)", "org.a11y.Status", "IsEnabled"),
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
  return on ? BusStatus::Ready : BusStatus::Disabled;
}

// Did a failed Set still reach a live accessibility bus? An error reply from
// the bus daemon's owner (a refusal, a bad argument) is an answer: setup was
// attempted and did not take. No owner, no service, a timeout or a closed
// connection is not.
static bool setup_reached_a_live_bus(const GError *error) {
  if (!error || !g_dbus_error_is_remote_error(error))
    return false;
  for (const GDBusError code :
       {G_DBUS_ERROR_SERVICE_UNKNOWN, G_DBUS_ERROR_NAME_HAS_NO_OWNER,
        G_DBUS_ERROR_NO_REPLY, G_DBUS_ERROR_TIMEOUT, G_DBUS_ERROR_TIMED_OUT,
        G_DBUS_ERROR_DISCONNECTED})
    if (g_error_matches(error, G_DBUS_ERROR, code))
      return false;
  return true;
}

bool AtspiDesktop::enable_accessibility() {
  if (connect_session_bus() != BusStatus::Ready)
    return false;
  // org.a11y.Status.IsEnabled is the desktop-neutral switch toolkits read.
  // at-spi-bus-launcher mirrors it into GSettings where that exists. Like every
  // other call this never activates a service: if the accessibility bus is not
  // running there is nothing to set, and capabilities keep saying so.
  Owned error;
  GVariant *reply = g_dbus_connection_call_sync(
      bus_, "org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties",
      "Set",
      g_variant_new("(ssv)", "org.a11y.Status", "IsEnabled",
                    g_variant_new_boolean(TRUE)),
      nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, kDBusTimeoutMs, nullptr,
      error.out());
  if (!reply) {
    note("setup_failed");
    note_error("setup", error.error);
    return setup_reached_a_live_bus(error.error);
  }
  g_variant_unref(reply);
  return true;
}

ProcessScan AtspiDesktop::zoom_processes() {
  // A Flatpak or snap Zoom runs in another pid namespace, so its pid never
  // matches the accessibility registry: it is reported as not exposed.
  return scan_zoom_processes("/proc", executable_, geteuid());
}

uint64_t AtspiDesktop::monotonic_ms() {
  return clock_ms();
}

// libatspi must never be asked for the desktop after a failed init: that aborts
// the process. Fetch the address with a bounded call (libatspi's own lookup has
// no timeout), hand it over through AT_SPI_BUS_ADDRESS, check atspi_init's
// result, and retry a failure only after a growing delay. Called only when a
// validated rule needs a read, so a build without rules never subscribes to the
// registry's signals.
bool AtspiDesktop::ensure_atspi() {
  if (atspi_ready_)
    return true;
  const int64_t now = static_cast<int64_t>(clock_ms());
  if (now < next_init_ms_)
    return false;
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
      // setenv races other threads' getenv; the reader thread only polls and
      // reads, and GDBus does not consult the environment after startup.
      const char *current = std::getenv("AT_SPI_BUS_ADDRESS");
      if (!current || std::strcmp(current, address) != 0)
        setenv("AT_SPI_BUS_ADDRESS", address, 1);
      // 0 or 1 is connected; 2 means the accessibility bus is unreachable.
      const int rc = atspi_init();
      ok = rc == 0 || rc == 1;
      if (!ok)
        atspi_exit(); // a failed init still reports "already initialized" next
    }
    g_variant_unref(reply);
  } else {
    note_error("get_address", error.error);
  }
  if (ok) {
    // Keep the connection as it is right after init. atspi_get_a11y_bus() opens
    // a new connection when called again, so liveness is checked on this one.
    a11y_connection_ = atspi_get_a11y_bus();
    if (a11y_connection_)
      dbus_connection_ref(a11y_connection_);
    atspi_ready_ = true;
    a11y_owner_ = owner_seen_;
    init_failures_ = 0;
    return true;
  }
  note("atspi_init_failed");
  const int64_t delay = std::min<int64_t>(
      kInitRetryMaxMs, kInitRetryBaseMs << std::min(init_failures_, 6));
  ++init_failures_;
  next_init_ms_ = now + delay;
  return false;
}

TreeRead AtspiDesktop::read_tree(int pid, int budget_ms,
                                 const std::function<bool()> &cancelled) {
  TreeRead read;
  if (!ensure_atspi()) {
    read.status = TreeRead::Status::Unreachable;
    return read;
  }
  // Second argument: no startup grace, or libatspi stretches the per-call
  // timeout of a freshly seen application to many seconds.
  atspi_set_timeout(kLinuxCallTimeoutMs, -1);
  drain_events();
  CollectLimits limits;
  limits.budget_ms = budget_ms;
  read = read_zoom_tree(*this, pid, limits, registry_, cancelled);
  drain_events();
  return read;
}

Lookup
AtspiDesktop::applications(int pid, const std::function<bool()> &cancelled,
                           const std::function<bool()> &out_of_time,
                           std::vector<std::unique_ptr<AccessibleNode>> &out) {
  AtspiAccessible *desktop = atspi_get_desktop(0);
  if (!desktop)
    return Lookup::Failed;
  // The registry's own child list is cached from events too; read it live.
  atspi_accessible_set_cache_mask(desktop, ATSPI_CACHE_NONE);
  atspi_accessible_clear_cache(desktop);
  Owned error;
  const gint count = atspi_accessible_get_child_count(desktop, error.out());
  if (error.error || count < 0) {
    note_error("desktop_count", error.error);
    g_object_unref(desktop);
    // A slow or restarting registry (NoReply, ServiceUnknown) is a failed read:
    // libatspi re-registers it when its well-known name reappears. Only a
    // dropped connection to the accessibility bus is unrecoverable.
    return a11y_connection_alive() ? Lookup::Failed : Lookup::BusLost;
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
    const guint child_pid = atspi_accessible_get_process_id(child, error.out());
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

} // namespace foresight::zoom
