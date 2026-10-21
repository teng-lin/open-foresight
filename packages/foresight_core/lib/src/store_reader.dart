import 'desktop_read_models.dart';
import 'graph_labels.dart';
import 'read_coordinator.dart';
import 'rpc_error.dart';

/// Read capabilities supplied by the connection; it owns disposal and paths.
///
/// Synchronous projections support the compiling boundary migration. Feature
/// views consume prepared state and [watch]/[read], never call these in build.
abstract interface class StoreReader {
  /// Terminal incompatibility retires all prepared rows until reconnect/update.
  RpcError? get failure;
  String get workspaceEpoch;
  String get dataRevision;
  String preference(String key, [String fallback = '']);
  ModelRegistration? model(String kind);
  List<ModelRegistration> get models;
  List<SourceSummary> get sourceSummaries;
  SourceDocument? sourceById(String id, {bool includeDeleted = false});
  List<NoteSummary> get noteSummaries;
  String noteBody(int id);
  Map<String, String> get googleSourceMimes;
  List<DocumentLabel> get documentLabels;
  List<DocumentCluster> get documentClusters;
  List<String> get documentClusterNames;
  String graphLabelSet();
  List<MeetingCollectionEntry> get meetingCollection;
  MeetingNoteData? meetingNote(int id);
  MeetingDetails? meetingPreview(int id);
  MeetingDetails? meetingWorkspace(int id);
  int? meetingRevision(int id);
  List<MeetingQuestion> meetingQuestions(int id);
  List<TranscriptSegment> meetingTranscript(int id, {bool finalOnly = false});
  List<MeetingArtifact> meetingArtifacts(int id, String kind);
  String meetingEnhancedNotes(int id);
  List<MeetingTask> meetingTasks(int id);
  List<SavedAnswer> conversationAnswers(int? meeting);
  List<ExportNote> get exportNotes;
  List<CalendarAttachment> calendarAttachments(int meeting);

  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query);
  Future<ReadResult<T>> read<T>(ReadQuery<T> query);
}
