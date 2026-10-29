#include "zoom_atspi_collect.h"

#include <chrono>

namespace foresight::zoom {
namespace {

struct State {
  const CollectLimits &limits;
  const std::function<bool()> &cancelled;
  const std::function<bool()> &out_of_time;
  ElementRegistry &registry;
  size_t nodes = 0;
  int errors = 0;
  bool truncated = false;
  bool identity_missing = false;
  bool was_cancelled = false;
  bool stopped = false;

  // Polled before every remote call.
  bool should_stop() {
    if (stopped)
      return true;
    if (cancelled()) {
      was_cancelled = true;
    } else if (!out_of_time() && nodes < limits.max_nodes) {
      return false;
    }
    truncated = true;
    stopped = true;
    return true;
  }
  void fail() {
    truncated = true;
    if (++errors >= limits.max_errors)
      stopped = true;
  }
};

// Returns false only when the node's own child list could not be read.
bool collect(AccessibleNode &node, int depth, State &state, AxNode &out) {
  if (state.should_stop())
    return true;
  if (depth > state.limits.max_depth) {
    state.truncated =
        true; // too deep to read; siblings are still worth reading
    return true;
  }
  ++state.nodes;
  NodeProps props = node.read();
  if (props.identity.empty()) {
    state.identity_missing = true;
  } else {
    out.object_id = state.registry.id_for(props.identity);
    if (out.object_id == 0)
      state.identity_missing = true;
  }
  out.role = std::move(props.role);
  out.value = std::move(props.name);
  out.description = std::move(props.description);
  out.states = std::move(props.states);
  out.attributes = std::move(props.attributes);
  if (props.failed)
    state.fail();
  if (props.child_count < 0) {
    state.fail();
    return depth != 0;
  }
  for (int i = 0; i < props.child_count; ++i) {
    if (state.should_stop())
      break;
    std::unique_ptr<AccessibleNode> child = node.child(i);
    if (!child) {
      state.fail();
      continue;
    }
    out.children.emplace_back();
    collect(*child, depth + 1, state, out.children.back());
  }
  if (depth == 0 && props.child_count == 0)
    state.truncated = true; // an application with no windows proves nothing
  return true;
}

} // namespace

TreeRead read_zoom_tree(AccessibleDesktop &desktop, int pid,
                        const CollectLimits &limits, ElementRegistry &registry,
                        const std::function<bool()> &cancelled) {
  TreeRead read;
  const auto now = limits.now_ms ? limits.now_ms : std::function<int64_t()>([] {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  });
  const int64_t deadline = now() + limits.budget_ms;
  const std::function<bool()> out_of_time = [&] { return now() >= deadline; };

  std::vector<std::unique_ptr<AccessibleNode>> apps;
  switch (desktop.applications(pid, cancelled, out_of_time, apps)) {
  case Lookup::Ok:
    break;
  case Lookup::Cancelled:
    read.status = TreeRead::Status::Cancelled;
    return read;
  case Lookup::BusLost:
    read.status = TreeRead::Status::BusLost;
    return read;
  case Lookup::Failed:
    read.status = TreeRead::Status::Failed;
    return read;
  }
  if (apps.empty()) {
    read.status = TreeRead::Status::NotExposed;
    return read;
  }

  registry.begin_read();
  State state{limits, cancelled, out_of_time, registry};
  bool readable = true;
  for (auto &app : apps)
    app->drop_cache();
  if (apps.size() == 1) {
    readable = collect(*apps[0], 0, state, read.snapshot.root);
  } else {
    // Several applications of one process: one synthetic root holds all
    // windows.
    read.snapshot.root.role = "application";
    for (auto &app : apps) {
      AxNode one;
      readable = collect(*app, 0, state, one) && readable;
      for (AxNode &window : one.children)
        read.snapshot.root.children.push_back(std::move(window));
    }
  }
  read.snapshot.truncated = state.truncated;
  read.identity_incomplete = state.identity_missing;
  registry.end_read(readable && !state.truncated);
  if (state.was_cancelled)
    read.status = TreeRead::Status::Cancelled;
  else
    read.status = readable ? TreeRead::Status::Ok : TreeRead::Status::Failed;
  return read;
}

} // namespace foresight::zoom
