// Gates, traversal rules and identity of the macOS source, driven by a fake
// environment and a fake accessibility tree. No Zoom, no permission.
#include "zoom_mac_source.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <map>
#include <set>

using namespace foresight::zoom;
using std::chrono::milliseconds;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition, message)                                              \
  do {                                                                         \
    ++checks;                                                                  \
    if (!(condition)) {                                                        \
      ++failures;                                                              \
      std::cerr << "FAIL: " << (message) << "  [" #condition "]\n";            \
    }                                                                          \
  } while (0)

struct FakeEnvironment final : Environment {
  bool supported = true;
  std::vector<ZoomInstance> running;
  bool trusted = true;
  int prompts = 0;
  int checks_without_prompt = 0;
  uint64_t clock = 100;

  bool os_supported() override {
    return supported;
  }
  std::vector<ZoomInstance> instances() override {
    return running;
  }
  bool accessibility_trusted(bool prompt) override {
    (prompt ? prompts : checks_without_prompt)++;
    return trusted;
  }
  uint64_t monotonic_ms() override {
    return clock += 7;
  }
  uint64_t uptime_ms() override {
    return clock;
  }
};

ZoomInstance zoom(const std::string &version = "7.2.2.88465",
                  const std::string &localization = "en") {
  ZoomInstance instance;
  instance.pid = 777;
  instance.version_readable = true;
  instance.version = version;
  instance.localization = localization;
  return instance;
}

// A fake element tree. Tokens are integers; `identity` maps a token to the
// element it denotes so two reads can return different tokens for one element.
struct FakeReader final : AxReader {
  std::map<ElementToken, NodeRead> nodes;
  std::map<ElementToken, int> identity;
  std::vector<ElementToken> window_tokens;
  AttrStatus window_status = AttrStatus::Ok;
  bool begin_ok = true;
  int begins = 0, ends = 0, reads = 0, retained = 0, released = 0;
  std::function<void(int)> on_read;

  bool begin(int) override {
    ++begins;
    return begin_ok;
  }
  AttrStatus windows(std::vector<ElementToken> &out) override {
    out = window_tokens;
    return window_status;
  }
  NodeRead read(ElementToken element) override {
    ++reads;
    if (on_read)
      on_read(reads);
    auto it = nodes.find(element);
    if (it == nodes.end()) {
      NodeRead missing;
      missing.call = AttrStatus::Failed;
      return missing;
    }
    return it->second;
  }
  void end() override {
    ++ends;
  }
  ElementToken retain(ElementToken element) override {
    ++retained;
    return element;
  }
  void release(ElementToken) override {
    ++released;
  }
  bool same(ElementToken a, ElementToken b) override {
    int ia = identity.count(a) ? identity[a] : static_cast<int>(a);
    int ib = identity.count(b) ? identity[b] : static_cast<int>(b);
    return ia == ib;
  }
};

TextAttr text(const std::string &value) {
  TextAttr attribute;
  attribute.status = AttrStatus::Ok;
  attribute.text = value;
  return attribute;
}

NodeRead element(const std::string &role, const std::string &description = {},
                 std::vector<ElementToken> children = {}) {
  NodeRead node;
  node.role = text(role);
  if (!description.empty())
    node.description = text(description);
  if (!children.empty()) {
    node.children_status = AttrStatus::Ok;
    node.children = std::move(children);
  }
  return node;
}

std::function<bool()> never = [] { return false; };

size_t count_nodes(const AxNode &node) {
  size_t total = 1;
  for (const auto &child : node.children)
    total += count_nodes(child);
  return total;
}

// A window (token 1) holding one tile (token 2).
void simple_meeting(FakeReader &reader) {
  reader.window_tokens = {1};
  reader.nodes[1] = element("AXWindow", {}, {2});
  reader.nodes[2] = element(
      "AXTabGroup", "Ada Example, Computer audio unmuted, Active speaker");
}

void check_gates() {
  FakeEnvironment env;
  FakeReader reader;
  ZoomMacSource source(env, reader);

  env.supported = false;
  auto outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.state == "unsupported_platform" &&
            outcome.reason == "macos_15_required",
        "old macOS");
  env.supported = true;

  outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.state == "zoom_not_running", "not running");
  CHECK(outcome.read_end_ms >= outcome.read_start_ms &&
            outcome.read_start_ms > 100,
        "read interval comes from the environment clock");

  env.running = {zoom(), zoom()};
  outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.state == "unavailable" &&
            outcome.reason == "ambiguous_processes",
        "several Zoom processes are never combined");

  ZoomInstance unreadable = zoom();
  unreadable.version_readable = false;
  env.running = {unreadable};
  outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.state == "unsupported_version" &&
            outcome.reason == "version_unreadable" && outcome.pid == 777,
        "unreadable version");

  env.running = {zoom("7.3.0.99999")};
  outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.reason == "zoom_version_unsupported" &&
            outcome.zoom_version == "7.3.0.99999",
        "unsupported version keeps the version for diagnostics");
  CHECK(reader.begins == 0, "no accessibility read behind a closed gate");

  env.running = {zoom("7.2.2.88465", "sv-FI")};
  env.trusted = false;
  outcome = source.snapshot(never);
  CHECK(outcome.state == "needs_setup" && outcome.locale_unsupported == false,
        "untrusted before setup");
}

void check_trust_transitions() {
  FakeEnvironment env;
  env.running = {zoom()};
  FakeReader reader;
  simple_meeting(reader);
  ZoomMacSource source(env, reader);

  env.trusted = false;
  auto outcome = source.snapshot(never);
  CHECK(outcome.state == "needs_setup" &&
            outcome.reason == "accessibility_not_trusted",
        "never granted: needs_setup");
  CHECK(env.prompts == 0 && env.checks_without_prompt >= 1,
        "snapshots never prompt");
  source.request_access();
  CHECK(env.prompts == 1, "setup prompts once");
  outcome = source.snapshot(never);
  CHECK(outcome.state == "permission_denied", "denied after setup");
  CHECK(env.prompts == 1, "snapshots still do not prompt");

  env.trusted = true;
  outcome = source.snapshot(never);
  CHECK(outcome.ok, "granted: readable");
  env.trusted = false;
  outcome = source.snapshot(never);
  CHECK(outcome.state == "permission_denied", "revoked: permission_denied");
  env.trusted = true;
  outcome = source.snapshot(never);
  CHECK(outcome.ok, "regranted: readable again");

  // Trust lost in the middle of a read.
  reader.on_read = [&](int) { reader.nodes[2].call = AttrStatus::Disabled; };
  outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.state == "permission_denied" &&
            outcome.reason == "accessibility_not_trusted",
        "kAXErrorAPIDisabled mid-read is a loss of trust");
  reader.on_read = nullptr;
  reader.nodes[2].call = AttrStatus::Ok;
  reader.window_status = AttrStatus::Disabled;
  outcome = source.snapshot(never);
  CHECK(outcome.state == "permission_denied", "disabled window list");
  CHECK(reader.begins == reader.ends, "every begin is paired with an end");
}

void check_window_list_and_timeout() {
  FakeEnvironment env;
  env.running = {zoom()};
  FakeReader reader;
  ZoomMacSource source(env, reader);

  reader.begin_ok = false;
  auto outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.reason == "ax_timeout_unavailable" &&
            reader.reads == 0,
        "no read without a bounded messaging timeout");
  reader.begin_ok = true;

  reader.window_status = AttrStatus::Failed;
  outcome = source.snapshot(never);
  CHECK(!outcome.ok && outcome.state == "unavailable" &&
            outcome.reason == "ax_read_failed",
        "a failed window list is a failed read");

  reader.window_status = AttrStatus::Absent;
  reader.window_tokens.clear();
  outcome = source.snapshot(never);
  CHECK(outcome.ok && !outcome.snapshot.truncated &&
            outcome.snapshot.root.children.empty(),
        "an application with no windows is an observed absence");
}

void check_absence_versus_failure() {
  FakeEnvironment env;
  env.running = {zoom()};
  ZoomMacSource *unused = nullptr;
  (void)unused;
  auto run = [&](const std::function<void(FakeReader &)> &arrange) {
    FakeReader reader;
    simple_meeting(reader);
    arrange(reader);
    ZoomMacSource source(env, reader);
    return source.snapshot(never);
  };
  auto base = run([](FakeReader &) {});
  CHECK(base.ok && !base.snapshot.truncated, "baseline is complete");
  CHECK(base.snapshot.root.children.size() == 1 &&
            base.snapshot.root.children[0].object_id != 0 &&
            base.snapshot.root.children[0].children[0].object_id != 0,
        "windows and tab groups get an element id");
  CHECK(!base.identity_incomplete, "ids available");

  auto absent = run([](FakeReader &r) {
    r.nodes[2].identifier.status = AttrStatus::Absent;
    r.nodes[2].value.status = AttrStatus::Absent;
  });
  CHECK(absent.ok && !absent.snapshot.truncated,
        "missing value/identifier is an observed absence");

  auto failed_text = run([](FakeReader &r) {
    r.nodes[2].description.status = AttrStatus::Failed;
  });
  CHECK(failed_text.ok && failed_text.snapshot.truncated,
        "a failed attribute read leaves the snapshot incomplete");

  auto failed_children = run(
      [](FakeReader &r) { r.nodes[1].children_status = AttrStatus::Failed; });
  CHECK(failed_children.snapshot.truncated &&
            failed_children.snapshot.root.children[0].children.empty(),
        "failed children are incomplete, not empty");

  auto failed_call =
      run([](FakeReader &r) { r.nodes[2].call = AttrStatus::Failed; });
  CHECK(failed_call.snapshot.truncated, "a failed whole-node read");

  auto no_role =
      run([](FakeReader &r) { r.nodes[2].role.status = AttrStatus::Absent; });
  CHECK(no_role.snapshot.truncated, "a node without a role is a failed read");

  auto empty_role = run([](FakeReader &r) { r.nodes[2].role = text(""); });
  CHECK(empty_role.snapshot.truncated, "an empty role is a failed read");

  auto foreign = run([](FakeReader &r) { r.nodes[1].foreign_child = true; });
  CHECK(foreign.snapshot.truncated, "a non-element child is incomplete");

  auto lossy = run([](FakeReader &r) { r.nodes[2].description.lossy = true; });
  CHECK(lossy.snapshot.truncated &&
            lossy.snapshot.root.children[0].children[0].description.empty(),
        "an unencodable or NUL-cut string is dropped and flagged");

  auto oversize = run([](FakeReader &r) {
    r.nodes[2].description = text(std::string(1025, 'x'));
  });
  CHECK(oversize.snapshot.truncated &&
            oversize.snapshot.root.children[0].children[0].description.empty(),
        "an oversize string is dropped and flagged");
  auto exact = run([](FakeReader &r) {
    r.nodes[2].description = text(std::string(1024, 'x'));
  });
  CHECK(!exact.snapshot.truncated, "a string at the bound is kept");
}

void check_limits() {
  FakeEnvironment env;
  env.running = {zoom()};

  // Depth: a chain longer than the bound stops at the bound.
  {
    FakeReader reader;
    reader.window_tokens = {1};
    for (ElementToken i = 1; i <= 200; ++i)
      reader.nodes[i] = element("AXGroup", {}, {i + 1});
    reader.nodes[1].role = text("AXWindow");
    reader.nodes[200].children.clear();
    reader.nodes[200].children_status = AttrStatus::Absent;
    ZoomMacSource source(env, reader);
    auto outcome = source.snapshot(never);
    size_t total = count_nodes(outcome.snapshot.root);
    CHECK(outcome.snapshot.truncated, "depth bound truncates");
    CHECK(total == static_cast<size_t>(kMaxDepth) + 1,
          "no node is created past the depth bound (" + std::to_string(total) +
              ")");
    CHECK(reader.reads == kMaxDepth, "no element is read past the bound");
  }
  // Node cap: nothing is created or read once the cap is reached.
  {
    FakeReader reader;
    reader.window_tokens = {1};
    std::vector<ElementToken> leaves;
    for (ElementToken i = 2; i < 1000; ++i) {
      leaves.push_back(i);
      reader.nodes[i] = element("AXGroup");
    }
    reader.nodes[1] = element("AXWindow", {}, leaves);
    CollectorLimits limits;
    limits.max_nodes = 50;
    ZoomMacSource source(env, reader, limits);
    auto outcome = source.snapshot(never);
    CHECK(outcome.snapshot.truncated, "node cap truncates");
    CHECK(count_nodes(outcome.snapshot.root) == 51,
          "exactly the capped nodes plus the root exist");
    CHECK(reader.reads == 50, "no read after the cap");
  }
  // Time budget, with an injected clock.
  {
    FakeReader reader;
    reader.window_tokens = {1};
    std::vector<ElementToken> leaves;
    for (ElementToken i = 2; i < 100; ++i) {
      leaves.push_back(i);
      reader.nodes[i] = element("AXGroup");
    }
    reader.nodes[1] = element("AXWindow", {}, leaves);
    auto now = std::chrono::steady_clock::time_point{};
    reader.on_read = [&](int) { now += milliseconds(10); };
    CollectorLimits limits;
    limits.budget = milliseconds(55);
    ZoomMacSource source(env, reader, limits, [&] { return now; });
    auto outcome = source.snapshot(never);
    CHECK(outcome.snapshot.truncated, "the read budget truncates");
    CHECK(reader.reads <= 7 && reader.reads >= 5,
          "reads stop when the budget is spent (" +
              std::to_string(reader.reads) + ")");
    CHECK(count_nodes(outcome.snapshot.root) ==
              static_cast<size_t>(reader.reads) + 1,
          "no placeholder nodes after the budget");
  }
  // Cancellation stops reading at once.
  {
    FakeReader reader;
    simple_meeting(reader);
    bool cancelled = false;
    reader.on_read = [&](int count) { cancelled = count >= 1; };
    ZoomMacSource source(env, reader);
    auto outcome = source.snapshot([&] { return cancelled; });
    CHECK(!outcome.ok && outcome.reason == "read_cancelled", "cancelled read");
    CHECK(reader.reads == 1, "no read after cancellation");
    CHECK(reader.begins == reader.ends, "end() still runs");
  }
}

void check_identity() {
  FakeEnvironment env;
  env.running = {zoom()};
  FakeReader reader;
  simple_meeting(reader);
  ZoomMacSource source(env, reader);

  auto first = source.snapshot(never);
  uint64_t window = first.snapshot.root.children[0].object_id;
  uint64_t tile = first.snapshot.root.children[0].children[0].object_id;
  CHECK(window != 0 && tile != 0 && window != tile, "distinct ids");

  // The next read returns different tokens that denote the same elements.
  reader.nodes[11] = reader.nodes[1];
  reader.nodes[11].children = {12};
  reader.nodes[12] = reader.nodes[2];
  reader.identity[11] = 1;
  reader.identity[12] = 2;
  reader.window_tokens = {11};
  auto second = source.snapshot(never);
  CHECK(second.snapshot.root.children[0].object_id == window &&
            second.snapshot.root.children[0].children[0].object_id == tile,
        "an element keeps its id across reads");
  CHECK(source.registry().size() == 2, "no duplicate registry entries");
  CHECK(reader.retained == 2, "elements are retained once");
}

void check_registry_pruning_and_capacity() {
  FakeEnvironment env;
  env.running = {zoom()};
  FakeReader reader;
  // Window 1 with six tiles.
  reader.window_tokens = {1};
  std::vector<ElementToken> tiles;
  for (ElementToken i = 2; i <= 7; ++i) {
    tiles.push_back(i);
    reader.nodes[i] = element("AXTabGroup", "P" + std::to_string(i) +
                                                ", Computer audio unmuted");
  }
  reader.nodes[1] = element("AXWindow", {}, tiles);
  {
    ZoomMacSource source(env, reader, {}, {}, 8);
    auto full = source.snapshot(never);
    CHECK(!full.identity_incomplete && source.registry().size() == 7,
          "window and six tiles identified");
    // An incomplete read did not see everyone: it must not forget anyone.
    reader.nodes[1] = element("AXWindow", {}, {2, 3});
    reader.nodes[3].description.status = AttrStatus::Failed;
    auto partial = source.snapshot(never);
    CHECK(partial.snapshot.truncated, "the read was incomplete");
    CHECK(source.registry().size() == 7 && reader.released == 0,
          "an incomplete read prunes nothing");
    reader.nodes[3].description = text("P3, Computer audio unmuted");
    // Only two tiles remain; the table is above half capacity, so unseen
    // entries are pruned and released.
    reader.nodes[1] = element("AXWindow", {}, {2, 3});
    auto fewer = source.snapshot(never);
    CHECK(!fewer.identity_incomplete, "ids still available");
    CHECK(source.registry().size() == 3, "unseen elements are pruned");
    CHECK(reader.released == 4, "pruned elements are released");
    // More elements than capacity: the extras get no id and flag the read.
    reader.nodes[1] = element("AXWindow", {}, tiles);
    for (ElementToken extra = 20; extra < 30; ++extra) {
      reader.nodes[extra] = element("AXTabGroup", "Q, Computer audio unmuted");
      reader.nodes[1].children.push_back(extra);
    }
    auto overflow = source.snapshot(never);
    CHECK(overflow.identity_incomplete, "a full identity table flags the read");
    CHECK(source.registry().size() <= 8, "the table never exceeds capacity");
    int unknown = 0;
    for (const auto &child : overflow.snapshot.root.children[0].children)
      unknown += child.object_id == 0;
    CHECK(unknown > 0, "elements beyond capacity have id 0");
  }
  CHECK(reader.retained == reader.released,
        "every retained element is released");
}

} // namespace

int main() {
  check_gates();
  check_trust_transitions();
  check_window_list_and_timeout();
  check_absence_versus_failure();
  check_limits();
  check_identity();
  check_registry_pruning_and_capacity();
  std::printf("zoom_mac_source: %d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
