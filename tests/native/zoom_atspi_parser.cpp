// Linux parser contract, driven by synthetic fixtures in
// tests/fixtures/zoom_observer_linux. The fixtures use made-up roles and names:
// they exercise the rule engine, not any real Zoom tree.
#include "zoom_atspi_parser.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <set>

namespace fs = std::filesystem;
using nlohmann::json;
using namespace foresight::zoom;

namespace {

int failures = 0;

void check(bool value, const std::string &what) {
  if (!value) {
    std::cerr << "FAIL: " << what << '\n';
    ++failures;
  }
}

AxNode node_from(const json &value) {
  AxNode node;
  node.object_id = value.value("object_id", 0);
  node.role = value.value("role", "");
  node.value = value.value("value", "");
  node.description = value.value("description", "");
  for (const auto &state : value.value("states", json::array()))
    node.states.insert(state.get<std::string>());
  const json attributes = value.value("attributes", json::object());
  for (const auto &[key, item] : attributes.items())
    node.attributes[key] = item.get<std::string>();
  for (const auto &child : value.value("children", json::array()))
    node.children.push_back(node_from(child));
  return node;
}

Matcher matcher_from(const json &value) {
  return {value.value("role", ""), value.value("name", "")};
}

RuleSet rules_from(const json &value) {
  RuleSet rules;
  const json roster = value.value("roster", json::object());
  rules.roster.enabled = roster.value("enabled", false);
  rules.roster.window = matcher_from(roster.value("window", json::object()));
  rules.roster.container =
      matcher_from(roster.value("container", json::object()));
  rules.roster.item_role = roster.value("item_role", "");
  rules.roster.self_attribute = roster.value("self_attribute", "");
  rules.roster.self_value = roster.value("self_value", "");
  const json speaker = value.value("speaker", json::object());
  rules.speaker.enabled = speaker.value("enabled", false);
  rules.speaker.state = speaker.value("state", "");
  return rules;
}

AxSnapshot snapshot_from(const json &value) {
  AxSnapshot snapshot;
  snapshot.truncated = value.value("truncated", false);
  snapshot.root = node_from(value["root"]);
  return snapshot;
}

void run_fixture(const fs::path &path) {
  std::ifstream input(path);
  const json fixture = json::parse(input);
  const std::string label = path.filename().string();
  const json &expect = fixture["expect"];
  const ParseResult result = parse_atspi_snapshot(
      snapshot_from(fixture["snapshot"]), rules_from(fixture["rules"]));

  check(expect["available"] == result.available, label + ": available");
  check(expect["reason"] == result.reason, label + ": reason");
  check(expect["complete"] == result.complete, label + ": complete");
  json participants = json::array();
  for (const Participant &participant : result.participants) {
    participants.push_back(
        {{"name", participant.name}, {"self", participant.self}});
    check(participant.key == linux_comparison_key(participant.name) &&
              participant.object_id != 0,
          label + ": key and identity");
  }
  check(expect["participants"] == participants, label + ": participants");
  json speakers = json::array();
  for (const Speaker &speaker : result.speakers) {
    speakers.push_back(speaker.participant);
    check(speaker.method == Method::AtspiState, label + ": method");
  }
  check(expect["speakers"] == speakers, label + ": speakers");
  if (result.available)
    check(result.window_object_id != 0, label + ": window identity");
}

// Bounds and encodings that fixtures would make unreadable.
void bounds(const fs::path &directory) {
  std::ifstream input(directory / "roster_no_speaker.json");
  const json fixture = json::parse(input);
  const RuleSet rules = rules_from(fixture["rules"]);
  const auto items = [](AxSnapshot &snapshot) -> std::vector<AxNode> & {
    return snapshot.root.children[0].children.back().children;
  };

  AxSnapshot many = snapshot_from(fixture["snapshot"]);
  items(many).clear();
  for (std::size_t i = 0; i < kMaxParticipants + 5; ++i) {
    AxNode person;
    person.object_id = 1000 + i;
    person.role = "synthetic-person";
    person.value = "Synthetic " + std::to_string(i);
    items(many).push_back(person);
  }
  items(many).resize(kMaxParticipants);
  const ParseResult full = parse_atspi_snapshot(many, rules);
  check(full.participants.size() == kMaxParticipants && full.complete,
        "exactly 256 participants stay complete");
  AxNode extra;
  extra.object_id = 5000;
  extra.role = "synthetic-person";
  extra.value = "One Too Many";
  items(many).push_back(extra);
  items(many).push_back(extra);
  const ParseResult capped = parse_atspi_snapshot(many, rules);
  check(capped.participants.size() == kMaxParticipants,
        "roster is capped at 256");
  check(!capped.complete, "a capped roster is incomplete");

  AxSnapshot long_name = snapshot_from(fixture["snapshot"]);
  items(long_name)[0].value = std::string(kMaxNameBytes + 1, 'x');
  const ParseResult overlong = parse_atspi_snapshot(long_name, rules);
  check(overlong.participants.size() == 1 && !overlong.complete,
        "an overlong name is dropped and the read is incomplete");

  AxSnapshot exact = snapshot_from(fixture["snapshot"]);
  items(exact)[0].value = std::string(kMaxNameBytes, 'x');
  check(parse_atspi_snapshot(exact, rules).complete,
        "a name at the bound is accepted");

  for (const char *bad :
       {"\xff", "a\xc3", "\xc0\x80", "\xed\xa0\x80", "\xf5\x80\x80\x80"}) {
    AxSnapshot invalid = snapshot_from(fixture["snapshot"]);
    items(invalid)[0].value = bad;
    const ParseResult result = parse_atspi_snapshot(invalid, rules);
    check(result.participants.size() == 1 && !result.complete,
          "invalid UTF-8 is dropped and makes the read incomplete");
  }

  AxSnapshot no_id = snapshot_from(fixture["snapshot"]);
  items(no_id)[0].object_id = 0;
  check(!parse_atspi_snapshot(no_id, rules).complete,
        "an item without identity is dropped");

  AxSnapshot only_bad = snapshot_from(fixture["snapshot"]);
  items(only_bad).resize(1);
  items(only_bad)[0].value = " ";
  const ParseResult nothing = parse_atspi_snapshot(only_bad, rules);
  check(!nothing.available && nothing.reason == "incomplete_read",
        "a roster whose only item was dropped is a failed read, not an empty "
        "room");
}

// A hostile, very deep tree must neither recurse without bound nor pass as a
// complete read.
void deep_input(const fs::path &directory) {
  std::ifstream input(directory / "roster_no_speaker.json");
  const json fixture = json::parse(input);
  const RuleSet rules = rules_from(fixture["rules"]);
  AxSnapshot deep;
  deep.root.role = "synthetic-application";
  AxNode *tail = &deep.root;
  for (int i = 0; i < 100000; ++i) {
    tail->children.emplace_back();
    tail = &tail->children.back();
    tail->role = "synthetic-toolbar";
  }
  const ParseResult result = parse_atspi_snapshot(deep, rules);
  check(!result.available && result.reason == "incomplete_read",
        "a tree deeper than the bound is an incomplete read");
  // Destroying the 100000-deep chain recursively would overflow the stack.
  std::vector<AxNode *> chain;
  for (AxNode *n = &deep.root; !n->children.empty(); n = &n->children.back())
    chain.push_back(n);
  for (auto it = chain.rbegin(); it != chain.rend(); ++it)
    (*it)->children.clear();
}

void keys() {
  check(linux_comparison_key("  Ada \t LOVELACE ") == "ada lovelace",
        "key folds case and spaces");
  check(linux_comparison_key("Ada") != linux_comparison_key("Adá"),
        "diacritics stay distinct");
}

// The rules compiled into the helper must stay empty until a live Linux Zoom
// snapshot justifies one.
void shipped_rules() {
  const RuleSet &rules = validated_rules();
  check(!rules.roster.enabled && !rules.speaker.enabled &&
            rules.zoom_versions.empty(),
        "shipped rules enable nothing without recorded evidence");
  const ParseResult result = parse_atspi_snapshot(AxSnapshot{}, rules);
  check(!result.available && result.reason == "no_validated_rules" &&
            result.participants.empty() && result.speakers.empty(),
        "shipped rules interpret nothing");
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: zoom_atspi_parser_test FIXTURE_DIRECTORY\n";
    return 2;
  }
  const fs::path directory = argv[1];
  const std::set<std::string> expected = {"ambiguous_rosters",
                                          "decoy_container",
                                          "duplicate_node_id",
                                          "empty_name",
                                          "isolate_only_names",
                                          "name_with_status_phrase",
                                          "no_roster",
                                          "no_window",
                                          "non_person_siblings",
                                          "roster_no_speaker",
                                          "roster_one_speaker",
                                          "roster_only_rules",
                                          "roster_two_speakers",
                                          "rules_not_validated",
                                          "self_marker_wrong_value",
                                          "truncated_no_window",
                                          "truncated_read",
                                          "two_containers_one_window",
                                          "two_selves",
                                          "unnamed_and_padded",
                                          "window_name_rule",
                                          "wrong_window_name_only"};
  std::set<std::string> found;
  for (const auto &entry : fs::directory_iterator(directory)) {
    if (entry.path().extension() != ".json")
      continue;
    run_fixture(entry.path());
    found.insert(entry.path().stem().string());
  }
  check(found == expected, "the fixture set is exactly the expected list");
  const std::size_t fixtures = found.size();
  bounds(directory);
  deep_input(directory);
  keys();
  shipped_rules();
  std::cout << fixtures << " fixtures, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
