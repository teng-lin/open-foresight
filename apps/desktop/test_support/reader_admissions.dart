import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/graph_labels.dart';

/// Counts typed boundary admissions. Fixture worker counts do not prove isolate placement.
final class ReaderAdmissions {
  final synchronous = <String, int>{},
      reads = <String, int>{},
      watches = <String, int>{},
      workers = <String, int>{};
  void count(Map<String, int> target, String key) =>
      target.update(key, (value) => value + 1, ifAbsent: () => 1);
  T sync<T>(String key, T Function() read) {
    count(synchronous, key);
    return read();
  }

  Map<String, Map<String, int>> snapshot() => {
    'sync': Map.of(synchronous),
    'read': Map.of(reads),
    'watch': Map.of(watches),
    'worker': Map.of(workers),
  };
}

final class CountingStoreReader implements StoreReader {
  final StoreReader delegate;
  final ReaderAdmissions admissions;
  CountingStoreReader(this.delegate, this.admissions);

  @override
  RpcError? get failure => admissions.sync('failure', () => delegate.failure);

  @override
  String get workspaceEpoch =>
      admissions.sync('workspaceEpoch', () => delegate.workspaceEpoch);

  @override
  String get dataRevision =>
      admissions.sync('dataRevision', () => delegate.dataRevision);

  @override
  List<ModelRegistration> get models =>
      admissions.sync('models', () => delegate.models);

  @override
  List<SourceSummary> get sourceSummaries =>
      admissions.sync('sourceSummaries', () => delegate.sourceSummaries);

  @override
  List<NoteSummary> get noteSummaries =>
      admissions.sync('noteSummaries', () => delegate.noteSummaries);

  @override
  Map<String, String> get googleSourceMimes =>
      admissions.sync('googleSourceMimes', () => delegate.googleSourceMimes);

  @override
  List<DocumentLabel> get documentLabels =>
      admissions.sync('documentLabels', () => delegate.documentLabels);

  @override
  List<DocumentCluster> get documentClusters =>
      admissions.sync('documentClusters', () => delegate.documentClusters);

  @override
  List<String> get documentClusterNames => admissions.sync(
    'documentClusterNames',
    () => delegate.documentClusterNames,
  );

  @override
  List<MeetingCollectionEntry> get meetingCollection =>
      admissions.sync('meetingCollection', () => delegate.meetingCollection);

  @override
  List<ExportNote> get exportNotes =>
      admissions.sync('exportNotes', () => delegate.exportNotes);

  @override
  String preference(String key, [String fallback = '']) =>
      admissions.sync('preference', () => delegate.preference(key, fallback));

  @override
  ModelRegistration? model(String kind) =>
      admissions.sync('model', () => delegate.model(kind));

  @override
  SourceDocument? sourceById(String id, {bool includeDeleted = false}) =>
      admissions.sync(
        'sourceById',
        () => delegate.sourceById(id, includeDeleted: includeDeleted),
      );

  @override
  String noteBody(int id) =>
      admissions.sync('noteBody', () => delegate.noteBody(id));

  @override
  String graphLabelSet() =>
      admissions.sync('graphLabelSet', () => delegate.graphLabelSet());

  @override
  MeetingNoteData? meetingNote(int id) =>
      admissions.sync('meetingNote', () => delegate.meetingNote(id));

  @override
  MeetingDetails? meetingPreview(int id) =>
      admissions.sync('meetingPreview', () => delegate.meetingPreview(id));

  @override
  MeetingDetails? meetingWorkspace(int id) =>
      admissions.sync('meetingWorkspace', () => delegate.meetingWorkspace(id));

  @override
  int? meetingRevision(int id) =>
      admissions.sync('meetingRevision', () => delegate.meetingRevision(id));

  @override
  List<MeetingQuestion> meetingQuestions(int id) =>
      admissions.sync('meetingQuestions', () => delegate.meetingQuestions(id));

  @override
  List<TranscriptSegment> meetingTranscript(int id, {bool finalOnly = false}) =>
      admissions.sync(
        'meetingTranscript',
        () => delegate.meetingTranscript(id, finalOnly: finalOnly),
      );

  @override
  List<MeetingArtifact> meetingArtifacts(int id, String kind) => admissions
      .sync('meetingArtifacts', () => delegate.meetingArtifacts(id, kind));

  @override
  String meetingEnhancedNotes(int id) => admissions.sync(
    'meetingEnhancedNotes',
    () => delegate.meetingEnhancedNotes(id),
  );

  @override
  List<MeetingTask> meetingTasks(int id) =>
      admissions.sync('meetingTasks', () => delegate.meetingTasks(id));

  @override
  List<SavedAnswer> conversationAnswers(int? meeting) => admissions.sync(
    'conversationAnswers',
    () => delegate.conversationAnswers(meeting),
  );

  @override
  List<CalendarAttachment> calendarAttachments(int meeting) => admissions.sync(
    'calendarAttachments',
    () => delegate.calendarAttachments(meeting),
  );

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    admissions.count(admissions.reads, query.projection);
    return delegate.read(query);
  }

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    admissions.count(admissions.watches, query.projection);
    return delegate.watch(query);
  }
}
