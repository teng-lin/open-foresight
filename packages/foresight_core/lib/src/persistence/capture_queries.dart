import '../rpc_error.dart';
import '../store.dart';
import 'meeting_queries.dart';

typedef IndexedMeetingSource = ({
  String content,
  String state,
  bool deleted,
  int revision,
});

final class CaptureQueries {
  CaptureQueries(this.store, this.meetings);
  final Store store;
  final MeetingQueries meetings;

  void requireMeeting(int id) {
    if (meetings.revision(id) == null) {
      throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $id');
    }
  }

  void setState(int id, String state) =>
      store.db.execute('UPDATE meetings SET state=? WHERE id=?', [state, id]);

  IndexedMeetingSource? source(String id) {
    final row = store.rows(
      'SELECT content,state,deleted,revision FROM sources WHERE id=?',
      [id],
    ).firstOrNull;
    return row == null
        ? null
        : (
            content: row['content'] as String,
            state: row['state'] as String,
            deleted: row['deleted'] == 1,
            revision: row['revision'] as int,
          );
  }
}
