import '../meeting_actions.dart';
import '../reference_note_transcript_format.dart';
import '../rpc_error.dart';
import '../store.dart';

typedef MeetingInput = ({int id, String title, int revision});

/// Small, synchronous writer-side snapshots for workflow acceptance. Feature
/// owners revalidate these values after awaits and commit without another await.
final class WorkflowQueries {
  WorkflowQueries(this.store);
  final Store store;

  MeetingInput meeting(int id) {
    final row = store.rows(
      'SELECT id,title,revision FROM meetings WHERE id=?',
      [id],
    ).firstOrNull;
    if (row == null) {
      throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $id');
    }
    return (
      id: row['id'] as int,
      title: row['title'] as String,
      revision: row['revision'] as int,
    );
  }

  int? notesRevision(int id) =>
      store.rows('SELECT revision FROM meeting_notes WHERE meeting_id=?', [
            id,
          ]).firstOrNull?['revision']
          as int?;

  List<MeetingEvidence> actionEvidence(int id) => [
    for (final row in store.rows(
      'SELECT id,text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
      [id],
    ))
      MeetingEvidence(
        'transcript:${row['id']}',
        extractSavedTranscriptText(row['text'] as String),
      ),
    if (store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
          id,
        ]).firstOrNull?['body']
        case final String text)
      MeetingEvidence('notes:$id', text),
  ];

  String? calendarMetadata(int id) =>
      store.rows('SELECT metadata FROM calendar_events WHERE meeting_id=?', [
            id,
          ]).firstOrNull?['metadata']
          as String?;

  ({String body, bool clipped})? documentSummary(String key) {
    final row = store.rows(
      'SELECT body,clipped FROM document_summary_cache WHERE cache_key=?',
      [key],
    ).firstOrNull;
    return row == null
        ? null
        : (body: row['body'] as String, clipped: row['clipped'] == 1);
  }

  void cacheDocumentSummaries(Iterable<List<Object?>> rows) {
    for (final row in rows) {
      store.db.execute(
        'INSERT OR REPLACE INTO document_summary_cache VALUES(?,?,?,?,?,?)',
        row,
      );
    }
  }
}
