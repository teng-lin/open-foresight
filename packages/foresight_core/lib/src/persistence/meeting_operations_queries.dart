import '../desktop_read_models.dart';
import '../meeting_actions.dart';
import '../meeting_workflow_store.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'read_schema_guard.dart';
import 'source_admission_queries.dart';

typedef MeetingOperationDetail = ({
  MeetingDetails meeting,
  List<MeetingNoteData> notes,
  List<TranscriptSegment> transcript,
  List<MeetingArtifact> artifacts,
  List<MeetingQuestion> questions,
});

/// Exact operation projections, distinct from calendar-enriched desktop reads.
final class MeetingOperationsQueries {
  final Store store;
  MeetingOperationsQueries(this.store);
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    store.db,
    () => store.rows(sql, args),
    supportedVersion: Store.schemaVersion,
  );
  MeetingDetails meeting(int id) {
    final row = _rows('SELECT * FROM meetings WHERE id=?', [id]).firstOrNull;
    if (row == null) {
      throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $id');
    }
    return MeetingDetails.fromRow(row);
  }

  List<MeetingDetails> list() => _rows(
    'SELECT m.*,d.created,d.reminder FROM meetings m LEFT JOIN meeting_details d ON d.meeting_id=m.id ORDER BY m.id',
  ).map(MeetingDetails.fromRow).toList();
  List<MeetingNoteData> notes(int id) => store.meetingQueries.notes(id);
  List<TranscriptSegment> transcript(int id) =>
      store.meetingQueries.transcript(id);
  List<MeetingArtifact> artifacts(int id) => _rows(
    'SELECT * FROM artifacts WHERE meeting_id=? ORDER BY id',
    [id],
  ).map(MeetingArtifact.fromRow).toList();
  List<MeetingQuestion> questions(int id) => _rows(
    'SELECT * FROM meeting_questions WHERE meeting_id=? ORDER BY id',
    [id],
  ).map(MeetingQuestion.fromRow).toList();
  List<MeetingTask> tasks(int id) => store.meetingQueries.tasks(id);
  MeetingOperationDetail detail(int id) => readSnapshot(
    store.db,
    () => (
      meeting: meeting(id),
      notes: notes(id),
      transcript: transcript(id),
      artifacts: artifacts(id),
      questions: questions(id),
    ),
    supportedVersion: Store.schemaVersion,
  );
  MeetingTask task(int id) {
    final row = _rows('SELECT * FROM meeting_tasks WHERE id=?', [
      id,
    ]).firstOrNull;
    if (row == null) {
      throw RpcError(RpcErrorCode.notFound, 'Task no longer exists');
    }
    return MeetingTask.fromRow(row);
  }

  void linkAnswer(int meeting, int answer) {
    if (_rows('SELECT 1 FROM answers WHERE id=?', [answer]).isEmpty) {
      throw RpcError(RpcErrorCode.notFound, 'This answer no longer exists.');
    }
    store.db.execute(
      'INSERT OR IGNORE INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
      [meeting, answer],
    );
  }

  void reportFailedIndex(String id) {
    final failure = SourceAdmissionQueries(store).indexingFailure(id);
    if (failure != null) {
      throw RpcError(
        RpcErrorCode.internal,
        'Saved, but indexing failed: ${failure.error}',
      );
    }
  }

  String? editTask(
    MeetingTask selected, {
    required String? task,
    required String? owner,
    required String? due,
    required String? status,
    required bool editDetails,
  }) => store.workflowTransaction(() {
    store.editMeetingTask(
      selected.id,
      task: task,
      owner: owner,
      due: due,
      status: status,
      editDetails: editDetails,
    );
    final artifact = store.meetingQueries
        .artifacts(selected.meetingId, 'actions')
        .firstOrNull;
    if (artifact == null) return null;
    store.editArtifact(
      artifact.id,
      renderMeetingActions(store.meetingTasks(selected.meetingId)),
    );
    return store.refreshArtifactSource(artifact.id);
  });
  bool isStructuredActionsArtifact(int id) => _rows(
    "SELECT a.meeting_id FROM artifacts a WHERE a.id=? AND a.kind='actions' AND EXISTS(SELECT 1 FROM meeting_tasks t WHERE t.meeting_id=a.meeting_id) AND NOT EXISTS(SELECT 1 FROM artifacts newer WHERE newer.meeting_id=a.meeting_id AND newer.kind='actions' AND newer.id>a.id)",
    [id],
  ).isNotEmpty;
  String? editArtifact(int id, String text, {int? lastManualEdit}) =>
      store.workflowTransaction(() {
        store.editArtifact(id, text, lastManualEdit: lastManualEdit);
        return store.refreshArtifactSource(id);
      });
}
