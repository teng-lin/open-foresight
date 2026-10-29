#pragma once
// Bounded traversal of an accessibility tree behind a thin node interface, so
// the limits, failure accounting and cancellation run against a fake tree
// without libatspi, a session bus or Zoom. zoom_observer_linux.cpp implements
// the interface over libatspi.
#include "zoom_linux_source.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace foresight::zoom {

inline constexpr int kMaxCallErrors = 3;
inline constexpr size_t kMaxStatesPerNode = 64;
inline constexpr size_t kMaxAttributesPerNode = 64;

// One node's own properties. `failed` is set when any property call failed or
// returned something unusable (an error, a missing attribute table, a state set
// holding only `defunct`); `child_count` is -1 when it could not be read.
struct NodeProps {
  std::string identity; // bus name plus object path; empty when unknown
  std::string role, name, description;
  std::set<std::string> states;
  std::map<std::string, std::string> attributes;
  bool failed = false;
  int child_count = 0;
};

class AccessibleNode {
public:
  virtual ~AccessibleNode() = default;
  // `interrupted` is polled before every remote call; once it reports true the
  // read returns what it has with `failed` set, so one node's several calls
  // cannot run on far past the budget or a cancellation.
  virtual NodeProps read(const std::function<bool()> &interrupted) = 0;
  // Null when the child cannot be fetched.
  virtual std::unique_ptr<AccessibleNode> child(int index) = 0;
  // Discards client-side cached values so the next read reflects live state.
  virtual void drop_cache() {}
};

enum class Lookup { Ok, Failed, Cancelled, BusLost };

class AccessibleDesktop {
public:
  virtual ~AccessibleDesktop() = default;
  // Every accessible application owned by `pid`. `stop` is polled between
  // remote calls; a stop that is a cancellation returns Cancelled, a spent
  // budget Failed.
  virtual Lookup
  applications(int pid, const std::function<bool()> &cancelled,
               const std::function<bool()> &out_of_time,
               std::vector<std::unique_ptr<AccessibleNode>> &out) = 0;
};

struct CollectLimits {
  int budget_ms = kLinuxReadBudgetMs;
  size_t max_nodes = kMaxNodes;
  int max_depth = kMaxDepth;
  int max_errors = kMaxCallErrors;
  // Milliseconds on any steady clock; defaults to std::chrono::steady_clock.
  std::function<int64_t()> now_ms;
};

// Reads the accessibility tree of the Zoom application(s) of `pid`. The tree is
// a single AxNode root: the application, or for several applications of one
// process a synthetic root holding all their windows. Any bound hit, failed
// call, unreadable zero-window application or cancellation sets `truncated`.
TreeRead read_zoom_tree(AccessibleDesktop &desktop, int pid,
                        const CollectLimits &limits, ElementRegistry &registry,
                        const std::function<bool()> &cancelled);

} // namespace foresight::zoom
