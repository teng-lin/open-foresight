// Pure parser for Zoom accessibility snapshots. Foundation string folding is
// used for localized comparisons; nothing here touches the Accessibility API.
#include "zoom_ax_parser.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <map>
#include <optional>
#include <string_view>

namespace foresight::zoom {
namespace {

// Phrases come from the Localizable.strings shipped inside Zoom 7.2.2 (88465)
// for its 17 localizations. They establish resource compatibility only: which
// nodes a live meeting exposes must be validated on a real call. Only English
// and Simplified Chinese are expected to be live-accepted first; every other
// row is fixture-covered data. Each status phrase must be unique across rows
// (checked by the parser test) so a phrase identifies exactly one locale.
constexpr LocalePatterns kLocales[] = {
    {"de",
     "Bei Computeraudio Stummschaltung deaktiviert",
     "Bei Computeraudio Stummschaltung aktiviert",
     "Aktiver Sprecher",
     {"Sprechen:", nullptr},
     "Teilnehmerliste",
     "ich",
     "Videominiaturansicht ausblenden",
     "Aktives Sprechervideo anzeigen"},
    {"en",
     "Computer audio unmuted",
     "Computer audio muted",
     "Active speaker",
     {"Talking:", nullptr},
     "Participants list",
     "me",
     "Hide thumbnail video",
     "Show active speaker video"},
    {"es",
     "Audio de la computadora no silenciado",
     "Audio de la computadora silenciado",
     "Orador activo",
     {"hablando:", nullptr},
     "Lista de participantes",
     "yo",
     "Ocultar vídeo en miniatura",
     "Mostrar el vídeo del hablante activo"},
    {"fr",
     "Son de l'ordinateur rétabli",
     "Ordinateur mis en sourdine",
     "Intervenant actif",
     {"la parole est à\u00a0:", nullptr},
     "Liste des participants",
     "moi",
     "Masquer la vignette de la vidéo",
     "Afficher la vidéo de l'intervenant actif"},
    {"id",
     "Audio komputer dibunyikan",
     "Audio komputer dibisukan",
     "Pembicara aktif",
     {"Berbicara:", nullptr},
     "Daftar peserta",
     "Saya",
     "Sembunyikan video gambar mini",
     "Tampilkan video pembicara aktif"},
    {"it",
     "Audio computer attivato",
     "Audio computer disattivato",
     "Oratore attivo",
     {"Conversazione:", "Conversazione in corso:"},
     "Elenco dei partecipanti",
     "io",
     "Nascondi video miniatura",
     "Mostra il video dell'oratore attivo"},
    {"ja",
     "ミュート解除されたコンピュータ オーディオ",
     "ミュートされたコンピュータ オーディオ",
     "アクティブ スピーカー",
     {"発言中:", nullptr},
     "参加者リスト",
     "自分",
     "サムネイル ビデオの非表示",
     "アクティブ スピーカー ビデオを表示"},
    {"ko",
     "컴퓨터 오디오 음소거 해제됨",
     "컴퓨터 오디오 음소거됨",
     "현재 발표자",
     {"말하는 중:", "말하기:"},
     "참가자 목록",
     "나",
     "썸네일 비디오 숨기기",
     "현재 발표자 비디오 표시"},
    {"nl",
     "Computeraudio ingeschakeld",
     "Computeraudio gedempt",
     "Actieve spreker",
     {"Aan het spreken:", nullptr},
     "Deelnemerslijst",
     "ik",
     "Miniatuurvideo verbergen",
     "Video van de actieve spreker weergeven"},
    {"pl",
     "Wyciszenie dźwięku z komputera wyłączone",
     "Dźwięk z komputera wyciszony",
     "Aktywny mówca",
     {"Mówi:", nullptr},
     "Lista uczestników",
     "ja",
     "Ukryj miniaturkę wideo",
     "Pokaż wideo aktywnego mówcy"},
    {"pt",
     "Áudio do computador ativado",
     "Áudio do computador desativado",
     "Orador ativo",
     {"Falando:", nullptr},
     "Lista de participantes",
     "eu",
     "Ocultar miniatura de vídeo",
     "Mostrar vídeo do orador ativo"},
    {"ru",
     "Звук компьютера включен",
     "Звук компьютера выключен",
     "Активный докладчик",
     {"говорит:", nullptr},
     "Список участников",
     "я",
     "Скрыть миниатюру видео",
     "Показывать видеоизображение активного докладчика"},
    {"sv",
     "Datorljudet aktiverades",
     "Datorljudet inaktiverades",
     "Aktiv talare",
     {"Talar:", nullptr},
     "Deltagarlista",
     "jag",
     "Dölj miniatyrbild av video",
     "Visa video med aktiv talare"},
    {"tr",
     "Bilgisayar sesi açıldı",
     "Bilgisayar sesi kapatıldı",
     "Aktif konuşmacı",
     {"Konuşan:", nullptr},
     "Katılımcı listesi",
     "ben",
     "Küçük resim videosunu gizle",
     "Aktif konuşmacı videosunu göster"},
    {"vi",
     "Âm thanh máy tính được hủy tắt tiếng",
     "Âm thanh máy tính bị tắt",
     "Diễn giả đang hoạt động",
     {"Đang nói:", "Trò chuyện:"},
     "Danh sách người tham gia",
     "tôi",
     "Ẩn video hình thu nhỏ",
     "Hiển thị video người nói đang hoạt động"},
    {"zh-Hans",
     "电脑音频开启",
     "电脑音频静音",
     "当前演讲者",
     {"正在发言：", nullptr},
     "参会者列表",
     "我",
     "隐藏视频缩略图",
     "显示当前演讲者的视频"},
    {"zh-Hant",
     "電腦音訊開啟",
     "電腦音訊靜音",
     "目前演講者",
     {"正在發言：", nullptr},
     "與會者清單",
     "我",
     "隱藏視訊縮圖",
     "顯示目前演講者的視訊"},
};
constexpr size_t kLocaleCount = sizeof(kLocales) / sizeof(kLocales[0]);

constexpr NSStringCompareOptions kFold = NSCaseInsensitiveSearch |
                                         NSDiacriticInsensitiveSearch |
                                         NSWidthInsensitiveSearch;

NSString *to_ns(const std::string &text) {
  return [[NSString alloc] initWithBytes:text.data()
                                  length:text.size()
                                encoding:NSUTF8StringEncoding];
}

NSString *to_ns(const char *text) {
  return text ? @(text) : nil;
}

std::string to_utf8(NSString *text) {
  const char *bytes = text.UTF8String;
  return bytes ? bytes : "";
}

bool is_separator(unichar c) {
  // ASCII, fullwidth and ideographic commas.
  return c == ',' || c == 0xFF0C || c == 0x3001;
}

NSString *trimmed(NSString *text) {
  return [text
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
}

NSString *strip_trailing_separators(NSString *text) {
  NSUInteger end = text.length;
  while (end > 0) {
    unichar c = [text characterAtIndex:end - 1];
    if (is_separator(c) ||
        [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c])
      --end;
    else
      break;
  }
  return [text substringToIndex:end];
}

bool fold_equal(NSString *a, NSString *b) {
  return [a compare:b options:kFold] == NSOrderedSame;
}

// Pattern strings are decoded once; the table is static data.
struct DecodedLocale {
  const LocalePatterns *source;
  NSString *unmuted, *muted, *active, *participants_list, *self_word, *hide,
      *show;
  NSString *talking[2];
};

const std::vector<DecodedLocale> &decoded_locales() {
  static const std::vector<DecodedLocale> locales = [] {
    std::vector<DecodedLocale> result;
    for (const auto &row : kLocales)
      result.push_back(
          {&row,
           to_ns(row.unmuted),
           to_ns(row.muted),
           to_ns(row.active_speaker),
           to_ns(row.participants_list),
           to_ns(row.self_word),
           to_ns(row.hide_thumbnail),
           to_ns(row.show_active_video),
           {to_ns(row.talking_prefix[0]), to_ns(row.talking_prefix[1])}});
    return result;
  }();
  return locales;
}

struct Tile {
  std::string name;
  AudioState audio = AudioState::Unknown;
  bool active = false;
  const DecodedLocale *locale = nullptr;
  uint64_t object_id = 0;
};

struct Context {
  size_t nodes = 0;
  bool truncated = false;
};

bool visit(Context &context, int depth) {
  if (depth > kMaxDepth || ++context.nodes > kMaxNodes) {
    context.truncated = true;
    return false;
  }
  return true;
}

// True when `text` (already trimmed) ends with `marker`, separated from what
// precedes it by a comma. `separator` receives that comma's index.
bool ends_with_marker(NSString *text, NSString *marker, NSUInteger &separator) {
  NSRange range =
      [text rangeOfString:marker
                  options:kFold | NSBackwardsSearch | NSAnchoredSearch];
  if (range.location == NSNotFound)
    return false;
  NSUInteger index = range.location;
  while (index > 0 && [NSCharacterSet.whitespaceAndNewlineCharacterSet
                          characterIsMember:[text characterAtIndex:index - 1]])
    --index;
  if (index == 0 || !is_separator([text characterAtIndex:index - 1]))
    return false;
  separator = index - 1;
  return true;
}

// True when the text holds nothing a person could read: whitespace, control or
// invisible format characters (zero-width space/joiners, bidi marks, BOM).
bool invisible_only(NSString *text) {
  NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
  for (NSUInteger i = 0; i < text.length; ++i) {
    unichar c = [text characterAtIndex:i];
    bool invisible = [space characterIsMember:c] || c < 0x20 ||
                     (c >= 0x7F && c < 0xA0) || c == 0x00AD || c == 0x061C ||
                     c == 0x180E || (c >= 0x200B && c <= 0x200F) ||
                     (c >= 0x202A && c <= 0x202E) ||
                     (c >= 0x2060 && c <= 0x206F) || c == 0xFEFF;
    if (!invisible)
      return false;
  }
  return true;
}

// True when `text` contains any locale's audio status or active-speaker phrase.
bool contains_status_text(NSString *text) {
  for (const auto &locale : decoded_locales())
    for (NSString *phrase : {locale.unmuted, locale.muted, locale.active})
      if ([text rangeOfString:phrase options:kFold].location != NSNotFound)
        return true;
  return false;
}

// True when `text` holds `marker` as a comma-separated item that is not the
// last one (`<x>, Active speaker, <y>`).
bool has_inner_marker(NSString *text, NSString *marker) {
  NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
  NSRange search = NSMakeRange(0, text.length);
  for (;;) {
    NSRange found = [text rangeOfString:marker options:kFold range:search];
    if (found.location == NSNotFound)
      return false;
    NSUInteger before = found.location;
    while (before > 0 &&
           [space characterIsMember:[text characterAtIndex:before - 1]])
      --before;
    NSUInteger after = NSMaxRange(found);
    while (after < text.length &&
           [space characterIsMember:[text characterAtIndex:after]])
      ++after;
    bool starts_item =
        before > 0 && is_separator([text characterAtIndex:before - 1]);
    bool inner = after < text.length && is_separator([text
                                            characterAtIndex:after]);
    if (starts_item && inner)
      return true;
    search = NSMakeRange(NSMaxRange(found), text.length - NSMaxRange(found));
  }
}

// A tile is `<name>, <audio status>[, <active marker>][, other details]`.
//
// The status anchors on its LAST occurrence: Zoom writes it after the name. If
// the text before it still contains any status or marker phrase, the name is
// ambiguous and the tile is dropped. The research rule took the earliest
// phrase.
//
// The marker makes the tile active only as the LAST item after the status. A
// marker that is a separated item but not last (`..., Active speaker, Video
// on`) is not a structure we have seen: the tile stays inactive but the read is
// incomplete, since a confident "nobody is speaking" would be a guess.
//
// A description with an active marker but no audio status is not accepted as a
// tile: that structure is unvalidated and a participant named "Eve, Active
// speaker" would otherwise become a speaker. It marks the read incomplete.
std::optional<Tile> parse_tile(const AxNode &node, bool &dropped) {
  NSString *description = to_ns(node.description);
  if (!description) {
    if (!node.description.empty())
      dropped = true;
    return std::nullopt;
  }
  struct Match {
    const DecodedLocale *locale = nullptr;
    NSRange range{NSNotFound, 0};
    AudioState audio = AudioState::Unknown;
  } best;
  for (const auto &locale : decoded_locales()) {
    for (int muted = 0; muted < 2; ++muted) {
      NSString *phrase = muted ? locale.muted : locale.unmuted;
      NSRange range = [description rangeOfString:phrase
                                         options:kFold | NSBackwardsSearch];
      if (range.location == NSNotFound)
        continue;
      // The last status wins; a longer phrase wins a tie.
      if (best.locale == nullptr || range.location > best.range.location ||
          (range.location == best.range.location &&
           range.length > best.range.length))
        best = {&locale, range,
                muted ? AudioState::Muted : AudioState::Unmuted};
    }
  }
  if (!best.locale) {
    NSString *whole = trimmed(description);
    for (const auto &locale : decoded_locales()) {
      NSUInteger separator = 0;
      if (ends_with_marker(whole, locale.active, separator)) {
        dropped = true;
        break;
      }
    }
    return std::nullopt;
  }
  // A name that itself holds status or marker text cannot be told from Zoom's
  // own words (`Mallory, Computer audio unmuted, Active speaker, <real
  // status>`). The tile is ambiguous: drop it, mark the read incomplete, and
  // never use it as locale evidence. A description made only of
  // attacker-controlled text with no real status is structurally identical to a
  // genuine tile and cannot be detected here.
  if (contains_status_text(
          [description substringToIndex:best.range.location])) {
    dropped = true;
    return std::nullopt;
  }
  Tile tile;
  tile.object_id = node.object_id;
  NSString *rest =
      trimmed([description substringFromIndex:NSMaxRange(best.range)]);
  NSUInteger separator = 0;
  tile.active = ends_with_marker(rest, best.locale->active, separator);
  if (!tile.active)
    for (const auto &locale : decoded_locales())
      if (has_inner_marker(rest, locale.active)) {
        dropped = true; // a marker that is not last: inactive but unsure
        break;
      }
  tile.audio = best.audio;
  tile.locale = best.locale;
  NSString *name = trimmed(strip_trailing_separators(
      [description substringToIndex:best.range.location]));
  if (invisible_only(name)) {
    dropped = true; // a status without a readable name is an unnamed tile
    return std::nullopt;
  }
  tile.name = to_utf8(name);
  if (tile.name.empty() || tile.name.size() > kMaxNameBytes) {
    dropped = true;
    return std::nullopt;
  }
  return tile;
}

void collect_tiles(const AxNode &node, int depth, Context &context,
                   bool &dropped, std::vector<Tile> &tiles) {
  if (!visit(context, depth))
    return;
  if (node.role == "AXTabGroup") {
    if (auto tile = parse_tile(node, dropped)) {
      tiles.push_back(std::move(*tile));
      return;
    }
  }
  for (const auto &child : node.children)
    collect_tiles(child, depth + 1, context, dropped, tiles);
}

// "Name (me)", "Name (host, me)" and "Name (Host) (me)": a final parenthetical
// listing the locale's self word. Anything after it (for example an audio
// status) is rejected.
std::optional<std::string> parse_self_label(NSString *value,
                                            NSString *self_word) {
  NSString *text = trimmed(value);
  if (text.length < 3)
    return std::nullopt;
  unichar close = [text characterAtIndex:text.length - 1];
  if (close != ')' && close != 0xFF09)
    return std::nullopt;
  NSUInteger open = NSNotFound;
  for (NSUInteger i = text.length - 1; i-- > 0;) {
    unichar c = [text characterAtIndex:i];
    if (c == '(' || c == 0xFF08) {
      open = i;
      break;
    }
  }
  if (open == NSNotFound)
    return std::nullopt;
  NSString *inside =
      [text substringWithRange:NSMakeRange(open + 1, text.length - open - 2)];
  bool listed = false;
  NSUInteger start = 0;
  for (NSUInteger i = 0; i <= inside.length; ++i) {
    if (i == inside.length || is_separator([inside characterAtIndex:i])) {
      NSString *item =
          trimmed([inside substringWithRange:NSMakeRange(start, i - start)]);
      if (item.length > 0 && fold_equal(item, self_word))
        listed = true;
      start = i + 1;
    }
  }
  if (!listed)
    return std::nullopt;
  NSString *name = trimmed([text substringToIndex:open]);
  if (name.length == 0)
    return std::nullopt;
  std::string result = to_utf8(name);
  if (result.empty() || result.size() > kMaxNameBytes)
    return std::nullopt;
  return result;
}

struct SelfEvidence {
  std::vector<std::string> names; // distinct comparison keys
};

void collect_self_text(const AxNode &node, int depth, Context &context,
                       const DecodedLocale &locale, SelfEvidence &evidence) {
  if (!visit(context, depth))
    return;
  if (node.role == "AXStaticText") {
    if (NSString *value = to_ns(node.value)) {
      if (auto name = parse_self_label(value, locale.self_word)) {
        std::string key = comparison_key(*name);
        if (std::find(evidence.names.begin(), evidence.names.end(), key) ==
            evidence.names.end()) {
          evidence.names.push_back(key);
        }
      }
    }
  }
  for (const auto &child : node.children)
    collect_self_text(child, depth + 1, context, locale, evidence);
}

void collect_self(const AxNode &node, int depth, Context &context,
                  const DecodedLocale &locale, SelfEvidence &evidence) {
  if (!visit(context, depth))
    return;
  if (node.role == "AXOutline") {
    if (NSString *description = to_ns(node.description)) {
      if (fold_equal(trimmed(description), locale.participants_list)) {
        // The Participants-list visit shares this pass's node budget.
        collect_self_text(node, depth, context, locale, evidence);
        return;
      }
    }
  }
  for (const auto &child : node.children)
    collect_self(child, depth + 1, context, locale, evidence);
}

struct Compact {
  const DecodedLocale *locale = nullptr;
  size_t labels = 0;
  // A direct static text with an empty or undecodable value: it could have been
  // the talking label, so absence cannot be asserted.
  bool unreadable = false;
  std::optional<std::string> name;
};

// A compact window is an AXWindow whose direct children include both
// localized controls. The two-child "Show video render" shape is not accepted
// until it has a live-validated fixture.
std::optional<Compact> parse_compact(const AxNode &window) {
  for (const auto &locale : decoded_locales()) {
    bool hide = false, show = false;
    for (const auto &child : window.children) {
      if (child.role != "AXButton")
        continue;
      NSString *description = to_ns(child.description);
      if (!description)
        continue;
      NSString *label = trimmed(description);
      hide = hide || fold_equal(label, locale.hide);
      show = show || fold_equal(label, locale.show);
    }
    if (!hide || !show)
      continue;
    Compact compact;
    compact.locale = &locale;
    for (const auto &child : window.children) {
      if (child.role != "AXStaticText")
        continue;
      NSString *value = to_ns(child.value);
      if (!value || value.length == 0) {
        compact.unreadable = true;
        continue;
      }
      for (NSString *prefix : locale.talking) {
        if (!prefix)
          continue;
        NSRange range = [value rangeOfString:prefix
                                     options:kFold | NSAnchoredSearch];
        if (range.location == NSNotFound)
          continue;
        ++compact.labels;
        NSString *name = trimmed([value substringFromIndex:NSMaxRange(range)]);
        bool usable = !invisible_only(name);
        for (NSUInteger i = 0; usable && i < name.length; ++i) {
          unichar c = [name characterAtIndex:i];
          // A list of names is not one speaker.
          if (is_separator(c) || c < 0x20)
            usable = false;
        }
        std::string text = to_utf8(name);
        if (usable && !text.empty() && text.size() <= kMaxNameBytes)
          compact.name = text;
        else
          compact.name.reset();
        break;
      }
    }
    return compact;
  }
  return std::nullopt;
}

ParseResult unavailable(const char *reason) {
  ParseResult result;
  result.reason = reason;
  return result;
}

bool numeric(std::string_view part) {
  return !part.empty() && part.size() <= 9 &&
         std::all_of(part.begin(), part.end(),
                     [](unsigned char c) { return c >= '0' && c <= '9'; });
}

} // namespace

const LocalePatterns *locale_patterns(size_t &count) {
  count = kLocaleCount;
  return kLocales;
}

bool locale_supported(const std::string &localization) {
  std::string_view value(localization);
  for (const auto &row : kLocales)
    if (value == row.id)
      return true;
  // "ko-KR" and "pt-PT" are Zoom's regional resource names. Chinese needs its
  // script, and other regions of a shipped language map to that language.
  auto dash = value.find_first_of("-_");
  std::string_view language = value.substr(0, dash);
  if (language == "zh")
    return value.find("Hans") != std::string_view::npos ||
           value.find("Hant") != std::string_view::npos;
  if (language == "pt")
    return value == "pt-PT"; // Brazilian Portuguese is not shipped
  for (const auto &row : kLocales)
    if (language == row.id)
      return true;
  return false;
}

std::string comparison_key(const std::string &name) {
  @autoreleasepool {
    NSString *text = to_ns(name);
    if (!text)
      return name;
    text = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:nil]
               .precomposedStringWithCanonicalMapping;
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in
         [text componentsSeparatedByCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet])
      if (word.length > 0)
        [words addObject:word];
    return to_utf8([words componentsJoinedByString:@" "]);
  }
}

bool zoom_version_supported(const std::string &bundle_version) {
  std::vector<std::string_view> parts;
  std::string_view rest(bundle_version);
  for (;;) {
    auto dot = rest.find('.');
    parts.push_back(rest.substr(0, dot));
    if (dot == std::string_view::npos)
      break;
    rest.remove_prefix(dot + 1);
  }
  if (parts.size() < 2 || parts.size() > 4)
    return false;
  for (auto part : parts)
    if (!numeric(part))
      return false;
  return parts[0] == "7" && parts[1] == "2";
}

namespace {
ParseResult parse_snapshot_impl(const AxSnapshot &snapshot) {
  std::vector<const AxNode *> windows;
  if (snapshot.root.role == "AXWindow") {
    windows.push_back(&snapshot.root);
  } else if (snapshot.root.role == "AXApplication") {
    for (const auto &child : snapshot.root.children)
      if (child.role == "AXWindow")
        windows.push_back(&child);
  } else {
    return unavailable("unexpected_root");
  }
  if (windows.empty())
    return unavailable(snapshot.truncated ? "incomplete_read"
                                          : "no_meeting_window");

  bool dropped = false;
  Context tile_context;
  std::vector<std::vector<Tile>> window_tiles(windows.size());
  size_t tile_windows = 0;
  size_t chosen = 0;
  for (size_t i = 0; i < windows.size(); ++i) {
    collect_tiles(*windows[i], 0, tile_context, dropped, window_tiles[i]);
    if (!window_tiles[i].empty()) {
      ++tile_windows;
      chosen = i;
    }
  }
  if (tile_windows > 1)
    return unavailable("ambiguous_windows");

  ParseResult result;
  const DecodedLocale *locale = nullptr;
  bool conflict = false;
  auto note_locale = [&](const DecodedLocale *seen) {
    if (!seen)
      return;
    if (!locale)
      locale = seen;
    else if (locale != seen)
      conflict = true;
  };

  std::vector<Tile> tiles;
  std::optional<Compact> compact;
  if (tile_windows == 1) {
    tiles = std::move(window_tiles[chosen]);
  } else if (!snapshot.truncated && !tile_context.truncated && !dropped) {
    // Compact inference is a fallback for snapshots that are known complete,
    // have no ordinary tile, and dropped no tile-like node.
    size_t compact_windows = 0;
    for (size_t i = 0; i < windows.size(); ++i) {
      if (auto found = parse_compact(*windows[i])) {
        ++compact_windows;
        chosen = i;
        compact = found;
      }
    }
    if (compact_windows > 1)
      return unavailable("ambiguous_windows");
  }
  if (tiles.empty() && !compact) {
    // No evidence from an incomplete read is a failed read, never a quiet
    // meeting: the missing part of the tree may have held the tiles.
    bool incomplete = snapshot.truncated || tile_context.truncated || dropped;
    return unavailable(incomplete ? "incomplete_read"
                                  : "no_participant_evidence");
  }

  if (tiles.size() > kMaxParticipants) {
    tiles.resize(kMaxParticipants);
    dropped = true;
  }
  result.window_index = static_cast<int>(chosen);
  result.window_object_id = windows[chosen]->object_id;

  // One meeting has one locale. If tiles disagree, a clear majority wins and
  // the outliers (a hostile name, a stray label) are dropped as an incomplete
  // read; without a majority the conflict stands.
  {
    std::map<const DecodedLocale *, size_t> counts;
    for (const auto &tile : tiles)
      ++counts[tile.locale];
    if (counts.size() > 1) {
      for (const auto &[candidate, count] : counts)
        if (count > tiles.size() - count) {
          std::vector<Tile> kept;
          for (auto &tile : tiles)
            if (tile.locale == candidate)
              kept.push_back(std::move(tile));
          tiles = std::move(kept);
          dropped = true;
          break;
        }
    }
  }
  for (size_t i = 0; i < tiles.size(); ++i) {
    note_locale(tiles[i].locale);
    // The same element twice is a traversal anomaly, not two participants.
    bool repeated = false;
    if (tiles[i].object_id != 0)
      for (size_t j = 0; j < i && !repeated; ++j)
        repeated = tiles[j].object_id == tiles[i].object_id;
    if (repeated) {
      dropped = true;
      continue;
    }
    Participant participant;
    participant.name = tiles[i].name;
    participant.key = comparison_key(tiles[i].name);
    participant.audio = tiles[i].audio;
    participant.object_id = tiles[i].object_id;
    result.participants.push_back(std::move(participant));
    if (tiles[i].active)
      result.speakers.push_back(
          {result.participants.size() - 1, Method::ParticipantStatus});
  }

  bool compact_conflict = false;
  if (compact) {
    note_locale(compact->locale);
    if (compact->name && compact->labels == 1 && !compact->unreadable) {
      Participant participant;
      participant.name = *compact->name;
      participant.key = comparison_key(participant.name);
      result.participants.push_back(std::move(participant));
      result.speakers.push_back({0, Method::CompactTalkingLabel});
    } else if (compact->labels > 0 || compact->unreadable) {
      compact_conflict = true; // several or unusable labels: unknown speaker
    }
  }

  // Locale comes from tile statuses and compact controls only. The
  // Participants-list label is shared by some locales (Spanish, Portuguese) and
  // a self word must never contradict an established meeting locale.
  if (conflict)
    return unavailable("locale_conflict");
  SelfEvidence self_evidence;
  Context self_context;
  if (locale)
    for (const auto *window : windows)
      collect_self(*window, 0, self_context, *locale, self_evidence);
  if (self_context.truncated)
    dropped = true;
  if (self_evidence.names.size() == 1) {
    // Mark self only when exactly one participant carries that name.
    size_t matches = 0, index = 0;
    for (size_t i = 0; i < result.participants.size(); ++i)
      if (result.participants[i].key == self_evidence.names[0]) {
        ++matches;
        index = i;
      }
    if (matches == 1)
      result.participants[index].self = true;
  }

  result.available = true;
  result.locale = locale ? locale->source->id : "";
  result.complete = !snapshot.truncated && !tile_context.truncated &&
                    !dropped && !compact_conflict;
  return result;
}

} // namespace

// The caller may have no autorelease pool (the helper's loop is plain C++);
// without one, every folded string and UTF8String buffer would live until exit.
ParseResult parse_snapshot(const AxSnapshot &snapshot) {
  @autoreleasepool {
    return parse_snapshot_impl(snapshot);
  }
}

} // namespace foresight::zoom
