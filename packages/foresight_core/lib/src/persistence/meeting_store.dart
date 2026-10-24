import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import '../meeting_actions.dart';
import '../rpc_error.dart';
import 'read_schema_guard.dart';

typedef DerivedSourceWriter =
    String Function(
      String title,
      String body,
      String mime,
      String provenance, {
      String? id,
      bool locallyEdited,
    });

class MeetingStore {
  final Database db;
  final int supportedVersion;
  final DerivedSourceWriter _writeSource;
  MeetingStore(
    this.db, {
    required this.supportedVersion,
    required DerivedSourceWriter writeSource,
  }) : _writeSource = writeSource;
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    db,
    () => db
        .select(sql, args)
        .map((row) => Map<String, Object?>.from(row))
        .toList(),
    supportedVersion: supportedVersion,
  );
  String importText(
    String title,
    String body,
    String mime,
    String provenance, {
    String? id,
    bool locallyEdited = false,
  }) => _writeSource(
    title,
    body,
    mime,
    provenance,
    id: id,
    locallyEdited: locallyEdited,
  );
  int meeting(String title) {
    db.execute('INSERT INTO meetings(title,state) VALUES(?,\'idle\')', [title]);
    final id = db.lastInsertRowId;
    db.execute('INSERT INTO meeting_details(meeting_id,created) VALUES(?,?)', [
      id,
      DateTime.now().millisecondsSinceEpoch,
    ]);
    return id;
  }

  void renameMeeting(int id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed.length > 500) {
      throw RpcError(
        RpcErrorCode.invalidArgument,
        'Meeting name must contain 1–500 characters.',
      );
    }
    db.execute(
      'UPDATE meetings SET title=?,title_manually_edited=1 WHERE id=?',
      [trimmed, id],
    );
    if (db.updatedRows != 1) {
      throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $id');
    }
  }

  /// Preserve startup's synchronous selection/update boundary before recording
  /// recovery is scheduled; no helper work or await belongs to this operation.
  List<int> interruptActiveCaptures() {
    final interrupted = _rows(
      "SELECT id FROM meetings WHERE state IN ('recording','transcribing','paused')",
    ).map((row) => row['id'] as int).toList();
    db.execute(
      "UPDATE meetings SET state='interrupted' WHERE state IN ('recording','transcribing','paused')",
    );
    return interrupted;
  }

  void saveMeetingNotes(int meetingId, String body, {int? lastManualEdit}) {
    final previous = _rows(
      'SELECT body FROM meeting_notes WHERE meeting_id=?',
      [meetingId],
    ).firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    final manual =
        lastManualEdit ?? (body != (previous?['body'] ?? '') ? now : null);
    db.execute('SAVEPOINT save_meeting_notes');
    try {
      if (previous == null) _snapshotMeetingEvents(meetingId);
      db.execute(
        'INSERT INTO meeting_notes(meeting_id,body,revision,timestamp,last_manual_edit) VALUES(?,?,1,?,?) '
        'ON CONFLICT(meeting_id) DO UPDATE SET body=excluded.body,revision=meeting_notes.revision+1,timestamp=excluded.timestamp,'
        'last_manual_edit=COALESCE(excluded.last_manual_edit,meeting_notes.last_manual_edit)',
        [meetingId, body, now, manual],
      );
      db.execute('RELEASE save_meeting_notes');
    } catch (_) {
      db.execute('ROLLBACK TO save_meeting_notes');
      db.execute('RELEASE save_meeting_notes');
      rethrow;
    }
  }

  // Original event/document associations capture a name when the note is
  // inserted. Later calendar refreshes do not supply that historical name.
  void _snapshotMeetingEvents(int meeting) {
    if (_rows(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_events'",
    ).isEmpty) {
      return;
    }
    for (final event in _rows(
      'SELECT event_key,metadata FROM calendar_events WHERE meeting_id=? ORDER BY rowid',
      [meeting],
    )) {
      final key = event['event_key'] as String;
      if (key.isEmpty) continue;
      var title = '';
      try {
        final metadata = jsonDecode(event['metadata'] as String);
        if (metadata is Map && metadata['summary'] is String) {
          title = metadata['summary'] as String;
        }
      } on FormatException {
        // Malformed legacy metadata cannot establish a captured event name.
      }
      db.execute(
        'INSERT INTO meeting_note_events(meeting_id,event_key,title) VALUES(?,?,?)',
        [meeting, key, title],
      );
    }
  }

  void transcript(
    int meeting,
    String text,
    bool finalText,
    int start,
    int end,
    String source,
  ) {
    db.execute(
      'INSERT INTO transcript(meeting_id,text,final,start_ms,end_ms,source) VALUES(?,?,?,?,?,?)',
      [meeting, text, finalText ? 1 : 0, start, end, source],
    );
    if (finalText) {
      db.execute('UPDATE meetings SET revision=revision+1 WHERE id=?', [
        meeting,
      ]);
    }
  }

  void artifact(
    int meeting,
    String kind,
    String generated,
    String model, {
    int? inputRevision,
    String promptVersion = 'meeting-v1',
    Map<String, Object?>? manifest,
  }) {
    final revision =
        inputRevision ??
        _rows('SELECT revision FROM meetings WHERE id=?', [
          meeting,
        ]).first['revision'];
    void insert() => db.execute(
      'INSERT INTO artifacts(meeting_id,kind,generated,input_revision,model,prompt_version,created,manifest) VALUES(?,?,?,?,?,?,?,?)',
      [
        meeting,
        kind,
        generated,
        revision,
        model,
        promptVersion,
        DateTime.now().millisecondsSinceEpoch,
        manifest == null ? null : jsonEncode(manifest),
      ],
    );
    if (kind == 'enhanced_notes') {
      _writeEnhancedNote(meeting, insert, body: generated);
    } else {
      insert();
    }
  }

  Map<String, Object?>? summaryCheckpoint(int meeting) => _rows(
    'SELECT c.*,a.generated FROM meeting_summary_checkpoints c JOIN artifacts a ON a.id=c.artifact_id '
    'WHERE c.meeting_id=? AND a.edited IS NULL '
    'AND NOT EXISTS(SELECT 1 FROM artifacts newer WHERE newer.meeting_id=c.meeting_id AND newer.kind=\'summary\' AND newer.id>a.id)',
    [meeting],
  ).firstOrNull;

  String saveSummary(
    int meeting,
    String body,
    String model, {
    required int revision,
    required int inputLength,
    required String inputDigest,
    required String identity,
    required Map<String, Object?> manifest,
  }) {
    db.execute('SAVEPOINT save_summary');
    try {
      artifact(
        meeting,
        'summary',
        body,
        model,
        inputRevision: revision,
        promptVersion: 'summary-v1',
        manifest: manifest,
      );
      db.execute(
        'INSERT OR REPLACE INTO meeting_summary_checkpoints VALUES(?,?,?,?,?)',
        [meeting, db.lastInsertRowId, inputLength, inputDigest, identity],
      );
      final source = importText(
        'Meeting $meeting summary',
        body,
        'text/markdown',
        'Generated summary of meeting:$meeting at transcript revision $revision; summary-v1',
        id: 'meeting-summary-$meeting',
      );
      db.execute('RELEASE save_summary');
      return source;
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO save_summary');
        db.execute('RELEASE save_summary');
      }
      rethrow;
    }
  }

  void editArtifact(int id, String text, {int? lastManualEdit}) {
    final enhanced = _rows(
      "SELECT selected.meeting_id,COALESCE((SELECT enhanced_body FROM meeting_notes WHERE meeting_id=selected.meeting_id),selected.edited,selected.generated) AS body FROM artifacts AS selected WHERE selected.id=? AND selected.kind='enhanced_notes' "
      'AND NOT EXISTS (SELECT 1 FROM artifacts AS newer WHERE newer.meeting_id=selected.meeting_id '
      'AND newer.kind=selected.kind AND newer.id>selected.id)',
      [id],
    ).firstOrNull;
    void update() =>
        db.execute('UPDATE artifacts SET edited=? WHERE id=?', [text, id]);
    if (enhanced == null) {
      update();
      if (db.updatedRows != 1) {
        throw RpcError(
          RpcErrorCode.notFound,
          'This artifact no longer exists.',
        );
      }
    } else {
      _writeEnhancedNote(
        enhanced['meeting_id'] as int,
        update,
        body: text,
        manual: true,
        editTimestamp: lastManualEdit,
        changed: enhanced['body'] != text,
      );
    }
  }

  String meetingEnhancedNotes(int meeting) =>
      _rows(
            "SELECT COALESCE((SELECT enhanced_body FROM meeting_notes WHERE meeting_id=?),(SELECT COALESCE(edited,generated) FROM artifacts WHERE meeting_id=? AND kind='enhanced_notes' ORDER BY id DESC LIMIT 1),'') AS body",
            [meeting, meeting],
          ).first['body']
          as String;

  void restoreMeetingEnhancedDraft(int meeting, String body) {
    db.execute('UPDATE meeting_notes SET enhanced_body=? WHERE meeting_id=?', [
      body,
      meeting,
    ]);
  }

  void saveMeetingEnhancedDraft(int meeting, String body) =>
      _writeEnhancedNote(meeting, () {}, body: body, completed: false);

  // The original saves the current raw/enhanced fields and save timestamp as
  // one Note replacement. Historical artifacts do not replace that current Note.
  void _writeEnhancedNote(
    int meeting,
    void Function() write, {
    required String body,
    bool manual = false,
    bool completed = true,
    int? editTimestamp,
    bool changed = true,
  }) {
    db.execute('SAVEPOINT save_enhanced_note');
    try {
      if (_rows('SELECT meeting_id FROM meeting_notes WHERE meeting_id=?', [
        meeting,
      ]).isEmpty) {
        _snapshotMeetingEvents(meeting);
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final column = manual ? 'last_manual_edit' : 'last_enhanced';
      final date = manual
          ? editTimestamp ?? (changed ? now : null)
          : completed
          ? now
          : null;
      db.execute(
        "INSERT INTO meeting_notes(meeting_id,body,revision,timestamp,$column,enhanced_body) VALUES(?,'',0,?,?,?) "
        'ON CONFLICT(meeting_id) DO UPDATE SET timestamp=excluded.timestamp,enhanced_body=excluded.enhanced_body,'
        '$column=COALESCE(excluded.$column,meeting_notes.$column)',
        [meeting, now, date, body],
      );
      write();
      db.execute('RELEASE save_enhanced_note');
    } catch (_) {
      db.execute('ROLLBACK TO save_enhanced_note');
      db.execute('RELEASE save_enhanced_note');
      rethrow;
    }
  }

  List<Map<String, Object?>> meetingTasks(int meeting) => _rows(
    'SELECT * FROM meeting_tasks WHERE meeting_id=? ORDER BY stale,status,id',
    [meeting],
  );

  T workflowTransaction<T>(T Function() write) {
    db.execute('SAVEPOINT meeting_workflow');
    try {
      final result = write();
      db.execute('RELEASE meeting_workflow');
      return result;
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO meeting_workflow');
        db.execute('RELEASE meeting_workflow');
      }
      rethrow;
    }
  }

  String saveMeetingTasks(
    int meeting,
    List<MeetingAction> tasks,
    String model,
    int revision,
    Map<String, Object?> manifest,
  ) => workflowTransaction(() {
    db.execute('UPDATE meeting_tasks SET stale=1 WHERE meeting_id=?', [
      meeting,
    ]);
    for (final task in tasks) {
      db.execute(
        'INSERT INTO meeting_tasks(meeting_id,task_key,task,owner,due,status,evidence,input_revision,stale,manual) VALUES(?,?,?,?,?,?,?,?,0,0) '
        'ON CONFLICT(meeting_id,task_key) DO UPDATE SET task=CASE WHEN manual=1 THEN meeting_tasks.task ELSE excluded.task END,'
        'owner=CASE WHEN manual=1 THEN meeting_tasks.owner ELSE excluded.owner END,due=CASE WHEN manual=1 THEN meeting_tasks.due ELSE excluded.due END,'
        'status=CASE WHEN manual=1 OR meeting_tasks.status=\'completed\' THEN meeting_tasks.status ELSE excluded.status END,'
        'evidence=excluded.evidence,input_revision=excluded.input_revision,stale=0',
        [
          meeting,
          task.key,
          task.task,
          task.owner,
          task.due,
          task.status,
          jsonEncode(task.evidence),
          revision,
        ],
      );
    }
    final body = renderMeetingActions(meetingTasks(meeting));
    artifact(
      meeting,
      'actions',
      body,
      model,
      inputRevision: revision,
      promptVersion: meetingActionsVersion,
      manifest: manifest,
    );
    return importText(
      'Meeting $meeting actions',
      body,
      'text/markdown',
      'Generated tasks for meeting:$meeting at transcript revision $revision; $meetingActionsVersion',
      id: 'meeting-actions-$meeting',
    );
  });

  void editMeetingTask(
    int id, {
    String? task,
    String? owner,
    String? due,
    String? status,
    bool editDetails = false,
  }) {
    final row = _rows('SELECT * FROM meeting_tasks WHERE id=?', [
      id,
    ]).firstOrNull;
    if (row == null) {
      throw RpcError(RpcErrorCode.notFound, 'Task no longer exists');
    }
    if (status != null &&
        !['open', 'completed', 'cancelled'].contains(status)) {
      throw ArgumentError('Invalid task status');
    }
    if (editDetails &&
        (task == null || task.trim().isEmpty || task.length > 1000)) {
      throw ArgumentError('Task text is required');
    }
    if ((owner?.length ?? 0) > 250 || (due?.length ?? 0) > 250) {
      throw ArgumentError('Task owner or due date is too long');
    }
    db.execute(
      'UPDATE meeting_tasks SET task=?,owner=?,due=?,status=?,manual=1 WHERE id=?',
      [
        editDetails ? task!.trim() : row['task'],
        editDetails ? owner : row['owner'],
        editDetails ? due : row['due'],
        status ?? row['status'],
        id,
      ],
    );
  }

  String saveWorkflowArtifact(
    int meeting,
    String kind,
    String body,
    String model,
    int revision,
    Map<String, Object?> manifest,
  ) {
    artifact(
      meeting,
      kind,
      body,
      model,
      inputRevision: revision,
      promptVersion: '$kind-v1',
      manifest: manifest,
    );
    return importText(
      'Meeting $meeting ${kind.replaceAll('_', ' ')}',
      body,
      'text/markdown',
      'Generated $kind for meeting:$meeting at transcript revision $revision',
      id: 'meeting-$kind-$meeting',
    );
  }

  /// Editing the latest accepted artifact updates the stable derived source;
  /// old-version edits never replace the current searchable text.
  String? refreshArtifactSource(int artifactId) {
    final row = _rows(
      'SELECT a.* FROM artifacts a WHERE a.id=? AND NOT EXISTS(SELECT 1 FROM artifacts newer WHERE newer.meeting_id=a.meeting_id AND newer.kind=a.kind AND newer.id>a.id)',
      [artifactId],
    ).firstOrNull;
    if (row == null ||
        ![
          'summary',
          'actions',
          'preparation',
          'enhanced_notes',
        ].contains(row['kind'])) {
      return null;
    }
    final id = 'meeting-${row['kind']}-${row['meeting_id']}';
    return importText(
      'Meeting ${row['meeting_id']} ${row['kind']}',
      (row['edited'] ?? row['generated']) as String,
      'text/markdown',
      'Accepted ${row['kind']} of meeting:${row['meeting_id']}; artifact:$artifactId; transcript revision ${row['input_revision']}',
      id: id,
      locallyEdited: row['edited'] != null,
    );
  }
}
