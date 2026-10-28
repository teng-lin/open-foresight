#include "zoom_mac_source.h"

#include <algorithm>

namespace foresight::zoom {
namespace {

void gate(SnapshotOutcome &outcome, const char *state, const char *reason) {
  outcome.ok = false;
  outcome.state = state;
  outcome.reason = reason;
}

} // namespace

void ZoomMacSource::request_access() {
  setup_requested_ = true;
  if (environment_.accessibility_trusted(true))
    trusted_before_ = true;
}

SnapshotOutcome
ZoomMacSource::snapshot(const std::function<bool()> &cancelled) {
  SnapshotOutcome outcome;
  outcome.read_start_ms = environment_.monotonic_ms();
  read(outcome, cancelled);
  outcome.read_end_ms =
      std::max(environment_.monotonic_ms(), outcome.read_start_ms);
  return outcome;
}

void ZoomMacSource::read(SnapshotOutcome &outcome,
                         const std::function<bool()> &cancelled) {
  if (!environment_.os_supported()) {
    gate(outcome, "unsupported_platform", "macos_15_required");
    return;
  }
  std::vector<ZoomInstance> instances = environment_.instances();
  if (instances.empty()) {
    gate(outcome, "zoom_not_running", "zoom_not_running");
    return;
  }
  if (instances.size() > 1) {
    // Several candidate processes are never combined.
    gate(outcome, "unavailable", "ambiguous_processes");
    return;
  }
  const ZoomInstance &zoom = instances.front();
  outcome.pid = zoom.pid;
  if (!zoom.version_readable) {
    gate(outcome, "unsupported_version", "version_unreadable");
    return;
  }
  outcome.zoom_version = zoom.version;
  if (!zoom_version_supported(zoom.version)) {
    gate(outcome, "unsupported_version", "zoom_version_unsupported");
    return;
  }
  outcome.locale_unsupported =
      !zoom.localization.empty() && !locale_supported(zoom.localization);

  if (!environment_.accessibility_trusted(false)) {
    gate(outcome,
         trusted_before_ || setup_requested_ ? "permission_denied"
                                             : "needs_setup",
         "accessibility_not_trusted");
    return;
  }
  trusted_before_ = true;

  if (!reader_.begin(zoom.pid)) {
    // Without a messaging timeout a wedged Zoom could stall every read.
    gate(outcome, "unavailable", "ax_timeout_unavailable");
    return;
  }
  registry_.begin_read();
  CollectResult collected =
      collect_application(reader_, registry_, cancelled, limits_, now_);
  registry_.end_read(!collected.snapshot.truncated && !collected.cancelled &&
                     !collected.trust_lost && !collected.windows_failed);
  reader_.end();
  if (collected.trust_lost) {
    gate(outcome, "permission_denied", "accessibility_not_trusted");
    return;
  }
  if (collected.cancelled) {
    gate(outcome, "unavailable", "read_cancelled");
    return;
  }
  if (collected.windows_failed) {
    gate(outcome, "unavailable", "ax_read_failed");
    return;
  }
  outcome.snapshot = std::move(collected.snapshot);
  outcome.identity_incomplete = collected.identity_incomplete;
  outcome.ok = true;
}

} // namespace foresight::zoom
