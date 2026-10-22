import 'package:sqlite3/sqlite3.dart';
import '../read_models.dart';
import 'read_schema_guard.dart';

/// Named immutable reads; the writer owns this connection.
class MeetingQueries {
  final Database _db;
  final int supportedVersion;
  MeetingQueries(this._db, {required this.supportedVersion});
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    _db,
    () =>
        _db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList(),
    supportedVersion: supportedVersion,
  );
  String _meetingEnhancedNotes(int meeting) =>
      _rows(
            "SELECT COALESCE((SELECT enhanced_body FROM meeting_notes WHERE meeting_id=?),(SELECT COALESCE(edited,generated) FROM artifacts WHERE meeting_id=? AND kind='enhanced_notes' ORDER BY id DESC LIMIT 1),'') AS body",
            [meeting, meeting],
          ).first['body']
          as String;
  List<Map<String, Object?>> _conversationAnswers(int? meetingId) => _rows(
    meetingId == null
        ? "SELECT * FROM answers WHERE conversation='desktop' ORDER BY id"
        : 'SELECT answers.* FROM answers JOIN meeting_answers ON answer_id=answers.id WHERE meeting_id=? ORDER BY answers.id',
    meetingId == null ? [] : [meetingId],
  );
  List<Map<String, Object?>> _meetingCollection() => _rows(
    'SELECT meetings.*,meeting_details.created,meeting_details.reminder,'
    'calendar_events.starts AS calendar_starts,calendar_events.ends AS calendar_ends,'
    'calendar_events.status AS calendar_status,'
    'COALESCE(saved.has_transcript,0) AS has_transcript,saved.duration_ms '
    'FROM meetings LEFT JOIN meeting_details ON meetings.id=meeting_details.meeting_id '
    'LEFT JOIN calendar_events ON meetings.id=calendar_events.meeting_id '
    'LEFT JOIN (SELECT meeting_id,1 AS has_transcript,MAX(end_ms) AS duration_ms '
    'FROM transcript WHERE final=1 GROUP BY meeting_id) AS saved ON saved.meeting_id=meetings.id '
    'ORDER BY COALESCE(calendar_events.starts,meeting_details.created),meetings.id',
  );
  List<Map<String, Object?>> _recordedMeetingCountRows() => _rows(
    'SELECT COUNT(DISTINCT meeting_id) AS n FROM transcript WHERE final=1',
  );
  List<Map<String, Object?>> _completedAnswerCountRows() =>
      _rows("SELECT COUNT(*) AS n FROM answers WHERE status='completed'");
  List<Map<String, Object?>> _completedAnswerHistory() =>
      _rows("SELECT body,created FROM answers WHERE status='completed'");
  List<Map<String, Object?>> _meetingNoteRows(int id) =>
      _rows('SELECT * FROM meeting_notes WHERE meeting_id=?', [id]);
  List<Map<String, Object?>> _meetingPreviewRows(int id) => _rows(
    'SELECT meetings.*,meeting_details.created,calendar_events.starts AS calendar_starts,calendar_events.ends AS calendar_ends,'
    '(SELECT MAX(end_ms) FROM transcript WHERE meeting_id=meetings.id AND final=1) AS duration_ms FROM meetings '
    'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
    'LEFT JOIN calendar_events ON calendar_events.meeting_id=meetings.id WHERE meetings.id=?',
    [id],
  );
  List<Map<String, Object?>> _meetingWorkspaceRows(int id) => _rows(
    'SELECT meetings.*,meeting_details.created,calendar_events.starts,calendar_events.ends FROM meetings '
    'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
    'LEFT JOIN calendar_events ON calendar_events.meeting_id=meetings.id WHERE meetings.id=?',
    [id],
  );
  List<Map<String, Object?>> _enhancedNoteArtifacts(int id) => _rows(
    "SELECT * FROM artifacts WHERE meeting_id=? AND kind='enhanced_notes' ORDER BY id DESC LIMIT 1",
    [id],
  );
  List<Map<String, Object?>> _meetingQuestions(int id) => _rows(
    'SELECT q.*,a.body,a.citations FROM meeting_questions q '
    'LEFT JOIN answers a ON a.id=q.answer_id WHERE q.meeting_id=? ORDER BY q.id',
    [id],
  );
  List<Map<String, Object?>> _finalTranscript(int id) => _rows(
    'SELECT text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
    [id],
  );
  List<Map<String, Object?>> _meetingTranscript(int id) =>
      _rows('SELECT * FROM transcript WHERE meeting_id=? ORDER BY id', [id]);
  List<Map<String, Object?>> _meetingArtifacts(int id, String kind) => _rows(
    'SELECT * FROM artifacts WHERE meeting_id=? AND kind=? ORDER BY id DESC',
    [id, kind],
  );
  List<Map<String, Object?>> _exportNotes() => _rows(
    'WITH candidates(note_type,note_id,timestamp) AS ('
    'SELECT 0,meeting_id,timestamp FROM meeting_notes UNION ALL '
    'SELECT 1,id,timestamp FROM notes), '
    'acquired AS (SELECT * FROM candidates ORDER BY timestamp DESC LIMIT 1000) '
    'SELECT * FROM ('
    'SELECT meetings.id,meetings.title,meeting_notes.body,'
    'COALESCE(meeting_notes.enhanced_body,(SELECT COALESCE(edited,generated) FROM artifacts '
    "WHERE artifacts.meeting_id=meetings.id AND kind='enhanced_notes' "
    'ORDER BY id DESC LIMIT 1)) AS enhanced_body,'
    'COALESCE(calendar_events.starts,meeting_notes.timestamp,meeting_details.created,0) AS export_date,'
    'calendar_events.ends AS export_end,calendar_events.metadata AS export_metadata,'
    '(SELECT title FROM meeting_note_events WHERE meeting_id=meetings.id '
    'AND event_key=note_event.event_key AND title!=\'\' ORDER BY id DESC LIMIT 1) AS association_title '
    'FROM acquired JOIN meetings ON acquired.note_type=0 AND meetings.id=acquired.note_id '
    'JOIN meeting_notes ON meeting_notes.meeting_id=meetings.id '
    'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
    'LEFT JOIN meeting_note_events AS note_event ON note_event.id=('
    'SELECT id FROM meeting_note_events WHERE meeting_id=meetings.id '
    'AND event_key!=\'\' ORDER BY id LIMIT 1) '
    'LEFT JOIN calendar_events ON calendar_events.event_key=COALESCE(note_event.event_key,('
    'SELECT event_key FROM calendar_events AS export_event '
    'WHERE export_event.meeting_id=meetings.id ORDER BY export_event.rowid LIMIT 1'
    ')) UNION ALL '
    'SELECT notes.id,notes.title,notes.body,NULL AS enhanced_body,'
    'COALESCE(notes.timestamp,0) AS export_date,NULL AS export_end,NULL AS export_metadata,NULL AS association_title '
    'FROM acquired JOIN notes ON acquired.note_type=1 AND notes.id=acquired.note_id'
    ') ORDER BY export_date DESC,id',
  );
  List<MeetingCollectionEntry> collection() =>
      _meetingCollection().map(MeetingCollectionEntry.fromRow).toList();
  int recordedMeetingCount() => _recordedMeetingCountRows().single['n'] as int;
  int completedAnswerCount() => _completedAnswerCountRows().single['n'] as int;
  List<({String body, int created})> completedAnswerHistory() => [
    for (final row in _completedAnswerHistory())
      (body: row['body'] as String, created: row['created'] as int),
  ];
  List<MeetingNoteData> notes(int id) =>
      _meetingNoteRows(id).map(MeetingNoteData.fromRow).toList();
  MeetingNoteData? note(int id) => notes(id).firstOrNull;
  List<MeetingDetails> previews(int id) =>
      _meetingPreviewRows(id).map(MeetingDetails.fromRow).toList();
  MeetingDetails? preview(int id) => previews(id).firstOrNull;
  List<MeetingDetails> workspaces(int id) =>
      _meetingWorkspaceRows(id).map(MeetingDetails.fromRow).toList();
  MeetingDetails? workspace(int id) => workspaces(id).firstOrNull;
  int? revision(int id) =>
      _rows('SELECT revision FROM meetings WHERE id=?', [
            id,
          ]).firstOrNull?['revision']
          as int?;
  String? calendarEventMetadata(int id) =>
      _rows('SELECT metadata FROM calendar_events WHERE meeting_id=?', [
            id,
          ]).firstOrNull?['metadata']
          as String?;
  List<MeetingArtifact> enhancedNoteArtifacts(int id) =>
      _enhancedNoteArtifacts(id).map(MeetingArtifact.fromRow).toList();
  String enhancedNotes(int id) => _meetingEnhancedNotes(id);
  List<MeetingQuestion> questions(int id) =>
      _meetingQuestions(id).map(MeetingQuestion.fromRow).toList();
  List<TranscriptSegment> transcript(int id, {bool finalOnly = false}) =>
      finalOnly
      ? _rows(
          'SELECT * FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
          [id],
        ).map(TranscriptSegment.fromRow).toList()
      : _meetingTranscript(id).map(TranscriptSegment.fromRow).toList();
  List<String> finalTranscriptText(int id) =>
      _finalTranscript(id).map((r) => r['text'] as String).toList();
  List<MeetingArtifact> artifacts(int id, String kind) =>
      _meetingArtifacts(id, kind).map(MeetingArtifact.fromRow).toList();
  List<MeetingTask> tasks(int id) => _rows(
    'SELECT * FROM meeting_tasks WHERE meeting_id=? ORDER BY stale,status,id',
    [id],
  ).map(MeetingTask.fromRow).toList();
  List<SavedAnswer> conversationAnswers(int? meeting) =>
      _conversationAnswers(meeting).map(SavedAnswer.fromRow).toList();
  List<ExportNote> exportNotes() =>
      _exportNotes().map(ExportNote.fromRow).toList();
}
