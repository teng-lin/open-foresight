import '../store.dart';

/// Content owned by the workspace. Model registrations, account configuration
/// and pending helper deletions survive the local privacy transaction.
const workspaceContentTables = [
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
  'source_selection_items',
  'source_selections',
  'conversation_scopes',
  'proactive_scopes',
  'answer_metadata',
  'legacy_preference_entities',
  'content_revisions',
  'google_sources',
  'google_folders',
  'calendar_events',
  'meeting_questions',
  'meeting_question_cursors',
  'meeting_answers',
  'meeting_note_events',
  'meeting_notes',
  'meeting_index_batches',
  'meeting_index_segments',
  'meeting_transcript_changes',
  'meeting_index_deletes',
  'meeting_transcript_sources',
  'meeting_index_progress',
  'meeting_index_jobs',
  'meeting_index_state',
  'meeting_summary_checkpoints',
  'meeting_tasks',
  'document_summary_cache',
  'artifacts',
  'transcript',
  'meeting_details',
  'meetings',
  'answers',
  'conversation_memory',
  'notes',
  'source_details',
  'document_labels',
  'document_clusters',
  'graph_documents',
  'graph_force_state',
  'graph_layouts',
  'sources',
  'request_keys',
];

class ClearedWorkspace {
  final List<String> sourceIds;
  final String epoch;

  ClearedWorkspace(Iterable<String> sourceIds, this.epoch)
    : sourceIds = List.unmodifiable(sourceIds);
}

/// The application passes its existing writer; this object never opens another
/// connection or owns service lifetime. Compaction and remote cleanup occur only
/// after this transaction has committed.
class WorkspacePersistence {
  final Store store;

  WorkspacePersistence(this.store);

  List<String> get sourceIds => List.unmodifiable(
    store.rows('SELECT id FROM sources').map((row) => row['id'] as String),
  );

  /// [sourceIds] is captured before the application invalidates in-flight work.
  /// Keeping that step outside this transaction preserves cancellation ordering.
  ClearedWorkspace clearLocalData(List<String> sourceIds) {
    final erased = List<String>.of(sourceIds, growable: false);
    store.db.execute('BEGIN IMMEDIATE');
    try {
      for (final id in erased) {
        store.db.execute(
          'INSERT OR IGNORE INTO pending_helper_deletes VALUES(?,?)',
          [id, DateTime.now().millisecondsSinceEpoch],
        );
      }
      // Producers/readers must already be fenced by the application owner.
      // Tombstones and storage identity survive the workspace content deletion.
      store.audioStore.rotateStorageGeneration();
      for (final table in workspaceContentTables) {
        store.db.execute('DELETE FROM $table');
      }
      store.db.execute(
        "DELETE FROM preferences WHERE key GLOB 'webAnswer.v1.*' OR key GLOB 'answerScope.*' OR key GLOB 'answerSources.*' OR key GLOB 'answerSourcesSelection.*' OR key GLOB 'proactiveScope.*' OR key GLOB 'preparationSources.*'",
      );
      store.renewWorkspaceEpoch();
      store.markPrivacyMaintenancePending();
      store.db.execute('COMMIT');
    } catch (_) {
      // SQLite can already roll back after IOERR/FULL. Keep the original error.
      if (!store.db.autocommit) store.db.execute('ROLLBACK');
      rethrow;
    }
    return ClearedWorkspace(erased, store.workspaceEpoch);
  }
}
