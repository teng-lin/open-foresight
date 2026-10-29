#include "zoom_linux_source.h"

namespace foresight::zoom {
namespace {

SnapshotOutcome refused(const char *state, const char *reason) {
  SnapshotOutcome outcome;
  outcome.state = state;
  outcome.reason = reason;
  return outcome;
}

} // namespace

void LinuxSource::request_access() {
  setup_attempted_ = true;
  desktop_.enable_accessibility();
}

SnapshotOutcome LinuxSource::snapshot(const std::function<bool()> &cancelled) {
  const uint64_t start = desktop_.monotonic_ms();
  switch (desktop_.bus_status()) {
  case BusStatus::Ready:
    seen_ready_ = true;
    break;
  case BusStatus::BusLost:
    return refused("unavailable", "atspi_bus_lost");
  case BusStatus::NoSessionBus:
    return refused("unavailable", "no_session_bus");
  case BusStatus::SessionBusUnreachable:
    return refused("unavailable", "session_bus_unreachable");
  case BusStatus::A11yBusAbsent:
    return refused("needs_setup", "atspi_bus_absent");
  case BusStatus::StatusUnreadable:
    return refused("unavailable", "atspi_status_unreadable");
  case BusStatus::Disabled:
    // As on macOS: once setup was requested, or a grant was seen and lost, the
    // state is permission_denied rather than needs_setup.
    if (setup_attempted_)
      return refused("permission_denied", "setup_not_effective");
    if (seen_ready_)
      return refused("permission_denied", "accessibility_lost");
    return refused("needs_setup", "accessibility_disabled");
  }
  const ProcessScan scan = desktop_.zoom_processes();
  if (!scan.ok)
    return refused("unavailable", "process_scan_failed");
  const std::vector<ZoomProcess> &processes = scan.processes;
  if (processes.empty())
    return refused("zoom_not_running", "zoom_not_running");
  if (processes.size() > 1)
    return refused("unavailable", "ambiguous_processes");

  SnapshotOutcome outcome;
  outcome.pid = processes[0].pid;
  outcome.zoom_version = processes[0].version;
  // Gate on the build before reading anything: rules apply to validated builds.
  if (!rules_.roster.enabled) {
    outcome.state = "unsupported_version";
    outcome.reason = "no_validated_rules";
    return outcome;
  }
  if (processes[0].version.empty()) {
    outcome.state = "unavailable";
    outcome.reason = "version_unreadable";
    return outcome;
  }
  if (!rules_.zoom_versions.contains(processes[0].version)) {
    outcome.state = "unsupported_version";
    outcome.reason = "zoom_version_unsupported";
    return outcome;
  }

  TreeRead read =
      desktop_.read_tree(outcome.pid, kLinuxReadBudgetMs, cancelled);
  outcome.read_start_ms = start;
  outcome.read_end_ms = desktop_.monotonic_ms();
  switch (read.status) {
  case TreeRead::Status::NotExposed:
    outcome.state = "unavailable";
    outcome.reason = "zoom_not_exposed";
    return outcome;
  case TreeRead::Status::Failed:
    outcome.state = "unavailable";
    outcome.reason = "ax_read_failed";
    return outcome;
  case TreeRead::Status::Cancelled:
    outcome.state = "unavailable";
    outcome.reason = "read_cancelled";
    return outcome;
  case TreeRead::Status::Unreachable:
    outcome.state = "unavailable";
    outcome.reason = "atspi_unreachable";
    return outcome;
  case TreeRead::Status::BusLost:
    outcome.state = "unavailable";
    outcome.reason = "atspi_bus_lost";
    return outcome;
  case TreeRead::Status::Ok:
    break;
  }
  outcome.ok = true;
  outcome.identity_incomplete = read.identity_incomplete;
  outcome.snapshot = std::move(read.snapshot);
  return outcome;
}

} // namespace foresight::zoom
