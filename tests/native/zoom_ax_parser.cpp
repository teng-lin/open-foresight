// Parser contract for Zoom accessibility snapshots. Uses only synthetic
// fixtures with controlled names; no Accessibility API and no permission.
#include "zoom_ax_parser.h"

#include <nlohmann/json.hpp>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <set>
#include <string>

using foresight::zoom::AxNode;
using foresight::zoom::AxSnapshot;
using foresight::zoom::Method;
using foresight::zoom::ParseResult;
using json = nlohmann::json;

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

json load(const std::string &path) {
  std::ifstream file(path);
  if (!file) {
    std::cerr << "cannot open " << path << '\n';
    std::exit(2);
  }
  return json::parse(file);
}

AxNode node_from(const json &value) {
  AxNode node;
  node.role = value.value("role", "");
  node.description = value.value("description", "");
  node.value = value.value("value", "");
  node.identifier = value.value("identifier", "");
  node.object_id = value.value("object_id", 0ULL);
  for (const auto &child : value.value("children", json::array()))
    node.children.push_back(node_from(child));
  return node;
}

const char *method_name(Method method) {
  return method == Method::ParticipantStatus ? "participant_status"
                                             : "compact_talking_label";
}

AxNode node(const std::string &role, const std::string &description = {},
            const std::string &value = {}) {
  AxNode result;
  result.role = role;
  result.description = description;
  result.value = value;
  return result;
}

AxSnapshot app_with(std::vector<AxNode> windows) {
  AxSnapshot snapshot;
  snapshot.root.role = "AXApplication";
  snapshot.root.children = std::move(windows);
  return snapshot;
}

AxSnapshot single_window(std::vector<AxNode> children) {
  AxNode window = node("AXWindow");
  window.children = std::move(children);
  return app_with({std::move(window)});
}

void check_scenario(const json &scenario) {
  const std::string name = scenario["name"];
  AxSnapshot snapshot;
  snapshot.root = node_from(scenario["snapshot"]);
  snapshot.truncated = scenario.value("truncated", false);
  ParseResult result = foresight::zoom::parse_snapshot(snapshot);
  const json &expected = scenario["expected"];
  CHECK(result.available == expected["available"].get<bool>(),
        name + ": availability");
  if (!expected["available"].get<bool>()) {
    CHECK(result.reason == expected["reason"].get<std::string>(),
          name + ": reason " + result.reason);
    CHECK(result.participants.empty() && result.speakers.empty(),
          name + ": unavailable results carry no participants or speakers");
    return;
  }
  CHECK(result.complete == expected["complete"].get<bool>(),
        name + ": complete");
  CHECK(result.locale == expected["locale"].get<std::string>(),
        name + ": locale " + result.locale);
  CHECK(result.window_index == expected["window_index"].get<int>(),
        name + ": window index");
  const json &participants = expected["participants"];
  CHECK(result.participants.size() == participants.size(),
        name + ": participant count");
  for (size_t i = 0; i < participants.size() && i < result.participants.size();
       ++i) {
    CHECK(result.participants[i].name ==
              participants[i]["name"].get<std::string>(),
          name + ": participant name " + result.participants[i].name);
    CHECK(result.participants[i].self == participants[i]["self"].get<bool>(),
          name + ": self flag of " + result.participants[i].name);
    if (participants[i].contains("key"))
      CHECK(result.participants[i].key ==
                participants[i]["key"].get<std::string>(),
            name + ": comparison key of " + result.participants[i].name);
    if (participants[i].contains("audio")) {
      const char *audio =
          result.participants[i].audio == foresight::zoom::AudioState::Muted
              ? "muted"
          : result.participants[i].audio == foresight::zoom::AudioState::Unmuted
              ? "unmuted"
              : "unknown";
      CHECK(audio == participants[i]["audio"].get<std::string>(),
            name + ": audio state of " + result.participants[i].name);
    }
    if (participants[i].contains("object_id"))
      CHECK(result.participants[i].object_id ==
                participants[i]["object_id"].get<uint64_t>(),
            name + ": object id");
  }
  const json &speakers = expected["speakers"];
  CHECK(result.speakers.size() == speakers.size(), name + ": speaker count");
  for (size_t i = 0; i < speakers.size() && i < result.speakers.size(); ++i) {
    const auto &speaker = result.speakers[i];
    CHECK(speaker.participant == speakers[i]["index"].get<size_t>(),
          name + ": speaker refers to participant index " +
              std::to_string(speaker.participant));
    CHECK(speaker.participant < result.participants.size(),
          name + ": speaker index in range");
    if (speaker.participant < result.participants.size())
      CHECK(result.participants[speaker.participant].name ==
                speakers[i]["name"].get<std::string>(),
            name + ": speaker name");
    CHECK(method_name(speaker.method) ==
              speakers[i]["method"].get<std::string>(),
          name + ": speaker method");
  }
}

std::string replace_placeholder(std::string format, const std::string &name) {
  auto at = format.find("%@");
  CHECK(at != std::string::npos, "format has a placeholder: " + format);
  if (at != std::string::npos)
    format.replace(at, 2, name);
  return format;
}

void check_locale(const json &locale) {
  const std::string id = locale["id"];
  const std::string ada = "Ada Example";
  const std::string bo = "Example, Bo";
  const std::string unmuted = locale["unmuted"], muted = locale["muted"],
                    active = locale["active_speaker"];

  // Ordinary tiles: status phrase, explicit marker, comma-bearing name.
  {
    AxSnapshot snapshot =
        single_window({node("AXTabGroup", ada + ", " + unmuted),
                       node("AXTabGroup", bo + ", " + muted + ", " + active)});
    ParseResult result = foresight::zoom::parse_snapshot(snapshot);
    CHECK(result.available, id + ": tiles available");
    CHECK(result.locale == id, id + ": tile locale was " + result.locale);
    CHECK(result.participants.size() == 2, id + ": two participants");
    if (result.participants.size() == 2) {
      CHECK(result.participants[0].name == ada, id + ": first name");
      CHECK(result.participants[1].name == bo, id + ": comma name preserved");
      CHECK(result.participants[0].audio ==
                foresight::zoom::AudioState::Unmuted,
            id + ": unmuted state");
      CHECK(result.participants[1].audio == foresight::zoom::AudioState::Muted,
            id + ": muted state");
    }
    CHECK(result.speakers.size() == 1 && result.speakers[0].participant == 1,
          id + ": only the marked tile speaks");
  }
  // A marker without a status phrase is an unvalidated structure: no speaker.
  {
    ParseResult result = foresight::zoom::parse_snapshot(
        single_window({node("AXTabGroup", ada + ", " + active)}));
    CHECK(!result.available && result.reason == "incomplete_read" &&
              result.speakers.empty(),
          id + ": marker-only tile is not a speaker");
  }
  // Compact window, both label forms Zoom ships.
  for (const char *key : {"talking_format", "talking_key"}) {
    std::string label = std::string(key) == "talking_format"
                            ? replace_placeholder(locale[key], ada)
                            : locale[key].get<std::string>() + ada;
    ParseResult result = foresight::zoom::parse_snapshot(
        single_window({node("AXButton", locale["hide_thumbnail"]),
                       node("AXButton", locale["show_active_video"]),
                       node("AXStaticText", {}, label)}));
    CHECK(result.available && result.speakers.size() == 1 &&
              result.speakers[0].method == Method::CompactTalkingLabel &&
              result.participants.size() == 1 &&
              result.participants[0].name == ada,
          id + ": compact label from " + key + " (" + label + ")");
    CHECK(result.locale == id, id + ": compact locale was " + result.locale);
  }
  // Self identity in the localized participants list.
  {
    AxNode outline = node("AXOutline", locale["participants_list"]);
    outline.children.push_back(node(
        "AXStaticText", {}, replace_placeholder(locale["self_format"], ada)));
    AxNode other = node("AXWindow");
    other.children.push_back(outline);
    AxNode tiles = node("AXWindow");
    tiles.children.push_back(node("AXTabGroup", ada + ", " + unmuted));
    ParseResult result =
        foresight::zoom::parse_snapshot(app_with({tiles, other}));
    CHECK(result.available && result.participants.size() == 1 &&
              result.participants[0].self,
          id + ": self from the participants list");
  }
}

void check_phrase_uniqueness() {
  size_t count = 0;
  const auto *locales = foresight::zoom::locale_patterns(count);
  CHECK(count == 17, "seventeen locale pattern sets");
  std::set<std::string> seen;
  for (size_t i = 0; i < count; ++i)
    for (const char *phrase :
         {locales[i].unmuted, locales[i].muted, locales[i].active_speaker}) {
      std::string folded = foresight::zoom::comparison_key(phrase);
      CHECK(seen.insert(folded).second,
            std::string("status phrase unique across locales: ") + phrase);
    }
}

void check_utilities() {
  using foresight::zoom::comparison_key;
  using foresight::zoom::locale_supported;
  using foresight::zoom::zoom_version_supported;
  CHECK(comparison_key("  Ada   LOVELACE\t") == "ada lovelace",
        "key folds case and whitespace");
  CHECK(comparison_key("Example, Ada") == "example, ada",
        "key keeps punctuation");
  CHECK(comparison_key("José") != comparison_key("Jose"),
        "key keeps diacritics: distinct people must not merge");
  CHECK(comparison_key("e\xcc\x81") == comparison_key("\xc3\xa9"),
        "key canonicalizes composed forms");

  for (const char *supported :
       {"7.2.2.88465", "7.2.0", "7.2.1.1", "7.2.3.99999", "7.2"})
    CHECK(zoom_version_supported(supported),
          std::string("supported version ") + supported);
  for (const char *unsupported :
       {"7.0.0.77593", "7.1.9", "7.3.0", "6.2.2", "17.2.1", "7.20.1", "", "7",
        "7.2.x", "7.2.2 (88465)", "7..2", "7.2.2.1.1", "abc"})
    CHECK(!zoom_version_supported(unsupported),
          std::string("unsupported version '") + unsupported + "'");

  for (const char *supported : {"en", "zh-Hans", "zh-Hant", "ko-KR", "pt-PT",
                                "de", "ja", "en-GB", "fr-CA", "zh-Hans-CN"})
    CHECK(locale_supported(supported),
          std::string("supported localization ") + supported);
  for (const char *unsupported :
       {"pt-BR", "zh", "zh-TW", "ar", "he", "th", "", "xx"})
    CHECK(!locale_supported(unsupported),
          std::string("unsupported localization '") + unsupported + "'");
}

void check_bounds_and_malformed() {
  using foresight::zoom::kMaxParticipants;
  const std::string status = ", Computer audio unmuted";

  // A tile deeper than the depth bound is not read.
  {
    AxNode chain = node("AXGroup");
    AxNode *tail = &chain;
    for (int i = 0; i < 100; ++i) {
      tail->children.push_back(node("AXGroup"));
      tail = &tail->children.back();
    }
    tail->children.push_back(node("AXTabGroup", "Deep Example" + status));
    AxNode window = node("AXWindow");
    window.children.push_back(std::move(chain));
    ParseResult result = foresight::zoom::parse_snapshot(app_with({window}));
    CHECK(!result.available, "tile beyond the depth bound is not evidence");
  }
  // Very deep chains must not exhaust the stack.
  {
    AxNode chain = node("AXGroup");
    AxNode *tail = &chain;
    for (int i = 0; i < 3000; ++i) {
      tail->children.push_back(node("AXGroup"));
      tail = &tail->children.back();
    }
    AxNode window = node("AXWindow");
    window.children.push_back(std::move(chain));
    ParseResult result = foresight::zoom::parse_snapshot(app_with({window}));
    CHECK(!result.available, "very deep tree yields no evidence");
  }
  // The node bound keeps earlier evidence but marks the read incomplete.
  {
    std::vector<AxNode> children;
    children.push_back(
        node("AXTabGroup", "Early Example" + status + ", Active speaker"));
    for (size_t i = 0; i < foresight::zoom::kMaxNodes + 10; ++i)
      children.push_back(node("AXGroup"));
    ParseResult result =
        foresight::zoom::parse_snapshot(single_window(std::move(children)));
    CHECK(result.available && !result.complete && result.speakers.size() == 1,
          "node bound: evidence kept, snapshot incomplete");
  }
  // More participants than one observation may carry.
  {
    std::vector<AxNode> children;
    for (size_t i = 0; i < kMaxParticipants + 20; ++i)
      children.push_back(
          node("AXTabGroup", "Person " + std::to_string(i) + status));
    ParseResult result =
        foresight::zoom::parse_snapshot(single_window(std::move(children)));
    CHECK(result.available && result.participants.size() == kMaxParticipants &&
              !result.complete,
          "participant bound truncates and marks incomplete");
  }
  // Invalid UTF-8 and over-long names never become participants.
  {
    ParseResult result = foresight::zoom::parse_snapshot(single_window(
        {node("AXTabGroup", "Valid Example" + status),
         node("AXTabGroup", std::string("Bad \xff\xfe Name") + status),
         node("AXTabGroup",
              std::string(foresight::zoom::kMaxNameBytes + 1, 'x') + status)}));
    CHECK(result.available && result.participants.size() == 1 &&
              result.participants[0].name == "Valid Example" &&
              !result.complete,
          "invalid or oversized names are dropped and flagged");
  }
  // Only malformed evidence: unavailable, never an invented speaker.
  {
    ParseResult result = foresight::zoom::parse_snapshot(single_window(
        {node("AXTabGroup", std::string("\xff") + status),
         node("AXTabGroup", std::string(",,, ") + "Computer audio muted")}));
    CHECK(!result.available && result.speakers.empty() &&
              result.reason == "incomplete_read",
          "malformed tiles produce no speaker and a failed read");
  }
  // Pure function: repeated parses agree.
  {
    AxSnapshot snapshot = single_window(
        {node("AXTabGroup", "Same Example" + status + ", Active speaker")});
    ParseResult first = foresight::zoom::parse_snapshot(snapshot);
    ParseResult second = foresight::zoom::parse_snapshot(snapshot);
    CHECK(first.participants.size() == second.participants.size() &&
              first.speakers.size() == second.speakers.size() &&
              first.complete == second.complete,
          "parsing is deterministic");
  }
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: zoom_ax_parser_test FIXTURE_DIR\n";
    return 2;
  }
  const std::string dir = argv[1];
  json scenarios = load(dir + "/scenarios.json")["scenarios"];
  json locales = load(dir + "/locales.json")["locales"];
  for (const auto &scenario : scenarios)
    check_scenario(scenario);
  for (const auto &locale : locales)
    check_locale(locale);
  check_phrase_uniqueness();
  check_utilities();
  check_bounds_and_malformed();
  std::printf("zoom_ax_parser: %d checks, %d failures (%zu scenarios, %zu "
              "locales)\n",
              checks, failures, scenarios.size(), locales.size());
  return failures == 0 ? 0 : 1;
}
