import '../desktop_read_models.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'meeting_queries.dart';

typedef NoteArtifactEdit = ({int meeting, String? edited, String generated});

final class NoteQueries {
  NoteQueries(this.store, this.meetings);
  final Store store;
  final MeetingQueries meetings;

  MeetingNoteData? note(int id) => meetings.note(id);
  String body(int id) => note(id)?.body ?? '';
  int? revision(int id) => note(id)?.revision;
  int meetingRevision(int id) =>
      meetings.revision(id) ??
      (throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $id'));

  NoteArtifactEdit? selectedArtifact(int id) {
    final row = store.rows(
      "SELECT selected.meeting_id,selected.edited,selected.generated FROM artifacts AS selected WHERE selected.id=? AND selected.kind='enhanced_notes' AND NOT EXISTS (SELECT 1 FROM artifacts AS newer WHERE newer.meeting_id=selected.meeting_id AND newer.kind=selected.kind AND newer.id>selected.id)",
      [id],
    ).firstOrNull;
    return row == null
        ? null
        : (
            meeting: row['meeting_id'] as int,
            edited: row['edited'] as String?,
            generated: row['generated'] as String,
          );
  }
}
