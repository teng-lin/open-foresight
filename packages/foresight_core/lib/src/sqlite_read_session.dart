import 'dart:convert';

import 'persistence/sqlite_runtime.dart';

import 'desktop_read_models.dart';
import 'graph_persistence.dart';
import 'persistence/meeting_queries.dart';
import 'persistence/conversation_queries.dart';
import 'persistence/read_schema_guard.dart';
import 'persistence/source_queries.dart';
import 'read_coordinator.dart';
import 'rpc_error.dart';
import 'store.dart';

/// Private persistence implementation; never exported through the desktop API.
final class SqliteReadSession {
  final Store _store;
  final bool _ownsStore;
  bool _closed = false;
  IncompatibleReadSchema? _incompatibility;
  void Function(IncompatibleReadSchema)? onIncompatible;

  SqliteReadSession.borrow(Store store) : _store = store, _ownsStore = false;
  SqliteReadSession.open(String path) : _store = _open(path), _ownsStore = true;

  static Store _open(String path) {
    try {
      return Store.readOnly(path);
    } catch (_) {
      // Store's established startup refusal is StateError. Classify a newer
      // schema into the reader's typed terminal failure without parsing text.
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        readSnapshot(db, () {}, supportedVersion: Store.schemaVersion);
      } finally {
        db.dispose();
      }
      rethrow;
    }
  }

  T snapshot<T>(T Function() read) {
    final incompatible = _incompatibility;
    if (incompatible != null) throw incompatible;
    if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Reader closed');
    try {
      return readSnapshot(
        _store.db,
        read,
        supportedVersion: Store.schemaVersion,
      );
    } on IncompatibleReadSchema catch (error) {
      _incompatibility = error;
      onIncompatible?.call(error);
      rethrow;
    }
  }

  /// The revision remains connection-local and is sampled at autocommit.
  ReadIdentity identity({
    required String owner,
    required String profile,
    required String connection,
  }) {
    final incompatible = _incompatibility;
    if (incompatible != null) throw incompatible;
    if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Reader closed');
    if (!_store.db.autocommit) {
      throw StateError('Reader identity requires an autocommit boundary');
    }
    final revision = _store.dataRevision;
    final epoch = snapshot(() => _store.workspaceEpoch);
    return ReadIdentity(
      owner: owner,
      profile: profile,
      connection: connection,
      epoch: epoch,
      revision: revision,
    );
  }

  ReadWorkerReply query(String projection, Map<String, Object?> arguments) =>
      snapshot(() {
        final epoch = _store.workspaceEpoch;
        return ReadWorkerReply(epoch, _project(projection, arguments));
      });

  Object? _project(String projection, Map<String, Object?> args) {
    final sources = SourceQueries(
      _store.db,
      supportedVersion: Store.schemaVersion,
    );
    final meetings = MeetingQueries(
      _store.db,
      supportedVersion: Store.schemaVersion,
    );
    int id() => args['id'] as int;
    switch (projection) {
      case 'answer_passages':
        return ConversationQueries(_store).answerPassages(
          args['question'] as String,
          Map<String, Object?>.from(args['revisions'] as Map),
          (args['semantic'] as List)
              .map((row) => Map<String, Object?>.from(row as Map))
              .toList(),
        );
      case 'sources':
        return sources.summaries();
      case 'source':
        return sources.source(
          args['id'] as String,
          includeDeleted: args['include_deleted'] == true,
        );
      case 'source_search':
        return sources.search(args['query'] as String);
      case 'output_stats':
        final period = args['period'] == null
            ? null
            : OutputStatsPeriod.fromArguments(
                Map<String, Object?>.from(args['period'] as Map),
              );
        return OutputStats(
          words: _store.localOutputWords,
          weekly: _store.weeklyOutputWords(
            DateTime.fromMillisecondsSinceEpoch(args['now'] as int),
            weekStarts: period?.weeks
                .map((week) => week.startMilliseconds)
                .toList(),
          ),
          period: period,
          recordedMeetings: meetings.recordedMeetingCount(),
          sources: sources.summaries().length,
          completedAnswers: meetings.completedAnswerCount(),
        );
      case 'preference':
        return sources.preference(
          args['key'] as String,
          args['fallback'] as String? ?? '',
        );
      case 'model':
        return sources.model(args['kind'] as String);
      case 'models':
        return sources.models();
      case 'notes':
        return sources.noteSummaries();
      case 'note_body':
        return sources.noteBody(id());
      case 'source_mimes':
        return sources.googleSourceMimes();
      case 'labels':
        return _store.documentLabels;
      case 'clusters':
        return sources.clusters();
      case 'cluster_names':
        return sources.clusterNames();
      case 'graph_label_set':
        return _store.graphLabelSet();
      case 'meetings':
        return meetings.collection();
      case 'meeting_note':
        return meetings.note(id());
      case 'meeting':
        return meetings.workspace(id());
      case 'meeting_preview':
        return meetings.preview(id());
      case 'meeting_revision':
        return meetings.revision(id());
      case 'transcript':
        return meetings.transcript(id(), finalOnly: args['final_only'] == true);
      case 'artifacts':
        return meetings.artifacts(id(), args['kind'] as String);
      case 'enhanced_notes':
        return meetings.enhancedNotes(id());
      case 'tasks':
        return meetings.tasks(id());
      case 'questions':
        return meetings.questions(id());
      case 'answers':
        final answers = meetings.conversationAnswers(args['meeting'] as int?);
        if (args['private_scope'] != true) return answers;
        final scope = args['scope_identity'] as String;
        return answers
            .where(
              (answer) =>
                  sources.preference('answerScope.v1.${answer.id}') == scope,
            )
            .toList();
      case 'export_notes':
        return meetings.exportNotes();
      case 'attachments':
        final metadata = meetings.calendarEventMetadata(id());
        if (metadata == null) return <CalendarAttachment>[];
        final rows =
            (jsonDecode(metadata) as Map)['attachments'] as List? ?? [];
        return rows
            .map(
              (row) => CalendarAttachment.fromRow(
                (row as Map).cast<String, Object?>(),
              ),
            )
            .toList();
      case 'graph_layout':
        // Captured IDs are selection parameters, not authoritative row data.
        final ids = (args['source_ids'] as List).cast<String>().toSet();
        final sources = _store.sourceSummaries
            .where((row) => ids.contains(row['id']))
            .toList();
        final identity = args['identity'] as String?;
        final layout = identity == null
            ? _store.loadRegisteredGraphLayout(
                sources,
                labelSet: args['label_set'] as String?,
              )
            : _store.loadGraphLayout(
                identity,
                sources,
                args['dimensions'] as int,
                labelSet: args['label_set'] as String?,
              );
        return StoredGraphLayout(
          Map.unmodifiable(layout.points),
          Map.unmodifiable({
            for (final entry in layout.vectors.entries)
              entry.key: List<double>.unmodifiable(entry.value),
          }),
          layout.complete,
          identity: layout.identity,
        );
      default:
        throw RpcError(
          RpcErrorCode.invalidArgument,
          'Unknown read projection: $projection',
        );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsStore) _store.close();
  }
}
