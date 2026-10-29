import 'dart:convert';
import 'dart:typed_data';

import 'meeting_speakers.dart';
import 'output_stats_period.dart';
import 'summary_generator.dart' show summaryDigest;
export 'output_stats_period.dart';

/// Scope resolved by core in one read snapshot, before querying saved answers.
/// A null ID set is workspace-wide; an empty set remains a private selection.
final class AnswerScopeSnapshot {
  final String mode;
  final Set<String>? ids;

  AnswerScopeSnapshot({required this.mode, required Set<String>? ids})
    : ids = ids == null ? null : Set.unmodifiable(ids);

  String get identity => summaryDigest(
    jsonEncode([mode, ids == null ? null : (ids!.toList()..sort())]),
  );

  /// Resolve already captured preferences without storage or default policy.
  /// Callers retain their lifetime/epoch checks; this identity authorizes no write.
  factory AnswerScopeSnapshot.fromPreferences({
    required String mode,
    String selectedJson = '[]',
    int? meeting,
  }) {
    if (mode == 'workspace') return AnswerScopeSnapshot(mode: mode, ids: null);
    if (mode == 'meeting' && meeting != null) {
      return AnswerScopeSnapshot(
        mode: mode,
        ids: {
          'meeting-$meeting',
          'meeting-summary-$meeting',
          'meeting-actions-$meeting',
          'meeting-enhanced_notes-$meeting',
          'meeting-preparation-$meeting',
        },
      );
    }
    if (mode == 'selected') {
      final decoded = jsonDecode(selectedJson);
      if (decoded is! List ||
          decoded.length > 100 ||
          decoded.any((id) => id is! String)) {
        throw StateError('Invalid selected answer sources');
      }
      return AnswerScopeSnapshot(
        mode: mode,
        ids: decoded.cast<String>().toSet(),
      );
    }
    throw StateError('Invalid answer source scope');
  }
}

/// Immutable persistence projections shared by core queries and desktop views.
///
/// SQL adapters alone construct these values. [toRow] preserves the existing
/// internal Store adapters while their application consumers migrate; views use
/// the named typed properties instead of indexing SQL rows.
abstract base class ReadProjection {
  final Map<String, Object?> _row;
  ReadProjection(Map<String, Object?> row) : _row = immutableReadMap(row);

  Map<String, Object?> toRow() => _row;
  String _text(String key, [String fallback = '']) =>
      _row[key] as String? ?? fallback;
  String? _optionalText(String key) => _row[key] as String?;
  int _integer(String key, [int fallback = 0]) => _row[key] as int? ?? fallback;
  int? _optionalInteger(String key) => _row[key] as int?;
  bool _flag(String key) => _row[key] == 1 || _row[key] == true;
}

Map<String, Object?> immutableReadMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key: immutableReadValue(entry.value),
    });

Object? immutableReadValue(Object? value) {
  if (value is Uint8List) return Uint8List.fromList(value).asUnmodifiableView();
  if (value is Map) {
    return immutableReadMap(value.cast<String, Object?>());
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(immutableReadValue));
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw ArgumentError.value(
    value,
    'value',
    'Unsupported read projection value',
  );
}

Map<String, Object?> readJsonMap(String? value) => value == null
    ? const {}
    : immutableReadMap((jsonDecode(value) as Map).cast<String, Object?>());

List<Map<String, Object?>> readJsonRows(String? value) => value == null
    ? const []
    : List.unmodifiable(
        (jsonDecode(value) as List).map(
          (row) => immutableReadMap((row as Map).cast<String, Object?>()),
        ),
      );

final class ModelRegistration extends ReadProjection {
  ModelRegistration.fromRow(super.row);
  String get kind => _text('kind');
  String get path => _text('path');
  String get digest => _text('digest');
  String get runtime => _text('runtime');
  String get backend => _text('backend');
  int get modelType => _integer('model_type');
}

base class SourceSummary extends ReadProjection {
  SourceSummary.fromRow(super.row);
  String get id => _text('id');
  String get title => _text('title');
  String get mime => _text('mime');
  String get provenance => _text('provenance');
  String get state => _text('state');
  String get error => _text('error');
  int get revision => _integer('revision');
  bool get deleted => _flag('deleted');
  bool get locallyEdited => _flag('locally_edited');
  int? get imported => _optionalInteger('imported');
  int? get changed => _optionalInteger('changed');
  String? get sourceUri => _optionalText('source_uri');
  List<String> get labels => List.unmodifiable(
    (jsonDecode(_text('labels', '[]')) as List).cast<String>(),
  );
}

final class SourceDocument extends SourceSummary {
  SourceDocument.fromRow(super.row) : super.fromRow();
  String get content => _text('content');
}

final class NoteSummary extends ReadProjection {
  NoteSummary.fromRow(super.row);
  int get id => _integer('id');
  String get title => _text('title');
  int get revision => _integer('revision');
}

base class MeetingDetails extends ReadProjection {
  MeetingDetails.fromRow(super.row);
  int get id => _integer('id');
  String get title => _text('title');
  String get state => _text('state');
  int get revision => _integer('revision');
  int? get created => _optionalInteger('created');
  int? get starts =>
      _optionalInteger('starts') ?? _optionalInteger('calendar_starts');
  int? get ends =>
      _optionalInteger('ends') ?? _optionalInteger('calendar_ends');
  int? get durationMs => _optionalInteger('duration_ms');
}

final class MeetingCollectionEntry extends MeetingDetails {
  MeetingCollectionEntry.fromRow(super.row) : super.fromRow();
  bool get reminder => _flag('reminder');
  bool get hasTranscript => _flag('has_transcript');
  String? get calendarStatus => _optionalText('calendar_status');
}

final class MeetingNoteData extends ReadProjection {
  MeetingNoteData.fromRow(super.row);
  int get meetingId => _integer('meeting_id');
  String get body => _text('body');
  String? get enhancedBody => _optionalText('enhanced_body');
  int get revision => _integer('revision');
  int? get timestamp => _optionalInteger('timestamp');
  int? get lastManualEdit => _optionalInteger('last_manual_edit');
  int? get lastEnhancedAt => _optionalInteger('last_enhanced');
}

final class TranscriptSegment extends ReadProjection {
  TranscriptSegment.fromRow(super.row);
  int get id => _integer('id');
  int get meetingId => _integer('meeting_id');
  String get body => _text('text');
  String get text => body;
  bool get finalSegment => _flag('final');
  int get startMs => _integer('start_ms');
  int get endMs => _integer('end_ms');
  String get source => _text('source');

  /// The capture route, independent of any person attribution.
  MeetingSpeaker get channel => MeetingSpeaker.fromSource(source);

  /// Null for historical rows and rows never attributed.
  int? get participantId => _optionalInteger('participant_id');
  String? get attributionState => _optionalText('attribution_state');
  String? get attributionMethod => _optionalText('attribution_method');
  bool get attributionManual => _flag('attribution_manual');

  /// The observed name snapshot, present only when the row names a person.
  String? get participantName => _optionalText('participant_name');
}

final class MeetingQuestion extends ReadProjection {
  MeetingQuestion.fromRow(super.row);
  int get id => _integer('id');
  int get meetingId => _integer('meeting_id');
  int? get transcriptId => _optionalInteger('transcript_id');
  String get question => _text('question');
  String get normalized => _text('normalized');
  String get state => _text('state');
  int? get answerId => _optionalInteger('answer_id');
  String get error => _text('error');
  int get created => _integer('created');
  String? get body => _optionalText('body');
  List<Citation> get citations => List.unmodifiable(
    readJsonRows(_optionalText('citations')).map(Citation.fromRow),
  );
}

final class MeetingArtifact extends ReadProjection {
  MeetingArtifact.fromRow(super.row);
  int get id => _integer('id');
  int get meetingId => _integer('meeting_id');
  String get kind => _text('kind');
  String get generated => _text('generated');
  String? get edited => _optionalText('edited');
  String get body => edited ?? generated;
  String get model => _text('model');
  int get inputRevision => _integer('input_revision');
  String? get promptVersion => _optionalText('prompt_version');
  int? get created => _optionalInteger('created');
  Map<String, Object?> get manifest => readJsonMap(_optionalText('manifest'));
}

final class TaskEvidence extends ReadProjection {
  TaskEvidence.fromRow(super.row);
  String get id => _text('id');
  String get quote => _text('quote');
}

final class MeetingTask extends ReadProjection {
  MeetingTask.fromRow(super.row);
  int get id => _integer('id');
  int get meetingId => _integer('meeting_id');
  String get key => _text('task_key');
  String get task => _text('task');
  String? get owner => _optionalText('owner');
  String? get due => _optionalText('due');
  String get status => _text('status');
  int get inputRevision => _integer('input_revision');
  bool get stale => _flag('stale');
  bool get manual => _flag('manual');
  List<TaskEvidence> get evidence => List.unmodifiable(
    readJsonRows(_optionalText('evidence')).map(TaskEvidence.fromRow),
  );
}

final class Citation extends ReadProjection {
  Citation.fromRow(super.row);
  String get kind => _text('kind');
  String get documentId => _text('document_id');
  int get revision => _integer('revision');
  String get label => _text('citation');
  String get excerpt => _text('excerpt');
  String? get url => _optionalText('url');
  String? get title => _optionalText('title');
}

final class SavedAnswer extends ReadProjection {
  SavedAnswer.fromRow(super.row);
  int get id => _integer('id');
  String get question => _text('question');
  String get body => _text('body');
  String get status => _text('status');
  String get model => _text('model');
  int get created => _integer('created');
  String get conversation => _text('conversation', 'desktop');
  String? get requestId => _optionalText('request_id');
  String? get modelResponse => _optionalText('model_response');
  List<Citation> get citations => List.unmodifiable(
    readJsonRows(_optionalText('citations')).map(Citation.fromRow),
  );
}

final class ExportNote extends ReadProjection {
  ExportNote.fromRow(super.row);
  int get id => _integer('id');
  String get title => _text('title');
  String get body => _text('body');
  String? get enhancedBody => _optionalText('enhanced_body');
  int get date => _integer('export_date');
  int? get end => _optionalInteger('export_end');
  String? get associationTitle => _optionalText('association_title');
  Map<String, Object?> get metadata =>
      readJsonMap(_optionalText('export_metadata'));
}

final class CalendarAttachment extends ReadProjection {
  CalendarAttachment.fromRow(super.row);
  String? get fileId => _optionalText('fileId');
  String? get fileUrl => _optionalText('fileUrl');
  String? get title => _optionalText('title');
  String? get mimeType => _optionalText('mimeType');
  String? get iconLink => _optionalText('iconLink');
}

final class DocumentCluster extends ReadProjection {
  DocumentCluster.fromRow(super.row);
  int get id => _integer('cluster_id');
  String get label => _text('label');
  String? get summary => _optionalText('summary');
  double get x => (_row['center_proj_x'] as num? ?? 0).toDouble();
  double get y => (_row['center_proj_y'] as num? ?? 0).toDouble();
  double get radius => (_row['radius'] as num? ?? 100).toDouble();
}

final class OutputStats {
  final int words, recordedMeetings, sources, completedAnswers;
  final List<int> weekly;
  final OutputStatsPeriod? period;
  OutputStats({
    required this.words,
    required Iterable<int> weekly,
    required this.recordedMeetings,
    required this.sources,
    required this.completedAnswers,
    this.period,
  }) : weekly = List.unmodifiable(weekly);
}
