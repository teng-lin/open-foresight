import 'package:sqlite3/sqlite3.dart';

import '../rpc_error.dart';
import '../store.dart';

/// Durable intent contains identities/revisions only; transcript rows remain
/// the authoritative content. An acknowledgement cannot retire newer work.
final class MeetingIndexIntent {
  const MeetingIndexIntent({
    required this.meeting,
    required this.epoch,
    required this.revision,
  });

  final int meeting;
  final String epoch;
  final int revision;
}

/// Read-only state for a captured search barrier; no transcript/source bodies.
final class MeetingIndexReadiness {
  const MeetingIndexReadiness({
    required this.revision,
    required this.state,
    required this.sourceExists,
    required this.sourceGenerated,
    required this.sourceDeleted,
    required this.sourceIndexed,
    required this.indexedRevision,
    required this.pendingRevision,
  });
  final int revision;
  final String state;
  final bool sourceExists, sourceGenerated, sourceDeleted, sourceIndexed;
  final int? indexedRevision, pendingRevision;
}

final class MeetingIndexJobs {
  MeetingIndexJobs(this.db, {required this.workspaceEpoch});

  factory MeetingIndexJobs.forStore(Store store) =>
      MeetingIndexJobs(store.db, workspaceEpoch: () => store.workspaceEpoch);

  final Database db;
  final String Function() workspaceEpoch;

  MeetingIndexIntent request(int meeting) {
    final rows = db.select('SELECT revision FROM meetings WHERE id=?', [
      meeting,
    ]);
    if (rows.isEmpty) {
      throw RpcError(RpcErrorCode.notFound, 'Meeting no longer exists.');
    }
    final intent = MeetingIndexIntent(
      meeting: meeting,
      epoch: workspaceEpoch(),
      revision: rows.single['revision'] as int,
    );
    db.execute(
      'INSERT INTO meeting_index_jobs(meeting_id,workspace_epoch,revision,requested) '
      'VALUES(?,?,?,?) ON CONFLICT(meeting_id) DO UPDATE SET '
      'workspace_epoch=excluded.workspace_epoch,revision=excluded.revision,'
      'requested=excluded.requested',
      [
        intent.meeting,
        intent.epoch,
        intent.revision,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return intent;
  }

  /// Reconstruct work even when disk failure prevented the explicit intent.
  /// The successful transcript revision is separate from source revision: many
  /// transcript commits may coalesce into one source/index update.
  List<MeetingIndexIntent> recover({
    int limit = 64,
    int afterMeeting = 0,
    bool verifyCompleted = false,
  }) {
    if (limit < 1 || limit > 256) throw ArgumentError.value(limit, 'limit');
    final epoch = workspaceEpoch();
    // A source deletion is an explicit retrieval boundary. Startup recovery
    // must not resurrect it merely because its meeting still has transcripts.
    db.execute(
      'DELETE FROM meeting_index_jobs WHERE workspace_epoch=? AND EXISTS('
      "SELECT 1 FROM sources s WHERE s.id='meeting-'||meeting_index_jobs.meeting_id "
      'AND s.deleted!=0)',
      [epoch],
    );
    db.execute(
      'INSERT INTO meeting_index_jobs(meeting_id,workspace_epoch,revision,requested) '
      'SELECT m.id,?,m.revision,? FROM meetings m '
      'LEFT JOIN meeting_index_state completed ON completed.meeting_id=m.id '
      'AND completed.workspace_epoch=? '
      "LEFT JOIN sources s ON s.id='meeting-'||m.id "
      'WHERE m.id>? AND (EXISTS(SELECT 1 FROM transcript t WHERE t.meeting_id=m.id AND t.final=1) '
      '${verifyCompleted ? 'OR s.generated=1' : ''}) '
      'AND (s.id IS NULL OR s.deleted=0) '
      'AND (completed.revision IS NULL OR completed.revision<m.revision '
      "OR s.id IS NULL OR s.state!='indexed' ${verifyCompleted ? 'OR s.generated=1' : ''}) "
      'ORDER BY m.id LIMIT ? '
      'ON CONFLICT(meeting_id) DO UPDATE SET '
      'workspace_epoch=excluded.workspace_epoch,revision=excluded.revision,'
      'requested=excluded.requested',
      [
        epoch,
        DateTime.now().millisecondsSinceEpoch,
        epoch,
        afterMeeting,
        limit,
      ],
    );
    return [
      for (final row in db.select(
        'SELECT j.meeting_id,j.workspace_epoch,j.revision FROM meeting_index_jobs j '
        'JOIN meetings m ON m.id=j.meeting_id '
        "LEFT JOIN sources s ON s.id='meeting-'||j.meeting_id "
        'WHERE j.workspace_epoch=? AND j.meeting_id>? AND (s.id IS NULL OR s.deleted=0) '
        'ORDER BY j.meeting_id LIMIT ?',
        [epoch, afterMeeting, limit],
      ))
        MeetingIndexIntent(
          meeting: row['meeting_id'] as int,
          epoch: row['workspace_epoch'] as String,
          revision: row['revision'] as int,
        ),
    ];
  }

  /// Return one extra row to let the caller refuse an oversized barrier rather
  /// than silently omitting accepted work. Filter active owners before LIMIT.
  List<MeetingIndexIntent> stoppedSearchSnapshot({
    required Iterable<int> activeMeetings,
    int limit = 64,
    int? captureMeeting,
  }) {
    if (limit < 1 || limit > 64) throw ArgumentError.value(limit, 'limit');
    final active = activeMeetings.toList(growable: false);
    if (active.isEmpty) return const [];
    if (active.length > 64) {
      throw ArgumentError.value(active.length, 'activeMeetings');
    }
    final epoch = workspaceEpoch();
    return [
      for (final row in db.select(
        'SELECT j.meeting_id,j.workspace_epoch,j.revision FROM meeting_index_jobs j '
        'JOIN meetings m ON m.id=j.meeting_id '
        "LEFT JOIN sources s ON s.id='meeting-'||m.id "
        'WHERE j.workspace_epoch=? '
        'AND j.meeting_id IN (${List.filled(active.length, '?').join(',')}) '
        "AND m.state NOT IN ('recording','transcribing','paused') "
        '${captureMeeting == null ? '' : 'AND m.id!=? '}'
        'AND EXISTS(SELECT 1 FROM transcript t WHERE t.meeting_id=m.id AND t.final=1) '
        'AND (s.id IS NULL OR (s.deleted=0 AND s.generated=1 AND s.locally_edited=0)) '
        'ORDER BY j.meeting_id LIMIT ?',
        [
          epoch,
          ...active,
          if (captureMeeting != null) captureMeeting,
          limit + 1,
        ],
      ))
        MeetingIndexIntent(
          meeting: row['meeting_id'] as int,
          epoch: row['workspace_epoch'] as String,
          revision: row['revision'] as int,
        ),
    ];
  }

  Map<int, MeetingIndexReadiness> searchReadiness(
    Iterable<int> meetings,
    String epoch,
  ) {
    final ids = meetings.toList(growable: false);
    if (ids.isEmpty) return const {};
    if (ids.length > 64) throw ArgumentError.value(ids.length, 'meetings');
    return {
      for (final row in db.select(
        'SELECT m.id,m.revision,m.state,s.id AS source_id,s.generated,s.locally_edited,s.deleted,s.state AS source_state,completed.revision AS indexed_revision,pending.revision AS pending_revision '
        'FROM meetings m '
        "LEFT JOIN sources s ON s.id='meeting-'||m.id "
        'LEFT JOIN meeting_index_state completed ON completed.meeting_id=m.id AND completed.workspace_epoch=? '
        'LEFT JOIN meeting_index_jobs pending ON pending.meeting_id=m.id AND pending.workspace_epoch=? '
        'WHERE m.id IN (${List.filled(ids.length, '?').join(',')})',
        [epoch, epoch, ...ids],
      ))
        row['id'] as int: MeetingIndexReadiness(
          revision: row['revision'] as int,
          state: row['state'] as String,
          sourceExists: row['source_id'] != null,
          sourceGenerated: row['generated'] == 1 && row['locally_edited'] == 0,
          sourceDeleted: row['deleted'] != null && row['deleted'] != 0,
          sourceIndexed: row['source_state'] == 'indexed',
          indexedRevision: row['indexed_revision'] as int?,
          pendingRevision: row['pending_revision'] as int?,
        ),
    };
  }

  void complete(MeetingIndexIntent intent) {
    if (intent.epoch != workspaceEpoch()) return;
    db.execute('SAVEPOINT complete_meeting_index');
    try {
      // A deleted meeting must not be recreated by an old producer.
      db.execute(
        'INSERT INTO meeting_index_state(meeting_id,workspace_epoch,revision) '
        'SELECT id,?,? FROM meetings WHERE id=? '
        'ON CONFLICT(meeting_id) DO UPDATE SET '
        'workspace_epoch=excluded.workspace_epoch,'
        'revision=CASE WHEN meeting_index_state.workspace_epoch=excluded.workspace_epoch '
        'THEN MAX(meeting_index_state.revision,excluded.revision) '
        'ELSE excluded.revision END',
        [intent.epoch, intent.revision, intent.meeting],
      );
      db.execute(
        'DELETE FROM meeting_index_jobs WHERE meeting_id=? AND workspace_epoch=? '
        'AND revision<=?',
        [intent.meeting, intent.epoch, intent.revision],
      );
      db.execute('RELEASE complete_meeting_index');
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO complete_meeting_index');
        db.execute('RELEASE complete_meeting_index');
      }
      rethrow;
    }
  }
}
