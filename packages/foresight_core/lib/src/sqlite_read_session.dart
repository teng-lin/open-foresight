import 'persistence/answer_scope_queries.dart';
import 'persistence/sqlite_statement_budget.dart';
import 'dart:convert';

import 'persistence/application_schema.dart';
import 'persistence/sqlite_snapshot_source.dart';
import 'persistence/label_queries.dart';
import 'persistence/output_statistics.dart';
import 'persistence/graph_queries.dart';
import 'persistence/answer_passage_queries.dart';

import 'read_models.dart';
import 'graph_view_data.dart';
import 'persistence/meeting_queries.dart';
import 'persistence/read_schema_guard.dart';
import 'persistence/source_queries.dart';
import 'read_coordinator.dart';
import 'rpc_error.dart';

/// Private persistence implementation; never exported through the desktop API.
final class SqliteReadSession {
  final SqliteSnapshotSource _store;
  final bool _ownsStore;
  bool _closed = false;
  final Duration? _executionBudget;
  final SqliteStatementBudget? _budget;
  IncompatibleReadSchema? _incompatibility;
  void Function(IncompatibleReadSchema)? onIncompatible;

  SqliteReadSession.borrow(SqliteSnapshotSource store)
    : _store = store,
      _ownsStore = false,
      _executionBudget = null,
      _budget = null;
  factory SqliteReadSession.open(
    String path, {
    Duration executionBudget = const Duration(seconds: 5),
  }) {
    if (executionBudget <= Duration.zero ||
        executionBudget > const Duration(seconds: 30)) {
      throw ArgumentError.value(executionBudget, 'executionBudget');
    }
    final store = SqliteSnapshotDatabase.open(path);
    try {
      // Eager owner binding at open; no symbol resolution happens in a snapshot.
      final budget = SqliteStatementBudget(store.db);
      return SqliteReadSession._owned(store, executionBudget, budget);
    } catch (_) {
      store.close();
      rethrow;
    }
  }

  SqliteReadSession._owned(this._store, this._executionBudget, this._budget)
    : _ownsStore = true;

  SourceQueries get _sources =>
      SourceQueries(_store.db, supportedVersion: applicationSchemaVersion);
  String get _epoch => _store.preference('workspaceEpoch');
  LabelQueries get _labels =>
      LabelQueries(_store.db, supportedVersion: applicationSchemaVersion);
  late final OutputStatistics _statistics = OutputStatistics(
    _store.db,
    supportedVersion: applicationSchemaVersion,
    dataRevision: () => _store.dataRevision,
  );

  T snapshot<T>(T Function() read) {
    final incompatible = _incompatibility;
    if (incompatible != null) throw incompatible;
    if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Reader closed');
    try {
      return readSnapshot(
        _store.db,
        read,
        supportedVersion: applicationSchemaVersion,
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
    final epoch = snapshot(() => _epoch);
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
        ReadWorkerReply project() =>
            ReadWorkerReply(_epoch, _project(projection, arguments));
        final limit = _executionBudget;
        return limit == null ? project() : _budget!.run(limit, project);
      });

  Object? _project(String projection, Map<String, Object?> args) {
    final sources = SourceQueries(
      _store.db,
      supportedVersion: applicationSchemaVersion,
    );
    final meetings = MeetingQueries(
      _store.db,
      supportedVersion: applicationSchemaVersion,
    );
    int id() => args['id'] as int;
    switch (projection) {
      case 'answer_passages':
        final revisions = Map<String, Object?>.from(args['revisions'] as Map);
        final semantic = (args['semantic'] as List)
            .map((row) => Map<String, Object?>.from(row as Map))
            .toList();
        return readAnswerPassages(
          _store.db,
          args['question'] as String,
          revisions,
          semantic,
          supportedVersion: applicationSchemaVersion,
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
          words: _statistics.localOutputWords,
          weekly: _statistics.weeklyOutputWords(
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
        return _labels.documentLabels;
      case 'clusters':
        return sources.clusters();
      case 'cluster_names':
        return sources.clusterNames();
      case 'graph_label_set':
        return _labels.graphLabelSet();
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
      case 'answer_scope':
        return readAnswerScope(
          _store.preference,
          args['conversation'] as String,
          meeting: args['meeting'] as int?,
          automatic: args['automatic'] == true,
        );
      case 'answers':
        return _answers(args, meetings, sources);
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
        final sources = _sources
            .summaries()
            .map((source) => source.toRow())
            .where((row) => ids.contains(row['id']))
            .toList();
        final identity = args['identity'] as String?;
        final layout = identity == null
            ? GraphQueries(_store.db).loadRegisteredGraphLayout(
                sources,
                labelSet: args['label_set'] as String?,
              )
            : GraphQueries(_store.db).loadGraphLayout(
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

  List<SavedAnswer> _answers(
    Map<String, Object?> args,
    MeetingQueries meetings,
    SourceQueries sources,
  ) {
    final answers = meetings.conversationAnswers(args['meeting'] as int?);
    if (args['private_scope'] != true) return answers;
    final scope = args['scope_identity'] as String;
    return answers
        .where(
          (answer) =>
              sources.preference('answerScope.v1.${answer.id}') == scope,
        )
        .toList();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsStore) (_store as SqliteSnapshotDatabase).close();
  }
}
