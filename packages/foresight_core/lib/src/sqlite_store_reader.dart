import 'dart:async';

import 'read_models.dart';
import 'graph_labels.dart';
import 'read_coordinator.dart';
import 'rpc_error.dart';
import 'sqlite_read_session.dart';
import 'sqlite_read_worker.dart';
import 'store.dart';
import 'store_reader.dart';

int _readerOwner = 0;

/// Core implementation. Connection lifecycle owns it; widgets see StoreReader.
final class SqliteStoreReader implements StoreReader {
  final SqliteReadSession _session;
  final String _owner = 'reader:${++_readerOwner}';
  final String _profile;
  String _connection;
  late final ReadCoordinator _coordinator;
  Future<void>? _closing;

  factory SqliteStoreReader.open(
    String path, {
    required String profile,
    required String connection,
  }) {
    // Resolve the environment before allocating the authoritative connection.
    final worker = SqliteReadWorker(path);
    return SqliteStoreReader._(
      SqliteReadSession.open(path),
      worker,
      profile,
      connection,
    );
  }

  /// Service reads use the writer connection's revision token, while SQL
  /// projections run on the same core-owned read worker as desktop reads.
  /// Closing this reader never closes the service's writer connection.
  factory SqliteStoreReader.service(
    Store writer, {
    required String profile,
    required String connection,
  }) => SqliteStoreReader.borrow(
    writer,
    worker: SqliteReadWorker(writer.path),
    profile: profile,
    connection: connection,
  );

  /// Internal tests can hold actual SQLite snapshots without an isolate gate.
  SqliteStoreReader.borrow(
    Store store, {
    required ReadWorker worker,
    String profile = 'fixture-profile',
    String connection = 'fixture-connection',
  }) : this._(SqliteReadSession.borrow(store), worker, profile, connection);

  SqliteStoreReader._(
    this._session,
    ReadWorker worker,
    this._profile,
    this._connection,
  ) {
    _coordinator = ReadCoordinator(
      identity: _identity,
      worker: worker,
      onClosed: _session.close,
    );
    _session.onIncompatible = (error) => unawaited(_coordinator.retire(error));
  }

  ReadIdentity _identity() => _session.identity(
    owner: _owner,
    profile: _profile,
    connection: _connection,
  );

  T _sync<T>(String projection, [Map<String, Object?> args = const {}]) {
    return _session.query(projection, args).value as T;
  }

  @override
  RpcError? get failure => _coordinator.failure;
  @override
  String get workspaceEpoch => _identity().epoch;
  @override
  String get dataRevision => _identity().revision;
  @override
  String preference(String key, [String fallback = '']) =>
      _sync('preference', {'key': key, 'fallback': fallback});
  @override
  ModelRegistration? model(String kind) => _sync('model', {'kind': kind});
  @override
  List<ModelRegistration> get models =>
      List.unmodifiable(_sync<List<ModelRegistration>>('models'));
  @override
  List<SourceSummary> get sourceSummaries =>
      List.unmodifiable(_sync<List<SourceSummary>>('sources'));
  @override
  SourceDocument? sourceById(String id, {bool includeDeleted = false}) =>
      _sync('source', {'id': id, 'include_deleted': includeDeleted});
  @override
  List<NoteSummary> get noteSummaries =>
      List.unmodifiable(_sync<List<NoteSummary>>('notes'));
  @override
  String noteBody(int id) => _sync('note_body', {'id': id});
  @override
  Map<String, String> get googleSourceMimes =>
      Map.unmodifiable(_sync<Map<String, String>>('source_mimes'));
  @override
  List<DocumentLabel> get documentLabels =>
      List.unmodifiable(_sync<List<DocumentLabel>>('labels'));
  @override
  List<DocumentCluster> get documentClusters =>
      List.unmodifiable(_sync<List<DocumentCluster>>('clusters'));
  @override
  List<String> get documentClusterNames =>
      List.unmodifiable(_sync<List<String>>('cluster_names'));
  @override
  String graphLabelSet() => _sync('graph_label_set');
  @override
  List<MeetingCollectionEntry> get meetingCollection =>
      List.unmodifiable(_sync<List<MeetingCollectionEntry>>('meetings'));
  @override
  MeetingNoteData? meetingNote(int id) => _sync('meeting_note', {'id': id});
  @override
  MeetingDetails? meetingPreview(int id) =>
      _sync('meeting_preview', {'id': id});
  @override
  MeetingDetails? meetingWorkspace(int id) => _sync('meeting', {'id': id});
  @override
  int? meetingRevision(int id) => _sync('meeting_revision', {'id': id});
  @override
  List<MeetingQuestion> meetingQuestions(int id) =>
      List.unmodifiable(_sync<List<MeetingQuestion>>('questions', {'id': id}));
  @override
  List<TranscriptSegment> meetingTranscript(int id, {bool finalOnly = false}) =>
      List.unmodifiable(
        _sync<List<TranscriptSegment>>('transcript', {
          'id': id,
          'final_only': finalOnly,
        }),
      );
  @override
  List<MeetingArtifact> meetingArtifacts(int id, String kind) =>
      List.unmodifiable(
        _sync<List<MeetingArtifact>>('artifacts', {'id': id, 'kind': kind}),
      );
  @override
  String meetingEnhancedNotes(int id) => _sync('enhanced_notes', {'id': id});
  @override
  List<MeetingTask> meetingTasks(int id) =>
      List.unmodifiable(_sync<List<MeetingTask>>('tasks', {'id': id}));
  @override
  List<SavedAnswer> conversationAnswers(int? meeting) => List.unmodifiable(
    _sync<List<SavedAnswer>>('answers', {'meeting': meeting}),
  );
  @override
  List<ExportNote> get exportNotes =>
      List.unmodifiable(_sync<List<ExportNote>>('export_notes'));
  @override
  List<CalendarAttachment> calendarAttachments(int meeting) =>
      List.unmodifiable(
        _sync<List<CalendarAttachment>>('attachments', {'id': meeting}),
      );
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) =>
      _coordinator.watch(query);
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) => _coordinator.read(query);

  void invalidate() => _coordinator.invalidate();
  void validateSchema() => _identity();
  void retarget(String connection) {
    _connection = connection;
    invalidate();
  }

  bool get busy => _coordinator.busy;
  Stream<void> get activityChanges => _coordinator.activityChanges;

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await _coordinator.close();
    _session.close();
  }
}
