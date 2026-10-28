// Historical executable definitions. Change schema by appending a version.
// Migrations 1–15 and their complete private helper closure are frozen at c28a1561.
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

class ApplicationMigrations {
  final Database db;
  ApplicationMigrations(this.db);
  void run(int version) {
    switch (version) {
      case 1:
      case 2:
        // Historical version-1 releases added tables without bumping the version.
        // Adopt that baseline once before applying individually versioned changes.
        _createLegacyTables();
      case 3:
        _migrateNoteHistory();
      case 4:
        _migrateModelMetadata();
      case 5:
        _migrateSourceUris();
      case 6:
        _migrateAnswerHistory();
      case 7:
        _migrateMeetingQuestions();
      case 8:
        _migrateGoogleTables();
      case 9:
        _reconcileLabelRecords();
      case 10:
        db.execute(
          'CREATE TABLE IF NOT EXISTS pending_helper_deletes(document_id TEXT PRIMARY KEY, queued_at INTEGER NOT NULL)',
        );
      case 11:
        if (!rows(
          'PRAGMA table_info(sources)',
        ).any((row) => row['name'] == 'locally_edited')) {
          db.execute(
            'ALTER TABLE sources ADD COLUMN locally_edited INTEGER NOT NULL DEFAULT 0',
          );
        }
        for (final row in rows('SELECT id,provenance FROM sources')) {
          var provenance = row['provenance'] as String;
          if (!provenance.startsWith('user edit; ')) continue;
          while (provenance.startsWith('user edit; ')) {
            provenance = provenance.substring('user edit; '.length);
          }
          db.execute(
            'UPDATE sources SET locally_edited=1,provenance=? WHERE id=?',
            [provenance, row['id']],
          );
        }
      case 12:
        if (!rows(
          'PRAGMA table_info(artifacts)',
        ).any((row) => row['name'] == 'created')) {
          // Older output has no generation date. Keep it in lifetime totals
          // without inventing a week from the meeting's creation date.
          db.execute('ALTER TABLE artifacts ADD COLUMN created INTEGER');
        }
      case 13:
        db.execute(
          'CREATE TABLE IF NOT EXISTS request_keys(key TEXT PRIMARY KEY,operation TEXT NOT NULL,arguments TEXT NOT NULL,result TEXT NOT NULL,created INTEGER NOT NULL)',
        );
      case 14:
        if (!rows(
          'PRAGMA table_info(artifacts)',
        ).any((row) => row['name'] == 'manifest')) {
          db.execute('ALTER TABLE artifacts ADD COLUMN manifest TEXT');
        }
        db.execute(
          'CREATE TABLE IF NOT EXISTS meeting_summary_checkpoints(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,artifact_id INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,input_length INTEGER NOT NULL,input_digest TEXT NOT NULL,identity TEXT NOT NULL)',
        );
      case 15:
        db.execute(
          "UPDATE artifacts SET kind='actions' WHERE kind='action_items'",
        );
        db.execute(
          'CREATE TABLE IF NOT EXISTS meeting_tasks(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,task_key TEXT NOT NULL,task TEXT NOT NULL,owner TEXT,due TEXT,status TEXT NOT NULL,evidence TEXT NOT NULL,input_revision INTEGER NOT NULL,stale INTEGER NOT NULL DEFAULT 0,manual INTEGER NOT NULL DEFAULT 0,UNIQUE(meeting_id,task_key))',
        );
        db.execute(
          'CREATE TABLE IF NOT EXISTS document_summary_cache(cache_key TEXT PRIMARY KEY,source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,source_revision INTEGER NOT NULL,body TEXT NOT NULL,identity TEXT NOT NULL,clipped INTEGER NOT NULL DEFAULT 0)',
        );
      case 16:
        _restoreGoogleModificationTimes();
      case 17:
        _canonicalizeLabels();
      case 18:
        _createContentHistory();
      case 19:
        if (!rows(
          'PRAGMA table_info(meetings)',
        ).any((row) => row['name'] == 'title_manually_edited')) {
          db.execute(
            'ALTER TABLE meetings ADD COLUMN title_manually_edited INTEGER NOT NULL DEFAULT 0',
          );
        }
      case 20:
        _boundContentHistory();
      case 21:
        _routeBackupErasure();
      case 22:
        _createMeetingIndex();
      case 23:
        _migratePreferenceEntities();
      case 24:
        _createRecordingAudio();
      case 25:
        _createMeetingAttribution();
      default:
        throw StateError('Missing application database migration $version');
    }
  }

  // Ordered24 owns this complete helper closure; do not modify older steps.
  void _createRecordingAudio() {
    db.execute('''
CREATE TABLE audio_storage_generation(
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),generation TEXT NOT NULL,
 admission TEXT NOT NULL CHECK(admission IN ('live','metadata_only')));
INSERT INTO audio_storage_generation SELECT 1,
 lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4'||substr(lower(hex(randomblob(2))),2)||
 '-a'||substr(lower(hex(randomblob(2))),2)||'-'||lower(hex(randomblob(6))),'live';
CREATE TABLE audio_erasure_intents(
 session_id TEXT PRIMARY KEY,generation TEXT NOT NULL,created INTEGER NOT NULL);
CREATE TABLE recording_sessions(
 id TEXT PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
 workspace_epoch TEXT NOT NULL,storage_generation TEXT NOT NULL,
 started_wall_ms INTEGER NOT NULL,stopped_wall_ms INTEGER,
 capture_state TEXT NOT NULL CHECK(capture_state IN ('starting','recording','pausing','paused','stopping','stopped','interrupted')),
 last_sequence INTEGER NOT NULL DEFAULT -1,terminal_error TEXT NOT NULL DEFAULT '',
 retain_lossless INTEGER NOT NULL DEFAULT 0 CHECK(retain_lossless IN (0,1)),
 UNIQUE(id,storage_generation));
CREATE TABLE recording_spans(
 id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
 ordinal INTEGER NOT NULL CHECK(ordinal>=0),capture_start_us INTEGER NOT NULL CHECK(capture_start_us>=0),
 capture_end_us INTEGER,playback_start_us INTEGER NOT NULL CHECK(playback_start_us>=0),playback_end_us INTEGER,
 wall_anchor_ms INTEGER NOT NULL,end_reason TEXT,
 UNIQUE(session_id,ordinal),CHECK(capture_end_us IS NULL OR capture_end_us>=capture_start_us),
 CHECK(playback_end_us IS NULL OR playback_end_us>=playback_start_us));
CREATE UNIQUE INDEX recording_one_open_span ON recording_spans(session_id) WHERE capture_end_us IS NULL;
CREATE TABLE audio_source_clocks(
 span_id TEXT NOT NULL REFERENCES recording_spans(id) ON DELETE CASCADE,
 source TEXT NOT NULL CHECK(source IN ('microphone','playback')),revision INTEGER NOT NULL CHECK(revision>=0),
 quality TEXT NOT NULL CHECK(quality IN ('unavailable','hardware_host_time','pipe_drain_estimate','linux_pts','pipewire_header_pts','pipewire_graph_time')),
 uncertainty_us INTEGER CHECK(uncertainty_us>=0),observed_capture_us INTEGER CHECK(observed_capture_us>=0),
 PRIMARY KEY(span_id,source,revision));
CREATE TABLE audio_chunk_publications(
 id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
 span_id TEXT NOT NULL REFERENCES recording_spans(id) ON DELETE CASCADE,
 source TEXT NOT NULL CHECK(source IN ('microphone','playback')),sequence INTEGER NOT NULL CHECK(sequence>=0),
 relative_path TEXT NOT NULL UNIQUE,publication_token TEXT NOT NULL UNIQUE,storage_generation TEXT NOT NULL,
 UNIQUE(session_id,source,sequence));
CREATE TABLE audio_chunks(
 id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
 span_id TEXT NOT NULL REFERENCES recording_spans(id) ON DELETE CASCADE,
 source TEXT NOT NULL CHECK(source IN ('microphone','playback')),
 sequence INTEGER NOT NULL CHECK(sequence>=0),relative_path TEXT NOT NULL UNIQUE,
 publication_token TEXT NOT NULL UNIQUE,storage_generation TEXT NOT NULL,
 sample_start INTEGER NOT NULL CHECK(sample_start>=0),sample_count INTEGER NOT NULL CHECK(sample_count>0),
 sample_rate INTEGER NOT NULL CHECK(sample_rate>0),channels INTEGER NOT NULL CHECK(channels>0),
 capture_start_us INTEGER NOT NULL CHECK(capture_start_us>=0),capture_end_us INTEGER NOT NULL CHECK(capture_end_us>=capture_start_us),
 byte_length INTEGER,sha256 TEXT,state TEXT NOT NULL CHECK(state IN ('reserved','published','missing','quarantined')),
 interrupted INTEGER NOT NULL DEFAULT 0 CHECK(interrupted IN (0,1)),
 gap_before INTEGER NOT NULL DEFAULT 0 CHECK(gap_before IN (0,1)),
 UNIQUE(session_id,source,sequence),UNIQUE(session_id,source,sample_start));
CREATE TABLE audio_representations(
 id TEXT PRIMARY KEY,chunk_id TEXT NOT NULL REFERENCES audio_chunks(id) ON DELETE CASCADE,
 codec TEXT NOT NULL,container TEXT NOT NULL,settings_revision TEXT NOT NULL,
 relative_path TEXT NOT NULL UNIQUE,byte_length INTEGER NOT NULL CHECK(byte_length>0),sha256 TEXT NOT NULL,
 decoded_samples INTEGER NOT NULL CHECK(decoded_samples>0),pre_skip INTEGER NOT NULL DEFAULT 0 CHECK(pre_skip>=0),
 state TEXT NOT NULL CHECK(state IN ('published','superseded_pending_purge','purged','missing')),
 validated INTEGER NOT NULL CHECK(validated IN (0,1)),UNIQUE(chunk_id,codec,settings_revision));
CREATE TABLE audio_segmentation_progress(
 session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
 source TEXT NOT NULL,span_id TEXT NOT NULL REFERENCES recording_spans(id) ON DELETE CASCADE,
 settings_revision TEXT NOT NULL,model_revision TEXT NOT NULL,cursor_sample INTEGER NOT NULL DEFAULT 0 CHECK(cursor_sample>=0),
 retain_from_sample INTEGER NOT NULL DEFAULT 0 CHECK(retain_from_sample>=0),
 error TEXT NOT NULL DEFAULT '' CHECK(length(error)<=1024),
 context BLOB NOT NULL DEFAULT X'' CHECK(length(context)<=65536),flushed INTEGER NOT NULL DEFAULT 0 CHECK(flushed IN (0,1)),
 publication_sealed INTEGER NOT NULL DEFAULT 0 CHECK(publication_sealed IN (0,1)),
 PRIMARY KEY(session_id,source,span_id),CHECK(retain_from_sample<=cursor_sample));
CREATE TABLE audio_asr_jobs(
 id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
 span_id TEXT NOT NULL REFERENCES recording_spans(id) ON DELETE CASCADE,source TEXT NOT NULL,
 sample_start INTEGER NOT NULL CHECK(sample_start>=0),sample_end INTEGER NOT NULL CHECK(sample_end>sample_start),
 owned_start INTEGER NOT NULL CHECK(owned_start>=sample_start),owned_end INTEGER NOT NULL CHECK(owned_end<=sample_end AND owned_end>owned_start),
 model_revision TEXT NOT NULL,settings_revision TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','running','retry','blocked','failed','completed','abandoned')),
 attempts INTEGER NOT NULL DEFAULT 0,lease_generation INTEGER NOT NULL DEFAULT 0,owner_generation TEXT,
 retry_after_ms INTEGER NOT NULL DEFAULT 0,error TEXT NOT NULL DEFAULT '',
 UNIQUE(session_id,source,owned_start,owned_end,model_revision));
CREATE INDEX audio_asr_pending ON audio_asr_jobs(state,retry_after_ms,id);
CREATE INDEX audio_asr_round_robin ON audio_asr_jobs(session_id,source,owned_start,id) WHERE state IN ('pending','retry');
CREATE TABLE audio_asr_job_chunks(
 job_id TEXT NOT NULL REFERENCES audio_asr_jobs(id) ON DELETE CASCADE,
 chunk_id TEXT NOT NULL REFERENCES audio_chunks(id) ON DELETE CASCADE,PRIMARY KEY(job_id,chunk_id));
CREATE TABLE audio_transform_jobs(
 id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('compression','export','playback')),input_identity TEXT NOT NULL UNIQUE,
 codec TEXT NOT NULL,container TEXT NOT NULL,settings_revision TEXT NOT NULL,
 settings TEXT NOT NULL CHECK(length(CAST(settings AS BLOB))<=16384),
 state TEXT NOT NULL CHECK(state IN ('pending','running','retry','blocked','failed','completed','abandoned')),
 attempts INTEGER NOT NULL DEFAULT 0,lease_generation INTEGER NOT NULL DEFAULT 0,owner_generation TEXT,
 retry_after_ms INTEGER NOT NULL DEFAULT 0,error TEXT NOT NULL DEFAULT '',
 output_representation_id TEXT REFERENCES audio_representations(id) ON DELETE SET NULL,
 output_metadata TEXT CHECK(length(CAST(output_metadata AS BLOB))<=16384));
CREATE INDEX audio_transform_pending ON audio_transform_jobs(kind,state,retry_after_ms,id);
CREATE TABLE audio_transform_inputs(
 job_id TEXT NOT NULL REFERENCES audio_transform_jobs(id) ON DELETE CASCADE,
 position INTEGER NOT NULL CHECK(position>=0),representation_id TEXT NOT NULL REFERENCES audio_representations(id) ON DELETE CASCADE,
 playback_start_frame INTEGER CHECK(playback_start_frame>=0 AND playback_start_frame<=4147200000),
 playback_frame_count INTEGER CHECK(playback_frame_count>0 AND playback_frame_count<=240000),
 playback_geometry_sha256 TEXT CHECK(length(playback_geometry_sha256)=64),
 CHECK((playback_start_frame IS NULL)=(playback_frame_count IS NULL)),
 CHECK((playback_start_frame IS NULL)=(playback_geometry_sha256 IS NULL)),
 PRIMARY KEY(job_id,position),UNIQUE(job_id,representation_id));
CREATE TABLE transcript_audio_links(
 transcript_id INTEGER PRIMARY KEY REFERENCES transcript(id) ON DELETE CASCADE,
 job_id TEXT NOT NULL REFERENCES audio_asr_jobs(id) ON DELETE CASCADE,ordinal INTEGER NOT NULL CHECK(ordinal>=0),
 transcript_revision INTEGER NOT NULL,source TEXT NOT NULL,sample_start INTEGER NOT NULL,sample_end INTEGER NOT NULL,
 UNIQUE(job_id,ordinal),CHECK(sample_end>sample_start));
CREATE TABLE audio_media_references(
 id TEXT PRIMARY KEY,representation_id TEXT NOT NULL REFERENCES audio_representations(id) ON DELETE CASCADE,
 owner_generation TEXT NOT NULL,purpose TEXT NOT NULL);
CREATE TRIGGER audio_session_reference_fence BEFORE DELETE ON recording_sessions BEGIN
 SELECT CASE WHEN EXISTS(SELECT 1 FROM audio_media_references r JOIN audio_representations p ON p.id=r.representation_id
 JOIN audio_chunks c ON c.id=p.chunk_id WHERE c.session_id=OLD.id)
 OR EXISTS(SELECT 1 FROM audio_asr_jobs j WHERE j.session_id=OLD.id AND j.state='running')
 OR EXISTS(SELECT 1 FROM audio_transform_jobs j WHERE j.session_id=OLD.id AND j.state='running')
 THEN RAISE(ABORT,'Recording readers and workers must release before deletion') END; END;
CREATE TRIGGER audio_session_erasure BEFORE DELETE ON recording_sessions BEGIN
 INSERT OR IGNORE INTO audio_erasure_intents VALUES(OLD.id,OLD.storage_generation,unixepoch()*1000);
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
''');
  }

  // Ordered25 owns this complete helper closure; do not modify older steps.
  void _createMeetingAttribution() {
    db.execute('''
CREATE TABLE meeting_participants(
 id INTEGER PRIMARY KEY,
 meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
 scope TEXT NOT NULL CHECK(length(scope) BETWEEN 1 AND 512),
 identity_key TEXT NOT NULL CHECK(length(identity_key) BETWEEN 1 AND 512),
 display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 500),
 is_self INTEGER NOT NULL DEFAULT 0 CHECK(is_self IN (0,1)),
 first_seen_ms INTEGER NOT NULL CHECK(first_seen_ms>=0),
 last_seen_ms INTEGER NOT NULL CHECK(last_seen_ms>=first_seen_ms),
 previous_display_name TEXT CHECK(previous_display_name IS NULL OR length(previous_display_name)<=500),
 rename_count INTEGER NOT NULL DEFAULT 0 CHECK(rename_count>=0),
 name_changed_ms INTEGER,
 name_manual INTEGER NOT NULL DEFAULT 0 CHECK(name_manual IN (0,1)),
 UNIQUE(meeting_id,scope,identity_key));
CREATE TABLE transcript_attributions(
 transcript_id INTEGER PRIMARY KEY REFERENCES transcript(id) ON DELETE CASCADE,
 participant_id INTEGER REFERENCES meeting_participants(id) ON DELETE SET NULL,
 display_name TEXT NOT NULL DEFAULT '' CHECK(length(display_name)<=500),
 rendered_name TEXT NOT NULL DEFAULT '' CHECK(length(rendered_name)<=120),
 state TEXT NOT NULL CHECK(state IN ('attributed','unknown','multiple','stale','unavailable')),
 method TEXT NOT NULL DEFAULT '' CHECK(length(method)<=64),
 parser_version TEXT NOT NULL DEFAULT '' CHECK(length(parser_version)<=64),
 policy_version TEXT NOT NULL DEFAULT '' CHECK(length(policy_version)<=64),
 evidence TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(evidence) AND length(CAST(evidence AS BLOB))<=2048),
 manual INTEGER NOT NULL DEFAULT 0 CHECK(manual IN (0,1)),
 revision INTEGER NOT NULL DEFAULT 1,
 updated_ms INTEGER NOT NULL,
 CHECK(state!='attributed' OR rendered_name!=''));
CREATE INDEX transcript_attributions_participant ON transcript_attributions(participant_id) WHERE participant_id IS NOT NULL;
CREATE TRIGGER transcript_attribution_participant_insert BEFORE INSERT ON transcript_attributions
 WHEN NEW.participant_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM meeting_participants p JOIN transcript t ON t.meeting_id=p.meeting_id WHERE p.id=NEW.participant_id AND t.id=NEW.transcript_id) BEGIN
 SELECT RAISE(ABORT,'Participant belongs to another meeting'); END;
CREATE TRIGGER transcript_attribution_participant_update BEFORE UPDATE OF transcript_id,participant_id ON transcript_attributions
 WHEN NEW.participant_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM meeting_participants p JOIN transcript t ON t.meeting_id=p.meeting_id WHERE p.id=NEW.participant_id AND t.id=NEW.transcript_id) BEGIN
 SELECT RAISE(ABORT,'Participant belongs to another meeting'); END;
CREATE TRIGGER transcript_attribution_manual_guard BEFORE UPDATE ON transcript_attributions
 WHEN OLD.manual=1 AND NEW.manual=0 BEGIN
 SELECT RAISE(ABORT,'Manual transcript attribution is protected'); END;
CREATE TRIGGER transcript_attribution_insert_revision AFTER INSERT ON transcript_attributions
 WHEN EXISTS(SELECT 1 FROM transcript WHERE id=NEW.transcript_id AND final=1) AND (NEW.manual=1 OR NEW.state!='unknown') BEGIN
 ${_attributionRevisionBump('NEW.transcript_id')} END;
CREATE TRIGGER transcript_attribution_insert_text AFTER INSERT ON transcript_attributions
 WHEN NEW.rendered_name!='' AND EXISTS(SELECT 1 FROM transcript WHERE id=NEW.transcript_id AND final=1) BEGIN
 ${_attributionReproject('NEW.transcript_id')} END;
CREATE TRIGGER transcript_attribution_update_revision AFTER UPDATE ON transcript_attributions
 WHEN EXISTS(SELECT 1 FROM transcript WHERE id=NEW.transcript_id AND final=1) AND (
 OLD.participant_id IS NOT NEW.participant_id OR OLD.display_name IS NOT NEW.display_name OR
 OLD.rendered_name IS NOT NEW.rendered_name OR OLD.state IS NOT NEW.state OR
 OLD.method IS NOT NEW.method OR OLD.manual IS NOT NEW.manual) BEGIN
 ${_attributionRevisionBump('NEW.transcript_id')} END;
CREATE TRIGGER transcript_attribution_update_text AFTER UPDATE ON transcript_attributions
 WHEN OLD.rendered_name IS NOT NEW.rendered_name AND EXISTS(SELECT 1 FROM transcript WHERE id=NEW.transcript_id AND final=1) BEGIN
 ${_attributionReproject('NEW.transcript_id')} END;
CREATE TRIGGER transcript_attribution_delete_revision AFTER DELETE ON transcript_attributions
 WHEN EXISTS(SELECT 1 FROM transcript WHERE id=OLD.transcript_id AND final=1) AND (OLD.manual=1 OR OLD.state!='unknown') BEGIN
 ${_attributionRevisionBump('OLD.transcript_id')} END;
CREATE TRIGGER transcript_attribution_delete_text AFTER DELETE ON transcript_attributions
 WHEN OLD.rendered_name!='' AND EXISTS(SELECT 1 FROM transcript WHERE id=OLD.transcript_id AND final=1) BEGIN
 ${_attributionReproject('OLD.transcript_id')} END;
CREATE TRIGGER transcript_attribution_erase_replaced AFTER UPDATE OF display_name ON transcript_attributions
 WHEN OLD.display_name!='' AND OLD.display_name IS NOT NEW.display_name BEGIN
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
CREATE TRIGGER transcript_attribution_erase AFTER DELETE ON transcript_attributions
 WHEN OLD.display_name!='' BEGIN
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
CREATE TRIGGER meeting_participant_erase_replaced AFTER UPDATE OF previous_display_name ON meeting_participants
 WHEN OLD.previous_display_name IS NOT NULL AND OLD.previous_display_name IS NOT NEW.previous_display_name BEGIN
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
CREATE TRIGGER meeting_participant_erase AFTER DELETE ON meeting_participants BEGIN
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
DROP VIEW source_contents;
CREATE VIEW source_contents AS SELECT s.id,CASE WHEN s.generated=1 AND m.meeting_id IS NOT NULL
 THEN COALESCE((SELECT group_concat(body,char(10)) FROM (
  SELECT '['||COALESCE(NULLIF(a.rendered_name,''),CASE trim(substr(t.source,1,instr(t.source||';',';')-1),char(9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279))
  WHEN 'microphone' THEN 'Microphone' WHEN 'microphone-capture-interruption' THEN 'Microphone'
  WHEN 'playback' THEN 'Remote' WHEN 'playback-capture-interruption' THEN 'Remote' ELSE 'Unknown' END)||' '||
  CAST(COALESCE(t.start_ms,0) AS INTEGER)||'–'||CAST(COALESCE(t.end_ms,0) AS INTEGER)||' ms] '||COALESCE(t.text,'') AS body
  FROM transcript t LEFT JOIN transcript_attributions a ON a.transcript_id=t.id
  WHERE t.meeting_id=m.meeting_id AND t.final=1 ORDER BY t.id)), '')
 ELSE s.content END AS content FROM sources s LEFT JOIN meeting_transcript_sources m ON m.source_id=s.id;
''');
  }

  // Attribution changes use the same invalidation as an edited transcript row.
  // Erasure markers are separate triggers: creating a name erases nothing.
  String _attributionRevisionBump(String transcript) =>
      'UPDATE meetings SET revision=revision+1 WHERE id=(SELECT meeting_id FROM transcript WHERE id=$transcript);';

  String _attributionReproject(String transcript) {
    final meeting = '(SELECT meeting_id FROM transcript WHERE id=$transcript)';
    return '''
 DELETE FROM meeting_index_segments WHERE transcript_id=$transcript;
 INSERT INTO meeting_transcript_changes(meeting_id,transcript_id,changed) VALUES($meeting,$transcript,unixepoch()*1000)
  ON CONFLICT(meeting_id,transcript_id) DO UPDATE SET version=version+1,projected=0,changed=excluded.changed;
 UPDATE sources SET revision=revision+1,state='pending',error='' WHERE generated=1 AND deleted=0 AND
  id IN(SELECT source_id FROM meeting_transcript_sources WHERE meeting_id=$meeting);
 UPDATE source_details SET changed=CAST((julianday('now')-2440587.5)*86400000 AS INTEGER) WHERE source_id IN
  (SELECT m.source_id FROM meeting_transcript_sources m JOIN sources s ON s.id=m.source_id WHERE m.meeting_id=$meeting AND s.generated=1 AND s.deleted=0);
''';
  }

  // Ordered23 owns its complete helper closure. Earlier definitions stay frozen.
  void _migratePreferenceEntities() {
    db.execute('''
CREATE TABLE answer_metadata(
 answer_id INTEGER PRIMARY KEY REFERENCES answers(id) ON DELETE CASCADE,
 scope_identity TEXT,web_answer INTEGER CHECK(web_answer IN (0,1)));
CREATE TABLE conversation_scopes(
 conversation TEXT PRIMARY KEY,meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
 mode TEXT NOT NULL);
CREATE TABLE proactive_scopes(
 meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,mode TEXT NOT NULL);
CREATE TABLE source_selections(
 purpose TEXT NOT NULL CHECK(purpose IN ('answer','picker','preparation')),
 owner TEXT NOT NULL,meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
 PRIMARY KEY(purpose,owner),CHECK(purpose='answer' OR meeting_id IS NOT NULL));
CREATE TABLE source_selection_items(
 purpose TEXT NOT NULL,owner TEXT NOT NULL,position INTEGER NOT NULL CHECK(position>=0),
 source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
 PRIMARY KEY(purpose,owner,position),
 FOREIGN KEY(purpose,owner) REFERENCES source_selections(purpose,owner) ON DELETE CASCADE);
CREATE TABLE legacy_preference_entities(
 key TEXT PRIMARY KEY,value BLOB NOT NULL,reason TEXT NOT NULL,created INTEGER NOT NULL,
 answer_id INTEGER REFERENCES answers(id) ON DELETE CASCADE,
 meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE);
CREATE INDEX legacy_preference_entities_created ON legacy_preference_entities(created);
CREATE TRIGGER legacy_preference_entities_erasure AFTER DELETE ON legacy_preference_entities BEGIN
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
CREATE TRIGGER answer_metadata_erasure AFTER DELETE ON answer_metadata BEGIN
 INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END;
CREATE TRIGGER answer_preference_orphans AFTER INSERT ON answers BEGIN
 DELETE FROM legacy_preference_entities WHERE answer_id IS NULL AND key IN
 ('answerScope.v1.'||NEW.id,'webAnswer.v1.'||NEW.id); END;
CREATE TRIGGER meeting_preference_orphans AFTER INSERT ON meetings BEGIN
 DELETE FROM legacy_preference_entities WHERE meeting_id IS NULL AND key IN
 ('answerScope.meeting:'||NEW.id,'answerSources.meeting:'||NEW.id,
 'proactiveScope.'||NEW.id,'answerSourcesSelection.'||NEW.id,'preparationSources.'||NEW.id); END;

''');
    for (final row in rows(
      "SELECT key,value FROM preferences WHERE key GLOB 'answerScope.*' OR key GLOB 'webAnswer.v1.*' OR key GLOB 'answerSources.*' OR key GLOB 'proactiveScope.*' OR key GLOB 'answerSourcesSelection.*' OR key GLOB 'preparationSources.*' ORDER BY key",
    )) {
      final key = row['key'] as String, value = row['value'];
      final parsed = _legacyPreferenceEntityKey(key);
      final reason = _moveLegacyPreferenceEntity(parsed, value);
      if (reason != null) {
        db.execute(
          "INSERT INTO legacy_preference_entities(key,value,reason,created,answer_id,meeting_id) VALUES(?,?,?,CAST(strftime('%s','now') AS INTEGER)*1000,?,?)",
          [
            key,
            value,
            reason,
            parsed.answer != null &&
                    rows('SELECT 1 FROM answers WHERE id=?', [
                      parsed.answer,
                    ]).isNotEmpty
                ? parsed.answer
                : null,
            parsed.meeting != null &&
                    rows('SELECT 1 FROM meetings WHERE id=?', [
                      parsed.meeting,
                    ]).isNotEmpty
                ? parsed.meeting
                : null,
          ],
        );
      }
      db.execute('DELETE FROM preferences WHERE key=?', [key]);
    }
  }

  ({String kind, String owner, int? meeting, int? answer, String? purpose})
  _legacyPreferenceEntityKey(String key) {
    for (final prefix in ['answerScope.v1.', 'webAnswer.v1.']) {
      if (!key.startsWith(prefix)) continue;
      final owner = key.substring(prefix.length),
          id = _legacyEntityInteger(key.substring(prefix.length));
      return (
        kind: id == null
            ? 'invalid'
            : prefix == 'answerScope.v1.'
            ? 'answerScope'
            : 'webAnswer',
        owner: owner,
        meeting: null,
        answer: id,
        purpose: null,
      );
    }
    for (final entry in {
      'answerScope.': 'conversation',
      'answerSources.': 'answer',
      'proactiveScope.': 'proactive',
      'answerSourcesSelection.': 'picker',
      'preparationSources.': 'preparation',
    }.entries) {
      if (!key.startsWith(entry.key)) continue;
      final owner = key.substring(entry.key.length);
      final conversation =
          entry.value == 'conversation' || entry.value == 'answer';
      final meeting = conversation
          ? owner.startsWith('meeting:')
                ? _legacyEntityInteger(owner.substring(8))
                : null
          : _legacyEntityInteger(owner);
      final invalid =
          owner.isEmpty ||
          ((!conversation || owner.startsWith('meeting:')) && meeting == null);
      return (
        kind: invalid
            ? 'invalid'
            : entry.value == 'conversation'
            ? 'conversation'
            : entry.value == 'proactive'
            ? 'proactive'
            : 'selection',
        owner: owner,
        meeting: meeting,
        answer: null,
        purpose: conversation ? 'answer' : entry.value,
      );
    }
    return (
      kind: 'invalid',
      owner: key,
      meeting: null,
      answer: null,
      purpose: null,
    );
  }

  int? _legacyEntityInteger(String text) {
    final value = int.tryParse(text);
    return value != null && '$value' == text ? value : null;
  }

  String? _moveLegacyPreferenceEntity(
    ({String kind, String owner, int? meeting, int? answer, String? purpose})
    key,
    Object? value,
  ) {
    if (key.kind == 'invalid') return 'invalid_key';
    if (value is! String) return 'invalid_value_type';
    if (key.answer != null &&
        rows('SELECT 1 FROM answers WHERE id=?', [key.answer]).isEmpty) {
      return 'orphan_answer';
    }
    if (key.meeting != null &&
        rows('SELECT 1 FROM meetings WHERE id=?', [key.meeting]).isEmpty) {
      return 'orphan_meeting';
    }
    switch (key.kind) {
      case 'answerScope':
      case 'webAnswer':
        if (key.kind == 'webAnswer' && value != 'true' && value != 'false') {
          return 'invalid_web_flag';
        }
        final column = key.kind == 'answerScope'
            ? 'scope_identity'
            : 'web_answer';
        db.execute(
          'INSERT INTO answer_metadata(answer_id,$column) VALUES(?,?) ON CONFLICT(answer_id) DO UPDATE SET $column=excluded.$column',
          [
            key.answer,
            key.kind == 'answerScope'
                ? value
                : value == 'true'
                ? 1
                : 0,
          ],
        );
      case 'conversation':
        db.execute(
          'INSERT INTO conversation_scopes(conversation,meeting_id,mode) VALUES(?,?,?)',
          [key.owner, key.meeting, value],
        );
      case 'proactive':
        db.execute(
          'INSERT INTO proactive_scopes(meeting_id,mode) VALUES(?,?)',
          [key.meeting, value],
        );
      case 'selection':
        Object? decoded;
        try {
          decoded = jsonDecode(value);
        } on FormatException {
          return 'invalid_source_selection';
        }
        if (decoded is! List || decoded.any((id) => id is! String)) {
          return 'invalid_source_selection';
        }
        for (final id in decoded) {
          if (rows('SELECT 1 FROM sources WHERE id=?', [id]).isEmpty) {
            return 'missing_selected_source';
          }
        }
        db.execute(
          'INSERT INTO source_selections(purpose,owner,meeting_id) VALUES(?,?,?)',
          [key.purpose, key.owner, key.meeting],
        );
        for (var position = 0; position < decoded.length; position++) {
          db.execute(
            'INSERT INTO source_selection_items(purpose,owner,position,source_id) VALUES(?,?,?,?)',
            [key.purpose, key.owner, position, decoded[position]],
          );
        }
      default:
        throw StateError('Unknown legacy entity kind');
    }
    return null;
  }

  /// Ordered22: current derived pieces; outbox holds identities/hashes only.
  void _createMeetingIndex() {
    db.execute('''
  CREATE INDEX IF NOT EXISTS source_details_uri ON source_details(source_uri,source_id);
  CREATE INDEX IF NOT EXISTS transcript_meeting_final_id ON transcript(meeting_id,final,id);
  CREATE TABLE meeting_transcript_sources(
   source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
   meeting_id INTEGER NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE);
  CREATE TABLE meeting_index_progress(
   meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
   workspace_epoch TEXT NOT NULL DEFAULT '',reset_required INTEGER NOT NULL DEFAULT 1,
   pending_changes INTEGER NOT NULL DEFAULT 0,pending_deletes INTEGER NOT NULL DEFAULT 0,
   seeding INTEGER NOT NULL DEFAULT 1,seed_after_id INTEGER NOT NULL DEFAULT 0,
   confirmed_revision INTEGER NOT NULL DEFAULT 0);
  CREATE TABLE meeting_transcript_changes(
   meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
   transcript_id INTEGER NOT NULL,version INTEGER NOT NULL DEFAULT 1,
   projected INTEGER NOT NULL DEFAULT 0,changed INTEGER NOT NULL,
   PRIMARY KEY(meeting_id,transcript_id));
  CREATE TABLE meeting_index_segments(
   id INTEGER PRIMARY KEY AUTOINCREMENT,
   meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
   transcript_id INTEGER NOT NULL REFERENCES transcript(id) ON DELETE CASCADE,
   channel INTEGER NOT NULL,ordinal INTEGER NOT NULL,
   text TEXT NOT NULL CHECK(length(CAST(text AS BLOB))<=65536),digest TEXT NOT NULL,
   acknowledged INTEGER NOT NULL DEFAULT 0,UNIQUE(transcript_id,ordinal));
  CREATE INDEX meeting_index_segments_pending ON meeting_index_segments(meeting_id,acknowledged,id);
  CREATE TABLE meeting_index_deletes(
   meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
   segment_id INTEGER NOT NULL,channel INTEGER NOT NULL,created INTEGER NOT NULL,
   PRIMARY KEY(meeting_id,segment_id));
  CREATE TABLE meeting_index_batches(
   meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
   workspace_epoch TEXT NOT NULL,metadata TEXT NOT NULL CHECK(length(CAST(metadata AS BLOB))<=16384),
   created INTEGER NOT NULL);
  INSERT INTO meeting_transcript_sources
   SELECT s.id,m.id FROM meetings m JOIN sources s ON s.id='meeting-'||m.id
   WHERE s.generated=1 AND s.locally_edited=0 AND
    EXISTS(SELECT 1 FROM transcript t WHERE t.meeting_id=m.id AND t.final=1);
  CREATE TRIGGER meeting_changes_count_insert AFTER INSERT ON meeting_transcript_changes BEGIN
   INSERT OR IGNORE INTO meeting_index_progress(meeting_id) VALUES(NEW.meeting_id);
   UPDATE meeting_index_progress SET pending_changes=pending_changes+1 WHERE meeting_id=NEW.meeting_id;
   UPDATE meeting_index_progress SET reset_required=2 WHERE meeting_id=NEW.meeting_id AND pending_changes>4096;
   DELETE FROM meeting_transcript_changes WHERE meeting_id=NEW.meeting_id AND
    (SELECT reset_required FROM meeting_index_progress WHERE meeting_id=NEW.meeting_id)=2;
  UPDATE meeting_index_progress SET reset_required=1 WHERE meeting_id=NEW.meeting_id AND reset_required=2;
  END;
  CREATE TRIGGER meeting_changes_count_delete AFTER DELETE ON meeting_transcript_changes BEGIN
   UPDATE meeting_index_progress SET pending_changes=pending_changes-1 WHERE meeting_id=OLD.meeting_id;
  END;
  CREATE TRIGGER meeting_deletes_count_insert AFTER INSERT ON meeting_index_deletes BEGIN
   INSERT OR IGNORE INTO meeting_index_progress(meeting_id) VALUES(NEW.meeting_id);
   UPDATE meeting_index_progress SET pending_deletes=pending_deletes+1 WHERE meeting_id=NEW.meeting_id;
   UPDATE meeting_index_progress SET reset_required=2 WHERE meeting_id=NEW.meeting_id AND pending_deletes>4096;
   DELETE FROM meeting_index_deletes WHERE meeting_id=NEW.meeting_id AND
    (SELECT reset_required FROM meeting_index_progress WHERE meeting_id=NEW.meeting_id)=2;
  UPDATE meeting_index_progress SET reset_required=1 WHERE meeting_id=NEW.meeting_id AND reset_required=2;
  END;
  CREATE TRIGGER meeting_deletes_count_delete AFTER DELETE ON meeting_index_deletes BEGIN
   UPDATE meeting_index_progress SET pending_deletes=pending_deletes-1 WHERE meeting_id=OLD.meeting_id;
  END;
  CREATE TRIGGER meeting_piece_delete AFTER DELETE ON meeting_index_segments
   WHEN EXISTS(SELECT 1 FROM meeting_transcript_sources WHERE meeting_id=OLD.meeting_id) BEGIN
   INSERT OR IGNORE INTO meeting_index_deletes VALUES(OLD.meeting_id,OLD.id,OLD.channel,unixepoch()*1000);
  END;
  CREATE TRIGGER meeting_transcript_insert AFTER INSERT ON transcript WHEN NEW.final=1 BEGIN
   INSERT INTO meeting_transcript_changes(meeting_id,transcript_id,changed) VALUES(NEW.meeting_id,NEW.id,unixepoch()*1000)
   ON CONFLICT(meeting_id,transcript_id) DO UPDATE SET version=version+1,projected=0,changed=excluded.changed;
   UPDATE sources SET revision=revision+1,state='pending',error='' WHERE generated=1 AND deleted=0 AND
   id IN(SELECT source_id FROM meeting_transcript_sources WHERE meeting_id=NEW.meeting_id);
   UPDATE source_details SET changed=CAST((julianday('now')-2440587.5)*86400000 AS INTEGER) WHERE source_id IN
    (SELECT m.source_id FROM meeting_transcript_sources m JOIN sources s ON s.id=m.source_id WHERE m.meeting_id=NEW.meeting_id AND s.generated=1 AND s.deleted=0);
  END;
  CREATE TRIGGER meeting_transcript_update AFTER UPDATE OF text,final,source,start_ms,end_ms ON transcript
   WHEN OLD.text IS NOT NEW.text OR OLD.final IS NOT NEW.final OR OLD.source IS NOT NEW.source OR
   OLD.start_ms IS NOT NEW.start_ms OR OLD.end_ms IS NOT NEW.end_ms BEGIN
   DELETE FROM meeting_index_segments WHERE transcript_id=OLD.id;
   INSERT INTO meeting_transcript_changes(meeting_id,transcript_id,changed) VALUES(NEW.meeting_id,NEW.id,unixepoch()*1000)
   ON CONFLICT(meeting_id,transcript_id) DO UPDATE SET version=version+1,projected=0,changed=excluded.changed;
   UPDATE meetings SET revision=revision+1 WHERE id=NEW.meeting_id;
   UPDATE sources SET revision=revision+1,state='pending',error='' WHERE generated=1 AND deleted=0 AND
   id IN(SELECT source_id FROM meeting_transcript_sources WHERE meeting_id=NEW.meeting_id);
   UPDATE source_details SET changed=CAST((julianday('now')-2440587.5)*86400000 AS INTEGER) WHERE source_id IN
    (SELECT m.source_id FROM meeting_transcript_sources m JOIN sources s ON s.id=m.source_id WHERE m.meeting_id=NEW.meeting_id AND s.generated=1 AND s.deleted=0);
   INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1');
  END;
  CREATE TRIGGER meeting_transcript_delete BEFORE DELETE ON transcript
   WHEN EXISTS(SELECT 1 FROM meeting_transcript_sources WHERE meeting_id=OLD.meeting_id) BEGIN
   DELETE FROM meeting_index_segments WHERE transcript_id=OLD.id;
   DELETE FROM meeting_transcript_changes WHERE meeting_id=OLD.meeting_id AND transcript_id=OLD.id;
   UPDATE meetings SET revision=revision+1 WHERE id=OLD.meeting_id;
   UPDATE sources SET revision=revision+1,state='pending',error='' WHERE generated=1 AND deleted=0 AND
   id IN(SELECT source_id FROM meeting_transcript_sources WHERE meeting_id=OLD.meeting_id);
   UPDATE source_details SET changed=CAST((julianday('now')-2440587.5)*86400000 AS INTEGER) WHERE source_id IN
    (SELECT m.source_id FROM meeting_transcript_sources m JOIN sources s ON s.id=m.source_id WHERE m.meeting_id=OLD.meeting_id AND s.generated=1 AND s.deleted=0);
  END;
  CREATE TRIGGER meeting_transcript_erase AFTER DELETE ON transcript BEGIN
   INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1');
  END;
  CREATE TRIGGER meeting_source_retired AFTER UPDATE OF deleted,generated ON sources
   WHEN NEW.deleted!=0 OR (OLD.generated=1 AND NEW.generated=0) BEGIN
   DELETE FROM meeting_index_segments WHERE meeting_id IN(SELECT meeting_id FROM meeting_transcript_sources WHERE source_id=NEW.id);
   DELETE FROM meeting_index_deletes WHERE meeting_id IN(SELECT meeting_id FROM meeting_transcript_sources WHERE source_id=NEW.id);
   DELETE FROM meeting_transcript_changes WHERE meeting_id IN(SELECT meeting_id FROM meeting_transcript_sources WHERE source_id=NEW.id);
   DELETE FROM meeting_index_batches WHERE meeting_id IN(SELECT meeting_id FROM meeting_transcript_sources WHERE source_id=NEW.id);
   DELETE FROM meeting_index_jobs WHERE meeting_id IN(SELECT meeting_id FROM meeting_transcript_sources WHERE source_id=NEW.id);
   UPDATE meeting_index_progress SET reset_required=1 WHERE meeting_id IN(SELECT meeting_id FROM meeting_transcript_sources WHERE source_id=NEW.id);
  END;
  ''');
    // The correlated read is intentionally absent from metadata/listing/index
    // writes. A requested body is assembled in transcript order, once per read.
    db.execute('''
  CREATE VIEW source_contents AS SELECT s.id,CASE WHEN s.generated=1 AND m.meeting_id IS NOT NULL
  THEN COALESCE((SELECT group_concat(body,char(10)) FROM (
   SELECT '['||CASE trim(substr(t.source,1,instr(t.source||';',';')-1),char(9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279))
   WHEN 'microphone' THEN 'Microphone' WHEN 'microphone-capture-interruption' THEN 'Microphone'
   WHEN 'playback' THEN 'Remote' WHEN 'playback-capture-interruption' THEN 'Remote' ELSE 'Unknown' END||' '||
   CAST(COALESCE(t.start_ms,0) AS INTEGER)||'–'||CAST(COALESCE(t.end_ms,0) AS INTEGER)||' ms] '||COALESCE(t.text,'') AS body
   FROM transcript t WHERE t.meeting_id=m.meeting_id AND t.final=1 ORDER BY t.id)), '')
  ELSE s.content END AS content FROM sources s LEFT JOIN meeting_transcript_sources m ON m.source_id=s.id;
  ''');
  }

  void _createContentHistory() {
    db.execute(
      'CREATE TABLE content_revisions(id INTEGER PRIMARY KEY,entity TEXT NOT NULL,entity_id TEXT NOT NULL,snapshot TEXT NOT NULL,created INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE INDEX content_revisions_entity ON content_revisions(entity,entity_id,id)',
    );
    const entities = {
      'notes': ['id', 'title', 'body', 'revision', 'timestamp'],
      'meeting_notes': [
        'meeting_id',
        'body',
        'revision',
        'enhanced_body',
        'timestamp',
        'last_enhanced',
        'last_manual_edit',
      ],
      'artifacts': [
        'id',
        'meeting_id',
        'kind',
        'generated',
        'edited',
        'input_revision',
        'model',
        'prompt_version',
        'created',
        'manifest',
      ],
      'meeting_tasks': [
        'id',
        'meeting_id',
        'task_key',
        'task',
        'owner',
        'due',
        'status',
        'evidence',
        'input_revision',
        'stale',
        'manual',
      ],
      'sources': [
        'id',
        'title',
        'content',
        'mime',
        'revision',
        'state',
        'error',
        'deleted',
        'provenance',
        'locally_edited',
      ],
    };
    for (final entity in entities.entries) {
      final table = entity.key;
      final id = entity.value.first;
      final snapshot = entity.value
          .map((column) => "'$column',OLD.$column")
          .join(',');
      const content = {
        'notes': ['title', 'body'],
        'meeting_notes': ['body', 'enhanced_body'],
        'artifacts': ['generated', 'edited'],
        'meeting_tasks': [
          'task',
          'owner',
          'due',
          'status',
          'evidence',
          'manual',
        ],
        'sources': ['title', 'content', 'mime', 'provenance'],
      };
      final changed = content[table]!
          .map((column) => 'OLD.$column IS NOT NEW.$column')
          .join(' OR ');
      final retained = table == 'sources'
          ? 'OLD.deleted=0 AND ($changed)'
          : changed;
      db.execute(
        'CREATE TRIGGER ${table}_retain_revision BEFORE UPDATE ON $table WHEN $retained BEGIN '
        "INSERT INTO content_revisions(entity,entity_id,snapshot,created) VALUES('$table',CAST(OLD.$id AS TEXT),json_object($snapshot),CAST(strftime('%s','now') AS INTEGER)*1000); END",
      );
      db.execute(
        'CREATE TRIGGER ${table}_erase_revisions AFTER DELETE ON $table BEGIN '
        "DELETE FROM content_revisions WHERE entity='$table' AND entity_id=CAST(OLD.$id AS TEXT); END",
      );
    }
    // Source deletion is soft; history must obey the same erasure boundary.
    db.execute(
      "CREATE TRIGGER sources_erase_deleted_revisions AFTER UPDATE OF deleted ON sources WHEN NEW.deleted=1 BEGIN DELETE FROM content_revisions WHERE entity='sources' AND entity_id=NEW.id; END",
    );
  }

  // Version 20 is independent of the frozen version-18 trigger definitions.
  void _boundContentHistory() {
    if (!rows(
      'PRAGMA table_info(sources)',
    ).any((row) => row['name'] == 'generated')) {
      db.execute(
        'ALTER TABLE sources ADD COLUMN generated INTEGER NOT NULL DEFAULT 0',
      );
    }
    db.execute(
      "UPDATE sources SET generated=1 WHERE locally_edited=0 AND EXISTS (SELECT 1 FROM meetings WHERE sources.id='meeting-'||meetings.id AND sources.provenance='meeting:'||meetings.id)",
    );
    if (!rows(
      'PRAGMA table_info(meeting_notes)',
    ).any((row) => row['name'] == 'enhanced_generated')) {
      db.execute(
        'ALTER TABLE meeting_notes ADD COLUMN enhanced_generated INTEGER NOT NULL DEFAULT 1',
      );
    }
    // Ambiguous historical ownership is retained conservatively. A later
    // generated write explicitly marks its draft; titles never classify content.
    db.execute(
      'UPDATE meeting_notes SET enhanced_generated=0 WHERE last_manual_edit IS NOT NULL AND (last_enhanced IS NULL OR last_manual_edit>=last_enhanced)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS meeting_index_jobs(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,workspace_epoch TEXT NOT NULL,revision INTEGER NOT NULL,requested INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS meeting_index_state(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,workspace_epoch TEXT NOT NULL,revision INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS content_revisions_created ON content_revisions(created)',
    );
    const entities = {
      'notes': ['id', 'title', 'body', 'revision', 'timestamp'],
      'meeting_notes': [
        'meeting_id',
        'body',
        'revision',
        'enhanced_body',
        'timestamp',
        'last_enhanced',
        'last_manual_edit',
      ],
      'artifacts': [
        'id',
        'meeting_id',
        'kind',
        'generated',
        'edited',
        'input_revision',
        'model',
        'prompt_version',
        'created',
        'manifest',
      ],
      'meeting_tasks': [
        'id',
        'meeting_id',
        'task_key',
        'task',
        'owner',
        'due',
        'status',
        'evidence',
        'input_revision',
        'stale',
        'manual',
      ],
      'sources': [
        'id',
        'title',
        'content',
        'mime',
        'revision',
        'state',
        'error',
        'deleted',
        'provenance',
        'locally_edited',
      ],
    };
    // This inventory is checked against ContentHistory.entities in tests.
    for (final entity in entities.entries) {
      final table = entity.key, id = entity.value.first;
      final snapshot = entity.value
          .map(
            (column) => column == 'enhanced_body'
                ? "'$column',CASE WHEN OLD.enhanced_generated=0 THEN OLD.enhanced_body ELSE NULL END"
                : "'$column',OLD.$column",
          )
          .join(',');
      const content = {
        'notes': ['title', 'body'],
        'artifacts': ['generated', 'edited'],
        'meeting_tasks': [
          'task',
          'owner',
          'due',
          'status',
          'evidence',
          'manual',
        ],
        'sources': ['title', 'content', 'mime', 'provenance'],
      };
      final changed = table == 'meeting_notes'
          ? 'OLD.body IS NOT NEW.body OR (OLD.enhanced_generated=0 AND OLD.enhanced_body IS NOT NEW.enhanced_body)'
          : content[table]!
                .map((column) => 'OLD.$column IS NOT NEW.$column')
                .join(' OR ');
      final retained = table == 'sources'
          ? 'OLD.deleted=0 AND OLD.generated=0 AND ($changed)'
          : changed;
      db.execute('DROP TRIGGER ${table}_retain_revision');
      db.execute(
        'CREATE TRIGGER ${table}_retain_revision BEFORE UPDATE ON $table WHEN $retained BEGIN '
        "INSERT INTO content_revisions(entity,entity_id,snapshot,created) VALUES('$table',CAST(OLD.$id AS TEXT),json_object($snapshot),CAST(strftime('%s','now') AS INTEGER)*1000); END",
      );
      db.execute('DROP TRIGGER ${table}_erase_revisions');
      db.execute(
        'CREATE TRIGGER ${table}_erase_revisions AFTER DELETE ON $table BEGIN '
        "DELETE FROM content_revisions WHERE entity='$table' AND entity_id=CAST(OLD.$id AS TEXT); "
        "INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.privacyMaintenancePending','1'); END",
      );
    }
    db.execute('DROP TRIGGER sources_erase_deleted_revisions');
    db.execute(
      "CREATE TRIGGER sources_erase_deleted_revisions AFTER UPDATE OF deleted ON sources WHEN NEW.deleted=1 BEGIN DELETE FROM content_revisions WHERE entity='sources' AND entity_id=NEW.id; INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.privacyMaintenancePending','1'); END",
    );
    // Inspect each historical snapshot's ownership, not the current row's: a
    // source that was later generated may still have genuine manual revisions.
    db.execute(
      "DELETE FROM content_revisions WHERE entity='sources' AND json_valid(snapshot) AND COALESCE(json_extract(snapshot,'\$.locally_edited'),0)=0 AND EXISTS (SELECT 1 FROM meetings WHERE json_extract(snapshot,'\$.id')='meeting-'||meetings.id AND json_extract(snapshot,'\$.provenance')='meeting:'||meetings.id)",
    );
    db.execute(
      "UPDATE content_revisions SET snapshot=json_set(snapshot,'\$.enhanced_body',NULL) WHERE entity='meeting_notes' AND json_valid(snapshot) AND (json_extract(snapshot,'\$.last_manual_edit') IS NULL OR json_extract(snapshot,'\$.last_enhanced')>json_extract(snapshot,'\$.last_manual_edit'))",
    );
    // A single migration scan bounds old history. Runtime pruning uses indexed
    // entity keys and at most 21 rows, never a repeated database-wide scan.
    db.execute(
      "DELETE FROM content_revisions WHERE id IN (SELECT id FROM (SELECT id,created,row_number() OVER (PARTITION BY entity,entity_id ORDER BY id DESC) AS rank,sum(length(CAST(snapshot AS BLOB))) OVER (PARTITION BY entity,entity_id ORDER BY id DESC) AS bytes FROM content_revisions) WHERE rank>20 OR bytes>33554432 OR created<CAST(strftime('%s','now') AS INTEGER)*1000-7776000000)",
    );
    db.execute(
      "CREATE TRIGGER IF NOT EXISTS content_revisions_bound AFTER INSERT ON content_revisions BEGIN DELETE FROM content_revisions WHERE entity=NEW.entity AND entity_id=NEW.entity_id AND id NOT IN (SELECT id FROM (SELECT id,sum(length(CAST(snapshot AS BLOB))) OVER (ORDER BY id DESC) AS bytes FROM (SELECT id,snapshot FROM content_revisions WHERE entity=NEW.entity AND entity_id=NEW.entity_id AND created>=CAST(strftime('%s','now') AS INTEGER)*1000-7776000000 ORDER BY id DESC LIMIT 20)) WHERE bytes<=33554432); END",
    );
  }

  // Version 21 separates ordinary logical deletion from full-clear compaction.
  // Existing legacy privacy markers retain their full-cleanup meaning.
  void _routeBackupErasure() {
    const entities = {
      'notes': 'id',
      'meeting_notes': 'meeting_id',
      'artifacts': 'id',
      'meeting_tasks': 'id',
      'sources': 'id',
    };
    for (final entity in entities.entries) {
      final table = entity.key, id = entity.value;
      db.execute('DROP TRIGGER ${table}_erase_revisions');
      db.execute(
        'CREATE TRIGGER ${table}_erase_revisions AFTER DELETE ON $table BEGIN '
        "DELETE FROM content_revisions WHERE entity='$table' AND entity_id=CAST(OLD.$id AS TEXT); "
        "INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END",
      );
    }
    db.execute('DROP TRIGGER sources_erase_deleted_revisions');
    db.execute(
      "CREATE TRIGGER sources_erase_deleted_revisions AFTER UPDATE OF deleted ON sources WHEN NEW.deleted=1 BEGIN DELETE FROM content_revisions WHERE entity='sources' AND entity_id=NEW.id; INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1'); END",
    );
  }

  void _canonicalizeLabels() {
    final oldSignature = jsonEncode(
      _documentLabels
          .map((label) => [label.documentId, label.name, label.source])
          .toList(),
    );
    final oldMembers =
        _documentLabels
            .map(
              (label) =>
                  jsonEncode([label.documentId, label.name, label.source]),
            )
            .toList()
          ..sort();
    final validLayouts = rows(
      'SELECT model_identity FROM graph_force_state WHERE label_set=?',
      [oldSignature],
    ).map((row) => row['model_identity']).toSet();
    db.execute(
      'ALTER TABLE document_labels ADD COLUMN position INTEGER NOT NULL DEFAULT 0',
    );
    final records = _documentLabels;
    for (final source in rows(
      'SELECT identities.source_id,d.labels FROM '
      '(SELECT source_id FROM source_details UNION SELECT document_id FROM document_labels) identities '
      'LEFT JOIN source_details d ON d.source_id=identities.source_id ORDER BY identities.source_id',
    )) {
      final id = source['source_id'] as String;
      final existing = {
        for (final row in rows(
          'SELECT * FROM document_labels WHERE document_id=? ORDER BY label_name',
          [id],
        ))
          row['label_name'] as String: row,
      };
      var names = <String>[];
      try {
        names = (jsonDecode(source['labels'] as String) as List)
            .cast<String>()
            .toList();
      } catch (_) {
        // Malformed legacy JSON cannot erase structured manual or automatic rows.
      }
      names = {...names, ...existing.keys}.toList();
      for (var position = 0; position < names.length; position++) {
        final name = names[position];
        if (existing.containsKey(name)) {
          db.execute(
            'UPDATE document_labels SET position=? WHERE document_id=? AND label_name=?',
            [position, id, name],
          );
        } else {
          final color = _historicalAllocateGraphLabelColor(name, records);
          db.execute(
            'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale,position) VALUES(?,?,?,?,NULL,?)',
            [id, name, 'user_defined', color, position],
          );
          records.add(
            _HistoricalDocumentLabel(id, name, 'user_defined', color),
          );
        }
      }
    }
    // SQLite table rebuilding works on every supported host library. Keep the
    // original key, foreign key, timestamps and URI; only the duplicate JSON
    // representation disappears. No DROP COLUMN support is assumed.
    final indexes = rows(
      "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='source_details' AND sql IS NOT NULL",
    ).map((row) => row['sql'] as String).toList();
    final oldDetailsCount = rows(
      'SELECT COUNT(*) AS n FROM source_details',
    ).single['n'];
    db.execute('''CREATE TABLE source_details_canonical(
      source_id TEXT PRIMARY KEY REFERENCES sources(id),imported INTEGER NOT NULL,
      changed INTEGER NOT NULL,source_uri TEXT NOT NULL DEFAULT '');
      INSERT INTO source_details_canonical(source_id,imported,changed,source_uri)
        SELECT source_id,imported,changed,source_uri FROM source_details;
      DROP TABLE source_details;
      ALTER TABLE source_details_canonical RENAME TO source_details;''');
    for (final index in indexes) {
      db.execute(index);
    }
    if (rows('SELECT COUNT(*) AS n FROM source_details').single['n'] !=
        oldDetailsCount) {
      throw StateError('Source details changed during label migration');
    }
    final ordered = rows(
      'SELECT l.document_id,l.label_name,l.label_source FROM document_labels l '
      'JOIN sources s ON s.id=l.document_id WHERE s.deleted=0 ORDER BY l.document_id,l.position',
    );
    final signature = jsonEncode(
      ordered
          .map(
            (row) => [
              row['document_id'],
              row['label_name'],
              row['label_source'],
            ],
          )
          .toList(),
    );
    final members =
        ordered
            .map(
              (row) => jsonEncode([
                row['document_id'],
                row['label_name'],
                row['label_source'],
              ]),
            )
            .toList()
          ..sort();
    if (jsonEncode(oldMembers) == jsonEncode(members)) {
      for (final model in validLayouts) {
        db.execute(
          'UPDATE graph_force_state SET label_set=? WHERE model_identity=?',
          [signature, model],
        );
      }
    }
    // A previously stale layout must not accidentally become valid merely
    // because canonical ordering now matches its old signature.
    for (final row in rows(
      'SELECT model_identity FROM graph_force_state WHERE label_set=?',
      [signature],
    )) {
      if (!validLayouts.contains(row['model_identity'])) {
        db.execute('DELETE FROM graph_force_state WHERE model_identity=?', [
          row['model_identity'],
        ]);
      }
    }
  }

  void _restoreGoogleModificationTimes() {
    for (final row in rows(
      "SELECT sources.id,google_sources.modified FROM google_sources JOIN sources ON sources.id=google_sources.source_id WHERE sources.deleted=0 AND sources.locally_edited=0 AND sources.provenance NOT LIKE 'user edit; %'",
    )) {
      final modified = row['modified'];
      final changed = modified is String
          ? DateTime.tryParse(modified)?.millisecondsSinceEpoch ?? 0
          : 0;
      db.execute(
        'UPDATE source_details SET changed=? WHERE source_id=? AND changed<>?',
        [changed, row['id'], changed],
      );
    }
  }

  void _createLegacyTables() {
    db.execute(
      '''CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,title TEXT NOT NULL,content TEXT NOT NULL,mime TEXT NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',deleted INTEGER NOT NULL DEFAULT 0,provenance TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1,timestamp INTEGER);
    CREATE TABLE IF NOT EXISTS answers(id INTEGER PRIMARY KEY,question TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL,citations TEXT NOT NULL,model TEXT NOT NULL,created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS models(kind TEXT PRIMARY KEY,path TEXT NOT NULL,digest TEXT NOT NULL,runtime TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meetings(id INTEGER PRIMARY KEY,title TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS transcript(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id),text TEXT NOT NULL,final INTEGER NOT NULL,start_ms INTEGER NOT NULL,end_ms INTEGER NOT NULL,source TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS artifacts(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id),kind TEXT NOT NULL,generated TEXT NOT NULL,edited TEXT,input_revision INTEGER NOT NULL,model TEXT NOT NULL,prompt_version TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS conversation_memory(conversation TEXT PRIMARY KEY,through_answer_id INTEGER NOT NULL,messages TEXT NOT NULL,token_counts TEXT);
    CREATE TABLE IF NOT EXISTS source_details(source_id TEXT PRIMARY KEY REFERENCES sources(id),imported INTEGER NOT NULL,changed INTEGER NOT NULL,labels TEXT NOT NULL DEFAULT '[]');
    CREATE TABLE IF NOT EXISTS document_labels(document_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,label_name TEXT NOT NULL,label_source TEXT NOT NULL,color_hex TEXT,rationale TEXT,PRIMARY KEY(document_id,label_name));
    CREATE TABLE IF NOT EXISTS document_clusters(cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,label TEXT UNIQUE NOT NULL,summary TEXT,centroid_embedding BLOB,center_proj_x REAL NOT NULL DEFAULT 0,center_proj_y REAL NOT NULL DEFAULT 0,radius REAL NOT NULL DEFAULT 100);
    CREATE TABLE IF NOT EXISTS graph_documents(model_identity TEXT NOT NULL,document_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,source_revision INTEGER NOT NULL,embedding BLOB NOT NULL,proj_x REAL NOT NULL,proj_y REAL NOT NULL,proj_z REAL NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(model_identity,document_id));
    CREATE TABLE IF NOT EXISTS graph_layouts(model_identity TEXT PRIMARY KEY,document_set TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS graph_force_state(model_identity TEXT PRIMARY KEY REFERENCES graph_layouts(model_identity) ON DELETE CASCADE,label_set TEXT NOT NULL);
    INSERT OR IGNORE INTO source_details(source_id,imported,changed) SELECT id,0,0 FROM sources;
    CREATE TABLE IF NOT EXISTS meeting_details(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id),created INTEGER NOT NULL,reminder INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS meeting_notes(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,body TEXT NOT NULL DEFAULT '',revision INTEGER NOT NULL DEFAULT 0,timestamp INTEGER);
    CREATE TABLE IF NOT EXISTS meeting_note_events(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meeting_notes(meeting_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,event_key TEXT NOT NULL,title TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting_answers(meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,answer_id INTEGER NOT NULL REFERENCES answers(id) ON DELETE CASCADE,PRIMARY KEY(meeting_id,answer_id));
    CREATE TABLE IF NOT EXISTS meeting_question_cursors(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,transcript_id INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting_questions(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,transcript_id INTEGER REFERENCES transcript(id) ON DELETE CASCADE,question TEXT NOT NULL,normalized TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'queued',answer_id INTEGER REFERENCES answers(id) ON DELETE SET NULL,error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL);
    INSERT OR IGNORE INTO meeting_details(meeting_id,created) SELECT id,0 FROM meetings;
    ''',
    );
  }

  void _migrateNoteHistory() {
    // Legacy profiles did not record when a note was saved. Preserve unknown
    // timestamps instead of manufacturing them from meeting creation times.
    for (final table in ['notes', 'meeting_notes']) {
      if (!db
          .select('PRAGMA table_info($table)')
          .any((row) => row['name'] == 'timestamp')) {
        db.execute('ALTER TABLE $table ADD COLUMN timestamp INTEGER');
      }
    }
    for (final column in ['last_enhanced', 'last_manual_edit']) {
      if (!db
          .select('PRAGMA table_info(meeting_notes)')
          .any((row) => row['name'] == column)) {
        db.execute('ALTER TABLE meeting_notes ADD COLUMN $column INTEGER');
      }
    }
    if (!db
        .select('PRAGMA table_info(meeting_notes)')
        .any((row) => row['name'] == 'enhanced_body')) {
      db.execute('ALTER TABLE meeting_notes ADD COLUMN enhanced_body TEXT');
    }
  }

  void _migrateModelMetadata() {
    if (!db
        .select('PRAGMA table_info(models)')
        .any((row) => row['name'] == 'backend')) {
      db.execute(
        "ALTER TABLE models ADD COLUMN backend TEXT NOT NULL DEFAULT 'llama_cpp'",
      );
    }
    if (!db
        .select('PRAGMA table_info(models)')
        .any((row) => row['name'] == 'model_type')) {
      db.execute(
        'ALTER TABLE models ADD COLUMN model_type INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  void _migrateSourceUris() {
    if (!db
        .select('PRAGMA table_info(source_details)')
        .any((row) => row['name'] == 'source_uri')) {
      db.execute(
        "ALTER TABLE source_details ADD COLUMN source_uri TEXT NOT NULL DEFAULT ''",
      );
      for (final row in rows('SELECT id,provenance FROM sources')) {
        final uri = _legacySourceUri(row['provenance'] as String);
        if (uri.isNotEmpty) {
          db.execute(
            'UPDATE source_details SET source_uri=? WHERE source_id=?',
            [uri, row['id']],
          );
        }
      }
    }
  }

  void _migrateAnswerHistory() {
    if (!db
        .select('PRAGMA table_info(answers)')
        .any((r) => r['name'] == 'conversation')) {
      db.execute(
        "ALTER TABLE answers ADD COLUMN conversation TEXT NOT NULL DEFAULT 'desktop'",
      );
    }
    if (!db
        .select('PRAGMA table_info(answers)')
        .any((r) => r['name'] == 'request_id')) {
      db.execute('ALTER TABLE answers ADD COLUMN request_id TEXT');
    }
    if (!db
        .select('PRAGMA table_info(answers)')
        .any((r) => r['name'] == 'model_response')) {
      db.execute('ALTER TABLE answers ADD COLUMN model_response TEXT');
    }
    if (!db
        .select('PRAGMA table_info(conversation_memory)')
        .any((r) => r['name'] == 'token_counts')) {
      db.execute(
        'ALTER TABLE conversation_memory ADD COLUMN token_counts TEXT',
      );
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS answer_request_id ON answers(request_id)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS answer_conversation_id ON answers(conversation,id)',
    );
  }

  void _migrateGoogleTables() {
    db.execute(
      '''CREATE TABLE IF NOT EXISTS google_sources(source_id TEXT PRIMARY KEY REFERENCES sources(id),account TEXT NOT NULL,file_id TEXT NOT NULL,modified TEXT NOT NULL,mime TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS calendar_events(event_key TEXT PRIMARY KEY,account TEXT NOT NULL,calendar_id TEXT NOT NULL,google_id TEXT NOT NULL,meeting_id INTEGER NOT NULL REFERENCES meetings(id),source_id TEXT NOT NULL,starts INTEGER NOT NULL,ends INTEGER NOT NULL,status TEXT NOT NULL,metadata TEXT NOT NULL,synced INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS google_folders(account TEXT NOT NULL,folder_id TEXT NOT NULL,PRIMARY KEY(account,folder_id));''',
    );
  }

  void _migrateMeetingQuestions() {
    final requiredOrigin = db
        .select('PRAGMA table_info(meeting_questions)')
        .any((row) => row['name'] == 'transcript_id' && row['notnull'] == 1);
    final lifetimeUnique = db
        .select('PRAGMA index_list(meeting_questions)')
        .any(
          (row) =>
              row['unique'] == 1 &&
              db
                      .select(
                        'SELECT name FROM pragma_index_info(?) ORDER BY seqno',
                        [row['name']],
                      )
                      .map((column) => column['name'])
                      .join(',') ==
                  'meeting_id,normalized',
        );
    if (!requiredOrigin && !lifetimeUnique) return;
    db.execute("""
        CREATE TABLE meeting_questions_interim(
          id INTEGER PRIMARY KEY,
          meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          transcript_id INTEGER REFERENCES transcript(id) ON DELETE CASCADE,
          question TEXT NOT NULL,normalized TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'queued',
          answer_id INTEGER REFERENCES answers(id) ON DELETE SET NULL,
          error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL);
        INSERT INTO meeting_questions_interim
          SELECT id,meeting_id,transcript_id,question,normalized,state,answer_id,error,created
          FROM meeting_questions;
        DROP TABLE meeting_questions;
        ALTER TABLE meeting_questions_interim RENAME TO meeting_questions;
      """);
  }

  void _reconcileLabelRecords() {
    for (final row in rows('SELECT source_id,labels FROM source_details')) {
      final id = row['source_id'] as String;
      List<String> names;
      try {
        names = (jsonDecode(row['labels'] as String) as List)
            .cast<String>()
            .toList();
      } on FormatException {
        names = _storedLabelNames(id);
      } on TypeError {
        names = _storedLabelNames(id);
      }
      _writeLabelRecords(id, names);
      db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
        jsonEncode(names),
        id,
      ]);
    }
  }

  List<String> _storedLabelNames(String id) => rows(
    'SELECT label_name FROM document_labels WHERE document_id=?',
    [id],
  ).map((row) => row['label_name'] as String).toList();
  List<_HistoricalDocumentLabel> get _documentLabels => rows(
    'SELECT l.* FROM document_labels l JOIN sources s ON s.id=l.document_id WHERE s.deleted=0',
  ).map(_HistoricalDocumentLabel.fromRow).toList();
  void _writeLabelRecords(String id, List<String> names) {
    for (final row in rows(
      'SELECT label_name FROM document_labels WHERE document_id=?',
      [id],
    )) {
      if (!names.contains(row['label_name'])) {
        db.execute(
          'DELETE FROM document_labels WHERE document_id=? AND label_name=?',
          [id, row['label_name']],
        );
      }
    }
    if (names.isEmpty) return;
    final records = _documentLabels;
    for (final name in names.toSet()) {
      if (rows(
        'SELECT 1 FROM document_labels WHERE document_id=? AND label_name=?',
        [id, name],
      ).isNotEmpty) {
        continue;
      }
      final color = _historicalAllocateGraphLabelColor(name, records);
      db.execute(
        'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale) VALUES(?,?,?,?,NULL)',
        [id, name, 'user_defined', color],
      );
      records.add(_HistoricalDocumentLabel(id, name, 'user_defined', color));
    }
  }

  static String _legacySourceUri(String provenance) {
    while (provenance.startsWith('user edit; ')) {
      provenance = provenance.substring('user edit; '.length);
    }
    if (provenance.startsWith('url:')) return provenance.substring(4);
    final marker = provenance.indexOf('; /');
    if (marker >= 0) {
      return Uri.file(provenance.substring(marker + 2)).toString();
    }
    return '';
  }

  List<Map<String, Object?>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) => db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList();
}

const _historicalGraphLabelPalette = [
  '#0EBC5F',
  '#60D5F3',
  '#7372FE',
  '#FEC700',
  '#FF8D41',
  '#3186FF',
  '#FF69C3',
];

class _HistoricalDocumentLabel {
  final String documentId, name, source;
  final String? colorHex, rationale;
  const _HistoricalDocumentLabel(
    this.documentId,
    this.name,
    this.source,
    this.colorHex, [
    this.rationale,
  ]);
  factory _HistoricalDocumentLabel.fromRow(Map<String, Object?> row) =>
      _HistoricalDocumentLabel(
        row['document_id'] as String,
        row['label_name'] as String,
        row['label_source'] as String,
        row['color_hex'] as String?,
        row['rationale'] as String?,
      );
}

String _historicalAllocateGraphLabelColor(
  String name,
  Iterable<_HistoricalDocumentLabel> labels, {
  Iterable<String?> clusterColors = const [],
}) {
  final existing = labels.toList();
  for (final label in existing) {
    if (label.name.toLowerCase() == name.toLowerCase() &&
        label.colorHex != null) {
      return label.colorHex!;
    }
  }
  final used = {
    for (final label in existing)
      if (label.colorHex != null) label.colorHex!.toUpperCase(),
    for (final color in clusterColors)
      if (color != null) color.toUpperCase(),
  };
  for (final color in _historicalGraphLabelPalette) {
    if (!used.contains(color.toUpperCase())) return color;
  }
  return _historicalGraphLabelPalette[name.hashCode.abs() %
      _historicalGraphLabelPalette.length];
}
