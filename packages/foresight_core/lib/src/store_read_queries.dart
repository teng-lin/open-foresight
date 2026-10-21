import 'desktop_read_models.dart';
import 'graph_persistence.dart';
import 'read_coordinator.dart';

/// Closed query names understood by the core-owned read worker, without SQL.
abstract final class StoreReadQueries {
  static ReadQuery<List<Map<String, Object?>>> answerPassages(
    String question,
    Map<String, Object?> revisions,
    List<Map<String, Object?>> semantic, {
    required String scope,
  }) => ReadQuery(
    projection: 'answer_passages',
    scope: scope,
    arguments: {
      'question': question,
      'revisions': revisions,
      'semantic': semantic,
    },
    decode: (value) => List.unmodifiable(
      (value as List).map(
        (row) => immutableReadMap(Map<String, Object?>.from(row as Map)),
      ),
    ),
  );

  static ReadQuery<List<SourceSummary>> sources({String scope = ''}) =>
      ReadQuery(
        projection: 'sources',
        scope: scope,
        decode: (value) =>
            List.unmodifiable((value as List).cast<SourceSummary>()),
      );

  static ReadQuery<SourceDocument?> source(
    String id, {
    bool includeDeleted = false,
  }) => ReadQuery(
    projection: 'source',
    arguments: {'id': id, 'include_deleted': includeDeleted},
    decode: (value) => value as SourceDocument?,
  );

  static ReadQuery<Set<String>> sourceSearch(String query) => ReadQuery(
    projection: 'source_search',
    arguments: {'query': query},
    decode: (value) => Set.unmodifiable((value as Set).cast<String>()),
  );

  static ReadQuery<OutputStats> outputStats({required DateTime now}) =>
      ReadQuery(
        projection: 'output_stats',
        arguments: {'now': now.millisecondsSinceEpoch},
        decode: (value) => value as OutputStats,
      );

  static ReadQuery<ModelRegistration?> model(String kind) => ReadQuery(
    projection: 'model',
    arguments: {'kind': kind},
    decode: (value) => value as ModelRegistration?,
  );

  static ReadQuery<List<ModelRegistration>> models() => ReadQuery(
    projection: 'models',
    decode: (value) =>
        List.unmodifiable((value as List).cast<ModelRegistration>()),
  );

  static ReadQuery<String> preference(String key, [String fallback = '']) =>
      ReadQuery(
        projection: 'preference',
        arguments: {'key': key, 'fallback': fallback},
        decode: (value) => value as String,
      );

  static ReadQuery<List<MeetingCollectionEntry>> meetings() => ReadQuery(
    projection: 'meetings',
    decode: (value) =>
        List.unmodifiable((value as List).cast<MeetingCollectionEntry>()),
  );

  static ReadQuery<MeetingNoteData?> meetingNote(int id) => ReadQuery(
    projection: 'meeting_note',
    arguments: {'id': id},
    decode: (value) => value as MeetingNoteData?,
  );

  static ReadQuery<MeetingDetails?> meeting(int id, {bool preview = false}) =>
      ReadQuery(
        projection: preview ? 'meeting_preview' : 'meeting',
        arguments: {'id': id},
        decode: (value) => value as MeetingDetails?,
      );

  static ReadQuery<List<TranscriptSegment>> transcript(
    int id, {
    bool finalOnly = false,
  }) => ReadQuery(
    projection: 'transcript',
    arguments: {'id': id, 'final_only': finalOnly},
    decode: (value) =>
        List.unmodifiable((value as List).cast<TranscriptSegment>()),
  );

  static ReadQuery<List<MeetingArtifact>> artifacts(int id, String kind) =>
      ReadQuery(
        projection: 'artifacts',
        arguments: {'id': id, 'kind': kind},
        decode: (value) =>
            List.unmodifiable((value as List).cast<MeetingArtifact>()),
      );

  static ReadQuery<List<MeetingTask>> tasks(int id) => ReadQuery(
    projection: 'tasks',
    arguments: {'id': id},
    decode: (value) => List.unmodifiable((value as List).cast<MeetingTask>()),
  );

  static ReadQuery<List<MeetingQuestion>> questions(int id) => ReadQuery(
    projection: 'questions',
    arguments: {'id': id},
    decode: (value) =>
        List.unmodifiable((value as List).cast<MeetingQuestion>()),
  );

  /// Scope is part of query identity, never an ordinary freshness invalidation.
  static ReadQuery<List<SavedAnswer>> answers(
    int? meeting, {
    required String scope,
    required bool privateScope,
  }) => ReadQuery(
    projection: 'answers',
    arguments: {
      'meeting': meeting,
      'scope_identity': scope,
      'private_scope': privateScope,
    },
    scope: scope,
    decode: (value) => List.unmodifiable((value as List).cast<SavedAnswer>()),
  );

  static ReadQuery<List<ExportNote>> exportNotes() => ReadQuery(
    projection: 'export_notes',
    decode: (value) => List.unmodifiable((value as List).cast<ExportNote>()),
  );

  static ReadQuery<List<CalendarAttachment>> attachments(int id) => ReadQuery(
    projection: 'attachments',
    arguments: {'id': id},
    decode: (value) =>
        List.unmodifiable((value as List).cast<CalendarAttachment>()),
  );

  static ReadQuery<StoredGraphLayout> graphLayout({
    required List<SourceSummary> sources,
    String? identity,
    int? dimensions,
    String? labelSet,
    required String helperIdentity,
  }) => ReadQuery(
    projection: 'graph_layout',
    scope: helperIdentity,
    arguments: {
      'source_ids': sources.map((source) => source.id).toList(),
      if (identity != null) 'identity': identity,
      if (dimensions != null) 'dimensions': dimensions,
      if (labelSet != null) 'label_set': labelSet,
    },
    decode: (value) => value as StoredGraphLayout,
  );
}
