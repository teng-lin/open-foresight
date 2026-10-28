import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/audio_playback_source.dart';
import 'package:foresight_core/src/application_services/audio_transform_scheduler.dart';
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_export_destinations.dart';
import 'package:foresight_core/src/persistence/audio_export_media.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/audio_transform_media.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'fixtures/durable_capture_routes.dart';
import 'sql_support_test_bootstrap.dart';

// Explicit native/codec artifacts only. All recordings are synthetic; this
// suite opens no microphone, output device, speech model or network connection.
void main() {
  bootstrapSqlSupportFixture();
  final env = Platform.environment;
  final native = env['FORESIGHT_NATIVE_LIBRARY'];
  final workerPath = env['FORESIGHT_TEST_MEDIA_WORKER'];
  final workerSha = env['FORESIGHT_TEST_MEDIA_SHA256'];
  final buildId = env['FORESIGHT_TEST_MEDIA_BUILD_ID'];
  final requiresWorker =
      native == null ||
          workerPath == null ||
          workerSha == null ||
          buildId == null ||
          (Platform.isMacOS && env['FORESIGHT_TEST_MEDIA_CDHASH'] == null)
      ? 'Requires explicit real owned native library and pinned assembly worker identities'
      : false;
  late Directory root;
  late Store store;
  late RecordingMedia media;
  late AudioSession session;
  late AudioSpan span;
  late List<AudioChunk> chunks;
  late NativeLibrary bindings;
  late AudioMediaExecutable executable;
  final sources = <NativeAudioPlaybackSource>[];
  final schedulers = <AudioTransformScheduler>[];
  final compressors = <AudioCompressionMedia>[];
  final brokers = <AudioExportDestinations>[];

  int references() =>
      store.db
              .select('SELECT COUNT(*) AS n FROM audio_media_references')
              .single['n']
          as int;

  NativeAudioPlaybackSource openSource() {
    final source = NativeAudioPlaybackSource.open(
      media: media,
      bindings: bindings,
      executable: executable,
      sessionId: session.id,
    );
    sources.add(source);
    return source;
  }

  AudioTransformScheduler scheduler(
    Future<AudioTransformOperation> Function(
      AudioTransformLease,
      bool Function(),
    )
    prepare,
  ) {
    final owner = AudioTransformScheduler(
      store: media.audio,
      ownerGeneration: media.ownerGeneration,
      prepare: prepare,
      nowMs: () => 0,
      committed: (_) {},
      changed: () {},
    );
    schedulers.add(owner);
    return owner;
  }

  setUp(() async {
    if (requiresWorker != false) return;
    sources.clear();
    schedulers.clear();
    compressors.clear();
    brokers.clear();
    final temporary = createTestTempDirectorySync('native-assembly-');
    root = Directory('${temporary.path}/private');
    privateDirectory(root.path);
    expect(root.statSync().mode & 0x1ff, 0x1c0);
    final parent = BackupDirectory(root.path, create: false);
    final profile = parent.child('profile'), chosen = parent.child('chosen');
    store = Store('${profile.path}/application.db');
    profile.close();
    chosen.close();
    parent.close();
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    media.admitNewCapture();
    addTearDown(() async {
      for (final source in sources.reversed) {
        await source.close();
      }
      for (final owner in schedulers.reversed) {
        await owner.close();
      }
      for (final compressor in compressors) {
        await compressor.fencePurges();
      }
      for (final broker in brokers) {
        broker.close();
      }
      media.close();
      store.close();
    });
    bindings = NativeLibrary(DynamicLibrary.open(native!));
    executable = AudioMediaExecutable(
      path: File(workerPath!).resolveSymbolicLinksSync(),
      sha256: workerSha!,
      buildId: buildId!,
      macosCdHash: env['FORESIGHT_TEST_MEDIA_CDHASH'] ?? '',
    );
    expect(
      sha256.convert(File(executable.path).readAsBytesSync()).toString(),
      executable.sha256,
    );
    session = media.audio.createSession(
      meetingId: store.meeting('Synthetic assembly'),
      startedWallMs: 0,
    );
    span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    CaptureRouteFixture route(AudioSource source, int count) =>
        CaptureRouteFixture(
          media,
          source,
          span.ordinal,
          0,
          media.preallocate(
            span: span,
            source: source,
            firstSequence: 0,
            count: count,
          ),
        );
    final microphone = route(AudioSource.microphone, 2);
    final playback = route(AudioSource.playback, 1);
    chunks = [
      await media.publish(microphone.audio(0)),
      await media.publish(
        microphone.audio(100000, voiced: true, marker: 10000),
      ),
      await media.publish(
        playback.audio(50000, voiced: true, marker: 6000, gap: true),
      ),
    ];
    media.audio.closeSpan(span.id, captureEndUs: 300000, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 300,
    );
    // Trusted fixture cursor authority, not an ASR/VAD acceptance claim. It
    // makes purge eligibility independent of a speech model in this codec test.
    for (final source in AudioSource.values) {
      final cursor = media.audio.initializeSegmentation(
        sessionId: session.id,
        spanId: span.id,
        source: source,
        settingsRevision: 'synthetic-cursor-v1',
        modelRevision: 'synthetic-no-asr',
        initialSample: 0,
      );
      media.audio.sealSegmentationPublications(span.id);
      final end = source == AudioSource.microphone ? 9600 : 4800;
      media.audio.admitSegments(
        cursor,
        throughSample: end,
        retainFromSample: end,
        ranges: [],
        flush: true,
      );
    }
    expect(store.db.select('SELECT 1 FROM audio_asr_jobs'), isEmpty);
  });

  Future<AudioCompressionMedia> compress() async {
    final worker = NativeAudioCompressionWorker(
      bindings: bindings,
      executable: executable,
    );
    final compression = AudioCompressionMedia(
      media: media,
      startWorker: worker.start,
    );
    compressors.add(compression);
    final owner = scheduler(compression.prepare);
    expect(compression.admitPending(), 3);
    for (var i = 0; i < 3; i++) {
      await owner.runOne();
      expect(owner.lastError, isEmpty);
    }
    final jobs = store.db.select(
      "SELECT state FROM audio_transform_jobs WHERE kind='compression'",
    );
    expect(jobs, hasLength(3));
    expect(jobs.map((r) => r['state']), everyElement('completed'));
    for (final chunk in chunks) {
      final retained = media.audio
          .usableRepresentations(chunk.id)
          .singleWhere((r) => r.codec == 'opus');
      expect(retained.decodedSamples, chunk.sampleCount);
      expect(retained.preSkip, greaterThanOrEqualTo(0));
    }
    return compression;
  }

  test(
    'real mixed playback and seek retain frozen source readers until close',
    () async {
      final source = openSource();
      expect(source.totalFrames, 14400);
      expect(references(), 3);
      final pcm = await source.decode(0, source.totalFrames);
      final expected = Int16List.fromList([
        ...List.filled(2400, 0),
        ...List.filled(2400, 3000),
        ...List.filled(2400, 8000),
        ...List.filled(2400, 5000),
        ...List.filled(4800, 0),
      ]);
      expect(pcm, orderedEquals(expected));
      expect(references(), 3);
      expect(
        await source.decode(3600, 6000),
        orderedEquals(expected.sublist(3600, 9600)),
      );
      expect(references(), 3);
      await source.close();
      expect(references(), 0);
      expect(bindings.restartRequired, isFalse);
    },
    skip: requiresWorker,
  );

  test(
    'real compression waits readers before purge and retained Opus reopens',
    () async {
      final original = openSource();
      final compression = await compress();
      expect(await compression.purgeReady(), 0);
      expect(references(), 3);
      for (final chunk in chunks) {
        expect(
          File(
            '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
          ).existsSync(),
          isTrue,
        );
      }
      await original.close();
      expect(references(), 0);
      expect(await compression.purgeReady(), 3);
      for (final chunk in chunks) {
        expect(
          File(
            '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
          ).existsSync(),
          isFalse,
        );
        expect(
          media.audio
              .representations(chunk.id)
              .singleWhere((r) => r.codec == 'pcm_s16le')
              .state,
          AudioRepresentationState.purged,
        );
      }
      final retained = openSource();
      expect(retained.totalFrames, 14400);
      final pcm = await retained.decode(0, retained.totalFrames);
      expect(pcm, hasLength(14400));
      expect(pcm.sublist(9600), everyElement(0));
      final energy =
          pcm
              .sublist(2400, 9600)
              .fold<int>(0, (sum, sample) => sum + sample.abs()) /
          7200;
      expect(energy, greaterThan(30));
      expect(references(), 3);
      await retained.close();
      expect(references(), 0);
      expect(bindings.restartRequired, isFalse);
    },
    skip: requiresWorker,
  );

  for (final format in [
    MeetingAudioExportFormat.mp3,
    MeetingAudioExportFormat.opus,
  ]) {
    test(
      'real retained-source ${format.name} export publishes and commits',
      () async {
        final compression = await compress();
        // With no playback reader, committed compression may purge directly.
        expect(await compression.purgeReady(), 0);
        for (final chunk in chunks) {
          expect(
            media.audio
                .representations(chunk.id)
                .singleWhere((r) => r.codec == 'pcm_s16le')
                .state,
            AudioRepresentationState.purged,
          );
        }
        final broker = AudioExportDestinations(
          media: media,
          now: () => Duration.zero,
        );
        brokers.add(broker);
        final caller = Object();
        final extension = format == MeetingAudioExportFormat.opus
            ? 'opus'
            : 'mp3';
        final output = '${root.path}/chosen/meeting.$extension';
        final grant = broker.authorize(
          sessionId: session.id,
          callerIdentity: caller,
          workspaceEpoch: store.workspaceEpoch,
          format: format,
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
          format: format,
          overwrite: false,
          allowIncomplete: false,
          current: () => true,
        );
        final job = media.audio.createExportJob(
          sessionId: session.id,
          codec: extension,
          container: extension == 'opus' ? 'ogg' : 'mp3',
          settingsRevision: 'shared-assembly-v1',
          settings: destination.frozenJobSettings,
        );
        destination.bindJob(job, current: () => true);
        final worker = NativeAudioAssemblyWorker(
          bindings: bindings,
          executable: executable,
        );
        final exports = AudioExportMedia(
          media: media,
          destinations: broker,
          startWorker: worker.start,
        );
        final owner = scheduler(exports.prepare);
        expect(File(output).existsSync(), isFalse);
        await owner.runOne();
        expect(owner.lastError, isEmpty);
        final completed = media.audio.transformJob(job.id)!;
        expect(
          completed.state,
          AudioJobState.completed,
          reason: completed.error,
        );
        final metadata =
            jsonDecode(completed.outputMetadata!) as Map<String, dynamic>;
        final bytes = File(output).readAsBytesSync();
        expect(bytes, isNotEmpty);
        expect(metadata['frames'], 14400);
        expect(metadata['byte_length'], bytes.length);
        expect(metadata['sha256'], sha256.convert(bytes).toString());
        expect(metadata['worker_build_id'], executable.buildId);
        expect(metadata['worker_sha256'], executable.sha256);
        if (format == MeetingAudioExportFormat.opus) {
          expect(ascii.decode(bytes.sublist(0, 4)), 'OggS');
          expect(metadata['final_granule'] - metadata['pre_skip'], 14400);
        } else {
          expect(ascii.decode(bytes, allowInvalid: true), contains('LAME'));
        }
        expect(references(), 0);
        expect(bindings.restartRequired, isFalse);
      },
      skip: requiresWorker,
    );
  }
}
