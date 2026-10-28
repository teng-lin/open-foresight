#pragma once
// Pure Zoom accessibility-snapshot parser. It consumes a plain snapshot tree
// (role, description, value, identifier, children) and has no dependency on the
// Accessibility API or on operating-system permission, so fixtures can exercise
// every evidence path. All strings are UTF-8 and untrusted source data.
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace foresight::zoom {

inline constexpr const char *kParserVersion = "mac-1";
// Bounds shared with docs/architecture/speaker-observer-protocol.md. The
// collector enforces them while reading; the parser enforces them again so a
// hostile or buggy snapshot cannot exhaust the stack or the frame limit.
inline constexpr int kMaxDepth = 64;
inline constexpr size_t kMaxNodes = 20000;
inline constexpr size_t kMaxParticipants = 256;
inline constexpr size_t kMaxNameBytes = 512;

struct AxNode {
  std::string role;
  std::string description;
  std::string value;
  std::string identifier;
  // Collector-assigned identity, stable while the same accessibility element
  // is alive within one helper process; 0 when unknown.
  uint64_t object_id = 0;
  std::vector<AxNode> children;
};

struct AxSnapshot {
  // An AXApplication whose children are AXWindow nodes, or a single AXWindow.
  AxNode root;
  // True when a depth/node/time bound or a failed attribute read left the tree
  // incomplete. Compact-window inference is disabled for incomplete snapshots.
  bool truncated = false;
};

enum class AudioState { Unknown, Muted, Unmuted };
enum class Method { ParticipantStatus, CompactTalkingLabel };

struct Participant {
  std::string name; // display spelling, only trimmed at the edges
  std::string key;  // comparison form: folded case/diacritics/width, spaces
  AudioState audio = AudioState::Unknown;
  bool self = false;
  uint64_t object_id = 0;
};

struct Speaker {
  size_t participant = 0; // index into ParseResult::participants
  Method method = Method::ParticipantStatus;
};

struct ParseResult {
  // False means no usable evidence; `reason` is a stable token.
  bool available = false;
  std::string reason;
  // Locale pattern-set id that produced the evidence (for example "en"), or
  // empty when unknown.
  std::string locale;
  // True only when every bound held and no candidate was dropped. Speakers
  // empty with complete=true is an observed absence of an active speaker.
  bool complete = false;
  // Index of the chosen AXWindow among the root's children (0 for a root that
  // is itself a window) and its collector identity.
  int window_index = -1;
  uint64_t window_object_id = 0;
  std::vector<Participant> participants;
  std::vector<Speaker> speakers;
};

ParseResult parse_snapshot(const AxSnapshot &snapshot);

// Comparison normalization: fold case, diacritics and character width, then
// collapse whitespace. Never used for display.
std::string comparison_key(const std::string &name);

// Initial acceptance covers Zoom 7.2.x on macOS. Anything else is reported as
// unsupported_version until its explicit markers are validated live.
bool zoom_version_supported(const std::string &bundle_version);

// Data-table access for tests.
struct LocalePatterns {
  const char *id;
  const char *unmuted;
  const char *muted;
  const char *active_speaker;
  // One or two accepted `Talking:` label prefixes (second may be nullptr).
  const char *talking_prefix[2];
  const char *participants_list;
  const char *self_word;
  const char *hide_thumbnail;
  const char *show_active_video;
};
const LocalePatterns *locale_patterns(size_t &count);

// True when a BCP 47 style localization name (for example "ko-KR", "pt-BR" or
// "zh-Hans") maps to a pattern set. Unsupported locales report unavailable.
bool locale_supported(const std::string &localization);

} // namespace foresight::zoom
