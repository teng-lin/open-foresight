#pragma once
// Pure interpretation of an AT-SPI snapshot of a Zoom window, over the shared
// snapshot types in zoom_ax_parser.h. Nothing here touches the desktop. An
// AT-SPI accessible maps onto AxNode as: role = lower-case role name, value =
// accessible name, description = accessible description, states and attributes
// as read. Rules are data, so a rule is enabled only after a recorded Linux
// Zoom snapshot justifies it; the shipped set enables none.
#include "zoom_ax_parser.h"

#include <set>
#include <string>

namespace foresight::zoom {

inline constexpr const char *kLinuxParserVersion = "linux-0";

// Selects nodes by role and, optionally, exact name (the AxNode value).
struct Matcher {
  std::string role;
  std::string name; // empty matches any name
  bool matches(const AxNode &node) const;
};

// Below a window matching `window`, the node matching `container` has children
// with role `item_role`; each is a participant named by its accessible name.
// Exactly one container may match in the whole snapshot.
struct RosterRule {
  bool enabled = false;
  Matcher window;
  Matcher container;
  std::string item_role;
  // The participant is the local user when this attribute has this value.
  std::string self_attribute;
  std::string self_value;
};

// A roster item whose AT-SPI state set contains `state` is speaking.
struct SpeakerRule {
  bool enabled = false;
  std::string state;
};

struct RuleSet {
  // Zoom builds the rules were validated against; empty disables parsing.
  std::set<std::string> zoom_versions;
  RosterRule roster;
  SpeakerRule speaker;
};

// The rules shipped in the helper: only those backed by recorded snapshots.
const RuleSet &validated_rules();

// Reason tokens match the shared vocabulary: no_validated_rules,
// no_meeting_window, no_participant_evidence, ambiguous_windows,
// incomplete_read.
ParseResult parse_atspi_snapshot(const AxSnapshot &snapshot,
                                 const RuleSet &rules);

// Folds ASCII case and collapses whitespace; display spelling is never altered.
std::string linux_comparison_key(const std::string &name);

} // namespace foresight::zoom
