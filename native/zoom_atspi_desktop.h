#pragma once
// The libatspi/GDBus implementation of the Linux desktop interfaces. Built only
// where libatspi and GIO development files exist; the helper's main() and a
// test main both construct it.
#include "zoom_atspi_collect.h"

#include <gio/gio.h>
#include <string>

// libdbus's connection type (the full definition stays out of this header).
struct DBusConnection;

namespace foresight::zoom {

class AtspiDesktop final : public LinuxDesktop, public AccessibleDesktop {
public:
  // `executable_name` is the basename of Zoom's main process (normally "zoom").
  explicit AtspiDesktop(std::string executable_name);
  ~AtspiDesktop() override;

  // Read-only and bounded; never initializes libatspi and never starts a
  // service.
  BusStatus bus_status() override;
  // The only function that sets anything on the desktop.
  bool enable_accessibility() override;
  ProcessScan zoom_processes() override;
  // Initializes libatspi on first use, then one bounded traversal.
  TreeRead read_tree(int pid, int budget_ms,
                     const std::function<bool()> &cancelled) override;
  uint64_t monotonic_ms() override;

  Lookup
  applications(int pid, const std::function<bool()> &cancelled,
               const std::function<bool()> &out_of_time,
               std::vector<std::unique_ptr<AccessibleNode>> &out) override;

private:
  BusStatus connect_session_bus();
  void drop_session_bus();
  bool ensure_atspi();
  void drain_events();
  // The connection libatspi opened to the accessibility bus is still up. Checks
  // the connection held since init, never atspi_get_a11y_bus() (which
  // reconnects).
  bool a11y_connection_alive() const;

  std::string executable_;
  GDBusConnection *bus_ = nullptr;
  bool atspi_ready_ = false;
  // Referenced when libatspi connected; liveness is checked on this connection.
  DBusConnection *a11y_connection_ = nullptr;
  std::string
      a11y_owner_; // unique name of org.a11y.Bus when libatspi connected
  std::string
      owner_seen_; // unique name of org.a11y.Bus at the last status check
  int init_failures_ = 0;
  int64_t next_init_ms_ = 0;
  ElementRegistry registry_;
};

// Bounded stderr diagnostics (stable tokens only), shared with main().
void note(const char *token);
void log_glib(const gchar *domain, GLogLevelFlags level, const gchar *,
              gpointer);

} // namespace foresight::zoom
