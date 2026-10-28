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

const maxParticipantNameLength = 500;
const maxParticipantKeyLength = 512;
const maxAttributionTokenLength = 64;
const maxAttributionEvidenceBytes = 2048;
const maxRenderedNameLength = 120;
const maxParticipantBatch = 256;

/// Collapse an untrusted participant name into the one-line label used inside
/// the indexed `[label start–end ms]` prefix. The stored display name is never
/// changed; only this derived form removes line breaks and the prefix bracket
/// characters that could forge another transcript prefix.
String renderedAttributionName(String displayName) {
  final buffer = StringBuffer();
  var pendingSpace = false;
  for (final rune in displayName.runes) {
    final isBreak =
        rune <= 0x20 ||
        (rune >= 0x7f && rune <= 0xa0) ||
        rune == 0x2028 ||
        rune == 0x2029 ||
        rune == 0x200b ||
        rune == 0xfeff;
    if (isBreak) {
      pendingSpace = buffer.isNotEmpty;
      continue;
    }
    if (pendingSpace) buffer.write(' ');
    pendingSpace = false;
    buffer.write(switch (rune) {
      0x5b => '(',
      0x5d => ')',
      _ => String.fromCharCode(rune),
    });
  }
  final runes = buffer.toString().runes.toList();
  return runes.length <= maxRenderedNameLength
      ? String.fromCharCodes(runes)
      : String.fromCharCodes(runes.take(maxRenderedNameLength)).trimRight();
}

void _bounded(String name, String value, int maximum, {bool required = false}) {
  if (value.length > maximum || (required && value.isEmpty)) {
    throw ArgumentError.value(
      value.length,
      name,
      required
          ? 'must contain 1–$maximum characters'
          : 'must contain at most $maximum characters',
    );
  }
}

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
  }) : evidence = Map.unmodifiable(evidence) {
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
    if (utf8.encode(evidenceJson).length > maxAttributionEvidenceBytes) {
      throw ArgumentError.value(
        evidence,
        'evidence',
        'Timing evidence exceeds $maxAttributionEvidenceBytes bytes',
      );
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

  /// Compact, bounded JSON object explaining the timing match (coverage,
  /// uncertainty and the like). Never a desktop tree.
  final Map<String, Object?> evidence;
  final bool manual;

  /// Populated only on values read back from storage.
  final int? transcriptId, revision, updatedMs;

  String get evidenceJson => jsonEncode(evidence);

  /// One-line label used in indexed text; empty means "use the channel label".
  String get renderedName => state == AttributionState.attributed
      ? renderedAttributionName(displayName)
      : '';

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
/// attribution failure never rolls back the text.
final class TranscriptWrite {
  const TranscriptWrite(
    this.transcriptId, {
    this.attributionSaved = false,
    this.attributionError,
  });
  final int transcriptId;

  /// True only when an attribution was requested and committed with the text.
  final bool attributionSaved;

  /// Non-null when an attribution was requested but could not be saved.
  final Object? attributionError;
}
