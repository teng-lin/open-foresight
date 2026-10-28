import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

/// Explicitly reconstruct the pre17 label shape before a test lowers user_version.
/// Production never downgrades a profile. Historical migration bodies retain
/// their original five-column writes; this fixture keeps that schema boundary.
void legacyLabelFixture(Database db) {
  preIncrementalIndexFixture(db);
  // A version-1/8/16 fixture cannot keep schema-18 tables or triggers. Retain
  // the original content while reconstructing that actual historical shape.
  for (final table in [
    'notes',
    'meeting_notes',
    'artifacts',
    'meeting_tasks',
    'sources',
  ]) {
    db.execute('DROP TRIGGER IF EXISTS ${table}_retain_revision');
    db.execute('DROP TRIGGER IF EXISTS ${table}_erase_revisions');
  }
  db.execute('DROP TRIGGER IF EXISTS sources_erase_deleted_revisions');
  db.execute('DROP TABLE IF EXISTS content_revisions');
  final columns = db
      .select('PRAGMA table_info(document_labels)')
      .map((r) => r['name'])
      .toSet();
  if (!columns.contains('position')) return;
  db.execute(
    "ALTER TABLE source_details ADD COLUMN labels TEXT NOT NULL DEFAULT '[]'",
  );
  for (final row in db.select('SELECT source_id FROM source_details')) {
    final labels = db
        .select(
          'SELECT label_name FROM document_labels WHERE document_id=? ORDER BY position',
          [row['source_id']],
        )
        .map((r) => r['label_name'])
        .toList();
    db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
      jsonEncode(labels),
      row['source_id'],
    ]);
  }
  db.execute('ALTER TABLE document_labels DROP COLUMN position');
}

/// Fixtures that lower user_version must remove the actual version22 schema,
/// rather than asking its ordered CREATE statements to tolerate a fake old DB.
void preIncrementalIndexFixture(Database db) {
  prePreferenceEntitiesFixture(db);
  for (final trigger in [
    'meeting_changes_count_insert',
    'meeting_changes_count_delete',
    'meeting_deletes_count_insert',
    'meeting_deletes_count_delete',
    'meeting_piece_delete',
    'meeting_transcript_insert',
    'meeting_transcript_update',
    'meeting_transcript_delete',
    'meeting_transcript_erase',
    'meeting_source_retired',
  ]) {
    db.execute('DROP TRIGGER IF EXISTS $trigger');
  }
  db.execute('DROP VIEW IF EXISTS source_contents');
  for (final table in [
    'meeting_index_batches',
    'meeting_index_segments',
    'meeting_transcript_changes',
    'meeting_index_deletes',
    'meeting_transcript_sources',
    'meeting_index_progress',
  ]) {
    db.execute('DROP TABLE IF EXISTS $table');
  }
  db.execute('DROP INDEX IF EXISTS source_details_uri');
  db.execute('DROP INDEX IF EXISTS transcript_meeting_final_id');
}

/// Reconstruct the pre23 preference representation before lowering user_version.
/// This is a test-only downgrade; preserve values instead of pretending that a
/// current schema is historical or making production CREATE statements tolerant.
void prePreferenceEntitiesFixture(Database db) {
  preRecordingAudioFixture(db);
  if (db
      .select(
        "SELECT 1 FROM sqlite_master WHERE name='answer_metadata' AND type='table'",
      )
      .isEmpty) {
    return;
  }
  db.execute("DROP TRIGGER IF EXISTS legacy_preference_entities_erasure");
  db.execute("DROP TRIGGER IF EXISTS answer_metadata_erasure");
  db.execute("DROP TRIGGER IF EXISTS answer_preference_orphans");
  db.execute("DROP TRIGGER IF EXISTS meeting_preference_orphans");
  db.execute(
    "INSERT OR REPLACE INTO preferences(key,value) SELECT 'answerScope.v1.'||answer_id,scope_identity FROM answer_metadata WHERE scope_identity IS NOT NULL",
  );
  db.execute(
    "INSERT OR REPLACE INTO preferences(key,value) SELECT 'webAnswer.v1.'||answer_id,CASE web_answer WHEN 1 THEN 'true' ELSE 'false' END FROM answer_metadata WHERE web_answer IS NOT NULL",
  );
  db.execute(
    "INSERT OR REPLACE INTO preferences(key,value) SELECT 'answerScope.'||conversation,mode FROM conversation_scopes",
  );
  db.execute(
    "INSERT OR REPLACE INTO preferences(key,value) SELECT 'proactiveScope.'||meeting_id,mode FROM proactive_scopes",
  );
  db.execute("""INSERT OR REPLACE INTO preferences(key,value)
    SELECT CASE purpose WHEN 'answer' THEN 'answerSources.' WHEN 'picker' THEN 'answerSourcesSelection.' ELSE 'preparationSources.' END||owner,
    (SELECT json_group_array(source_id) FROM (SELECT source_id FROM source_selection_items i WHERE i.purpose=s.purpose AND i.owner=s.owner ORDER BY position))
    FROM source_selections s""");
  db.execute(
    'INSERT OR REPLACE INTO preferences(key,value) SELECT key,value FROM legacy_preference_entities',
  );
  for (final table in [
    'source_selection_items',
    'source_selections',
    'conversation_scopes',
    'proactive_scopes',
    'answer_metadata',
    'legacy_preference_entities',
  ]) {
    db.execute('DROP TABLE $table');
  }
}

/// Reconstruct the actual pre25 schema: no attributions or participants, and
/// the version-22 `source_contents` view that renders channel labels only. Like
/// the audio fixture it refuses content it would silently discard.
void preMeetingAttributionFixture(Database db) {
  if (db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='transcript_attributions'",
      )
      .isEmpty) {
    return;
  }
  if (db.select('SELECT 1 FROM transcript_attributions LIMIT 1').isNotEmpty ||
      db.select('SELECT 1 FROM meeting_participants LIMIT 1').isNotEmpty) {
    throw StateError(
      'A historical migration fixture cannot contain speaker attribution',
    );
  }
  for (final trigger in [
    'transcript_attribution_participant_insert',
    'transcript_attribution_participant_update',
    'transcript_attribution_manual_guard',
    'transcript_attribution_manual_replace_guard',
    'transcript_attribution_replace',
    'transcript_attribution_insert',
    'transcript_attribution_update',
    'transcript_attribution_delete',
    'transcript_attribution_erase_replaced',
    'transcript_attribution_erase_replace',
    'transcript_attribution_erase',
    'meeting_participant_erase_renamed',
    'meeting_participant_erase',
  ]) {
    db.execute('DROP TRIGGER $trigger');
  }
  db.execute('DROP TABLE transcript_attributions');
  db.execute('DROP TABLE meeting_participants');
  db.execute('DROP VIEW source_contents');
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

/// Reconstruct the actual pre24 schema. These downgrade fixtures contain no
/// retained media; refusing nonempty audio avoids silently discarding fixture
/// content while manufacturing an older database version.
void preRecordingAudioFixture(Database db) {
  preMeetingAttributionFixture(db);
  if (db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='recording_sessions'",
      )
      .isEmpty) {
    return;
  }
  if (db.select('SELECT 1 FROM recording_sessions LIMIT 1').isNotEmpty) {
    throw StateError(
      'A historical migration fixture cannot contain recorded audio',
    );
  }
  db.execute('DROP TRIGGER audio_session_reference_fence');
  db.execute('DROP TRIGGER audio_session_erasure');
  for (final table in [
    'transcript_audio_links',
    'audio_media_references',
    'audio_transform_inputs',
    'audio_transform_jobs',
    'audio_asr_job_chunks',
    'audio_asr_jobs',
    'audio_segmentation_progress',
    'audio_representations',
    'audio_chunks',
    'audio_chunk_publications',
    'audio_source_clocks',
    'recording_spans',
    'recording_sessions',
    'audio_erasure_intents',
    'audio_storage_generation',
  ]) {
    db.execute('DROP TABLE $table');
  }
}
