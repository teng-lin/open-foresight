import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/audio_work_queries.dart';
import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  test('job control pages cover long queues without crossing session or kind', () {
    final root = createTestTempDirectorySync('audio-work-query-');
    final store = Store('${root.path}/application.db');
    addTearDown(store.close);
    final audio = AudioStore(
      store.db,
      workspaceEpoch: () => store.workspaceEpoch,
      mediaGeneration: () => store.audioStore.storageGeneration,
    );
    final session = audio.createSession(
      meetingId: store.meeting('Work pages'),
      startedWallMs: 0,
    );
    final other = audio.createSession(
      meetingId: store.meeting('Other recording'),
      startedWallMs: 0,
    );
    final span = audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final exports = <String>[],
        compression = <String>[],
        transcription = <String>[];
    for (var i = 0; i < 141; i++) {
      for (final kind in AudioTransformKind.values) {
        final id = AudioStore.newIdentity();
        store.db.execute(
          "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state) VALUES(?,?,?,?, 'opus','ogg','v1','{}','blocked')",
          [id, session.id, kind.name, id],
        );
        if (kind == AudioTransformKind.export) exports.add(id);
        if (kind == AudioTransformKind.compression) compression.add(id);
      }
      final id = AudioStore.newIdentity();
      store.db.execute(
        "INSERT INTO audio_asr_jobs(id,session_id,span_id,source,sample_start,sample_end,owned_start,owned_end,model_revision,settings_revision,state) VALUES(?,?,?,'microphone',?,?,?,?,'frozen-model','v1','failed')",
        [id, session.id, span.id, i, i + 1, i, i + 1],
      );
      transcription.add(id);
    }
    for (final state in ['completed', 'abandoned', 'pending']) {
      final id = AudioStore.newIdentity();
      store.db.execute(
        "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state) VALUES(?,?,'compression',?,'opus','ogg','v1','{}',?)",
        [id, session.id, id, state],
      );
    }
    final unrelated = AudioStore.newIdentity();
    store.db.execute(
      "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state) VALUES(?,?,'export',?,'opus','ogg','v1','{}','failed')",
      [unrelated, other.id, unrelated],
    );
    final queries = AudioWorkQueries(audio);
    List<String> collect(List<String> Function(String) next) {
      final result = <String>[];
      var after = '';
      while (true) {
        final page = next(after);
        expect(page.length, lessThanOrEqualTo(64));
        if (page.isEmpty) return result;
        result.addAll(page);
        after = page.last;
      }
    }

    expect(
      collect((id) => queries.unfinishedExports(session.id, afterId: id)),
      exports..sort(),
    );
    expect(
      collect((id) => queries.retryableCompression(session.id, afterId: id)),
      compression..sort(),
    );
    expect(
      collect((id) => queries.retryableTranscription(session.id, afterId: id)),
      transcription..sort(),
    );
    expect(queries.unfinishedExports(other.id), [unrelated]);
    expect(queries.retryableTranscription(other.id), isEmpty);
    store.db.execute('PRAGMA user_version=${audio.supportedVersion + 1}');
    for (final read in [
      () => queries.unfinishedExports(session.id),
      () => queries.retryableTranscription(session.id),
      () => queries.retryableCompression(session.id),
    ]) {
      expect(read, throwsA(isA<IncompatibleReadSchema>()));
    }
  });
}
