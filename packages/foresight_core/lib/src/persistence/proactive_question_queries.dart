import '../desktop_read_models.dart';
import '../store.dart';
import 'read_schema_guard.dart';

/// Durable queue, cursor and acceptance writes on the service writer. The
/// scheduler owns cancellation and dispatch; only this adapter owns their SQL.
final class ProactiveQuestionQueries {
  ProactiveQuestionQueries(this._store);
  final Store _store;
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    _store.db,
    () => _store.rows(sql, args),
    supportedVersion: Store.schemaVersion,
  );

  int get queuedCount =>
      _rows(
            "SELECT COUNT(*) AS n FROM meeting_questions WHERE state='queued'",
          ).single['n']
          as int;
  int? get oldestQueuedAt =>
      _rows(
            "SELECT MIN(created) AS oldest FROM meeting_questions WHERE state='queued'",
          ).single['oldest']
          as int?;

  void beginAtCurrentTranscript(int meeting) => _store.db.execute(
    'INSERT OR IGNORE INTO meeting_question_cursors(meeting_id,transcript_id) '
    'VALUES(?,(SELECT COALESCE(MAX(id),0) FROM transcript WHERE meeting_id=?))',
    [meeting, meeting],
  );
  List<int> restoreQueuedMeetings() {
    _store.db.execute(
      "UPDATE meeting_questions SET state='queued' WHERE state='answering'",
    );
    return _rows(
      "SELECT meeting_id FROM meeting_questions WHERE state='queued' UNION "
      'SELECT c.meeting_id FROM meeting_question_cursors c JOIN transcript t '
      'ON t.meeting_id=c.meeting_id WHERE t.final=1 AND t.id>c.transcript_id',
    ).map((row) => row['meeting_id'] as int).toList();
  }

  MeetingQuestion? question(int id) {
    final row = _rows('SELECT * FROM meeting_questions WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : MeetingQuestion.fromRow(row);
  }

  MeetingQuestion? nextQueued(int meeting) {
    final row = _rows(
      "SELECT * FROM meeting_questions WHERE meeting_id=? AND state='queued' ORDER BY id LIMIT 1",
      [meeting],
    ).firstOrNull;
    return row == null ? null : MeetingQuestion.fromRow(row);
  }

  int? cursor(int meeting) =>
      _rows(
            'SELECT transcript_id FROM meeting_question_cursors WHERE meeting_id=?',
            [meeting],
          ).firstOrNull?['transcript_id']
          as int?;
  bool hasFinalAfterCursor(int meeting) => _rows(
    'SELECT 1 FROM transcript t JOIN meeting_question_cursors c '
    'ON c.meeting_id=t.meeting_id WHERE t.meeting_id=? AND t.final=1 '
    'AND t.id>c.transcript_id LIMIT 1',
    [meeting],
  ).isNotEmpty;
  List<TranscriptSegment> finalSegmentsAfter(int meeting, int cursor) => _rows(
    'SELECT id,text FROM transcript WHERE meeting_id=? AND final=1 AND id>? ORDER BY id',
    [meeting, cursor],
  ).map(TranscriptSegment.fromRow).toList();

  void queueForRetry(int question) => _store.db.execute(
    "UPDATE meeting_questions SET state='queued',error='' WHERE id=?",
    [question],
  );
  void returnToQueue(int question) => _store.db.execute(
    "UPDATE meeting_questions SET state='queued' WHERE id=?",
    [question],
  );
  void markAnswering(int question) => _store.db.execute(
    "UPDATE meeting_questions SET state='answering',error='' WHERE id=?",
    [question],
  );
  String answerStatus(int answer) =>
      _rows('SELECT status FROM answers WHERE id=?', [answer]).single['status']
          as String;
  void finishAnswer(int question, int answer, String status, String error) =>
      _store.db.execute(
        'UPDATE meeting_questions SET state=?,answer_id=?,error=? WHERE id=?',
        [status, answer, error, question],
      );
  bool linkCommittedAnswer(int question, {int? answer, String? request}) {
    final saved = _rows(
      "SELECT id,status FROM answers WHERE status='completed' AND ${answer == null ? 'request_id=?' : 'id=?'} ORDER BY id DESC LIMIT 1",
      [answer ?? request],
    ).firstOrNull;
    if (saved == null) return false;
    _store.db.execute(
      "UPDATE meeting_questions SET state='completed',answer_id=?,error='' WHERE id=?",
      [saved['id'], question],
    );
    return true;
  }

  void failAnswer(int question, String error) => _store.db.execute(
    "UPDATE meeting_questions SET state='failed',error=? WHERE id=?",
    [error, question],
  );

  T detectionTransaction<T>(T Function() write) {
    _store.db.execute('SAVEPOINT detect_meeting_questions');
    try {
      final result = write();
      _store.db.execute('RELEASE detect_meeting_questions');
      return result;
    } catch (_) {
      _store.db.execute('ROLLBACK TO detect_meeting_questions');
      _store.db.execute('RELEASE detect_meeting_questions');
      rethrow;
    }
  }

  void supersedeQueued(int question) => _store.db.execute(
    "UPDATE meeting_questions SET state='superseded' WHERE id=? AND state='queued'",
    [question],
  );
  int insertDetected({
    required int meeting,
    required int? transcript,
    required String question,
    required String normalized,
    required int created,
  }) {
    _store.db.execute(
      'INSERT INTO meeting_questions(meeting_id,transcript_id,question,normalized,created) VALUES(?,?,?,?,?)',
      [meeting, transcript, question, normalized, created],
    );
    return _store.db.lastInsertRowId;
  }

  void advanceCursor(int meeting, int transcript) => _store.db.execute(
    'UPDATE meeting_question_cursors SET transcript_id=? WHERE meeting_id=?',
    [transcript, meeting],
  );
}
