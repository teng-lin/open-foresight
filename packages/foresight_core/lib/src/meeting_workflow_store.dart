import 'dart:convert';

import 'meeting_actions.dart';
import 'rpc_error.dart';
import 'store.dart';

extension MeetingWorkflowStore on Store {
  List<Map<String, Object?>> meetingTasks(int meeting) => rows(
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
    final row = rows('SELECT * FROM meeting_tasks WHERE id=?', [
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
    final row = rows(
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
