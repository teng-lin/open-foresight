import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'sql_support_test_bootstrap.dart';
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
  final selectedNative = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  final requiresNative = selectedNative == null
      ? 'Set the freshly built native library and SQL support to validate capture publication'
      : false;
  test(
    'first and resumed raw capture publish within their actual SQL spans',
    () async {
      bootstrapSqlSupportFixture();
      final root = createTestTempDirectorySync('native-span-publication-');
      final store = Store('${root.path}/app.db');
      final media = RecordingMedia.open(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      addTearDown(() {
        media.close();
        store.close();
      });
      final clock = DynamicLibrary.open(selectedNative!)
          .lookupFunction<Int64 Function(), int Function()>(
            'fs_recording_monotonic_us',
          );
      final fixture = File(
        '${File(selectedNative).absolute.parent.path}/native_recording_capture_test',
      ).absolute;
      expect(
        fixture.existsSync(),
        isTrue,
        reason: 'Build the root CMake native_recording_capture_test target',
      );
      final origin = clock();
      final session = media.audio.createSession(
        meetingId: store.meeting('Synthetic raw capture publication'),
        startedWallMs: DateTime.now().millisecondsSinceEpoch,
      );
      var playbackStart = 0, sourceSample = 0, previousEnd = 0;
      for (var attempt = 0; attempt < 2; attempt++) {
        // A real pause crosses the previous retained sample end before resume;
        // do not invent a future span to manufacture an admission bound.
        final waiting = Stopwatch()..start();
        while (clock() - origin <= previousEnd) {
          expect(waiting.elapsed, lessThan(const Duration(seconds: 2)));
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final span = media.audio.startSpan(
          session.id,
          captureStartUs: clock() - origin,
          playbackStartUs: playbackStart,
          wallAnchorMs: DateTime.now().millisecondsSinceEpoch,
        );
        final authority = media
            .preallocate(
              span: span,
              source: AudioSource.microphone,
              firstSequence: attempt,
              count: 1,
            )
            .single;
        final request = {
          'directory': media.sessionDirectory(session.id),
          'session_id': session.id,
          'generation': session.storageGeneration,
          'span': span.ordinal,
          'origin_us': origin,
          'source_sample': sourceSample,
          'chunk_ids': [
            {'id': authority.id, 'sequence': authority.sequence},
          ],
          // Forty milliseconds of samples arrive only one millisecond after
          // span admission. The old session-origin clamp places them before
          // both the first and the resumed span.
          'drained_override_us': origin + span.captureStartUs + 1000,
        };
        final child = await Process.start(fixture.path, ['--publish-estimate']);
        final output = child.stdout.transform(utf8.decoder).join();
        final errors = child.stderr.transform(utf8.decoder).join();
        final exited = child.exitCode;
        output.ignore();
        errors.ignore();
        exited.ignore();
        var exitObserved = false;
        late final Map<String, dynamic> result;
        try {
          child.stdin.writeln(jsonEncode(request));
          await child.stdin.close();
          final code = await exited.timeout(const Duration(seconds: 10));
          exitObserved = true;
          expect(code, 0, reason: await errors);
          result = (jsonDecode(await output) as Map).cast<String, dynamic>();
        } finally {
          if (!exitObserved) {
            child.kill(ProcessSignal.sigkill);
            await exited.timeout(const Duration(seconds: 10));
          }
        }
        final notice = RecordingChunkNotice.fromJson(
          (result['notice'] as Map).cast<String, dynamic>(),
        );
        print(
          'Synthetic raw span=${span.captureStartUs} '
          'nativeStart=${notice.captureStartUs} samples=${notice.frames}',
        );
        final chunk = await media.publish(notice);
        expect(
          notice.captureStartUs,
          greaterThanOrEqualTo(span.captureStartUs),
        );
        expect(notice.frames, 1920);
        expect(notice.sourceSample, sourceSample);
        expect(result['clock_quality'], 'pipe_drain_estimate');
        expect(result['acquired_through_us'], -1);
        // This validates the actual canonical WAV and authority before the
        // unchanged SQL span-bound guard admits the native publication.
        expect(chunk.sampleCount, 1920);
        expect(chunk.captureStartUs, notice.captureStartUs);
        expect(chunk.spanId, span.id);
        media.audio.closeSpan(
          span.id,
          captureEndUs: notice.captureEndUs,
          reason: 'paused',
        );
        media.audio.setCaptureState(session.id, AudioCaptureState.paused);
        previousEnd = notice.captureEndUs;
        playbackStart = media.audio.span(span.id)!.playbackEndUs!;
        sourceSample += notice.frames;
      }
      expect(media.audio.spans(session.id), hasLength(2));
      expect(
        store
            .rows('SELECT COUNT(*) AS count FROM audio_chunks')
            .single['count'],
        2,
      );
    },
    skip: requiresNative,
  );

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
