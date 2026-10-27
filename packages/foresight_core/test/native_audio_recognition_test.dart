import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/application_services/audio_recognition_scheduler.dart';
import 'package:foresight_core/src/application_services/native_audio_recognition.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  final nativeLibrary = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  final needsNative = nativeLibrary == null
      ? 'Requires current native library; synthetic PCM/protocol runner, no real-model inference'
      : false;
  late Directory root;
  late Store database;
  late AudioStore audio;
  late AudioSpan span;
  late AudioAsrLease lease;
  late File runtime, model;
  late NativeLibrary bindings;
  var releases = 0;

  AudioSpeechModelLease modelLease({String revision = 'frozen-model'}) =>
      AudioSpeechModelLease(
        revision: revision,
        runtime: runtime.path,
        path: model.path,
        release: () async {
          releases++;
        },
      );

  setUp(() async {
    root = createTestTempDirectorySync('saved-native-asr-');
    database = Store('${root.path}/application.db');
    audio = AudioStore(
      database.db,
      workspaceEpoch: () => database.workspaceEpoch,
      mediaGeneration: () => database.audioStore.storageGeneration,
    );
    final session = audio.createSession(
      meetingId: database.meeting('Saved audio'),
      startedWallMs: 0,
    );
    span = audio.startSpan(
      session.id,
      captureStartUs: 1000000,
      playbackStartUs: 2000000,
      wallAnchorMs: 0,
    );
    final id = AudioStore.newIdentity();
    final publication = audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      sequence: 0,
      relativePath:
          'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      id: id,
    );
    audio.publishPreallocatedChunk(
      id,
      publicationToken: publication.publicationToken,
      sampleStart: 0,
      sampleCount: 4800,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 1200000,
      captureEndUs: 1300000,
      byteLength: 9796,
      sha256: 'a' * 64,
    );
    final cursor = audio.initializeSegmentation(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      settingsRevision: 'vad-v1',
      modelRevision: 'frozen-model',
      initialSample: 0,
    );
    final jobId = AudioStore.newIdentity();
    audio.admitSegments(
      cursor,
      throughSample: 4800,
      retainFromSample: 4800,
      ranges: [
        AudioAsrRange(
          id: jobId,
          sampleStart: 0,
          sampleEnd: 4800,
          ownedStart: 0,
          ownedEnd: 4800,
        ),
      ],
    );
    lease = audio.claimJob(
      jobId,
      ownerGeneration: AudioStore.newIdentity(),
      nowMs: 0,
    )!;
    model = File('${root.path}/model')
      ..writeAsStringSync('protocol control fixture; no real weights');
    runtime = File('${root.path}/whisper-cli')
      ..writeAsStringSync('''#!/usr/bin/env python3
import sys,wave
with wave.open(sys.argv[sys.argv.index('-f')+1],'rb') as audio:
 assert audio.getframerate()==16000 and audio.getnchannels()==1
 assert audio.getnframes()==1600 and audio.getsampwidth()==2
print('Synthetic speech')
''');
    final mode = await Process.run('/bin/chmod', ['0700', runtime.path]);
    expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
    bindings = NativeLibrary(
      nativeLibrary == null
          ? DynamicLibrary.process()
          : DynamicLibrary.open(nativeLibrary),
    );
    releases = 0;
    addTearDown(database.close);
  });

  NativeAudioRecognition task({
    AcquireSpeechModel? acquireModel,
    ReadRecordingPcm? readPcm,
    Duration executionTimeout = const Duration(seconds: 3),
  }) => NativeAudioRecognition(
    bindings: bindings,
    store: audio,
    lease: lease,
    acquireModel: acquireModel ?? (_, _) async => modelLease(),
    readPcm:
        readPcm ??
        (_, {required frameOffset, required frameCount}) async =>
            Int16List(frameCount),
    queueTimeout: const Duration(seconds: 5),
    executionTimeout: executionTimeout,
  );

  test(
    'whole-job times preserve capture offset on the compact playback span',
    () {
      expect(
        recognitionPlaybackTimes(
          lease.job,
          span,
          audio.jobChunks(lease.job.id),
        ),
        (2200, 2300),
      );
    },
  );

  test(
    'model resolution cancellation never creates a native speech owner',
    () async {
      final acquired = Completer<void>(),
          release = Completer<AudioSpeechModelLease>();
      final execution = task(
        acquireModel: (_, current) async {
          acquired.complete();
          final model = await release.future;
          expect(current(), isFalse);
          return model;
        },
      );
      await acquired.future;
      execution.cancel();
      release.complete(modelLease());
      await expectLater(execution.result, throwsA(anything));
      await execution.closed;
      expect(releases, 1);
    },
  );

  test('frozen model mismatch is blocked before native admission', () async {
    final execution = task(
      acquireModel: (_, _) async => modelLease(revision: 'other-model'),
    );
    await expectLater(
      execution.result,
      throwsA(isA<AudioRecognitionBlocked>()),
    );
    await execution.closed;
    expect(releases, 1);
  });

  test('model lease release is idempotent', () async {
    final model = modelLease();
    await model.release();
    await model.release();
    expect(releases, 1);
  });

  test(
    'actual native protocol resamples saved PCM and joins before model release',
    () async {
      final reads = <(int, int)>[];
      final execution = task(
        readPcm: (_, {required frameOffset, required frameCount}) async {
          reads.add((frameOffset, frameCount));
          return Int16List(frameCount);
        },
      );
      final results = await execution.result;
      await execution.closed;
      expect(reads, [(0, 4800)]);
      expect(results.single.text, 'Synthetic speech');
      expect((results.single.startMs, results.single.endMs), (2200, 2300));
      expect(releases, 1);
      expect(audio.commitAsrResult(lease, results).newlyCommitted, isTrue);
      expect(
        database.db
            .select('SELECT text,start_ms,end_ms FROM transcript')
            .single,
        {'text': 'Synthetic speech', 'start_ms': 2200, 'end_ms': 2300},
      );
    },
    skip: needsNative,
  );

  test(
    'failed PCM reader retires native ownership before model release',
    () async {
      final execution = task(
        readPcm: (_, {required frameOffset, required frameCount}) async {
          throw const AudioRecognitionBlocked('audio_unavailable');
        },
      );
      await expectLater(
        execution.result,
        throwsA(isA<AudioRecognitionBlocked>()),
      );
      await execution.closed;
      expect(releases, 1);
      expect(bindings.lifetime.restartRequired, isFalse);
    },
    skip: needsNative,
  );

  test(
    'execution timeout cancels and joins actual child before model release',
    () async {
      runtime.writeAsStringSync(
        '#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n',
      );
      final execution = task(
        executionTimeout: const Duration(milliseconds: 300),
      );
      final watch = Stopwatch()..start();
      await expectLater(execution.result, throwsA(isA<TimeoutException>()));
      await execution.closed;
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(releases, 1);
      expect(bindings.lifetime.restartRequired, isFalse);
    },
    skip: needsNative,
  );
}
