// Bounded traversal contract over a fake accessibility tree: limits, failure
// accounting, cancellation, identity and cache freshness. No libatspi, session
// bus or Zoom is involved.
#include "zoom_atspi_collect.h"

#include <iostream>

using namespace foresight::zoom;

namespace {

int failures = 0;
int checks = 0;

void check(bool value, const std::string &what) {
  ++checks;
  if (!value) {
    std::cerr << "FAIL: " << what << '\n';
    ++failures;
  }
}

struct Counters {
  int reads = 0, children = 0, cache_drops = 0;
  int calls_per_read = 1; // remote calls one node's read makes
  int64_t clock_ms = 0;
};

// A tree described by data, so tests can mutate it between polls.
struct Spec {
  std::string identity, role = "r", name;
  std::set<std::string> states;
  std::map<std::string, std::string> attributes;
  bool failed = false;
  int reported_children = -1; // overrides children.size() when >= 0
  std::vector<Spec> children;
  bool child_fetch_fails = false; // fetching *this* node from its parent fails
};

class FakeNode final : public AccessibleNode {
public:
  FakeNode(const Spec &spec, Counters &counters, int64_t read_cost_ms)
      : spec_(spec), counters_(counters), cost_(read_cost_ms) {}
  NodeProps read(const std::function<bool()> &interrupted) override {
    ++counters_.reads;
    // A real node polls this before each of its remote calls.
    for (int call = 0; call < counters_.calls_per_read; ++call) {
      if (interrupted()) {
        NodeProps cut;
        cut.identity = spec_.identity;
        cut.failed = true;
        return cut;
      }
      counters_.clock_ms += cost_ / counters_.calls_per_read;
    }
    NodeProps props;
    props.identity = spec_.identity;
    props.role = spec_.role;
    props.name = spec_.name;
    props.states = spec_.states;
    props.attributes = spec_.attributes;
    props.failed = spec_.failed;
    props.child_count = spec_.reported_children >= 0
                            ? spec_.reported_children
                            : static_cast<int>(spec_.children.size());
    return props;
  }
  std::unique_ptr<AccessibleNode> child(int index) override {
    ++counters_.children;
    if (index >= static_cast<int>(spec_.children.size()) ||
        spec_.children[static_cast<size_t>(index)].child_fetch_fails)
      return nullptr;
    return std::make_unique<FakeNode>(
        spec_.children[static_cast<size_t>(index)], counters_, cost_);
  }
  void drop_cache() override {
    ++counters_.cache_drops;
  }

private:
  const Spec &spec_;
  Counters &counters_;
  int64_t cost_;
};

class FakeDesktop final : public AccessibleDesktop {
public:
  explicit FakeDesktop(Counters &counters, int64_t read_cost_ms = 0)
      : counters_(counters), cost_(read_cost_ms) {}
  Lookup
  applications(int pid, const std::function<bool()> &cancelled,
               const std::function<bool()> &,
               std::vector<std::unique_ptr<AccessibleNode>> &out) override {
    last_pid = pid;
    if (lookup != Lookup::Ok)
      return lookup;
    if (cancelled())
      return Lookup::Cancelled;
    for (const Spec &app : apps)
      out.push_back(std::make_unique<FakeNode>(app, counters_, cost_));
    return Lookup::Ok;
  }
  std::vector<Spec> apps;
  Lookup lookup = Lookup::Ok;
  int last_pid = 0;

private:
  Counters &counters_;
  int64_t cost_;
};

Spec leaf(const std::string &identity, const std::string &name = "") {
  Spec spec;
  spec.identity = identity;
  spec.name = name;
  return spec;
}

Spec app_with(std::vector<Spec> windows) {
  Spec app;
  app.identity = ":1.1/root";
  app.role = "application";
  app.children = std::move(windows);
  return app;
}

CollectLimits limits_for(Counters &counters, int budget_ms = 1000) {
  CollectLimits limits;
  limits.budget_ms = budget_ms;
  limits.now_ms = [&counters] { return counters.clock_ms; };
  return limits;
}

const std::function<bool()> never = [] { return false; };

void mapping_and_identity() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec window = leaf(":1.1/w", "Synthetic Window");
  window.states = {"showing", "active"};
  window.attributes = {{"k", "v"}};
  window.children = {leaf(":1.1/a", "A"), leaf(":1.1/b", "B")};
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  TreeRead read =
      read_zoom_tree(desktop, 77, limits_for(counters), registry, never);
  check(read.status == TreeRead::Status::Ok && !read.snapshot.truncated &&
            !read.identity_incomplete,
        "a clean read is Ok and complete");
  check(desktop.last_pid == 77, "the pid is forwarded");
  const AxNode &root = read.snapshot.root;
  check(root.role == "application" && root.children.size() == 1 &&
            root.children[0].value == "Synthetic Window" &&
            root.children[0].states.count("active") &&
            root.children[0].attributes.at("k") == "v" &&
            root.children[0].children.size() == 2,
        "role, name, states, attributes and children are mapped");
  const uint64_t a = root.children[0].children[0].object_id;
  check(a != 0 && a != root.children[0].children[1].object_id,
        "elements get distinct non-zero ids");

  // Cache freshness: every poll drops the client cache and re-reads live state.
  const int drops = counters.cache_drops;
  desktop.apps[0].children[0].children[0].states = {"showing"};
  desktop.apps[0].children[0].children[0].name = "A renamed";
  TreeRead second =
      read_zoom_tree(desktop, 77, limits_for(counters), registry, never);
  check(counters.cache_drops == drops + 1,
        "each poll drops the cache once per application");
  check(second.snapshot.root.children[0].children[0].value == "A renamed" &&
            second.snapshot.root.children[0].children[0].object_id == a,
        "the second poll reflects live changes and keeps the element id");
  desktop.apps[0].children[0].states = {"showing"};
  TreeRead third =
      read_zoom_tree(desktop, 77, limits_for(counters), registry, never);
  check(!third.snapshot.root.children[0].states.count("active"),
        "a toggled state is seen on the next poll");
}

void lookup_outcomes() {
  Counters counters;
  FakeDesktop desktop(counters);
  ElementRegistry registry;
  const struct {
    Lookup lookup;
    TreeRead::Status status;
  } cases[] = {{Lookup::Failed, TreeRead::Status::Failed},
               {Lookup::Cancelled, TreeRead::Status::Cancelled},
               {Lookup::BusLost, TreeRead::Status::BusLost}};
  for (const auto &c : cases) {
    desktop.lookup = c.lookup;
    check(read_zoom_tree(desktop, 1, limits_for(counters), registry, never)
                  .status == c.status,
          "lookup outcome maps to the matching status");
  }
  desktop.lookup = Lookup::Ok; // no applications at all: Zoom is not on the bus
  check(read_zoom_tree(desktop, 1, limits_for(counters), registry, never)
                .status == TreeRead::Status::NotExposed,
        "no application for the pid is NotExposed");
}

void node_limit() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec window = leaf(":1.1/w");
  for (int i = 0; i < 200; ++i)
    window.children.push_back(leaf(":1.1/c" + std::to_string(i)));
  desktop.apps = {app_with({window})};
  CollectLimits limits = limits_for(counters);
  limits.max_nodes = 10;
  ElementRegistry registry;
  TreeRead read = read_zoom_tree(desktop, 1, limits, registry, never);
  check(read.status == TreeRead::Status::Ok && read.snapshot.truncated,
        "the node limit truncates");
  check(counters.reads == 10, "no node is read past the limit");
  check(counters.children <= 11, "no child is fetched past the limit");
}

void depth_limit() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec chain = leaf(":1.1/d0");
  Spec *tail = &chain;
  for (int i = 1; i < 30; ++i) {
    tail->children.push_back(leaf(":1.1/d" + std::to_string(i)));
    tail = &tail->children.back();
  }
  desktop.apps = {app_with({chain})};
  CollectLimits limits = limits_for(counters);
  limits.max_depth = 5;
  ElementRegistry registry;
  TreeRead read = read_zoom_tree(desktop, 1, limits, registry, never);
  check(read.snapshot.truncated, "a tree deeper than the limit is truncated");
  check(counters.reads <= 6, "nodes below the depth limit are not read");
}

void deadline() {
  Counters counters;
  FakeDesktop desktop(counters, /*read_cost_ms=*/100);
  Spec window = leaf(":1.1/w");
  for (int i = 0; i < 50; ++i)
    window.children.push_back(leaf(":1.1/c" + std::to_string(i)));
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  TreeRead read = read_zoom_tree(
      desktop, 1, limits_for(counters, /*budget_ms=*/450), registry, never);
  check(read.snapshot.truncated && read.status == TreeRead::Status::Ok,
        "the time budget truncates");
  check(counters.reads <= 6, "no node is read after the budget is spent");
  check(counters.children <= 6,
        "no child is fetched after the budget is spent");
}

// One node's read makes several remote calls; the budget is checked before
// each, so a slow application overruns it by at most one call, not one whole
// node.
void budget_between_calls_of_one_node() {
  Counters counters;
  counters.calls_per_read = 6;
  FakeDesktop desktop(counters,
                      /*read_cost_ms=*/6 * 250); // six 250 ms calls per node
  Spec window = leaf(":1.1/w");
  window.children = {leaf(":1.1/a"), leaf(":1.1/b")};
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  CollectLimits limits = limits_for(counters, /*budget_ms=*/600);
  const int64_t start = counters.clock_ms;
  TreeRead read = read_zoom_tree(desktop, 1, limits, registry, never);
  check(read.snapshot.truncated, "an overrun budget truncates");
  check(counters.clock_ms - start <= 600 + 250,
        "the overrun is at most one call");
  check(counters.reads <= 2,
        "no second node is started once the budget is spent");

  Counters c2;
  c2.calls_per_read = 6;
  FakeDesktop d2(c2, 6 * 10);
  d2.apps = {app_with({leaf(":1.1/w")})};
  ElementRegistry r2;
  int polls = 0;
  read_zoom_tree(d2, 1, limits_for(c2, 1000), r2, [&] { return ++polls > 3; });
  check(c2.reads == 1 && polls < 12,
        "cancellation is polled between the calls of one node too");
}

void call_errors() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec window = leaf(":1.1/w");
  for (int i = 0; i < 20; ++i) {
    Spec child = leaf(":1.1/c" + std::to_string(i));
    child.child_fetch_fails = true;
    window.children.push_back(child);
  }
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  TreeRead read =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  check(read.snapshot.truncated, "failed child fetches truncate the read");
  check(counters.children == 1 + kMaxCallErrors,
        "traversal stops after the error limit");

  // A node whose property reads failed (error, defunct-only state set, missing
  // attribute table) counts as an error and is never trusted as complete.
  Counters c2;
  FakeDesktop d2(c2);
  Spec bad = leaf(":1.1/w");
  bad.failed = true;
  d2.apps = {app_with({bad})};
  ElementRegistry r2;
  TreeRead failed_props = read_zoom_tree(d2, 1, limits_for(c2), r2, never);
  check(failed_props.snapshot.truncated,
        "a node with failed property reads truncates the read");
}

void cancellation() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec window = leaf(":1.1/w");
  for (int i = 0; i < 50; ++i)
    window.children.push_back(leaf(":1.1/c" + std::to_string(i)));
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  TreeRead read = read_zoom_tree(desktop, 1, limits_for(counters), registry,
                                 [&] { return counters.reads >= 5; });
  check(read.status == TreeRead::Status::Cancelled && read.snapshot.truncated,
        "cancellation mid-read reports Cancelled");
  check(counters.reads == 5, "no node is read after cancellation");

  Counters c2;
  FakeDesktop d2(c2);
  d2.apps = {app_with({leaf(":1.1/w")})};
  ElementRegistry r2;
  check(read_zoom_tree(d2, 1, limits_for(c2), r2, [] { return true; }).status ==
            TreeRead::Status::Cancelled,
        "cancellation before the first call reports Cancelled");
  check(c2.reads == 0, "nothing is read when already cancelled");
}

void empty_root() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec bare = leaf(":1.1/root");
  bare.role = "application";
  desktop.apps = {bare};
  ElementRegistry registry;
  TreeRead empty =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  check(empty.status == TreeRead::Status::Ok && empty.snapshot.truncated,
        "an application with no windows is an incomplete read, never proof of "
        "absence");
}

class UnreadableRoot final : public AccessibleNode {
public:
  NodeProps read(const std::function<bool()> &) override {
    NodeProps props;
    props.identity = ":1.1/root";
    props.child_count = -1;
    return props;
  }
  std::unique_ptr<AccessibleNode> child(int) override {
    return nullptr;
  }
};

class OneRootDesktop final : public AccessibleDesktop {
public:
  Lookup
  applications(int, const std::function<bool()> &,
               const std::function<bool()> &,
               std::vector<std::unique_ptr<AccessibleNode>> &out) override {
    out.push_back(std::make_unique<UnreadableRoot>());
    return Lookup::Ok;
  }
};

void root_child_count_failure() {
  OneRootDesktop desktop;
  Counters counters;
  ElementRegistry registry;
  TreeRead read =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  check(read.status == TreeRead::Status::Failed,
        "an application whose child list cannot be read is Failed");
}

void missing_identity_and_several_applications() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec window = leaf("");
  window.children = {leaf(":1.1/a", "A")};
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  TreeRead read =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  check(read.identity_incomplete &&
            read.snapshot.root.children[0].object_id == 0,
        "an element without identity is reported");

  Counters c2;
  FakeDesktop d2(c2);
  Spec second = app_with({leaf(":1.2/w2", "Second")});
  second.identity = ":1.2/root";
  d2.apps = {app_with({leaf(":1.1/w1", "First")}), second};
  ElementRegistry r2;
  TreeRead both = read_zoom_tree(d2, 1, limits_for(c2), r2, never);
  check(both.snapshot.root.children.size() == 2 &&
            both.snapshot.root.children[0].value == "First" &&
            both.snapshot.root.children[1].value == "Second" &&
            !both.snapshot.truncated,
        "several applications of one process are read together");
  Counters c3;
  FakeDesktop d3(c3);
  Spec broken = app_with({leaf(":1.2/w2")});
  broken.children[0].failed = true;
  d3.apps = {app_with({leaf(":1.1/w1")}), broken};
  ElementRegistry r3;
  check(read_zoom_tree(d3, 1, limits_for(c3), r3, never).snapshot.truncated,
        "an error in any application makes the union incomplete");
}

void registry_policy() {
  Counters counters;
  FakeDesktop desktop(counters);
  Spec window = leaf(":1.1/w");
  window.children = {leaf(":1.1/a", "A"), leaf(":1.1/b", "B")};
  desktop.apps = {app_with({window})};
  ElementRegistry registry;
  TreeRead first =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  const uint64_t a = first.snapshot.root.children[0].children[0].object_id;
  const uint64_t b = first.snapshot.root.children[0].children[1].object_id;

  // A truncated read that never reaches element b must not forget it.
  CollectLimits tight = limits_for(counters);
  tight.max_nodes = 3;
  TreeRead cut = read_zoom_tree(desktop, 1, tight, registry, never);
  check(cut.snapshot.truncated, "the cut read is truncated");
  TreeRead after =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  check(after.snapshot.root.children[0].children[0].object_id == a &&
            after.snapshot.root.children[0].children[1].object_id == b,
        "ids survive a truncated read in between");

  // A complete read that no longer shows b drops it; its return gets a new id.
  desktop.apps[0].children[0].children.pop_back();
  read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  desktop.apps[0].children[0].children.push_back(leaf(":1.1/b", "B"));
  TreeRead back =
      read_zoom_tree(desktop, 1, limits_for(counters), registry, never);
  const uint64_t b2 = back.snapshot.root.children[0].children[1].object_id;
  check(b2 != b && b2 != 0,
        "an element that left in a complete read returns with a new id");

  // Capacity: at the bound a new identity is unknown, never a reused id.
  ElementRegistry small(2);
  small.begin_read();
  check(small.id_for("x") != 0 && small.id_for("y") != 0 &&
            small.id_for("z") == 0,
        "a full registry reports unknown identity");
  small.end_read(true);
}

} // namespace

int main() {
  mapping_and_identity();
  lookup_outcomes();
  node_limit();
  depth_limit();
  deadline();
  call_errors();
  budget_between_calls_of_one_node();
  cancellation();
  empty_root();
  root_child_count_failure();
  missing_identity_and_several_applications();
  registry_policy();
  std::cout << "zoom_atspi_collect: " << checks << " checks, " << failures
            << " failures\n";
  return failures == 0 ? 0 : 1;
}
