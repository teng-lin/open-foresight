#include "zoom_atspi_parser.h"

#include <cctype>
#include <vector>

namespace foresight::zoom {

bool Matcher::matches(const AxNode &node) const {
  return node.role == role && (name.empty() || node.value == name);
}

const RuleSet &validated_rules() {
  // No Linux Zoom accessibility signal has been recorded from a live meeting
  // (docs/architecture/zoom-speaker-attribution.md, "Linux live feasibility").
  // With no validated build the helper reports capabilities and unavailable
  // intervals but never a roster or a speaker.
  static const RuleSet rules{};
  return rules;
}

namespace {

// Decodes one UTF-8 scalar at `i`; returns its length or 0 when invalid.
size_t utf8_length(const std::string &text, size_t i, unsigned &code) {
  const auto byte = [&](size_t k) {
    return static_cast<unsigned char>(text[k]);
  };
  const unsigned lead = byte(i);
  if (lead < 0x80) {
    code = lead;
    return 1;
  }
  size_t length = lead >= 0xf0 && lead <= 0xf4 ? 4
                  : lead >= 0xe0               ? 3
                  : lead >= 0xc2               ? 2
                                               : 0;
  if (lead > 0xf4 || length == 0 || i + length > text.size())
    return 0;
  code = lead & (0xffu >> (length + 1));
  for (size_t k = 1; k < length; ++k) {
    if ((byte(i + k) & 0xc0) != 0x80)
      return 0;
    code = (code << 6) | (byte(i + k) & 0x3f);
  }
  static const unsigned minimum[] = {0, 0, 0x80, 0x800, 0x10000};
  if (code < minimum[length] || code > 0x10ffff ||
      (code >= 0xd800 && code <= 0xdfff))
    return 0;
  return length;
}

// Whitespace, control and invisible format characters, as for the macOS parser:
// soft hyphen, Arabic letter mark, Mongolian vowel separator, zero-width and
// bidi marks, embeddings and isolates, invisible operators, and the BOM.
bool invisible(unsigned code) {
  return code <= 0x20 || (code >= 0x7f && code <= 0xa0) || code == 0x00ad ||
         code == 0x061c || code == 0x1680 || code == 0x180e ||
         (code >= 0x2000 && code <= 0x200f) ||
         (code >= 0x2028 && code <= 0x202f) || code == 0x205f ||
         (code >= 0x2060 && code <= 0x206f) || code == 0x3000 || code == 0xfeff;
}

enum class NameCheck { Ok, Unnamed, Invalid };

// Trims edge whitespace (including no-break space) and classifies the name.
// Interior text, commas and punctuation are kept as displayed.
NameCheck clean_name(const std::string &raw, std::string &out) {
  std::vector<std::pair<size_t, size_t>> scalars; // offset, length
  bool visible = false;
  for (size_t i = 0; i < raw.size();) {
    unsigned code = 0;
    const size_t length = utf8_length(raw, i, code);
    if (length == 0)
      return NameCheck::Invalid;
    scalars.push_back({i, length});
    if (!invisible(code))
      visible = true;
    i += length;
  }
  if (!visible)
    return NameCheck::Unnamed;
  const auto blank = [&](size_t index) {
    unsigned code = 0;
    utf8_length(raw, scalars[index].first, code);
    return code <= 0x20 || code == 0xa0 || code == 0x3000;
  };
  size_t first = 0, last = scalars.size();
  while (first < last && blank(first))
    ++first;
  while (last > first && blank(last - 1))
    --last;
  out = raw.substr(scalars[first].first, scalars[last - 1].first +
                                             scalars[last - 1].second -
                                             scalars[first].first);
  return NameCheck::Ok;
}

struct Target {
  const AxNode *window;
  const AxNode *container;
};

// Every container below every matching window, in document order. A matched
// window or container is not searched for nested matches. Recursion stops at
// kMaxDepth; a deeper node sets `too_deep` and is not searched.
struct Search {
  std::vector<Target> found;
  bool saw_window = false;
  bool too_deep = false;
};

void find_containers(const AxNode &node, const RosterRule &rule,
                     const AxNode *window, int depth, Search &search) {
  if (depth > kMaxDepth) {
    search.too_deep = true;
    return;
  }
  if (!window && rule.window.matches(node)) {
    search.saw_window = true;
    find_containers(node, rule, &node, depth, search);
    return;
  }
  if (window && rule.container.matches(node)) {
    search.found.push_back({window, &node});
    return;
  }
  for (const AxNode &child : node.children)
    find_containers(child, rule, window, depth + 1, search);
}

ParseResult refuse(const char *reason) {
  ParseResult result;
  result.available = false;
  result.reason = reason;
  return result;
}

} // namespace

std::string linux_comparison_key(const std::string &name) {
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
    key.push_back(static_cast<char>(c < 0x80 ? std::tolower(c) : c));
  }
  return key;
}

ParseResult parse_atspi_snapshot(const AxSnapshot &snapshot,
                                 const RuleSet &rules) {
  if (!rules.roster.enabled)
    return refuse("no_validated_rules");
  Search search;
  find_containers(snapshot.root, rules.roster, nullptr, 0, search);
  const std::vector<Target> &targets = search.found;
  if (targets.empty()) {
    // A truncated or too deep read cannot rule a meeting out.
    if (snapshot.truncated || search.too_deep)
      return refuse("incomplete_read");
    return refuse(search.saw_window ? "no_participant_evidence"
                                    : "no_meeting_window");
  }
  if (targets.size() > 1)
    return refuse("ambiguous_windows");

  ParseResult result;
  result.available = true;
  result.window_index = 0;
  result.window_object_id = targets[0].window->object_id;
  // A truncated read cannot prove a roster or the absence of a speaker.
  bool complete = !snapshot.truncated && !search.too_deep;
  std::set<uint64_t> seen;
  std::vector<bool> speaking;
  for (const AxNode &item : targets[0].container->children) {
    if (item.role != rules.roster.item_role)
      continue;
    if (result.participants.size() >= kMaxParticipants) {
      complete = false;
      break;
    }
    // Equal names stay separate participants, but one element cannot be two.
    if (item.object_id == 0 || !seen.insert(item.object_id).second) {
      complete = false;
      continue;
    }
    std::string name;
    if (item.value.size() > kMaxNameBytes ||
        clean_name(item.value, name) != NameCheck::Ok) {
      complete = false;
      continue;
    }
    Participant participant;
    participant.name = name;
    participant.key = linux_comparison_key(name);
    participant.object_id = item.object_id;
    if (!rules.roster.self_attribute.empty()) {
      const auto self = item.attributes.find(rules.roster.self_attribute);
      participant.self = self != item.attributes.end() &&
                         self->second == rules.roster.self_value;
    }
    result.participants.push_back(participant);
    speaking.push_back(rules.speaker.enabled &&
                       item.states.contains(rules.speaker.state));
  }
  // Self is only claimed when exactly one participant carries the marker.
  size_t selves = 0;
  for (const Participant &participant : result.participants)
    selves += participant.self;
  if (selves > 1) {
    for (Participant &participant : result.participants)
      participant.self = false;
    complete = false;
  }
  if (result.participants.empty())
    return refuse(complete ? "no_participant_evidence" : "incomplete_read");
  // Without a validated active-speaker signal an empty speaker list is
  // ignorance, not an observed absence.
  if (!rules.speaker.enabled)
    complete = false;
  if (complete)
    for (size_t i = 0; i < speaking.size(); ++i)
      if (speaking[i])
        result.speakers.push_back({i, Method::AtspiState});
  result.complete = complete;
  return result;
}

} // namespace foresight::zoom
