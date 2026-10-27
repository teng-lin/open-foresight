import 'audio_store.dart';
import 'read_schema_guard.dart';

/// Bounded metadata pages for service-owned cancellation and explicit retries.
/// Callers retain admission checks between pages and before each mutation.
final class AudioWorkQueries {
  AudioWorkQueries(this.audio);
  final AudioStore audio;

  List<String> unfinishedExports(
    String sessionId, {
    String afterId = '',
  }) => _ids(
    "SELECT id FROM audio_transform_jobs WHERE session_id=? AND kind='export' AND state NOT IN ('completed','abandoned') AND id>? ORDER BY id LIMIT 64",
    sessionId,
    afterId,
  );

  List<String> retryableTranscription(
    String sessionId, {
    String afterId = '',
  }) => _ids(
    "SELECT id FROM audio_asr_jobs WHERE session_id=? AND state IN ('failed','blocked') AND id>? ORDER BY id LIMIT 64",
    sessionId,
    afterId,
  );

  List<String> retryableCompression(
    String sessionId, {
    String afterId = '',
  }) => _ids(
    "SELECT id FROM audio_transform_jobs WHERE session_id=? AND kind='compression' AND state IN ('failed','blocked') AND id>? ORDER BY id LIMIT 64",
    sessionId,
    afterId,
  );

  List<String> _ids(String sql, String session, String after) => readSnapshot(
    audio.db,
    () => List.unmodifiable(
      audio.db.select(sql, [session, after]).map((row) => row['id'] as String),
    ),
    supportedVersion: audio.supportedVersion,
  );
}
