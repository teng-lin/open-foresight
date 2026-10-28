#pragma once
// Platform-independent half of the Zoom speaker observer helper: the NDJSON
// wire protocol from docs/architecture/speaker-observer-protocol.md, the
// polling session, and participant reference assignment. The operating-system
// side supplies a Source; nothing here touches the Accessibility API.
#include "zoom_ax_parser.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace foresight::zoom {

inline constexpr int kProtocolVersion = 1;
inline constexpr size_t kMaxLineBytes = 262144;
inline constexpr int kDefaultPollMs = 500;
inline constexpr int kMinPollMs = 100;
inline constexpr int kMaxPollMs = 5000;
inline constexpr int kDefaultDeadlineMs = 2000;
inline constexpr int kMinDeadlineMs = 100;
inline constexpr int kMaxDeadlineMs = 30000;

// Wire `capabilities` state tokens.
struct Capabilities {
  std::string state;
  std::string reason;
  std::string zoom_version;
  std::string locale;
};

// One passive snapshot attempt. When `ok` is false, `state` is the capability
// state that explains why (for example zoom_not_running or permission_denied,
// or `unavailable` for a failed read) and `reason` a stable token.
struct SnapshotOutcome {
  bool ok = false;
  std::string state;
  std::string reason;
  int pid = 0;
  std::string zoom_version;
  uint64_t read_start_ms = 0;
  uint64_t read_end_ms = 0;
  // The installed Zoom's preferred localization has no pattern set; used only
  // to explain a snapshot that yields no evidence.
  bool locale_unsupported = false;
  AxSnapshot snapshot;
};

class Source {
public:
  virtual ~Source() = default;
  // Explicit setup: may prompt the user. Invoked only for a `setup` request.
  virtual void request_access() = 0;
  // Read and report. Must never prompt, activate Zoom or change its state.
  // `cancelled` is polled between accessibility calls.
  virtual SnapshotOutcome snapshot(const std::function<bool()> &cancelled) = 0;
  // Thread-safe clocks. `monotonic_ms` is the protocol clock domain
  // (mach_continuous_time on macOS); `uptime_ms` excludes system sleep.
  virtual uint64_t monotonic_ms() = 0;
  virtual uint64_t uptime_ms() = 0;
};

struct ObserverConfig {
  std::string helper = "zoom_observer_macos";
  std::string helper_version = "1";
  std::string platform = "macos";
  int in_fd = 0;
  int out_fd = 1;
  int err_fd = 2;
};

// Map one snapshot outcome onto the wire capability description.
Capabilities describe_capabilities(const SnapshotOutcome &outcome);

// Runs the protocol until stop, stdin close or a protocol error. Returns the
// process exit code: 0 for stop or end of input, 2 for a protocol error.
int run_observer(Source &source, const ObserverConfig &config);

} // namespace foresight::zoom
