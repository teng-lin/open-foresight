#pragma once
// The Linux Source for the shared observer core: the gate order from the
// desktop accessibility stack down to one bounded tree read, over a
// LinuxDesktop interface so the logic runs without a session bus, AT-SPI or
// Zoom. The libatspi/GDBus implementation of LinuxDesktop lives in
// zoom_observer_linux.cpp.
#include "zoom_atspi_parser.h"
#include "zoom_observer_core.h"

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace foresight::zoom {

// Per-read budget and per-call timeout, as for the macOS helper.
inline constexpr int kLinuxReadBudgetMs = 1500;
inline constexpr int kLinuxCallTimeoutMs = 250;
// Longest accessible string the collector keeps; the parser rejects names over
// kMaxNameBytes, so one byte more is enough to prove a name oversize.
inline constexpr size_t kMaxCollectedBytes = kMaxNameBytes + 1;

enum class BusStatus {
  Ready,
  NoSessionBus,
  SessionBusUnreachable,
  A11yBusAbsent,
  StatusUnreadable,
  Disabled,
  // The accessibility bus or registry went away after libatspi connected.
  BusLost,
};

struct ZoomProcess {
  int pid = 0;
  std::string version; // empty when unknown
};

struct ProcessScan {
  // False when /proc could not be listed: an unknown, not an absent, Zoom.
  bool ok = true;
  std::vector<ZoomProcess> processes;
};

struct TreeRead {
  enum class Status {
    Ok,
    NotExposed,
    Failed,
    Cancelled,
    BusLost,
    // libatspi could not be initialized against the accessibility bus.
    Unreachable
  } status = Status::Failed;
  AxSnapshot snapshot;
  // An element's identity could not be established.
  bool identity_incomplete = false;
};

class LinuxDesktop {
public:
  virtual ~LinuxDesktop() = default;
  // Read-only: never activates a service or changes a setting.
  virtual BusStatus bus_status() = 0;
  // Explicit setup only: enables desktop accessibility support.
  virtual void enable_accessibility() = 0;
  virtual ProcessScan zoom_processes() = 0;
  // One bounded traversal of the application owning `pid`.
  virtual TreeRead read_tree(int pid, int budget_ms,
                             const std::function<bool()> &cancelled) = 0;
  virtual uint64_t monotonic_ms() = 0; // CLOCK_MONOTONIC
};

// Stable small integers for AT-SPI object identities. Ids are never reused.
// Unseen entries are dropped only after a complete read: a truncated, failed or
// cancelled read says nothing about elements it did not reach, and forgetting
// them would hand their owners new references. The table is bounded; at
// capacity a new identity gets 0 (unknown), which the caller reports as
// incomplete.
class ElementRegistry {
public:
  explicit ElementRegistry(size_t capacity = 2 * kMaxNodes)
      : capacity_(capacity) {}
  void begin_read() {
    ++generation_;
  }
  uint64_t id_for(const std::string &identity) {
    auto found = ids_.find(identity);
    if (found == ids_.end()) {
      if (ids_.size() >= capacity_)
        return 0;
      found = ids_.emplace(identity, Entry{++next_, generation_}).first;
    }
    found->second.seen = generation_;
    return found->second.id;
  }
  void end_read(bool complete) {
    if (!complete)
      return;
    for (auto it = ids_.begin(); it != ids_.end();)
      it = it->second.seen == generation_ ? std::next(it) : ids_.erase(it);
  }
  size_t size() const {
    return ids_.size();
  }

private:
  struct Entry {
    uint64_t id;
    uint64_t seen;
  };
  std::map<std::string, Entry> ids_;
  size_t capacity_;
  uint64_t generation_ = 0;
  uint64_t next_ = 0;
};

class LinuxSource final : public Source {
public:
  LinuxSource(LinuxDesktop &desktop, const RuleSet &rules)
      : desktop_(desktop), rules_(rules) {}

  void request_access() override;
  SnapshotOutcome snapshot(const std::function<bool()> &cancelled) override;
  uint64_t monotonic_ms() override {
    return desktop_.monotonic_ms();
  }
  // CLOCK_MONOTONIC does not count system sleep, so it is its own uptime.
  uint64_t uptime_ms() override {
    return desktop_.monotonic_ms();
  }

private:
  LinuxDesktop &desktop_;
  const RuleSet &rules_;
  bool setup_attempted_ = false;
  // Accessibility was seen enabled at some point; losing it is not a first run.
  bool seen_ready_ = false;
};

} // namespace foresight::zoom
