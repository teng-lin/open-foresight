import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/application_services/audio_playback_source.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/audio_queries.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

const session = '00112233-4455-4677-8899-aabbccddeeff';
const job = '10112233-4455-4677-8899-aabbccddeeff';

void main() {
  final environment = Platform.environment;
  final native = environment['FORESIGHT_NATIVE_LIBRARY'];
  final worker = environment['FORESIGHT_TEST_MEDIA_WORKER'];
  final buildId = environment['FORESIGHT_TEST_MEDIA_BUILD_ID'];
  final cdHash = environment['FORESIGHT_TEST_MEDIA_CDHASH'] ?? '';
  final requiresWorker = native == null || worker == null || buildId == null
      ? 'Requires freshly built owned media ABI and pinned synthetic codec fixture'
      : false;
  late Directory root;
  late BackupDirectory directory;
  late BackupFile lock;
  late NativeLibrary bindings;
  late AudioMediaExecutable executable;

  setUp(() {
    final temporary = createTestTempDirectorySync('owned-media-dart-');
    root = Directory('${temporary.path}/private');
    privateDirectory(root.path);
    expect(root.statSync().mode & 0x1ff, 0x1c0);
    directory = BackupDirectory(root.path, create: false);
    addTearDown(directory.close);
    lock = directory.open('owner.lock', create: true);
    expect(lock.tryExclusiveLease(), isTrue);
    addTearDown(lock.close);
    if (requiresWorker == false) {
      bindings = NativeLibrary(DynamicLibrary.open(native!));
      executable = AudioMediaExecutable(
        path: File(worker!).resolveSymbolicLinksSync(),
        sha256: sha256.convert(File(worker).readAsBytesSync()).toString(),
        buildId: buildId!,
        macosCdHash: cdHash,
      );
    }
  });

  AudioMediaRequest request(
    AudioMediaOperation operation,
    String hash, {
    int frames = 960,
    String secondHash = '',
    int start = 0,
    int count = 0,
  }) => AudioMediaRequest(
    operation: operation,
    sessionId: session,
    jobId: job,
    epoch: 4,
    inputSha256: hash,
    sourceFrames: frames,
    secondInputSha256: secondHash,
    startFrame: start,
    frameCount: count,
  );

  test('invalid requests refuse unbounded or mismatched work', () {
    expect(
      () => request(AudioMediaOperation.encodeOpus, '0' * 64, frames: 240001),
      throwsArgumentError,
    );
    expect(
      () => request(
        AudioMediaOperation.decodePcm,
        '0' * 64,
        frames: 240000,
        count: 240001,
      ),
      throwsArgumentError,
    );
    expect(
      () => request(AudioMediaOperation.mixExportMp3, '0' * 64),
      throwsArgumentError,
    );
    expect(
      () => request(AudioMediaOperation.encodeOpus, 'unverified'),
      throwsArgumentError,
    );
    expect(
      () => AudioMediaExecutable(
        path: 'relative',
        sha256: '0' * 64,
        buildId: '0' * 64,
        macosCdHash: '',
      ),
      throwsArgumentError,
    );
  });

  test(
    'five-second decode and assembly requests retain bounded shared range',
    () {
      final decode = request(
        AudioMediaOperation.decodePcm,
        '0' * 64,
        frames: 240000,
        count: 240000,
      );
      expect(decode.frameCount, 240000);
      final assembly = request(
        AudioMediaOperation.assemblePcm,
        '0' * 64,
        frames: 48000 * 86400,
        start: 48000 * 86395,
        count: 240000,
      );
      expect(assembly.operation.index, 6);
      expect(assembly.operation.pcm, isTrue);
      expect(
        () => request(
          AudioMediaOperation.assemblePcm,
          '0' * 64,
          frames: 48000 * 86400 + 1,
          count: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => request(AudioMediaOperation.assembleMp3, '0' * 64, start: 1),
        throwsArgumentError,
      );
    },
  );

  Future<AudioMediaResult> convert({
    required AudioMediaRequest request,
    required String inputName,
    required String outputName,
    String? secondName,
    bool cancel = false,
    AudioMediaExecutable? selected,
  }) async {
    final input = directory.open(inputName, readOnly: true);
    final second = secondName == null
        ? null
        : directory.open(secondName, readOnly: true);
    final output = directory.open(outputName, create: true);
    late final NativeAudioMediaTask task;
    try {
      task = await NativeAudioMediaTask.start(
        bindings: bindings,
        executable: selected ?? executable,
        request: request,
        inputDescriptor: input.descriptor,
        secondInputDescriptor: second?.descriptor ?? -1,
        outputDescriptor: output.descriptor,
        ownerLockDescriptor: lock.descriptor,
        current: () => true,
      );
    } finally {
      // Close caller copies while native launch can still be in progress.
      input.close();
      second?.close();
      output.close();
    }
    if (cancel) task.cancel();
    try {
      return await task.result.catchError((Object error) {
        if (error is AudioMediaFailure) {
          print(
            'Synthetic codec failure: ${error.status} ${error.reason} ${error.stderr}',
          );
        }
        throw error;
      });
    } finally {
      await task.closed;
    }
  }

  test(
    'real Opus encode/decode validates bytes and releases owner',
    () async {
      final input = File('${root.path}/input.raw');
      directory.open('input.raw', create: true)
        ..write(Uint8List(960 * 2))
        ..close();
      final hash = sha256.convert(input.readAsBytesSync()).toString();
      final encoded = await convert(
        request: request(AudioMediaOperation.encodeOpus, hash),
        inputName: 'input.raw',
        outputName: 'clip.opus',
      );
      expect(encoded.frames, 960);
      expect(encoded.finalGranule, 960 + encoded.preSkip);
      final bytes = File('${root.path}/clip.opus').readAsBytesSync();
      expect(encoded.outputBytes, bytes.length);
      expect(encoded.outputSha256, sha256.convert(bytes).toString());
      final decoded = await convert(
        request: request(
          AudioMediaOperation.decodePcm,
          encoded.outputSha256,
          start: 240,
          count: 480,
        ),
        inputName: 'clip.opus',
        outputName: 'decoded.raw',
      );
      expect(decoded.frames, 480);
      expect(decoded.outputBytes, 960);
      expect(File('${root.path}/decoded.raw').lengthSync(), 960);
      expect(bindings.restartRequired, isFalse);
    },
    skip: requiresWorker,
  );

  test(
    'real mixed MP3 conversion uses both exact input capabilities',
    () async {
      final bytes = Uint8List(960 * 2);
      directory.open('first.raw', create: true)
        ..write(bytes)
        ..close();
      directory.open('second.raw', create: true)
        ..write(bytes)
        ..close();
      final hash = sha256.convert(bytes).toString();
      final result = await convert(
        request: request(
          AudioMediaOperation.mixExportMp3,
          hash,
          secondHash: hash,
        ),
        inputName: 'first.raw',
        secondName: 'second.raw',
        outputName: 'export.mp3',
      );
      expect(result.frames, 960);
      expect(result.outputBytes, greaterThan(0));
      expect(
        result.outputSha256,
        sha256
            .convert(File('${root.path}/export.mp3').readAsBytesSync())
            .toString(),
      );
      expect(bindings.restartRequired, isFalse);
    },
    skip: requiresWorker,
  );

  test(
    'cancellation joins real native ownership before closing',
    () async {
      final bytes = Uint8List(240000 * 2);
      directory.open('input.raw', create: true)
        ..write(bytes)
        ..close();
      await expectLater(
        convert(
          request: request(
            AudioMediaOperation.encodeOpus,
            sha256.convert(bytes).toString(),
            frames: 240000,
          ),
          inputName: 'input.raw',
          outputName: 'cancelled.opus',
          cancel: true,
        ),
        throwsA(
          isA<AudioMediaFailure>().having(
            (error) => error.status,
            'status',
            'cancelled',
          ),
        ),
      );
      expect(bindings.restartRequired, isFalse);
    },
    skip: requiresWorker,
  );

  test(
    'sample-exact SQL manifest retains4801 plus one frame through actual owned assembly',
    () async {
      bootstrapSqlSupportFixture();
      final store = Store('${root.path}/application.db');
      final media = RecordingMedia.open(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      NativeAudioPlaybackSource? source;
      try {
        final session = media.audio.createSession(
          meetingId: store.meeting('Exact tail'),
          startedWallMs: 0,
        );
        final clips = BackupDirectory(
          media.sessionDirectory(session.id),
          create: false,
        );
        try {
          void clip(
            AudioSpan span,
            int sequence,
            int sample,
            int frames,
            int capture,
            int value,
          ) {
            final publication = media
                .preallocate(
                  span: span,
                  source: AudioSource.microphone,
                  firstSequence: sequence,
                  count: 1,
                )
                .single;
            final bytes = Uint8List(196 + frames * 2),
                d = ByteData(196 + frames * 2);
            void text(int offset, String value) => bytes.setRange(
              offset,
              offset + value.length,
              ascii.encode(value),
            );
            d.setUint32(4, bytes.length - 8, Endian.little);
            d.setUint32(16, 16, Endian.little);
            d.setUint16(20, 1, Endian.little);
            d.setUint16(22, 1, Endian.little);
            d.setUint32(24, 48000, Endian.little);
            d.setUint32(28, 96000, Endian.little);
            d.setUint16(32, 2, Endian.little);
            d.setUint16(34, 16, Endian.little);
            d.setUint32(40, 144, Endian.little);
            d.setUint32(152, 0, Endian.little);
            d.setUint64(156, sequence, Endian.little);
            d.setUint64(164, span.ordinal, Endian.little);
            d.setUint64(172, sample, Endian.little);
            d.setUint64(180, capture, Endian.little);
            d.setUint32(192, frames * 2, Endian.little);
            for (var i = 0; i < frames; i++) {
              d.setInt16(196 + i * 2, value, Endian.little);
            }
            bytes.setAll(0, d.buffer.asUint8List());
            text(0, 'RIFF');
            text(8, 'WAVEfmt ');
            text(36, 'fsid');
            text(44, session.id);
            text(80, session.storageGeneration);
            text(116, publication.id);
            text(188, 'data');
            final file = clips.open('${publication.id}.wav', create: true);
            try {
              file.write(bytes);
              file.sync();
            } finally {
              file.close();
            }
            clips.sync();
            media.audio.publishPreallocatedChunk(
              publication.id,
              publicationToken: publication.publicationToken,
              sampleStart: sample,
              sampleCount: frames,
              sampleRate: 48000,
              channels: 1,
              captureStartUs: capture,
              captureEndUs: capture + frames * 1000000 ~/ 48000,
              byteLength: bytes.length,
              sha256: sha256.convert(bytes).toString(),
            );
          }

          final first = media.audio.startSpan(
            session.id,
            captureStartUs: 0,
            playbackStartUs: 0,
            wallAnchorMs: 0,
          );
          clip(first, 0, 0, 4801, 0, 1234);
          media.audio.closeSpan(
            first.id,
            captureEndUs: 100020,
            reason: 'pause',
          );
          final last = media.audio.startSpan(
            session.id,
            captureStartUs: 500000,
            playbackStartUs: 100020,
            wallAnchorMs: 0,
          );
          clip(last, 1, 4801, 1, 500000, 2346);
          media.audio.closeSpan(last.id, captureEndUs: 500020, reason: 'stop');
          media.audio.setCaptureState(
            session.id,
            AudioCaptureState.stopped,
            stoppedWallMs: 0,
          );
          source = NativeAudioPlaybackSource.open(
            media: media,
            bindings: bindings,
            executable: executable,
            sessionId: session.id,
          );
          expect(source.totalFrames, 4802);
          final frozen = store.db.select(
            'SELECT playback_start_frame,playback_frame_count,playback_geometry_sha256 FROM audio_transform_inputs ORDER BY position',
          );
          expect(
            frozen.map(
              (r) => (r['playback_start_frame'], r['playback_frame_count']),
            ),
            [(0, 4801), (4801, 1)],
          );
          expect(
            frozen.every(
              (r) => RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(r['playback_geometry_sha256'] as String),
            ),
            isTrue,
          );
          final pcm = await source.decode(0, 4802);
          expect(pcm.length, 4802);
          // Shared both-source selection applies the protocol's fixed half gain
          // even when playback is absent. No sample, including the tail, drops.
          expect(pcm.take(4801), everyElement(617));
          expect(pcm.last, 1173);
          expect(
            AudioQueries(
              media.audio,
            ).sessions(session.meetingId).single.durationUs,
            4802 * 1000000 ~/ 48000,
          );
          await source.close();
          source = null;
          final progress = media.audio.initializeSegmentation(
            sessionId: session.id,
            spanId: last.id,
            source: AudioSource.microphone,
            settingsRevision: 'sample-test',
            modelRevision: 'sample-model',
            initialSample: 4801,
          );
          final recognitionId = AudioStore.newIdentity();
          media.audio.admitSegments(
            progress,
            throughSample: 4802,
            retainFromSample: 4802,
            ranges: [
              AudioAsrRange(
                id: recognitionId,
                sampleStart: 4801,
                sampleEnd: 4802,
                ownedStart: 4801,
                ownedEnd: 4802,
              ),
            ],
          );
          final recognition = media.audio.claimJob(
            recognitionId,
            ownerGeneration: media.ownerGeneration,
            nowMs: 0,
          )!;
          final transcript = media.audio
              .commitAsrResult(recognition, [
                const AudioTranscriptResult(
                  text: 'Tail',
                  sampleStart: 4801,
                  sampleEnd: 4802,
                  startMs: 500,
                  endMs: 501,
                ),
              ])
              .transcriptIds
              .single;
          final target = AudioQueries(
            media.audio,
          ).transcriptSeekTarget(transcript)!;
          expect(target.playbackFrame, 4801);
          expect(target.playbackUs, 4801 * 1000000 ~/ 48000);
          expect(target.toMap()['playbackFrame'], 4801);
          expect(
            store.db
                .select('SELECT COUNT(*) AS n FROM audio_media_references')
                .single['n'],
            0,
          );
          expect(
            clips.entryExists('${media.audio.chunks(session.id).first.id}.wav'),
            isTrue,
          );
        } finally {
          clips.close();
        }
      } finally {
        await source?.close();
        media.close();
        store.close();
      }
    },
    skip: requiresWorker,
  );

  test(
    'wrong executable identity fails without poisoning known-exit cleanup',
    () async {
      final bytes = Uint8List(960 * 2);
      directory.open('input.raw', create: true)
        ..write(bytes)
        ..close();
      final wrong = AudioMediaExecutable(
        path: executable.path,
        sha256: '0' * 64,
        buildId: executable.buildId,
        macosCdHash: executable.macosCdHash,
      );
      await expectLater(
        convert(
          request: request(
            AudioMediaOperation.encodeOpus,
            sha256.convert(bytes).toString(),
          ),
          inputName: 'input.raw',
          outputName: 'rejected.opus',
          selected: wrong,
        ),
        throwsA(
          isA<AudioMediaFailure>().having(
            (error) => error.reason,
            'reason',
            'executable_digest',
          ),
        ),
      );
      expect(File('${root.path}/rejected.opus').lengthSync(), 0);
      expect(bindings.restartRequired, isFalse);
    },
    skip: requiresWorker,
  );
}
