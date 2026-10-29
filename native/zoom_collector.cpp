#include "zoom_collector.h"

#include <algorithm>

namespace foresight::zoom {

ElementRegistry::~ElementRegistry() {
  for (auto &entry : entries_)
    reader_.release(entry.element);
}

uint64_t ElementRegistry::identify(ElementToken element) {
  for (auto &entry : entries_)
    if (reader_.same(entry.element, element)) {
      entry.seen = read_;
      return entry.id;
    }
  if (entries_.size() >= capacity_)
    return 0;
  entries_.push_back({reader_.retain(element), ++counter_, read_});
  return counter_;
}

void ElementRegistry::end_read(bool read_completed) {
  if (!read_completed || entries_.size() < capacity_ / 2)
    return;
  std::vector<Entry> kept;
  for (auto &entry : entries_) {
    if (entry.seen == read_)
      kept.push_back(entry);
    else
      reader_.release(entry.element);
  }
  entries_.swap(kept);
}

namespace {

class Collector {
public:
  Collector(AxReader &reader, ElementRegistry &registry,
            const std::function<bool()> &cancelled,
            const CollectorLimits &limits, SteadyNow now)
      : reader_(reader), registry_(registry), cancelled_(cancelled),
        limits_(limits), now_(now ? std::move(now) : [] {
          return std::chrono::steady_clock::now();
        }) {
    deadline_ = now_() + limits_.budget;
  }

  CollectResult run() {
    CollectResult result;
    result.snapshot.root.role = "AXApplication";
    std::vector<ElementToken> windows;
    switch (reader_.windows(windows)) {
    case AttrStatus::Ok:
    case AttrStatus::Absent: // an application with no windows
      break;
    case AttrStatus::Disabled:
      trust_lost_ = true;
      truncated_ = true;
      break;
    case AttrStatus::Failed:
      windows_failed_ = true;
      truncated_ = true;
      break;
    }
    for (ElementToken window : windows) {
      if (!admit(1))
        break;
      result.snapshot.root.children.emplace_back();
      read_into(window, 1, result.snapshot.root.children.back());
    }
    result.snapshot.truncated = truncated_;
    result.trust_lost = trust_lost_;
    result.cancelled = cancelled_hit_;
    result.windows_failed = windows_failed_;
    result.identity_incomplete = identity_incomplete_;
    result.nodes = nodes_;
    return result;
  }

private:
  // Counts one node against the limits. After any limit or cancellation no
  // further node is created or read.
  bool admit(int depth) {
    if (limit_hit_ || cancelled_hit_)
      return false;
    if (cancelled_()) {
      cancelled_hit_ = true;
      return false;
    }
    if (depth > limits_.max_depth || nodes_ >= limits_.max_nodes ||
        now_() > deadline_) {
      limit_hit_ = true;
      truncated_ = true;
      return false;
    }
    ++nodes_;
    return true;
  }

  void fail(AttrStatus status) {
    if (status == AttrStatus::Disabled)
      trust_lost_ = true;
    truncated_ = true;
  }

  std::string text(const TextAttr &attribute) {
    switch (attribute.status) {
    case AttrStatus::Absent:
      return {};
    case AttrStatus::Failed:
    case AttrStatus::Disabled:
      fail(attribute.status);
      return {};
    case AttrStatus::Ok:
      break;
    }
    if (attribute.lossy || attribute.text.size() > limits_.max_string_bytes) {
      truncated_ = true; // not trusted as evidence
      return {};
    }
    return attribute.text;
  }

  void read_into(ElementToken element, int depth, AxNode &node) {
    NodeRead read = reader_.read(element);
    if (read.call != AttrStatus::Ok) {
      fail(read.call);
      return;
    }
    node.role = text(read.role);
    node.description = text(read.description);
    node.value = text(read.value);
    node.identifier = text(read.identifier);
    if (node.role.empty()) {
      // A node whose role cannot be read cannot be classified: its subtree is
      // unknown, not empty.
      truncated_ = true;
      return;
    }
    if (node.role == "AXWindow" || node.role == "AXTabGroup") {
      node.object_id = registry_.identify(element);
      if (node.object_id == 0)
        identity_incomplete_ = true;
    }
    if (read.foreign_child)
      truncated_ = true;
    switch (read.children_status) {
    case AttrStatus::Absent:
      return;
    case AttrStatus::Failed:
    case AttrStatus::Disabled:
      fail(read.children_status);
      return;
    case AttrStatus::Ok:
      break;
    }
    for (ElementToken child : read.children) {
      if (!admit(depth + 1))
        return;
      node.children.emplace_back();
      read_into(child, depth + 1, node.children.back());
    }
  }

  AxReader &reader_;
  ElementRegistry &registry_;
  const std::function<bool()> &cancelled_;
  CollectorLimits limits_;
  SteadyNow now_;
  std::chrono::steady_clock::time_point deadline_;
  size_t nodes_ = 0;
  bool truncated_ = false;
  bool limit_hit_ = false;
  bool trust_lost_ = false;
  bool cancelled_hit_ = false;
  bool windows_failed_ = false;
  bool identity_incomplete_ = false;
};

} // namespace

CollectResult collect_application(AxReader &reader, ElementRegistry &registry,
                                  const std::function<bool()> &cancelled,
                                  const CollectorLimits &limits,
                                  SteadyNow now) {
  return Collector(reader, registry, cancelled, limits, std::move(now)).run();
}

} // namespace foresight::zoom
