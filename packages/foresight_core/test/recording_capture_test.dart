import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/recording_capture.dart';
import 'package:test/test.dart';

const sessionId = '11111111-1111-4111-a111-111111111111';
const generation = '22222222-2222-4222-a222-222222222222';
const chunkId = '33333333-3333-4333-a333-333333333333';

Map<String, dynamic> chunkJson() => {
  'chunk_id': chunkId,
  'session_id': sessionId,
  'generation': generation,
  'source': 0,
  'sequence': 6,
  'span': 2,
  'source_sample': 480000,
  'frames': 4800,
  'sample_rate': 48000,
  'channels': 1,
  'capture_start_us': 12300000,
  'bytes': 9796,
  'relative_path': '$chunkId.wav',
  'interrupted': false,
  'gap_before': false,
  'contents_synced': true,
  'directory_synced': true,
};

Map<String, dynamic> snapshotJson() => {
  'version': 1,
  'ready': true,
  'session_id': sessionId,
  'generation': generation,
  'source': 0,
  'span': 2,
  'state': 'capturing',
  'capture_active': true,
  'error': null,
  'clock_quality': 'hardware_host_time',
  'uncertainty_us': null,
  'current_volume': 0.125,
  'peak_volume': 0.5,
  'last_voice_capture_us': 12400000,
  'source_sample': 484800,
  'acquired_through_us': 12400000,
  'queued_frames': 4800,
  'ready_chunks': 1,
  'reserved_chunks': 3,
  'outstanding_chunks': 4,
  'chunks': [chunkJson()],
};

void main() {
  test('publication keeps source samples and acquisition clock separate', () {
    final snapshot = RecordingCaptureSnapshot.fromJson(snapshotJson());
    expect(snapshot.captureActive, isTrue);
    expect(snapshot.clockQuality, RecordingClockQuality.hardwareHostTime);
    expect(snapshot.uncertaintyUs, isNull);
    expect(snapshot.lastVoiceCaptureUs, 12400000);
    expect(snapshot.acquiredThroughUs, 12400000);
    expect(snapshot.currentVolume, 0.125);
    final chunk = snapshot.chunks.single;
    expect(chunk.source, AudioSource.microphone);
    expect(chunk.sourceSample, 480000);
    expect(chunk.captureStartUs, 12300000);
    expect(chunk.captureEndUs, 12400000);
    expect(chunk.byteLength, 196 + chunk.frames * 2);
  });

  test('sealed storage warning remains visible with no active microphone', () {
    final value = snapshotJson()
      ..['state'] = 'failed'
      ..['capture_active'] = false
      ..['error'] = 'Disk full';
    final snapshot = RecordingCaptureSnapshot.fromJson(value);
    expect(snapshot.error, 'Disk full');
    expect(snapshot.captureActive, isFalse);
    expect(snapshot.chunks, hasLength(1));
  });

  test(
    'rejects malformed extent, path, rate and source before filesystem use',
    () {
      for (final mutation in <Map<String, Object>>[
        {'relative_path': '../other.wav'},
        {'sample_rate': 16000},
        {'channels': 2},
        {'frames': 0},
        {'frames': 240001},
        {'bytes': 9795},
        {'source': 2},
        {'source_sample': -1},
        {'sequence': 1.0},
        {'chunk_id': 'x' * 36},
      ]) {
        expect(
          () => RecordingChunkNotice.fromJson(chunkJson()..addAll(mutation)),
          throwsFormatException,
          reason: mutation.toString(),
        );
      }
    },
  );

  test(
    'rejects mismatched publication owner and duplicate delivery in one batch',
    () {
      for (final mutation in <Map<String, Object>>[
        {'session_id': generation},
        {'generation': sessionId},
        {'span': 3},
        {'source': 1},
      ]) {
        final value = snapshotJson()
          ..['chunks'] = [chunkJson()..addAll(mutation)];
        expect(
          () => RecordingCaptureSnapshot.fromJson(value),
          throwsFormatException,
        );
      }
      expect(
        () => RecordingCaptureSnapshot.fromJson(
          snapshotJson()..['chunks'] = [chunkJson(), chunkJson()],
        ),
        throwsFormatException,
      );
    },
  );

  test('rejects unbounded batches and contradictory active status', () {
    for (final mutation in <Map<String, dynamic>>[
      {'chunks': List.generate(65, (_) => chunkJson())},
      {'ready': false},
      {'state': 'sealed'},
      {'error': 'Disk full'},
      {'queued_frames': 307201},
      {'outstanding_chunks': 65},
      {'version': 2},
      {'clock_quality': 'invented'},
      {'current_volume': double.nan},
      {'peak_volume': 1.001},
      {'last_voice_capture_us': -1},
    ]) {
      expect(
        () =>
            RecordingCaptureSnapshot.fromJson(snapshotJson()..addAll(mutation)),
        throwsFormatException,
        reason: mutation.keys.toString(),
      );
    }
  });

  test('an estimate never becomes a measured acquisition bound', () {
    final snapshot = RecordingCaptureSnapshot.fromJson(
      snapshotJson()..['clock_quality'] = 'pipe_drain_estimate',
    );
    expect(snapshot.clockQuality, RecordingClockQuality.pipeDrainEstimate);
    expect(snapshot.uncertaintyUs, isNull);
    final graph = RecordingCaptureSnapshot.fromJson(
      snapshotJson()..['clock_quality'] = 'pipewire_graph_time',
    );
    expect(graph.clockQuality, RecordingClockQuality.pipewireGraphTime);
    expect(graph.uncertaintyUs, isNull);
  });
}
