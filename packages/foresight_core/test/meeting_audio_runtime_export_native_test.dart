import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/meeting_audio_runtime.dart';
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_export_destinations.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'fixtures/durable_capture_routes.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  final environment = Platform.environment;
  final native = environment['FORESIGHT_NATIVE_LIBRARY'];
  final worker = environment['FORESIGHT_TEST_MEDIA_WORKER'];
  final workerSha = environment['FORESIGHT_TEST_MEDIA_SHA256'];
  final buildId = environment['FORESIGHT_TEST_MEDIA_BUILD_ID'];
  final cdHash = environment['FORESIGHT_TEST_MEDIA_CDHASH'] ?? '';
  final requiresWorker =
      native == null || worker == null || workerSha == null || buildId == null
      ? 'Requires current owned native ABI and explicitly pinned production assembly worker'
      : false;

  test(
    'real runtime export survives settled caller and recording deletion preserves its user-owned file',
    () async {
      final temporary = createTestTempDirectorySync('runtime-real-export-');
      final root = Directory('${temporary.path}/private');
      privateDirectory(root.path);
      expect(root.statSync().mode & 0x1ff, 0x1c0);
      final base = BackupDirectory(root.path, create: false);
      final profile = base.child('profile'), chosen = base.child('chosen');
      final output = '${chosen.path}/saved.opus';
      final store = Store('${profile.path}/application.db');
      profile.close();
      chosen.close();
      base.close();
      addTearDown(store.close);
      expect(
        sha256.convert(File(worker!).readAsBytesSync()).toString(),
        workerSha,
      );
      final bindings = NativeLibrary(DynamicLibrary.open(native!));
      var captureOwned = true;
      var activity = const AudioCaptureActivity();
      var requestCurrent = true;
      var notifiedRunningExport = false, notifiedCommittedExport = false;
      var committedWithRaw = false;
      final observationFailures = <String>[];
      String? rawPath, rawId, exportId;
      late MeetingAudioRuntime runtime;
      void changed() {
        if (rawPath == null || exportId == null) return;
        final job = runtime.media.audio.transformJob(exportId);
        final references =
            store.db.select(
                  'SELECT COUNT(*) AS n FROM audio_media_references WHERE representation_id=?',
                  [rawId],
                ).single['n']
                as int;
        if (job?.state == AudioJobState.running &&
            runtime.transforms.runningJobId == exportId) {
          notifiedRunningExport = true;
          if (references == 0) {
            observationFailures.add('Running real export lost its input lease');
          }
          if (!File(rawPath).existsSync()) {
            observationFailures.add(
              'Running real export lost raw source bytes',
            );
          }
        }
        if (job?.state == AudioJobState.completed &&
            runtime.transforms.runningJobId == exportId) {
          notifiedCommittedExport = true;
          committedWithRaw = File(rawPath).existsSync();
          if (references != 0) {
            observationFailures.add(
              'Committed export did not release its DB input lease',
            );
          }
        }
      }

      runtime = MeetingAudioRuntime(
        store: store,
        bindings: bindings,
        executable: AudioMediaExecutable(
          path: File(worker).resolveSymbolicLinksSync(),
          sha256: workerSha!,
          buildId: buildId!,
          macosCdHash: cdHash,
        ),
        assemblySupported: true,
        configuration: RuntimeConfiguration(const {}),
        changed: changed,
        committed: (_) {},
        captureActivity: () => activity,
        captureOwned: () => captureOwned,
        bindCapture: (_, _) {},
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );
      addTearDown(() async {
        captureOwned = false;
        await runtime.close();
      });
      await runtime.initialize();
      expect(runtime.assemblySupported, true);
      final media = runtime.media;
      final meeting = store.meeting('Synthetic silent source');
      final session = media.audio.createSession(
        meetingId: meeting,
        startedWallMs: 0,
      );
      final span = media.audio.startSpan(
        session.id,
        captureStartUs: 0,
        playbackStartUs: 0,
        wallAnchorMs: 0,
      );
      runtime.prepareSpan(
        span,
        modelRevision: 'no-model-needed-for-silence',
        sourceStarts: {AudioSource.microphone: 0},
      );
      final reservations = media.preallocate(
        span: span,
        source: AudioSource.microphone,
        firstSequence: 0,
        count: 1,
      );
      // Only canonical WAV production is synthetic. Compression, descriptor pager,
      // codec subprocess, actual retirement, publication and cleanup are real.
      final route = CaptureRouteFixture(
        media,
        AudioSource.microphone,
        span.ordinal,
        0,
        reservations,
      );
      final notice = route.audio(0, frames: 48000);
      final chunk = await media.publish(notice);
      rawPath = '${media.sessionDirectory(session.id)}/${chunk.id}.wav';
      rawId = '${chunk.id}.raw';
      media.audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      media.audio.setCaptureState(
        session.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 1000,
      );
      runtime.spanSealed(media.audio.span(span.id)!);
      store.transcript(
        meeting,
        'Independent saved note',
        true,
        0,
        1000,
        'manual',
      );
      final other = media.audio.createSession(
        meetingId: store.meeting('Another logical meeting'),
        startedWallMs: 1000,
      );
      activity = AudioCaptureActivity(
        activeSessionId: other.id,
        state: MeetingAudioPhysicalState.starting,
      );
      Future<void> until(bool Function() ready, String reason) async {
        final clock = Stopwatch()..start();
        while (!ready()) {
          if (clock.elapsed > const Duration(seconds: 45)) {
            fail(
              '$reason; jobs=${store.db.select("SELECT id,kind,state,error FROM audio_transform_jobs").map((r) => Map<String, Object?>.from(r)).toList()}; runtime=${runtime.lastError}; speech=${runtime.saved.lastError}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      await until(
        () =>
            media.audio
                .segmentation(session.id, AudioSource.microphone, span.id)
                ?.flushed ==
            true,
        'Silent segmentation must finish without an ASR model',
      );
      expect(store.db.select('SELECT * FROM audio_asr_jobs'), isEmpty);
      final originalHash = sha256
          .convert(File(rawPath).readAsBytesSync())
          .toString();
      expect(originalHash, chunk.sha256);
      final caller = Object();
      final grant = await runtime.authorizeExportDestination(
        sessionId: session.id,
        callerIdentity: caller,
        workspaceEpoch: store.workspaceEpoch,
        format: MeetingAudioExportFormat.opus,
        outputPath: output,
        overwrite: false,
        allowIncomplete: false,
        current: () => requestCurrent,
      );
      final unusedGrant = await runtime.authorizeExportDestination(
        sessionId: session.id,
        callerIdentity: caller,
        workspaceEpoch: store.workspaceEpoch,
        format: MeetingAudioExportFormat.opus,
        outputPath: '${File(output).parent.path}/unused.opus',
        overwrite: false,
        allowIncomplete: false,
        current: () => requestCurrent,
      );
      final receipt = await runtime.export(
        sessionId: session.id,
        callerIdentity: caller,
        workspaceEpoch: store.workspaceEpoch,
        format: MeetingAudioExportFormat.opus,
        destinationToken: grant.token,
        overwrite: false,
        allowIncomplete: false,
        current: () => requestCurrent,
      );
      exportId = receipt.jobId;
      expect(media.audio.transformJob(exportId)!.state, AudioJobState.pending);
      expect(File(output).existsSync(), false);
      expect(File(rawPath).existsSync(), true);
      // Simulate a successful RPC reply settling and its real caller disconnecting.
      // No fake scheduler/execution port is installed in this runtime graph.
      requestCurrent = false;
      runtime.invalidateCaller(caller);
      await expectLater(
        runtime.export(
          sessionId: session.id,
          callerIdentity: caller,
          workspaceEpoch: store.workspaceEpoch,
          format: MeetingAudioExportFormat.opus,
          destinationToken: unusedGrant.token,
          overwrite: false,
          allowIncomplete: false,
          current: () => true,
        ),
        throwsA(isA<AudioExportConflict>()),
      );
      captureOwned = false;
      activity = const AudioCaptureActivity();
      media.audio.setCaptureState(
        other.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 1000,
      );
      runtime.captureStopped(session);
      await until(
        () =>
            media.audio.transformJob(exportId!)?.state ==
                AudioJobState.completed &&
            !runtime.transforms.busy,
        'Admitted export must outlive the original request/caller',
      );
      final exported = File(output).readAsBytesSync();
      final metadata =
          jsonDecode(media.audio.transformJob(exportId)!.outputMetadata!)
              as Map;
      expect(metadata['validated'], true);
      expect(metadata['frames'], 48000);
      expect(metadata['sha256'], sha256.convert(exported).toString());
      expect(metadata['byte_length'], exported.length);
      expect(ascii.decode(exported.take(4).toList()), 'OggS');
      expect(notifiedRunningExport, true);
      expect(notifiedCommittedExport, true);
      expect(committedWithRaw, true);
      expect(observationFailures, isEmpty);
      expect(bindings.restartRequired, false);
      expect(runtime.transforms.restartRequired, false);
      await until(
        () => media.audio
            .representations(chunk.id)
            .any(
              (r) =>
                  r.codec == 'opus' &&
                  r.state == AudioRepresentationState.published,
            ),
        'Background compression must retain validated audio',
      );
      await until(
        () =>
            media.audio
                .representations(chunk.id)
                .singleWhere((r) => r.id == rawId)
                .state ==
            AudioRepresentationState.purged,
        'Raw cleanup must follow segmentation, export commit and actual worker retirement',
      );
      expect(File(rawPath).existsSync(), false);
      expect(store.db.select('SELECT * FROM audio_media_references'), isEmpty);
      final retained = media.audio
          .representations(chunk.id)
          .singleWhere((r) => r.codec == 'opus');
      expect(retained.validated, true);
      final retainedFile = File(
        '${File(store.path).parent.path}/${retained.relativePath}',
      );
      expect(
        sha256.convert(retainedFile.readAsBytesSync()).toString(),
        retained.sha256,
      );
      final managed = media.sessionDirectory(session.id);
      final exportedHash = sha256.convert(exported).toString();
      await runtime.deleteRecording(session.id, current: () => true);
      expect(media.audio.session(session.id), isNull);
      expect(Directory(managed).existsSync(), false);
      expect(
        store.db.select(
          'SELECT * FROM audio_erasure_intents WHERE session_id=?',
          [session.id],
        ),
        isEmpty,
      );
      expect(File(output).existsSync(), true);
      expect(
        sha256.convert(File(output).readAsBytesSync()).toString(),
        exportedHash,
      );
      expect(
        store.db.select('SELECT text FROM transcript WHERE meeting_id=?', [
          meeting,
        ]).single['text'],
        'Independent saved note',
      );
      await runtime.close();
      // A surviving native inherited FD would refuse this actual owner flock.
      final next = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      next.close();
    },
    skip: requiresWorker,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
