import 'dart:convert';

/// Why a saved transcript row does or does not carry a person name. The
/// distinct non-attributed states stay separate so a later consumer can explain
/// a missing name; only [attributed] renders a name.
enum AttributionState {
  attributed,
  unknown,
  multiple,
  stale,
  unavailable;

  static AttributionState parse(String value) => values.firstWhere(
    (state) => state.name == value,
    orElse: () => throw FormatException('Unknown attribution state: $value'),
  );
}

/// Evidence method names are stored as bounded text so adding one needs no
/// schema migration. [manual] is reserved for user corrections.
abstract final class AttributionMethod {
  static const manual = 'manual';
  static const participantStatus = 'participant_status';
  static const compactTalkingLabel = 'compact_talking_label';
  static const layoutInference = 'layout_inference';
}

/// Every text limit counts Unicode code points, in Dart and in SQLite alike.
const maxParticipantNameLength = 500;
const maxParticipantKeyLength = 512;
const maxAttributionTokenLength = 64;

/// Compact timing evidence. The cap covers the largest core evidence (eight
/// candidate references of 128 code points each, plus an epoch prefix, about
/// 3.1 KB when non-ASCII) with margin; it remains a bound, not a tree dump.
const maxAttributionEvidenceBytes = 4096;
const maxRenderedNameLength = 120;
const maxParticipantBatch = 256;

/// SQLite extended result codes a rejected attribution reports. Only these
/// numbers are surfaced for a rejection, never the exception or its bound
/// parameters (which can contain participant names).
const sqliteConstraintForeignKey = 787;
const sqliteConstraintTrigger = 1811;

int _runeCount(String value) => value.runes.length;

String _truncateRunes(String value, int maximum) => _runeCount(value) <= maximum
    ? value
    : String.fromCharCodes(value.runes.take(maximum));

/// Format, bidirectional and invisible-selector characters that are removed
/// from rendered names: soft hyphen, Arabic letter mark, zero-width space,
/// directional marks, embeddings and isolates, the word joiner and invisible
/// math operators, deprecated format controls, variation selectors, the BOM and
/// tag characters.
bool _stripped(int rune) =>
    rune == 0x00ad ||
    rune == 0x061c ||
    rune == 0x200b ||
    (rune >= 0x200e && rune <= 0x200f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x2064) ||
    (rune >= 0x2066 && rune <= 0x206f) ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    rune == 0xfeff ||
    (rune >= 0xe0000 && rune <= 0xe007f) ||
    (rune >= 0xe0100 && rune <= 0xe01ef);

bool _whitespace(int rune) =>
    rune <= 0x20 ||
    (rune >= 0x7f && rune <= 0xa0) ||
    rune == 0x2028 ||
    rune == 0x2029;

/// Joiners are kept in rendered text (they are part of some names) but never
/// count as visible content.
bool _joiner(int rune) => rune == 0x200c || rune == 0x200d;

/// Collapse an untrusted participant name into the one-line label used inside
/// the indexed `[label start–end ms]` prefix. The stored display name is never
/// changed. This derived form removes line breaks, format and bidirectional
/// controls and the prefix bracket characters that could forge another
/// transcript prefix; it is empty when no visible character remains.
String renderedAttributionName(String displayName) {
  final buffer = StringBuffer();
  var pendingSpace = false, visible = false;
  for (final rune in displayName.runes) {
    if (_stripped(rune)) continue;
    if (_whitespace(rune)) {
      pendingSpace = buffer.isNotEmpty;
      continue;
    }
    if (pendingSpace) buffer.write(' ');
    pendingSpace = false;
    if (!_joiner(rune)) visible = true;
    buffer.write(switch (rune) {
      0x5b => '(',
      0x5d => ')',
      _ => String.fromCharCode(rune),
    });
  }
  if (!visible) return '';
  final text = buffer.toString();
  return _runeCount(text) <= maxRenderedNameLength
      ? text
      : _truncateRunes(text, maxRenderedNameLength).trimRight();
}

void _bounded(String name, String value, int maximum, {bool required = false}) {
  final count = _runeCount(value);
  // SQLite's length() stops at U+0000, so a NUL would fail the CHECK limits
  // (and lose a whole batch); it is never valid in stored text.
  if (count > maximum || (required && count == 0) || value.contains('\u0000')) {
    throw ArgumentError.value(
      count,
      name,
      required
          ? 'must contain 1–$maximum characters without U+0000'
          : 'must contain at most $maximum characters without U+0000',
    );
  }
}

String _withoutNul(String value) => value.replaceAll('\u0000', '');

/// Maximum evidence nesting. SQLite's json_valid rejects more than 999 levels;
/// real evidence is flat, so this keeps a wide margin.
const maxAttributionEvidenceDepth = 32;

/// Copy JSON-compatible [value] with sorted keys, rejecting anything that is
/// not finite JSON or nests too deeply (which also stops cycles).
Object? _canonicalValue(Object? value, int depth) {
  if (depth > maxAttributionEvidenceDepth) {
    throw ArgumentError.value(
      'evidence',
      'evidence',
      'Evidence nests deeper than $maxAttributionEvidenceDepth levels',
    );
  }
  return switch (value) {
    null || bool() || String() => value,
    int() => value,
    double() when value.isFinite => value,
    List() => [for (final item in value) _canonicalValue(item, depth + 1)],
    Map() => _canonicalMap(value, depth),
    _ => throw ArgumentError.value(
      'evidence',
      'evidence',
      'Evidence must be finite JSON values',
    ),
  };
}

Map<String, Object?> _canonicalMap(Map<Object?, Object?> value, int depth) {
  if (value.keys.any((key) => key is! String)) {
    throw ArgumentError.value(
      'evidence',
      'evidence',
      'Evidence keys must be strings',
    );
  }
  final keys = value.keys.cast<String>().toList()..sort();
  return <String, Object?>{
    for (final key in keys) key: _canonicalValue(value[key], depth + 1),
  };
}

/// Validate and canonicalize evidence once, at construction, so later changes
/// to the caller's map or its nested values cannot alter what is stored, and
/// equal evidence always has equal text.
String _canonicalEvidence(Map<String, Object?> evidence) {
  final encoded = jsonEncode(_canonicalValue(evidence, 0));
  if (utf8.encode(encoded).length > maxAttributionEvidenceBytes) {
    throw ArgumentError.value(
      'evidence',
      'evidence',
      'Timing evidence exceeds $maxAttributionEvidenceBytes bytes',
    );
  }
  return encoded;
}

Object? _freeze(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _freeze(entry.value),
  }),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

/// A person observed in one meeting. Identity is meeting-local: [scope] names
/// the recording-session/window the observer read and [identityKey] is that
/// observer's object identity inside it. A display name is never an identity,
/// so duplicate names and rejoining participants stay separate until the
/// observer proves continuity.
final class MeetingParticipant {
  MeetingParticipant({
    this.id,
    required this.scope,
    required this.identityKey,
    required this.displayName,
    this.isSelf = false,
    required this.firstSeenMs,
    required this.lastSeenMs,
    this.previousDisplayName,
    this.renameCount = 0,
    this.nameChangedMs,
    this.nameManual = false,
  }) {
    _bounded('scope', scope, maxParticipantKeyLength, required: true);
    _bounded(
      'identityKey',
      identityKey,
      maxParticipantKeyLength,
      required: true,
    );
    _bounded(
      'displayName',
      displayName,
      maxParticipantNameLength,
      required: true,
    );
    if (renderedAttributionName(displayName).isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'A participant requires a visible name',
      );
    }
    if (previousDisplayName != null) {
      _bounded(
        'previousDisplayName',
        previousDisplayName!,
        maxParticipantNameLength,
      );
    }
    if (firstSeenMs < 0 || lastSeenMs < firstSeenMs) {
      throw ArgumentError('Participant seen interval is not ordered');
    }
  }

  /// Non-throwing entry point for observed data: truncates the name to the
  /// limit and returns null when the participant cannot be stored (empty or
  /// oversized key, no visible name, unordered times). Keys are never
  /// truncated, because that could merge two identities.
  static MeetingParticipant? tryCreate({
    required String scope,
    required String identityKey,
    required String displayName,
    bool isSelf = false,
    required int firstSeenMs,
    required int lastSeenMs,
  }) {
    try {
      return MeetingParticipant(
        scope: scope,
        identityKey: identityKey,
        displayName: _truncateRunes(
          _withoutNul(displayName),
          maxParticipantNameLength,
        ),
        isSelf: isSelf,
        firstSeenMs: firstSeenMs,
        lastSeenMs: lastSeenMs,
      );
    } on ArgumentError {
      return null;
    }
  }

  factory MeetingParticipant.fromRow(Map<String, Object?> row) =>
      MeetingParticipant(
        id: row['id'] as int,
        scope: row['scope'] as String,
        identityKey: row['identity_key'] as String,
        displayName: row['display_name'] as String,
        isSelf: row['is_self'] == 1,
        firstSeenMs: row['first_seen_ms'] as int,
        lastSeenMs: row['last_seen_ms'] as int,
        previousDisplayName: row['previous_display_name'] as String?,
        renameCount: row['rename_count'] as int,
        nameChangedMs: row['name_changed_ms'] as int?,
        nameManual: row['name_manual'] == 1,
      );

  factory MeetingParticipant.fromJson(Map<String, Object?> json) =>
      MeetingParticipant(
        id: json['id'] as int?,
        scope: json['scope'] as String,
        identityKey: json['identity_key'] as String,
        displayName: json['display_name'] as String,
        isSelf: json['self'] == true,
        firstSeenMs: json['first_seen_ms'] as int,
        lastSeenMs: json['last_seen_ms'] as int,
        previousDisplayName: json['previous_display_name'] as String?,
        renameCount: json['rename_count'] as int? ?? 0,
        nameChangedMs: json['name_changed_ms'] as int?,
        nameManual: json['name_manual'] == true,
      );

  /// Database identity; null until the participant has been saved.
  final int? id;

  /// Session/window scope the observer used for [identityKey].
  final String scope;
  final String identityKey;

  /// Latest observed (or manually assigned) spelling, kept verbatim.
  final String displayName;
  final bool isSelf;

  /// Millisecond marks on the saved transcript timeline.
  final int firstSeenMs, lastSeenMs;

  /// Rename tracking: the immediately previous spelling, how many renames were
  /// recorded and when the current spelling was first seen.
  final String? previousDisplayName;
  final int renameCount;
  final int? nameChangedMs;

  /// A user-assigned name that later observations must not replace.
  final bool nameManual;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'scope': scope,
    'identity_key': identityKey,
    'display_name': displayName,
    'self': isSelf,
    'first_seen_ms': firstSeenMs,
    'last_seen_ms': lastSeenMs,
    if (previousDisplayName != null)
      'previous_display_name': previousDisplayName,
    'rename_count': renameCount,
    if (nameChangedMs != null) 'name_changed_ms': nameChangedMs,
    'name_manual': nameManual,
  };
}

/// Persisted association between one transcript row and a person. It never
/// replaces raw transcript text and never changes the legacy audio channel.
final class TranscriptAttribution {
  TranscriptAttribution({
    this.participantId,
    this.displayName = '',
    required this.state,
    this.method = '',
    this.parserVersion = '',
    this.policyVersion = '',
    Map<String, Object?> evidence = const {},
    this.manual = false,
    this.transcriptId,
    this.revision,
    this.updatedMs,
  }) : evidenceJson = _canonicalEvidence(evidence) {
    _bounded('displayName', displayName, maxParticipantNameLength);
    _bounded('method', method, maxAttributionTokenLength);
    _bounded('parserVersion', parserVersion, maxAttributionTokenLength);
    _bounded('policyVersion', policyVersion, maxAttributionTokenLength);
    if (state == AttributionState.attributed &&
        renderedAttributionName(displayName).isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'An attributed segment requires a visible name',
      );
    }
    if (manual && method != AttributionMethod.manual) {
      throw ArgumentError.value(method, 'method', 'Manual rows use "manual"');
    }
  }

  /// Non-throwing entry point for observed data, so a limit can never stop a
  /// transcript from being saved. Names are truncated to the limit. Anything
  /// else out of bounds (oversized method or version, evidence that is too
  /// large or not finite JSON, or an attributed name with no visible
  /// character) downgrades the result to [AttributionState.unknown], dropping
  /// the evidence and name rather than guessing.
  factory TranscriptAttribution.clamped({
    int? participantId,
    String displayName = '',
    required AttributionState state,
    String method = '',
    String parserVersion = '',
    String policyVersion = '',
    Map<String, Object?> evidence = const {},
  }) {
    try {
      return TranscriptAttribution(
        participantId: participantId,
        displayName: _truncateRunes(
          _withoutNul(displayName),
          maxParticipantNameLength,
        ),
        state: state,
        method: method,
        parserVersion: parserVersion,
        policyVersion: policyVersion,
        evidence: evidence,
      );
    } on Object {
      // Any construction failure, including an unencodable evidence value.
      return TranscriptAttribution(state: AttributionState.unknown);
    }
  }

  /// A user correction. It names [participantId]/[displayName] and survives
  /// every later automatic observation until explicitly reset.
  factory TranscriptAttribution.manual({
    int? participantId,
    required String displayName,
    Map<String, Object?> evidence = const {},
  }) => TranscriptAttribution(
    participantId: participantId,
    displayName: displayName,
    state: AttributionState.attributed,
    method: AttributionMethod.manual,
    evidence: evidence,
    manual: true,
  );

  /// A user decision that this segment must not carry a person name; it keeps
  /// the channel label and blocks automatic naming.
  factory TranscriptAttribution.manualUnnamed() => TranscriptAttribution(
    state: AttributionState.unknown,
    method: AttributionMethod.manual,
    manual: true,
  );

  factory TranscriptAttribution.fromRow(Map<String, Object?> row) =>
      TranscriptAttribution(
        participantId: row['participant_id'] as int?,
        displayName: row['display_name'] as String,
        state: AttributionState.parse(row['state'] as String),
        method: row['method'] as String,
        parserVersion: row['parser_version'] as String,
        policyVersion: row['policy_version'] as String,
        evidence: Map<String, Object?>.from(
          jsonDecode(row['evidence'] as String) as Map,
        ),
        manual: row['manual'] == 1,
        transcriptId: row['transcript_id'] as int,
        revision: row['revision'] as int,
        updatedMs: row['updated_ms'] as int,
      );

  factory TranscriptAttribution.fromJson(Map<String, Object?> json) =>
      TranscriptAttribution(
        participantId: json['participant_id'] as int?,
        displayName: json['display_name'] as String? ?? '',
        state: AttributionState.parse(json['state'] as String),
        method: json['method'] as String? ?? '',
        parserVersion: json['parser_version'] as String? ?? '',
        policyVersion: json['policy_version'] as String? ?? '',
        evidence: Map<String, Object?>.from(json['evidence'] as Map? ?? {}),
        manual: json['manual'] == true,
      );

  /// Meeting-local participant row, when the observer's roster was saved.
  final int? participantId;

  /// Name as observed when this row was attributed; later renames never edit it
  /// implicitly.
  final String displayName;
  final AttributionState state;
  final String method;
  final String parserVersion, policyVersion;

  /// Canonical JSON text of the compact, bounded timing evidence (coverage,
  /// uncertainty and the like; never a desktop tree). It is captured once at
  /// construction, so it cannot change afterwards.
  final String evidenceJson;
  final bool manual;

  /// Populated only on values read back from storage.
  final int? transcriptId, revision, updatedMs;

  /// Deeply immutable view of [evidenceJson], including its top level.
  late final Map<String, Object?> evidence =
      _freeze(jsonDecode(evidenceJson)) as Map<String, Object?>;

  /// One-line label used in indexed text; empty means "use the channel label".
  String get renderedName => state == AttributionState.attributed
      ? renderedAttributionName(displayName)
      : '';

  /// The same attribution naming [name], used when a user-owned participant
  /// name supersedes the spelling an observation carried.
  TranscriptAttribution withDisplayName(String name) => TranscriptAttribution(
    participantId: participantId,
    displayName: name,
    state: state,
    method: method,
    parserVersion: parserVersion,
    policyVersion: policyVersion,
    evidence: evidence,
    manual: manual,
  );

  /// Content equality ignoring storage bookkeeping.
  bool sameContent(TranscriptAttribution other) =>
      participantId == other.participantId &&
      displayName == other.displayName &&
      state == other.state &&
      method == other.method &&
      parserVersion == other.parserVersion &&
      policyVersion == other.policyVersion &&
      manual == other.manual &&
      evidenceJson == other.evidenceJson;

  Map<String, Object?> toJson() => {
    if (participantId != null) 'participant_id': participantId,
    'display_name': displayName,
    'state': state.name,
    'method': method,
    'parser_version': parserVersion,
    'policy_version': policyVersion,
    'evidence': evidence,
    'manual': manual,
  };
}

/// Result of one automatic attribution write.
enum AttributionWriteOutcome { written, unchanged, protectedByManual }

/// Result of saving a transcript row with its optional attribution. An
/// attribution rejection never rolls back the text.
final class TranscriptWrite {
  const TranscriptWrite(
    this.transcriptId, {
    this.attributionSaved = false,
    this.attributionErrorCode,
  });
  final int transcriptId;

  /// True only when an attribution was requested and committed with the text.
  final bool attributionSaved;

  /// Set when an attribution was requested but rejected: the SQLite extended
  /// result code of the rejection ([sqliteConstraintForeignKey] for an unknown
  /// participant, [sqliteConstraintTrigger] for another meeting's). It is a
  /// number on purpose; an exception would carry participant names.
  final int? attributionErrorCode;
}

/// A failure while writing an attribution beside its transcript row. It
/// carries only SQLite's result codes: the underlying exception prints the
/// bound parameters, which include participant names.
final class AttributionWriteFailure implements Exception {
  const AttributionWriteFailure(this.resultCode, this.extendedResultCode);

  /// Primary result code (19 is a constraint violation, which no retry can
  /// fix; busy, I/O and full-disk codes are transient).
  final int resultCode, extendedResultCode;
  bool get isConstraint => resultCode == 19;

  @override
  String toString() =>
      'Attribution write failed (SQLite code $extendedResultCode)';
}
