import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/audio_playback_source.dart';
import 'package:foresight_core/src/application_services/audio_startup_recovery.dart';
import 'package:foresight_core/src/application_services/audio_transform_scheduler.dart';
import 'package:foresight_core/src/application_services/meeting_audio_runtime.dart';
import 'package:foresight_core/src/application_services/saved_audio_player.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/persistence/audio_export_destinations.dart';
import 'package:foresight_core/src/persistence/audio_media_erasure.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/recording_capture.dart';
import 'package:foresight_core/src/recording_playback.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

Future<void> until(bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      fail('Runtime fence was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

// Controlled worker ports distinguish result from actual close; media, SQLite,
// runtime, scheduler and player are real. These do not qualify native devices.
final class ControlledExecution implements AudioTransformExecution {
  ControlledExecution() {
    resultOwner.future.ignore();
    exit.future.ignore();
  }
  final resultOwner = Completer<AudioEncodedResult>(), exit = Completer<void>();
  int cancellations = 0;
  @override
  Future<AudioEncodedResult> get result => resultOwner.future;
  @override
  Future<void> get closed => exit.future;
  @override
  void cancel() {
    cancellations++;
    if (!resultOwner.isCompleted) {
      resultOwner.completeError(StateError('Cancelled'));
    }
  }
}

final class ControlledTransform implements AudioTransformOperation {
  final started = Completer<void>();
  final execution = ControlledExecution();
  @override
  bool get hasValidatedOutput => false;
  @override
  Future<AudioTransformExecution> start() async {
    started.complete();
    return execution;
  }

  @override
  void markWorkerClosed() {}
  @override
  Future<AudioTransformOutput> publish(AudioEncodedResult? result) =>
      throw StateError('Cancelled worker cannot publish');
  @override
  void resetForRetry() {}
  @override
  void abort() {}
  @override
  void committed() {}
  @override
  void close() {}
}

final class ControlledSource implements AudioPlaybackSource {
  final closing = Completer<void>(), exit = Completer<void>();
  @override
  int get totalFrames => 48000;
  @override
  Future<Int16List> decode(int startFrame, int frameCount) async =>
      Int16List(frameCount);
  @override
  void cancel() {}
  @override
  Future<void> close() async {
    if (!closing.isCompleted) closing.complete();
    await exit.future;
  }
}

final class ControlledOutput implements PcmPlaybackOutput {
  ControlledOutput(this.generation);
  @override
  final int generation;
  final exit = Completer<void>();
  @override
  PcmOutputSnapshot snapshot() => PcmOutputSnapshot.fromJson({
    'version': 1,
    'generation': generation,
    'queued_frames': 0,
    'rendered_frames': 0,
    'underruns': 0,
    'start_token': 1,
    'ready': true,
    'paused': false,
    'stopped': false,
    'buffering': false,
    'error': null,
  });
  @override
  int push(Int16List stereo, {required int generation}) => stereo.length ~/ 2;
  @override
  Future<void> pauseFlush(int nextGeneration) async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> close() => exit.future;
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late MeetingAudioRuntime runtime;
  var owned = false;
  var activity = const AudioCaptureActivity();
  late List<RecordingMedia> bound;
  final expectedCloseFailures = <MeetingAudioRuntime>{};
  setUp(() {
    final temporary = createTestTempDirectorySync('meeting-audio-runtime-');
    root = Directory('${temporary.path}/private');
    privateDirectory(root.path);
    expect(root.statSync().mode & 0x1ff, 0x1c0);
    final base = BackupDirectory(root.path, create: false);
    final profile = base.child('profile');
    store = Store('${profile.path}/application.db');
    profile.close();
    base.close();
    owned = false;
    activity = const AudioCaptureActivity();
    bound = [];
    addTearDown(store.close);
  });
  MeetingAudioRuntime owner({RecoverAudioBatch? recover}) {
    final value = MeetingAudioRuntime(
      store: store,
      bindings: NativeLibrary(DynamicLibrary.process()),
      executable: null,
      assemblySupported: false,
      configuration: RuntimeConfiguration(const {}),
      changed: () {},
      committed: (_) {},
      captureActivity: () => activity,
      captureOwned: () => owned,
      bindCapture: (media, _) => bound.add(media),
      nowMs: () => 1000,
      recoverAudio: recover,
    );
    addTearDown(() async {
      owned = false;
      try {
        await value.close();
      } catch (_) {
        if (!expectedCloseFailures.contains(value)) rethrow;
      }
    });
    return value;
  }

  Future<({AudioSession session, AudioChunk chunk, Uint8List bytes})> recording(
    RecordingMedia media,
  ) async {
    media.admitNewCapture();
    final session = media.audio.createSession(
      meetingId: store.meeting('Saved silent recording'),
      startedWallMs: 0,
    );
    final span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final reservation = media
        .preallocate(
          span: span,
          source: AudioSource.microphone,
          firstSequence: 0,
          count: 1,
        )
        .single;
    final bytes = Uint8List(216), header = ByteData.sublistView(bytes);
    void text(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, ascii.encode(value));
    text(0, 'RIFF');
    header.setUint32(4, 208, Endian.little);
    text(8, 'WAVEfmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 48000, Endian.little);
    header.setUint32(28, 96000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    text(36, 'fsid');
    header.setUint32(40, 144, Endian.little);
    text(44, session.id);
    text(80, session.storageGeneration);
    text(116, reservation.id);
    header.setUint64(164, span.ordinal, Endian.little);
    text(188, 'data');
    header.setUint32(192, 20, Endian.little);
    final directory = BackupDirectory(
      media.sessionDirectory(session.id),
      create: false,
    );
    try {
      directory.open('${reservation.id}.wav', create: true)
        ..write(bytes)
        ..sync()
        ..close();
      directory.sync();
    } finally {
      directory.close();
    }
    final chunk = await media.publish(
      RecordingChunkNotice.fromJson({
        'chunk_id': reservation.id,
        'session_id': session.id,
        'generation': session.storageGeneration,
        'source': 0,
        'sequence': 0,
        'span': span.ordinal,
        'source_sample': 0,
        'frames': 10,
        'sample_rate': 48000,
        'channels': 1,
        'capture_start_us': 0,
        'bytes': 216,
        'relative_path': '${reservation.id}.wav',
        'interrupted': false,
        'gap_before': false,
        'contents_synced': true,
        'directory_synced': true,
      }),
    );
    media.audio.closeSpan(span.id, captureEndUs: 208, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 1,
    );
    return (session: session, chunk: chunk, bytes: bytes);
  }

  void privateFile(String directory, String name, List<int> bytes) {
    final d = BackupDirectory(directory, create: false);
    try {
      d.open(name, create: true)
        ..write(bytes)
        ..close();
    } finally {
      d.close();
    }
  }

  test('future schema retires idle audio reads and new admission', () async {
    runtime = owner();
    await runtime.initialize();
    await until(() => !runtime.busy);
    store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
    try {
      expect(runtime.busy, false);
    } finally {
      store.db.execute('PRAGMA user_version=${Store.schemaVersion}');
    }
    // Restoring metadata cannot reactivate a retired service owner.
    expect(runtime.busy, false);
    await expectLater(runtime.prepareForCapture(), throwsA(isA<RpcError>()));
  });

  test(
    'shutdown cancels contended startup without opening a replacement graph',
    () async {
      final previous = RecordingMedia.open(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      addTearDown(previous.close);
      runtime = owner();
      final refused = expectLater(runtime.initialize(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await runtime.close();
      await refused;
      expect(bound, isEmpty);
      expect(
        () => RecordingMedia.open(
          store,
          ownerGeneration: AudioStore.newIdentity(),
        ),
        throwsA(isA<MediaOwnerContended>()),
      );
      previous.close();
      final replacement = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      replacement.close();
    },
  );

  test(
    'shutdown joins controlled startup recovery before releasing real media lock',
    () async {
      final initial = RecordingMedia.open(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      final session = initial.audio.createSession(
        meetingId: store.meeting('Interrupted'),
        startedWallMs: 0,
      );
      final span = initial.audio.startSpan(
        session.id,
        captureStartUs: 0,
        playbackStartUs: 0,
        wallAnchorMs: 0,
      );
      initial.preallocate(
        span: span,
        source: AudioSource.microphone,
        firstSequence: 0,
        count: 1,
      );
      initial.close();
      final entered = Completer<void>(),
          recovered = Completer<List<AudioChunk>>();
      runtime = owner(
        recover: (rows) {
          entered.complete();
          return recovered.future;
        },
      );
      addTearDown(() {
        if (!recovered.isCompleted) recovered.complete([]);
      });
      final cancelled = expectLater(
        runtime.initialize(),
        throwsA(isA<RpcError>()),
      );
      await entered.future;
      var closed = false;
      final closing = runtime.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      expect(bound, isEmpty);
      expect(
        () => RecordingMedia.open(
          store,
          ownerGeneration: AudioStore.newIdentity(),
        ),
        throwsStateError,
      );
      recovered.complete([]);
      await cancelled;
      await closing;
      // A concurrent child can briefly retain the close-on-exec lease. This
      // grants replacement only after actual kernel acquisition; the blocked
      // startup owner above must still refuse immediate synchronous admission.
      final replacement = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      replacement.close();
      expect(bound, isEmpty);
    },
  );
  test(
    'normal shutdown closes queued export leases and preserves exact recovery receipt',
    () async {
      runtime = owner();
      await runtime.initialize();
      owned = true;
      final fixture = await recording(runtime.media), caller = Object();
      final base = BackupDirectory(root.path, create: false);
      final chosen = base.child('chosen');
      base.close();
      final output = '${chosen.path}/audio.mp3';
      chosen.close();
      final grant = runtime.destinations.authorize(
        sessionId: fixture.session.id,
        callerIdentity: caller,
        workspaceEpoch: store.workspaceEpoch,
        format: MeetingAudioExportFormat.mp3,
        outputPath: output,
        overwrite: false,
        allowIncomplete: false,
        current: () => true,
      );
      final lease = runtime.destinations.consume(
        token: grant.token,
        sessionId: fixture.session.id,
        callerIdentity: caller,
        workspaceEpoch: store.workspaceEpoch,
        format: MeetingAudioExportFormat.mp3,
        overwrite: false,
        allowIncomplete: false,
        current: () => true,
      );
      final job = runtime.media.audio.createExportJob(
        sessionId: fixture.session.id,
        codec: 'mp3',
        container: 'mp3',
        settingsRevision: 'shared-assembly-v1',
        settings: lease.frozenJobSettings,
      );
      lease.bindJob(job);
      final receipt = File(
        '${runtime.media.sessionDirectory(fixture.session.id)}/${job.id}.export-publication.json',
      );
      final before = receipt.readAsStringSync();
      owned = false;
      await runtime.close();
      expect(runtime.destinations.boundLeaseCount, 0);
      expect(lease.current, false);
      expect(receipt.readAsStringSync(), before);
      expect(File(output).existsSync(), false);
      final media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      final broker = AudioExportDestinations(
        media: media,
        now: () => Duration.zero,
      );
      try {
        final claimed = media.audio.claimTransformJob(
          job.id,
          ownerGeneration: media.ownerGeneration,
          nowMs: 0,
        )!;
        final recovered = await broker.recover(
          claimed.job,
          current: () => true,
        );
        expect(recovered.hasValidatedOutput, false);
        recovered.markWorkerClosed();
        recovered.close();
        media.audio.interruptTransformJob(claimed, error: 'fixture_shutdown');
        media.audio.releaseTransformLeaseReferences(claimed);
      } finally {
        broker.close();
        media.close();
      }
    },
  );
  test(
    'committed clear followed by cleanup failure rebinds current media and permits fresh capture',
    () async {
      runtime = owner();
      await runtime.initialize();
      final oldMedia = runtime.media,
          oldGeneration = oldMedia.audio.storageGeneration,
          epoch = store.workspaceEpoch;
      final cleanup = StateError('postcommit account cleanup failed');
      await expectLater(
        runtime.clearWorkspace(() async {
          WorkspacePersistence(store).clearLocalData([]);
          throw cleanup;
        }),
        throwsA(same(cleanup)),
      );
      expect(store.workspaceEpoch, isNot(epoch));
      expect(runtime.media, same(bound.last));
      expect(bound, hasLength(2));
      expect(identical(runtime.media, oldMedia), false);
      expect(runtime.media.audio.storageGeneration, isNot(oldGeneration));
      expect(oldMedia.ensureAvailable, throwsStateError);
      runtime.media.ensureAvailable();
      await runtime.prepareForCapture();
      final fresh = await recording(runtime.media);
      expect(
        (await runtime.readMeeting(
          fresh.session.meetingId,
          current: () => true,
        )).sessions.single.id,
        fresh.session.id,
      );
    },
  );
  test(
    'delete waits for 149 files despite unrelated older unsafe erasure intents',
    () async {
      runtime = owner();
      await runtime.initialize();
      final fixture = await recording(runtime.media), session = fixture.session;
      final path = runtime.media.sessionDirectory(session.id);
      for (var i = 0; i < 148; i++) {
        privateFile(path, '$i.partial', [1]);
      }
      const oldId = '00000000-0000-4000-8000-000000000001';
      store.db.execute(
        'INSERT INTO audio_erasure_intents(session_id,generation,created) VALUES(?,?,0)',
        [oldId, session.storageGeneration],
      );
      final oldDirectory = BackupDirectory('${File(path).parent.path}/$oldId');
      oldDirectory.child('unsafe').close();
      oldDirectory.close();
      await runtime.deleteRecording(session.id, current: () => true);
      expect(Directory(path).existsSync(), false);
      expect(
        store.db.select(
          'SELECT 1 FROM audio_erasure_intents WHERE session_id=?',
          [session.id],
        ),
        isEmpty,
      );
      expect(
        store.db.select(
          'SELECT 1 FROM audio_erasure_intents WHERE session_id=?',
          [oldId],
        ),
        hasLength(1),
      );
    },
  );
  for (final action in ['delete', 'retention']) {
    test(
      'targeted $action joins but is not blocked by an unrelated failing background erasure',
      () async {
        runtime = owner();
        await runtime.initialize();
        final fixture = await recording(runtime.media),
            session = fixture.session;
        const oldId = '00000000-0000-4000-8000-000000000002';
        final path = runtime.media.sessionDirectory(session.id);
        store.db.execute(
          'INSERT INTO audio_erasure_intents(session_id,generation,created) VALUES(?,?,0)',
          [oldId, session.storageGeneration],
        );
        final older = BackupDirectory('${File(path).parent.path}/$oldId');
        older.child('unsafe').close();
        older.close();
        final entered = Completer<void>();
        runtime.erasure = AudioMediaErasure(
          media: runtime.media,
          sessionQuiesced: (id) {
            if (id == oldId && !entered.isCompleted) entered.complete();
            return true;
          },
        );
        runtime.captureStopped(session);
        await entered.future;
        if (action == 'delete') {
          await runtime.deleteRecording(session.id, current: () => true);
          expect(Directory(path).existsSync(), false);
        } else {
          await runtime.setRetainLossless(
            session.id,
            true,
            current: () => true,
          );
          expect(runtime.media.audio.retainLossless(session.id), true);
          expect(Directory(path).existsSync(), true);
        }
        expect(
          runtime.media.audio.pendingErasures().map((i) => i.sessionId),
          contains(oldId),
        );
      },
    );
  }
  test(
    'transcript seek keeps the authoritative sample instead of rounding microseconds',
    () async {
      runtime = owner();
      await runtime.initialize();
      await runtime.suspendForModelChange();
      final value = await recording(runtime.media);
      final audio = runtime.media.audio;
      final progress = audio.initializeSegmentation(
        sessionId: value.session.id,
        spanId: value.chunk.spanId,
        source: AudioSource.microphone,
        settingsRevision: 'sample-test',
        modelRevision: 'sample-model',
        initialSample: 0,
      );
      final id = AudioStore.newIdentity();
      audio.admitSegments(
        progress,
        throughSample: 10,
        retainFromSample: 10,
        ranges: [
          AudioAsrRange(
            id: id,
            sampleStart: 9,
            sampleEnd: 10,
            ownedStart: 9,
            ownedEnd: 10,
          ),
        ],
      );
      final lease = audio.claimJob(
        id,
        ownerGeneration: runtime.media.ownerGeneration,
        nowMs: 0,
      )!;
      final transcript = audio
          .commitAsrResult(lease, [
            const AudioTranscriptResult(
              text: 'Last sample',
              sampleStart: 9,
              sampleEnd: 10,
              startMs: 0,
              endMs: 1,
            ),
          ])
          .transcriptIds
          .single;
      await runtime.player.close();
      final source = ControlledSource()..exit.complete();
      runtime.player = SavedAudioPlayer(
        openSource: (_, _) async => source,
        openOutput: (_, _) async =>
            throw StateError('Paused seek must not open a device'),
        changed: () {},
      );
      // Controlled playback capability; real SQL link/timeline and runtime dispatch.
      runtime.assemblySupported = true;
      await runtime.seekTranscript(
        value.session.id,
        transcript,
        current: () => true,
      );
      expect(runtime.player.presentation.positionUs, 9 * 1000000 ~/ 48000);
      expect(
        runtime.player.presentation.state,
        MeetingAudioPlaybackState.paused,
      );
      expect(source.closing.isCompleted, true);
    },
  );

  test(
    'missing codec retains published raw and reports unsupported player and export',
    () async {
      runtime = owner();
      await runtime.initialize();
      final fixture = await recording(runtime.media);
      final path =
          '${runtime.media.sessionDirectory(fixture.session.id)}/${fixture.chunk.id}.wav';
      runtime.compression.admitPending();
      await runtime.transforms.runOne();
      final job = store.db
          .select("SELECT * FROM audio_transform_jobs WHERE kind='compression'")
          .single;
      expect(job['state'], 'blocked');
      expect(job['error'], 'audio_codec_unavailable');
      expect(File(path).readAsBytesSync(), fixture.bytes);
      expect(
        sha256.convert(File(path).readAsBytesSync()).toString(),
        fixture.chunk.sha256,
      );
      final page = await runtime.readMeeting(
            fixture.session.meetingId,
            current: () => true,
          ),
          presentation = page.sessions.single;
      expect(presentation.availability, MeetingAudioAvailability.available);
      expect(presentation.playbackSupported, false);
      expect(presentation.canPlay, false);
      expect(presentation.exportFormats, isEmpty);
      expect(presentation.canExport, false);
      expect(presentation.compression.failed, 1);
      await expectLater(
        runtime.play(fixture.session.id, current: () => true),
        throwsA(isA<RpcError>()),
      );
      await expectLater(
        runtime.authorizeExportDestination(
          sessionId: fixture.session.id,
          callerIdentity: Object(),
          workspaceEpoch: store.workspaceEpoch,
          format: MeetingAudioExportFormat.mp3,
          outputPath: '${root.path}/saved.mp3',
          overwrite: false,
          allowIncomplete: false,
          current: () => true,
        ),
        throwsA(isA<RpcError>()),
      );
    },
  );
  test(
    'unknown transform close refuses capture and retains real DB readers and profile lock',
    () async {
      runtime = owner();
      await runtime.initialize();
      final fixture = await recording(runtime.media);
      await runtime.transforms.close();
      final operation = ControlledTransform();
      addTearDown(() {
        if (!operation.execution.exit.isCompleted) {
          operation.execution.exit.complete();
        }
      });
      runtime.transforms = AudioTransformScheduler(
        store: runtime.media.audio,
        ownerGeneration: runtime.media.ownerGeneration,
        prepare: (_, _) async => operation,
        nowMs: () => 0,
        committed: (_) {},
        changed: () {},
      );
      final job = runtime.media.audio.createTransformJob(
        sessionId: fixture.session.id,
        kind: AudioTransformKind.compression,
        inputs: runtime.media.audio
            .representations(fixture.chunk.id)
            .map((r) => r.id)
            .toList(),
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'controlled-v1',
        settings: const {},
      );
      final work = runtime.transforms.runOne();
      final failedWork = expectLater(work, throwsStateError);
      await operation.started.future;
      owned = true;
      final admission = runtime.prepareForCapture();
      final refused = expectLater(admission, throwsStateError);
      await until(() => operation.execution.cancellations > 0);
      operation.execution.exit.completeError(
        StateError('Actual worker exit is unknown'),
      );
      await failedWork;
      await refused;
      expect(runtime.transforms.restartRequired, true);
      expect(
        runtime.media.audio.transformJob(job.id)!.state,
        AudioJobState.running,
      );
      expect(
        store.db.select('SELECT * FROM audio_media_references'),
        isNotEmpty,
      );
      expect(
        () => RecordingMedia.open(
          store,
          ownerGeneration: AudioStore.newIdentity(),
        ),
        throwsStateError,
      );
      owned = false;
      await expectLater(runtime.close(), throwsStateError);
      expect(
        () => RecordingMedia.open(
          store,
          ownerGeneration: AudioStore.newIdentity(),
        ),
        throwsStateError,
      );
      expect(
        store.db.select('SELECT * FROM audio_media_references'),
        isNotEmpty,
      );
      expectedCloseFailures.add(runtime);
      // Only this synthetic worker fixture has no surviving native/process owner.
      // Explicit fixture disposal is not a production unknown-exit recovery path.
      runtime.media.close();
    },
  );
  test(
    'capture admission joins transform actual exit then player source and output owners',
    () async {
      runtime = owner();
      await runtime.initialize();
      final fixture = await recording(runtime.media);
      await runtime.transforms.close();
      final operation = ControlledTransform(), source = ControlledSource();
      ControlledOutput? output;
      addTearDown(() {
        if (!operation.execution.exit.isCompleted) {
          operation.execution.exit.complete();
        }
        if (!source.exit.isCompleted) source.exit.complete();
        if (output case final sink?) {
          if (!sink.exit.isCompleted) sink.exit.complete();
        }
      });
      runtime.transforms = AudioTransformScheduler(
        store: runtime.media.audio,
        ownerGeneration: runtime.media.ownerGeneration,
        prepare: (_, _) async => operation,
        nowMs: () => 0,
        committed: (_) {},
        changed: () {},
      );
      final job = runtime.media.audio.createTransformJob(
        sessionId: fixture.session.id,
        kind: AudioTransformKind.compression,
        inputs: runtime.media.audio
            .representations(fixture.chunk.id)
            .map((r) => r.id)
            .toList(),
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'controlled-v1',
        settings: const {},
      );
      final working = runtime.transforms.runOne();
      await operation.started.future;
      await runtime.player.close();
      runtime.player = SavedAudioPlayer(
        openSource: (_, _) async => source,
        openOutput: (generation, _) async =>
            output = ControlledOutput(generation),
        changed: () {},
      );
      await runtime.player.play(fixture.session.id, current: () => true);
      owned = true;
      var admitted = false;
      final admission = runtime.prepareForCapture().then(
        (_) => admitted = true,
      );
      await until(() => operation.execution.cancellations > 0);
      expect(admitted, false);
      expect(source.closing.isCompleted, false);
      expect(
        runtime.media.audio.transformJob(job.id)!.state,
        AudioJobState.running,
      );
      expect(
        store.db.select('SELECT * FROM audio_media_references'),
        isNotEmpty,
      );
      operation.execution.exit.complete();
      await working;
      await source.closing.future;
      expect(admitted, false);
      source.exit.complete();
      output!.exit.complete();
      await admission;
      expect(admitted, true);
      expect(runtime.player.busy, false);
      expect(
        runtime.media.audio.transformJob(job.id)!.state,
        AudioJobState.retry,
      );
      expect(store.db.select('SELECT * FROM audio_media_references'), isEmpty);
      owned = false;
    },
  );
}
