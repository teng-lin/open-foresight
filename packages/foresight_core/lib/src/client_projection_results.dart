import 'dart:convert';

/// Wire validation stays separate from SQLite projection defaults. Known fields
/// are checked without filling absent fields or rewriting the original row.
Map<String, Object?> projectionResult(
  Object? value, {
  required Map<String, Type> identities,
  String strings = '',
  String integers = '',
  String flags = '',
  String jsonObjects = '',
  Map<String, void Function(Object?)> jsonLists = const {},
}) {
  final row = Map<String, Object?>.from(value as Map);
  Never invalid() => throw const FormatException('Invalid projection response');
  bool matches(Object? item, Type type) =>
      type == String ? item is String : item is int;
  for (final entry in identities.entries) {
    if (!matches(row[entry.key], entry.value)) invalid();
  }
  for (final (fields, type) in [(strings, String), (integers, int)]) {
    for (final field in fields.split(' ').where((field) => field.isNotEmpty)) {
      final item = row[field];
      if (item != null && !matches(item, type)) invalid();
    }
  }
  for (final field in flags.split(' ').where((field) => field.isNotEmpty)) {
    final item = row[field];
    if (item != null &&
        item is! bool &&
        !(item is int && (item == 0 || item == 1))) {
      invalid();
    }
  }
  for (final field
      in jsonObjects.split(' ').where((field) => field.isNotEmpty)) {
    final item = row[field];
    if (item != null) {
      Map<String, Object?>.from(jsonDecode(item as String) as Map);
    }
  }
  for (final entry in jsonLists.entries) {
    final item = row[entry.key];
    if (item == null) continue;
    for (final element in jsonDecode(item as String) as List) {
      entry.value(element);
    }
  }
  return row;
}

Map<String, Object?> sourceResult(Object? value) => projectionResult(
  value,
  identities: const {'id': String},
  strings: 'title mime provenance state error source_uri content',
  integers: 'revision imported changed',
  flags: 'deleted locally_edited',
  jsonLists: {'labels': (value) => value as String},
);

Map<String, Object?> exportNoteResult(Object? value) => projectionResult(
  value,
  identities: const {'id': int},
  strings: 'title body enhanced_body association_title',
  integers: 'export_date export_end timestamp revision',
  jsonObjects: 'export_metadata',
);

Map<String, Object?> meetingResult(Object? value) => projectionResult(
  value,
  identities: const {'id': int},
  strings: 'title state calendar_status',
  integers:
      'revision created starts calendar_starts ends calendar_ends duration_ms',
  flags: 'reminder has_transcript',
);

Map<String, Object?> meetingNoteResult(Object? value) => projectionResult(
  value,
  identities: const {'meeting_id': int},
  strings: 'body enhanced_body',
  integers: 'revision timestamp last_manual_edit last_enhanced',
);

Map<String, Object?> transcriptResult(Object? value) => projectionResult(
  value,
  identities: const {'id': int, 'meeting_id': int},
  strings:
      'text source speaker_label channel participant_name attribution_state attribution_method',
  integers: 'start_ms end_ms speaker_id participant_id',
  flags: 'final attribution_manual',
);

Map<String, Object?> artifactResult(Object? value) => projectionResult(
  value,
  identities: const {'id': int, 'meeting_id': int},
  strings: 'kind generated edited model prompt_version',
  integers: 'input_revision created',
  jsonObjects: 'manifest',
);

Map<String, Object?> questionResult(Object? value) => projectionResult(
  value,
  identities: const {'id': int, 'meeting_id': int},
  strings: 'question normalized state error body',
  integers: 'transcript_id answer_id created',
  jsonLists: {
    'citations': (value) => projectionResult(
      value,
      identities: const {},
      strings: 'kind document_id citation excerpt url title',
      integers: 'revision',
    ),
  },
);

Map<String, Object?> taskResult(Object? value) => projectionResult(
  value,
  identities: const {'id': int, 'meeting_id': int},
  strings: 'task_key task owner due status',
  integers: 'input_revision',
  flags: 'stale manual',
  jsonLists: {
    'evidence': (value) =>
        projectionResult(value, identities: const {}, strings: 'id quote'),
  },
);
