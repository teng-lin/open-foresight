import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/application_services/audio_transform_scheduler.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/persistence/audio_export_destinations.dart';
import 'package:foresight_core/src/persistence/audio_export_media.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

final class Execution implements AudioTransformExecution {
  Execution() {
    resultValue.future.ignore();
    exit.future.ignore();
  }
  final resultValue = Completer<AudioEncodedResult>(), exit = Completer<void>();
  int cancellations = 0;
  @override
  Future<AudioEncodedResult> get result => resultValue.future;
  @override
  Future<void> get closed => exit.future;
  @override
  void cancel() {
    cancellations++;
    if (!resultValue.isCompleted) {
      resultValue.completeError(StateError('Cancelled'));
    }
  }
}

final _write = DynamicLibrary.process()
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late RecordingMedia media;
  late AudioExportDestinations broker;
  late AudioExportMedia exports;
  late AudioTransformScheduler scheduler;
  late AudioTransformJob job;
  late Execution execution;
  late String output;
  final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
  var starts = 0, now = 0, throwAtStart = false;
  final started = StreamController<void>.broadcast();
  tearDownAll(started.close);
  AudioEncodedResult result() => AudioEncodedResult(
    sha256: sha256.convert(bytes).toString(),
    byteLength: bytes.length,
    frames: 4800,
    preSkip: 0,
    finalGranule: 0,
    workerBuildId: 'a' * 64,
    workerSha256: 'b' * 64,
  );
  int references() =>
      store.db
              .select('SELECT COUNT(*) AS n FROM audio_media_references')
              .single['n']
          as int;
  Future<void> waitStarted(int count) async {
    if (starts >= count) return;
    await started.stream
        .firstWhere((_) => starts >= count)
        .timeout(const Duration(seconds: 5));
  }

  setUp(() {
    starts = now = 0;
    throwAtStart = false;
    final temporary = createTestTempDirectorySync('audio-export-worker-');
    final root = Directory('${temporary.path}/private');
    privateDirectory(root.path);
    expect(root.statSync().mode & 0x1ff, 0x1c0);
    final parent = BackupDirectory(root.path, create: false),
        profile = parent.child('profile'),
        chosen = parent.child('chosen');
    output = '${chosen.path}/recording.mp3';
    store = Store('${profile.path}/application.db');
    profile.close();
    chosen.close();
    parent.close();
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    final session = media.audio.createSession(
      meetingId: store.meeting('Export'),
      startedWallMs: 0,
    );
    final span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final authority = media
        .preallocate(
          span: span,
          source: AudioSource.microphone,
          firstSequence: 0,
          count: 1,
        )
        .single;
    media.audio.publishPreallocatedChunk(
      authority.id,
      publicationToken: authority.publicationToken,
      sampleStart: 0,
      sampleCount: 4800,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 100000,
      byteLength: 9796,
      sha256: 'c' * 64,
    );
    media.audio.closeSpan(span.id, captureEndUs: 100000, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 0,
    );
    broker = AudioExportDestinations(
      media: media,
      now: () => Duration(milliseconds: now),
    );
    final caller = Object();
    final grant = broker.authorize(
      sessionId: session.id,
      callerIdentity: caller,
      workspaceEpoch: store.workspaceEpoch,
      format: MeetingAudioExportFormat.mp3,
      outputPath: output,
      overwrite: false,
      allowIncomplete: false,
      current: () => true,
    );
    final destination = broker.consume(
      token: grant.token,
      sessionId: session.id,
      callerIdentity: caller,
      workspaceEpoch: store.workspaceEpoch,
      format: MeetingAudioExportFormat.mp3,
      overwrite: false,
      allowIncomplete: false,
      current: () => true,
    );
    job = media.audio.createExportJob(
      sessionId: session.id,
      codec: 'mp3',
      container: 'mp3',
      settingsRevision: 'shared-assembly-v1',
      settings: destination.frozenJobSettings,
    );
    destination.bindJob(job, current: () => true);
    exports = AudioExportMedia(
      media: media,
      destinations: broker,
      startWorker:
          ({
            required lease,
            required manifest,
            required outputDescriptor,
            required current,
          }) async {
            starts++;
            started.add(null);
            expect(manifest.timelineFrames, 4800);
            if (throwAtStart) throw StateError('Before native admission');
            final pointer = calloc<Uint8>(bytes.length);
            try {
              pointer.asTypedList(bytes.length).setAll(0, bytes);
              expect(
                _write(outputDescriptor, pointer, bytes.length),
                bytes.length,
              );
            } finally {
              calloc.free(pointer);
            }
            return execution = Execution();
          },
    );
    scheduler = AudioTransformScheduler(
      store: media.audio,
      ownerGeneration: media.ownerGeneration,
      prepare: exports.prepare,
      nowMs: () => now,
      committed: (_) {},
      changed: () {},
    );
    addTearDown(() async {
      if (starts > 0 && !throwAtStart) {
        if (!execution.resultValue.isCompleted) {
          execution.resultValue.completeError(StateError('Test closed'));
        }
        if (!execution.exit.isCompleted) execution.exit.complete();
      }
      await scheduler.close();
      broker.close();
      media.close();
      store.close();
    });
  });
  test(
    'a successful result waits actual exit before external publication and DB commit',
    () async {
      final work = scheduler.runOne();
      await waitStarted(1);
      expect(references(), 1);
      execution.resultValue.complete(result());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(File(output).existsSync(), isFalse);
      expect(references(), 1);
      execution.exit.complete();
      await work;
      expect(File(output).readAsBytesSync(), bytes);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
      expect(references(), 0);
      expect(starts, 1);
    },
  );
  test(
    'explicit cancellation retains input readers and staging until actual exit',
    () async {
      final work = scheduler.runOne();
      await waitStarted(1);
      var settled = false;
      final cancelling = scheduler.cancel(job.id).then((_) => settled = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(execution.cancellations, 1);
      expect(settled, isFalse);
      expect(references(), 1);
      execution.exit.complete();
      await cancelling;
      await work;
      expect(File(output).existsSync(), isFalse);
      expect(references(), 0);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.abandoned);
    },
  );
  test(
    'DB commit failure recovers exact published output without running assembly again',
    () async {
      store.db.execute(
        "CREATE TEMP TRIGGER reject_export_commit BEFORE UPDATE OF state ON audio_transform_jobs WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'synthetic commit fault'); END",
      );
      final work = scheduler.runOne();
      await waitStarted(1);
      execution.resultValue.complete(result());
      execution.exit.complete();
      await work;
      expect(File(output).readAsBytesSync(), bytes);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(references(), 0);
      store.db.execute('DROP TRIGGER reject_export_commit');
      now = 10000;
      await scheduler.runOne();
      expect(starts, 1);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
      expect(File(output).readAsBytesSync(), bytes);
    },
  );
  test(
    'failure before native admission can retry the exact destination in the same process',
    () async {
      throwAtStart = true;
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(references(), 0);
      expect(File(output).existsSync(), isFalse);
      throwAtStart = false;
      now = 10000;
      final work = scheduler.runOne();
      await waitStarted(2);
      execution.resultValue.complete(result());
      execution.exit.complete();
      await work;
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
    },
  );
  test(
    'invalid frame result never publishes and original input remains available',
    () async {
      final work = scheduler.runOne();
      await waitStarted(1);
      execution.resultValue.complete(
        AudioEncodedResult(
          sha256: sha256.convert(bytes).toString(),
          byteLength: bytes.length,
          frames: 4799,
          preSkip: 0,
          finalGranule: 0,
          workerBuildId: 'a' * 64,
          workerSha256: 'b' * 64,
        ),
      );
      execution.exit.complete();
      await work;
      expect(File(output).existsSync(), isFalse);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(
        store.db
            .select(
              "SELECT COUNT(*) AS n FROM audio_representations WHERE state='published'",
            )
            .single['n'],
        1,
      );
    },
  );
}
