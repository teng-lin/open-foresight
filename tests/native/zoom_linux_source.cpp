// Gate order and outcome mapping of the Linux Source, over a scripted desktop:
// no session bus, AT-SPI or Zoom is involved.
#include "zoom_linux_source.h"

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

class FakeDesktop final : public LinuxDesktop {
public:
  BusStatus bus_status() override {
    return bus;
  }
  bool enable_accessibility() override {
    ++setups;
    if (!setup_reaches_bus)
      return false;
    if (setup_effective)
      bus = BusStatus::Ready;
    return true;
  }
  ProcessScan zoom_processes() override {
    return {scan_ok, processes};
  }
  TreeRead read_tree(int pid, int budget_ms,
                     const std::function<bool()> &cancelled) override {
    ++reads;
    if (flip_cancel)
      tree.status =
          cancelled() ? TreeRead::Status::Cancelled : TreeRead::Status::Ok;
    last_pid = pid;
    last_budget_ms = budget_ms;
    return tree;
  }
  uint64_t monotonic_ms() override {
    return clock += 7;
  }

  BusStatus bus = BusStatus::Ready;
  bool setup_effective = false;
  bool setup_reaches_bus = true;
  bool scan_ok = true;
  bool flip_cancel = false;
  std::vector<ZoomProcess> processes{{4242, "0.0.0-synthetic"}};
  TreeRead tree{TreeRead::Status::Ok, {}, false};
  int setups = 0, reads = 0, last_pid = 0, last_budget_ms = 0;
  uint64_t clock = 1000;
};

RuleSet synthetic_rules() {
  RuleSet rules;
  rules.zoom_versions = {"0.0.0-synthetic"};
  rules.roster = {true, {"w", ""}, {"r", ""}, "p", "", ""};
  return rules;
}

const std::function<bool()> never = [] { return false; };

void expect(const SnapshotOutcome &outcome, bool ok, const char *state,
            const char *reason, const std::string &what) {
  check(outcome.ok == ok && outcome.state == state && outcome.reason == reason,
        what + " (got ok=" + std::to_string(outcome.ok) + " " + outcome.state +
            "/" + outcome.reason + ")");
}

void gate_order() {
  FakeDesktop desktop;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  const struct {
    BusStatus bus;
    const char *state, *reason;
  } cases[] = {
      {BusStatus::NoSessionBus, "unavailable", "no_session_bus"},
      {BusStatus::SessionBusUnreachable, "unavailable",
       "session_bus_unreachable"},
      {BusStatus::A11yBusAbsent, "needs_setup", "atspi_bus_absent"},
      {BusStatus::StatusUnreadable, "unavailable", "atspi_status_unreadable"},
      {BusStatus::Disabled, "needs_setup", "accessibility_disabled"}};
  for (const auto &c : cases) {
    desktop.bus = c.bus;
    expect(source.snapshot(never), false, c.state, c.reason, c.reason);
  }
  check(desktop.reads == 0, "no tree is read behind a failed gate");

  desktop.bus = BusStatus::Ready;
  desktop.scan_ok = false;
  expect(source.snapshot(never), false, "unavailable", "process_scan_failed",
         "an unreadable /proc is not 'Zoom is not running'");
  desktop.scan_ok = true;
  desktop.processes.clear();
  expect(source.snapshot(never), false, "zoom_not_running", "zoom_not_running",
         "no Zoom");
  desktop.processes = {{1, "0.0.0-synthetic"}, {2, "0.0.0-synthetic"}};
  expect(source.snapshot(never), false, "unavailable", "ambiguous_processes",
         "two Zooms");
  check(desktop.reads == 0, "an ambiguous process is never read");
}

void build_gates() {
  FakeDesktop desktop;
  desktop.processes = {{4242, "0.0.0-synthetic"}};
  {
    const RuleSet none{};
    LinuxSource source(desktop, none);
    const SnapshotOutcome outcome = source.snapshot(never);
    expect(outcome, false, "unsupported_version", "no_validated_rules",
           "the shipped, empty rule set interprets nothing");
    check(outcome.pid == 4242 && outcome.zoom_version == "0.0.0-synthetic",
          "the target Zoom is still reported");
    check(desktop.reads == 0, "no tree is read without a validated rule");
  }
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  desktop.processes = {{4242, ""}};
  expect(source.snapshot(never), false, "unavailable", "version_unreadable",
         "unknown version");
  desktop.processes = {{4242, "9.9.9"}};
  expect(source.snapshot(never), false, "unsupported_version",
         "zoom_version_unsupported", "a build outside the list");
  check(desktop.reads == 0, "an unsupported build is never read");
}

void reads() {
  FakeDesktop desktop;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  desktop.tree.snapshot.truncated = true;
  desktop.tree.identity_incomplete = true;
  SnapshotOutcome outcome = source.snapshot(never);
  check(outcome.ok && outcome.pid == 4242 &&
            outcome.zoom_version == "0.0.0-synthetic" &&
            outcome.snapshot.truncated && outcome.identity_incomplete,
        "an ok read carries the snapshot and its flags");
  check(desktop.last_pid == 4242 &&
            desktop.last_budget_ms == kLinuxReadBudgetMs,
        "the read is bounded by the budget");
  check(outcome.read_end_ms > outcome.read_start_ms &&
            outcome.read_start_ms > 1000,
        "read times come from the monotonic clock");
  check(source.uptime_ms() > 0 && source.monotonic_ms() > 0, "clocks answer");

  const struct {
    TreeRead::Status status;
    const char *reason;
  } failures_[] = {{TreeRead::Status::NotExposed, "zoom_not_exposed"},
                   {TreeRead::Status::Failed, "ax_read_failed"},
                   {TreeRead::Status::Cancelled, "read_cancelled"},
                   {TreeRead::Status::Unreachable, "atspi_unreachable"}};
  for (const auto &f : failures_) {
    desktop.tree.status = f.status;
    expect(source.snapshot(never), false, "unavailable", f.reason, f.reason);
  }
}

void setup_is_explicit() {
  FakeDesktop desktop;
  desktop.bus = BusStatus::Disabled;
  desktop.setup_effective = true;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  expect(source.snapshot(never), false, "needs_setup", "accessibility_disabled",
         "before setup");
  check(desktop.setups == 0, "reading capabilities never changes a setting");
  source.request_access();
  check(desktop.setups == 1, "setup is forwarded once, only on request");
  expect(source.snapshot(never), true, "", "", "setup took effect");
}

void cancel_is_forwarded() {
  FakeDesktop desktop;
  desktop.flip_cancel = true;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  bool cancel = false;
  const std::function<bool()> flag = [&cancel] { return cancel; };
  check(source.snapshot(flag).ok, "not cancelled: the read succeeds");
  cancel = true;
  expect(source.snapshot(flag), false, "unavailable", "read_cancelled",
         "the cancel callback reaches read_tree");
}

void other_states_survive_setup() {
  const struct {
    BusStatus bus;
    const char *state, *reason;
  } cases[] = {
      {BusStatus::A11yBusAbsent, "needs_setup", "atspi_bus_absent"},
      {BusStatus::NoSessionBus, "unavailable", "no_session_bus"},
      {BusStatus::StatusUnreadable, "unavailable", "atspi_status_unreadable"}};
  for (const auto &c : cases) {
    FakeDesktop desktop;
    desktop.bus = c.bus;
    const RuleSet rules = synthetic_rules();
    LinuxSource source(desktop, rules);
    source.request_access();
    expect(source.snapshot(never), false, c.state, c.reason,
           std::string("after setup: ") + c.reason);
  }
}

void grant_lost() {
  FakeDesktop desktop;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  check(source.snapshot(never).ok, "accessibility starts enabled");
  desktop.bus = BusStatus::Disabled;
  expect(source.snapshot(never), false, "permission_denied",
         "accessibility_lost",
         "a grant that was seen and lost is not a first run");
}

// A lost registry cannot be recovered in-process: the outcome is fatal, with
// the exit status the supervisor's restart relies on.
void registry_loss_is_fatal() {
  {
    FakeDesktop desktop;
    desktop.bus = BusStatus::BusLost;
    const RuleSet rules = synthetic_rules();
    LinuxSource source(desktop, rules);
    const SnapshotOutcome outcome = source.snapshot(never);
    expect(outcome, false, "unavailable", "atspi_bus_lost", "bus lost");
    check(outcome.fatal && outcome.fatal_exit == kLinuxExitRegistryLost &&
              kLinuxExitRegistryLost == 4,
          "a lost bus is fatal with exit status 4");
  }
  {
    FakeDesktop desktop;
    desktop.tree.status = TreeRead::Status::BusLost;
    const RuleSet rules = synthetic_rules();
    LinuxSource source(desktop, rules);
    const SnapshotOutcome outcome = source.snapshot(never);
    expect(outcome, false, "unavailable", "atspi_bus_lost", "connection lost");
    check(outcome.fatal && outcome.fatal_exit == 4 && outcome.pid == 4242,
          "a dropped connection during a read is fatal too");
  }
  FakeDesktop desktop;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  desktop.tree.status = TreeRead::Status::Failed;
  check(!source.snapshot(never).fatal, "an ordinary failed read is not fatal");
}

// A setup that never reached an accessibility bus did nothing: a bus that shows
// up later, disabled, is a first run, not a failed setup.
void setup_that_reached_nothing() {
  FakeDesktop desktop;
  desktop.bus = BusStatus::A11yBusAbsent;
  desktop.setup_reaches_bus = false;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  source.request_access();
  check(desktop.setups == 1, "setup was attempted");
  desktop.bus = BusStatus::Disabled;
  expect(source.snapshot(never), false, "needs_setup", "accessibility_disabled",
         "a setup that reached no bus is not blamed later");
}

void setup_not_effective() {
  FakeDesktop desktop;
  desktop.bus = BusStatus::Disabled;
  const RuleSet rules = synthetic_rules();
  LinuxSource source(desktop, rules);
  source.request_access();
  expect(source.snapshot(never), false, "permission_denied",
         "setup_not_effective", "a setup that did not enable support says so");
}

void registry() {
  ElementRegistry registry;
  registry.begin_read();
  const uint64_t a = registry.id_for(":1.2/a"), b = registry.id_for(":1.2/b");
  check(a != 0 && b != 0 && a != b && registry.id_for(":1.2/a") == a,
        "ids are stable and distinct");
  registry.end_read(true);
  registry.begin_read();
  check(registry.id_for(":1.2/a") == a, "an element seen again keeps its id");
  registry.end_read(true);
  check(registry.size() == 1,
        "elements not seen in the latest read are dropped");
  registry.begin_read();
  const uint64_t again = registry.id_for(":1.2/b");
  check(again != a && again != b,
        "ids are never reused for a returning element");
  registry.end_read(true);
}

} // namespace

int main() {
  gate_order();
  build_gates();
  reads();
  setup_is_explicit();
  setup_not_effective();
  setup_that_reached_nothing();
  registry_loss_is_fatal();
  cancel_is_forwarded();
  other_states_survive_setup();
  grant_lost();
  registry();
  std::cout << "zoom_linux_source: " << checks << " checks, " << failures
            << " failures\n";
  return failures == 0 ? 0 : 1;
}
