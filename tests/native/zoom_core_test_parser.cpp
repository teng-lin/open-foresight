// Linux-only stand-in for the macOS snapshot parser, so the platform-neutral
// observer core suite (zoom_observer_core.cpp, which feeds the core participant
// tiles in the macOS description grammar) runs on Linux as well. It understands
// only `<name>, Computer audio (un)muted[, Active speaker]` tiles under
// AXTabGroup nodes; the real macOS parser is tested by zoom_ax_parser on macOS
// and the real Linux parser by zoom_atspi_parser. It exists to exercise the
// core (framing, sessions, references, shutdown), not to define any parsing
// rule.
#include "zoom_ax_parser.h"

#include <algorithm>
#include <cctype>

namespace foresight::zoom {

std::string comparison_key(const std::string &name) {
  std::string key;
  bool gap = false;
  for (unsigned char c : name) {
    if (std::isspace(c)) {
      gap = !key.empty();
      continue;
    }
    if (gap)
      key.push_back(' ');
    gap = false;
    key.push_back(static_cast<char>(std::tolower(c)));
  }
  return key;
}

namespace {

struct Tile {
  std::string name;
  AudioState audio = AudioState::Unknown;
  bool active = false;
  bool valid = false;
};

Tile parse_tile(const std::string &description) {
  static const std::pair<const char *, AudioState> statuses[] = {
      {", Computer audio unmuted", AudioState::Unmuted},
      {", Computer audio muted", AudioState::Muted}};
  Tile tile;
  size_t best = std::string::npos;
  for (const auto &[text, state] : statuses) {
    const size_t at = description.rfind(text);
    if (at != std::string::npos && (best == std::string::npos || at > best)) {
      best = at;
      tile.audio = state;
    }
  }
  if (best == std::string::npos)
    return tile;
  tile.name = description.substr(0, best);
  const size_t status_end =
      best + (tile.audio == AudioState::Unmuted ? 24 : 22);
  tile.active = description.compare(status_end, std::string::npos,
                                    ", Active speaker") == 0;
  tile.valid = true;
  return tile;
}

void collect_tiles(const AxNode &node, std::vector<const AxNode *> &found) {
  if (node.role == "AXTabGroup") {
    if (parse_tile(node.description).valid) {
      found.push_back(&node);
      return;
    }
  }
  for (const AxNode &child : node.children)
    collect_tiles(child, found);
}

} // namespace

ParseResult parse_snapshot(const AxSnapshot &snapshot) {
  ParseResult result;
  std::vector<const AxNode *> windows;
  const AxNode &root = snapshot.root;
  if (root.role == "AXWindow")
    windows.push_back(&root);
  else
    for (const AxNode &child : root.children)
      if (child.role == "AXWindow")
        windows.push_back(&child);
  const AxNode *chosen = nullptr;
  std::vector<const AxNode *> tiles;
  bool saw_window = !windows.empty();
  for (const AxNode *window : windows) {
    std::vector<const AxNode *> found;
    collect_tiles(*window, found);
    if (found.empty())
      continue;
    if (chosen) {
      result.reason = "ambiguous_windows";
      return result;
    }
    chosen = window;
    tiles = std::move(found);
  }
  if (!chosen) {
    result.reason = snapshot.truncated ? "incomplete_read"
                    : saw_window       ? "no_participant_evidence"
                                       : "no_meeting_window";
    return result;
  }
  result.available = true;
  result.locale = "en";
  result.complete = !snapshot.truncated;
  result.window_index = static_cast<int>(chosen - windows.front());
  result.window_object_id = chosen->object_id;
  for (const AxNode *node : tiles) {
    const Tile tile = parse_tile(node->description);
    if (tile.name.empty() || tile.name.size() > kMaxNameBytes ||
        result.participants.size() >= kMaxParticipants) {
      result.complete = false;
      continue;
    }
    Participant participant;
    participant.name = tile.name;
    participant.key = comparison_key(tile.name);
    participant.audio = tile.audio;
    participant.object_id = node->object_id;
    result.participants.push_back(participant);
    if (tile.active)
      result.speakers.push_back(
          {result.participants.size() - 1, Method::ParticipantStatus});
  }
  if (result.participants.empty()) {
    result.available = false;
    result.reason =
        result.complete ? "no_participant_evidence" : "incomplete_read";
  }
  return result;
}

} // namespace foresight::zoom
