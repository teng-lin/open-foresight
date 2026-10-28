import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import '../meeting_actions.dart';
import '../meeting_attribution.dart';
import '../rpc_error.dart';
import 'meeting_index_jobs.dart';
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
  final String Function()? _workspaceEpoch;
  MeetingStore(
    this.db, {
    required this.supportedVersion,
    required DerivedSourceWriter writeSource,
    String Function()? workspaceEpoch,
  }) : _writeSource = writeSource,
       _workspaceEpoch = workspaceEpoch;
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
      "SELECT id FROM meetings WHERE state IN ('starting','recording','transcribing','paused')",
    ).map((row) => row['id'] as int).toList();
    db.execute(
      "UPDATE meetings SET state='interrupted' WHERE state IN ('starting','recording','transcribing','paused')",
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

  /// Save a transcript row and, when supplied, its attribution in one
  /// transaction. Attribution is optional metadata and is checked before it is
  /// written: an unknown participant, or one from another meeting, is reported
  /// as [TranscriptWrite.attributionErrorCode] and the text is kept. Any
  /// exception from the write itself, whether a busy, I/O or full-disk error
  /// or a failure in a downstream invalidation trigger, is not an attribution
  /// problem: it propagates with nothing committed so the caller's bounded
  /// retry boundary reruns the whole row. The attribution and the text bump the
  /// meeting revision once between them. This atomic pairing holds for this
  /// path (used by `RecordingTranscriptPersistence`); rows committed by other
  /// writers, such as the durable-audio ASR commit, are attributed afterwards
  /// with [saveAutomaticAttribution].
  TranscriptWrite transcriptWithAttribution(
    int meeting,
    String text,
    bool finalText,
    int start,
    int end,
    String source, {
    TranscriptAttribution? attribution,
  }) => _savepoint('save_transcript_attribution', () {
    transcript(meeting, text, finalText, start, end, source);
    final id = db.lastInsertRowId;
    if (attribution == null) return TranscriptWrite(id);
    final rejection = _attributionRejection(meeting, attribution);
    if (rejection != null) {
      return TranscriptWrite(id, attributionErrorCode: rejection);
    }
    final afterText = _meetingRevision(meeting);
    _writeAttribution(id, attribution, overwriteManual: attribution.manual);
    // Nobody can observe this transaction's middle, so one bump covers the
    // text and its attribution together.
    if (_meetingRevision(meeting) > afterText) {
      db.execute('UPDATE meetings SET revision=? WHERE id=?', [
        afterText,
        meeting,
      ]);
    }
    return TranscriptWrite(id, attributionSaved: true);
  });

  int _meetingRevision(int meeting) =>
      _rows('SELECT revision FROM meetings WHERE id=?', [
            meeting,
          ]).single['revision']
          as int;

  /// The extended result code the database would report for an attribution
  /// that cannot be stored, or null when it can.
  int? _attributionRejection(int meeting, TranscriptAttribution attribution) {
    final participant = attribution.participantId;
    if (participant == null) return null;
    final owner = _rows(
      'SELECT meeting_id FROM meeting_participants WHERE id=?',
      [participant],
    ).firstOrNull;
    if (owner == null) return sqliteConstraintForeignKey;
    return owner['meeting_id'] == meeting ? null : sqliteConstraintTrigger;
  }

  T _savepoint<T>(String name, T Function() write) {
    db.execute('SAVEPOINT $name');
    try {
      final result = write();
      db.execute('RELEASE $name');
      return result;
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO $name');
        db.execute('RELEASE $name');
      }
      rethrow;
    }
  }

  /// Upsert a meeting's observed roster in one transaction (at most
  /// [maxParticipantBatch]; larger rosters use [saveParticipantsInBatches]) and
  /// return the saved participants in input order. Observations never merge by
  /// display name. A name change applies only when it is at least as recent as
  /// the participant's latest observation, so a delayed or retried batch cannot
  /// regress a name; an observed rename is recorded on the participant but never
  /// rewrites the name snapshots already attached to transcript rows, and
  /// cannot replace a name the user assigned. Participants do not touch
  /// transcript invalidation, so a roster refresh reindexes nothing.
  List<MeetingParticipant> saveParticipants(
    int meeting,
    List<MeetingParticipant> participants,
  ) {
    if (participants.length > maxParticipantBatch) {
      throw ArgumentError.value(
        participants.length,
        'participants',
        'at most $maxParticipantBatch per batch',
      );
    }
    const applies = 'name_manual=0 AND excluded.last_seen_ms>=last_seen_ms';
    const renamed = '$applies AND display_name IS NOT excluded.display_name';
    return _savepoint('save_meeting_participants', () {
      final saved = <MeetingParticipant>[];
      for (final p in participants) {
        db.execute(
          'INSERT INTO meeting_participants(meeting_id,scope,identity_key,display_name,is_self,first_seen_ms,last_seen_ms) '
          'VALUES(?,?,?,?,?,?,?) ON CONFLICT(meeting_id,scope,identity_key) DO UPDATE SET '
          'previous_display_name=CASE WHEN $renamed THEN meeting_participants.display_name ELSE previous_display_name END,'
          'rename_count=rename_count+($renamed),'
          'name_changed_ms=CASE WHEN $renamed THEN excluded.last_seen_ms ELSE name_changed_ms END,'
          'display_name=CASE WHEN $applies THEN excluded.display_name ELSE meeting_participants.display_name END,'
          'is_self=MAX(is_self,excluded.is_self),'
          'first_seen_ms=MIN(first_seen_ms,excluded.first_seen_ms),'
          'last_seen_ms=MAX(last_seen_ms,excluded.last_seen_ms)',
          [
            meeting,
            p.scope,
            p.identityKey,
            p.displayName,
            p.isSelf ? 1 : 0,
            p.firstSeenMs,
            p.lastSeenMs,
          ],
        );
        saved.add(
          MeetingParticipant.fromRow(
            _rows(
              'SELECT * FROM meeting_participants WHERE meeting_id=? AND scope=? AND identity_key=?',
              [meeting, p.scope, p.identityKey],
            ).single,
          ),
        );
      }
      return List.unmodifiable(saved);
    });
  }

  /// Save a roster of any size in consecutive batches. Each batch is atomic
  /// and committed in order; a failure leaves the earlier batches saved, which
  /// is safe because the upsert is idempotent. Callers retry the whole roster.
  List<MeetingParticipant> saveParticipantsInBatches(
    int meeting,
    List<MeetingParticipant> participants,
  ) => [
    for (var i = 0; i < participants.length; i += maxParticipantBatch)
      ...saveParticipants(
        meeting,
        participants.sublist(
          i,
          i + maxParticipantBatch > participants.length
              ? participants.length
              : i + maxParticipantBatch,
        ),
      ),
  ];

  /// Persist an automatic observation. A manual row is never replaced, and an
  /// identical observation writes nothing (so retries are idempotent).
  AttributionWriteOutcome saveAutomaticAttribution(
    int transcriptId,
    TranscriptAttribution attribution,
  ) {
    if (attribution.manual) {
      throw ArgumentError.value(
        attribution.manual,
        'attribution',
        'Use setManualAttribution for corrections',
      );
    }
    return _savepoint(
      'save_automatic_attribution',
      () =>
          _writeAttribution(transcriptId, attribution, overwriteManual: false),
    );
  }

  /// A user correction replaces any prior attribution and survives all later
  /// automatic observations until [resetAttribution]. It also records a durable
  /// reprojection intent for the owning meeting.
  void setManualAttribution(
    int transcriptId,
    TranscriptAttribution attribution,
  ) {
    if (!attribution.manual) {
      throw ArgumentError.value(
        attribution.manual,
        'attribution',
        'A correction must be manual',
      );
    }
    _savepoint('save_manual_attribution', () {
      _writeAttribution(transcriptId, attribution, overwriteManual: true);
      _requestIndex(_transcriptMeeting(transcriptId));
    });
  }

  /// Remove a correction (or any attribution) so the row shows its channel
  /// label again and automatic observation may name it. Returns whether a row
  /// existed.
  bool resetAttribution(int transcriptId) =>
      _savepoint('reset_attribution', () {
        final meeting = _transcriptMeeting(transcriptId);
        db.execute(
          'DELETE FROM transcript_attributions WHERE transcript_id=?',
          [transcriptId],
        );
        final removed = db.updatedRows == 1;
        if (removed) _requestIndex(meeting);
        return removed;
      });

  /// Rename a participant for the whole meeting: the participant name becomes
  /// user-owned and every transcript row naming that participant is relabeled
  /// in one statement, except a row the user corrected to a different custom
  /// name. Returns the number of relabeled rows.
  int renameParticipant(int participantId, String displayName) {
    if (renderedAttributionName(displayName).isEmpty ||
        displayName.length > maxParticipantNameLength) {
      throw RpcError(
        RpcErrorCode.invalidArgument,
        'Participant name must contain 1–$maxParticipantNameLength characters.',
      );
    }
    return _savepoint('rename_participant', () {
      final participant = _rows(
        'SELECT meeting_id,display_name FROM meeting_participants WHERE id=?',
        [participantId],
      ).firstOrNull;
      if (participant == null) {
        throw RpcError(
          RpcErrorCode.notFound,
          'Participant not found: $participantId',
        );
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final previousName = participant['display_name'] as String;
      db.execute(
        'UPDATE meeting_participants SET previous_display_name=CASE WHEN display_name IS NOT ? THEN display_name ELSE previous_display_name END,'
        'rename_count=rename_count+(display_name IS NOT ?),'
        'name_changed_ms=CASE WHEN display_name IS NOT ? THEN ? ELSE name_changed_ms END,'
        'display_name=?,name_manual=1 WHERE id=?',
        [
          displayName,
          displayName,
          displayName,
          now,
          displayName,
          participantId,
        ],
      );
      db.execute(
        "UPDATE transcript_attributions SET display_name=?,rendered_name=?,revision=revision+1,updated_ms=? "
        "WHERE participant_id=? AND state='attributed' AND (manual=0 OR display_name=?) "
        'AND (display_name IS NOT ? OR rendered_name IS NOT ?)',
        [
          displayName,
          renderedAttributionName(displayName),
          now,
          participantId,
          previousName,
          displayName,
          renderedAttributionName(displayName),
        ],
      );
      final relabeled = db.updatedRows;
      if (relabeled > 0) _requestIndex(participant['meeting_id'] as int);
      return relabeled;
    });
  }

  int _transcriptMeeting(int transcriptId) {
    final row = _rows('SELECT meeting_id FROM transcript WHERE id=?', [
      transcriptId,
    ]).firstOrNull;
    if (row == null) {
      throw RpcError(
        RpcErrorCode.notFound,
        'Transcript segment not found: $transcriptId',
      );
    }
    return row['meeting_id'] as int;
  }

  // The durable intent lets recovery reproject after a crash; the application
  // still owns kicking its tracked producer.
  void _requestIndex(int meeting) {
    final epoch = _workspaceEpoch;
    if (epoch == null) return;
    MeetingIndexJobs(db, workspaceEpoch: epoch).request(meeting);
  }

  AttributionWriteOutcome _writeAttribution(
    int transcriptId,
    TranscriptAttribution attribution, {
    required bool overwriteManual,
  }) {
    _transcriptMeeting(transcriptId);
    var a = attribution;
    if (!overwriteManual &&
        a.participantId != null &&
        a.state == AttributionState.attributed) {
      // A name the user gave the participant outranks the observed spelling,
      // so a delayed or retried observation cannot undo a rename.
      final owner = _rows(
        'SELECT display_name FROM meeting_participants WHERE id=? AND name_manual=1',
        [a.participantId],
      ).firstOrNull;
      if (owner != null && owner['display_name'] != a.displayName) {
        a = a.withDisplayName(owner['display_name'] as String);
      }
    }
    final existing = _rows(
      'SELECT * FROM transcript_attributions WHERE transcript_id=?',
      [transcriptId],
    ).firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = [
      a.participantId,
      a.displayName,
      a.renderedName,
      a.state.name,
      a.method,
      a.parserVersion,
      a.policyVersion,
      a.evidenceJson,
      a.manual ? 1 : 0,
      now,
    ];
    if (existing == null) {
      db.execute(
        'INSERT INTO transcript_attributions(participant_id,display_name,rendered_name,state,method,parser_version,policy_version,evidence,manual,updated_ms,transcript_id) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        [...values, transcriptId],
      );
      return AttributionWriteOutcome.written;
    }
    if (existing['manual'] == 1 && !overwriteManual) {
      return AttributionWriteOutcome.protectedByManual;
    }
    if (TranscriptAttribution.fromRow(existing).sameContent(a)) {
      return AttributionWriteOutcome.unchanged;
    }
    db.execute(
      'UPDATE transcript_attributions SET participant_id=?,display_name=?,rendered_name=?,state=?,method=?,parser_version=?,policy_version=?,evidence=?,manual=?,updated_ms=?,revision=revision+1 WHERE transcript_id=?',
      [...values, transcriptId],
    );
    return AttributionWriteOutcome.written;
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
    db.execute(
      'UPDATE meeting_notes SET enhanced_body=?,enhanced_generated=0 WHERE meeting_id=?',
      [body, meeting],
    );
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
        "INSERT INTO meeting_notes(meeting_id,body,revision,timestamp,$column,enhanced_body,enhanced_generated) VALUES(?,'',0,?,?,?,?) "
        'ON CONFLICT(meeting_id) DO UPDATE SET timestamp=excluded.timestamp,enhanced_body=excluded.enhanced_body,enhanced_generated=excluded.enhanced_generated,'
        '$column=COALESCE(excluded.$column,meeting_notes.$column)',
        [meeting, now, date, body, manual ? 0 : 1],
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
