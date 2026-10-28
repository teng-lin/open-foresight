import 'dart:async';

import 'package:foresight_core/src/application_services/audio_recognition_scheduler.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

class Execution implements AudioRecognitionExecution {
  final output = Completer<List<AudioTranscriptResult>>();
  final exit = Completer<void>();
  int cancellations = 0;
  bool cancelThrows = false;
  @override
  Future<List<AudioTranscriptResult>> get result => output.future;
  @override
  Future<void> get closed => exit.future;
  @override
  void cancel() {
    cancellations++;
    if (cancelThrows) throw StateError('Cancellation observer failed');
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  bootstrapSqlSupportFixture();
  late Store database;
  late AudioStore audio;
  late AudioSession session;
  late AudioSpan span;
  late AudioRecognitionScheduler scheduler;
  late Execution execution;
  final executions = <Execution>[];
  var committed = 0, changes = 0;
  var notificationThrows = false;
  var automatic = false;
  final admitted = <AudioAsrJob>[];

  List<AudioTranscriptResult> result(AudioAsrJob job) => [
    AudioTranscriptResult(
      text: 'Saved words',
      sampleStart: job.ownedStart,
      sampleEnd: job.ownedEnd,
      startMs: job.ownedStart * 1000 ~/ 48000,
      endMs: job.ownedEnd * 1000 ~/ 48000,
    ),
  ];

  setUp(() {
    final root = createTestTempDirectorySync('saved-asr-');
    database = Store('${root.path}/application.db');
    audio = AudioStore(
      database.db,
      workspaceEpoch: () => database.workspaceEpoch,
      mediaGeneration: () => database.audioStore.storageGeneration,
    );
    session = audio.createSession(
      meetingId: database.meeting('Saved meeting'),
      startedWallMs: 0,
    );
    span = audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    executions.clear();
    admitted.clear();
    committed = changes = 0;
    notificationThrows = automatic = false;
    scheduler = AudioRecognitionScheduler(
      store: audio,
      ownerGeneration: AudioStore.newIdentity(),
      nowMs: () => 0,
      start: (lease) {
        admitted.add(lease.job);
        execution = Execution();
        executions.add(execution);
        if (automatic) {
          execution.output.complete(result(lease.job));
          execution.exit.complete();
        }
        return execution;
      },
      committed: (_) {
        committed++;
        if (notificationThrows) throw StateError('Indexer unavailable');
      },
      changed: () {
        changes++;
      },
    );
    addTearDown(() async {
      for (final task in executions) {
        if (!task.output.isCompleted) task.output.complete([]);
        if (!task.exit.isCompleted) task.exit.complete();
      }
      try {
        await scheduler.close();
      } catch (_) {
        /* Expected unconfirmed fixture. */
      }
      database.close();
    });
  });

  AudioAsrJob job({AudioSource source = AudioSource.microphone}) {
    final cursor = audio.initializeSegmentation(
      sessionId: session.id,
      spanId: span.id,
      source: source,
      settingsRevision: 'vad-v1',
      modelRevision: 'frozen-model',
      initialSample: 0,
    );
    final start = cursor.cursorSample;
    final id = AudioStore.newIdentity();
    final reservation = audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: source,
      sequence: start ~/ 4800,
      relativePath:
          'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      id: id,
    );
    audio.publishPreallocatedChunk(
      id,
      publicationToken: reservation.publicationToken,
      sampleStart: start,
      sampleCount: 4800,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: start * 1000000 ~/ 48000,
      captureEndUs: (start + 4800) * 1000000 ~/ 48000,
      byteLength: 9796,
      sha256: 'a' * 64,
    );
    final jobId = AudioStore.newIdentity();
    audio.admitSegments(
      cursor,
      throughSample: start + 4800,
      retainFromSample: start + 4800,
      ranges: [
        AudioAsrRange(
          id: jobId,
          sampleStart: start,
          sampleEnd: start + 4800,
          ownedStart: start,
          ownedEnd: start + 4800,
        ),
      ],
    );
    return audio.job(jobId)!;
  }

  int refs() =>
      database.db.select('SELECT 1 FROM audio_media_references').length;

  test(
    'one serialized turn retains readers until actual worker exit',
    () async {
      final input = job();
      final run = scheduler.runOne();
      expect(scheduler.runOne(), same(run));
      await tick();
      execution.output.complete(result(input));
      await tick();
      expect(audio.job(input.id)!.state, AudioJobState.running);
      expect(refs(), 1);
      expect(committed, 0);
      execution.exit.complete();
      await run;
      expect(audio.job(input.id)!.state, AudioJobState.completed);
      expect(refs(), 0);
      expect(committed, 1);
      expect(changes, greaterThan(0));
    },
  );

  test(
    'postcommit observer failure preserves durable text and avoids replay',
    () async {
      final input = job();
      automatic = notificationThrows = true;
      await scheduler.runOne();
      await scheduler.runOne();
      expect(audio.job(input.id)!.state, AudioJobState.completed);
      expect(database.db.select('SELECT 1 FROM transcript'), hasLength(1));
      expect(committed, 1);
      expect(scheduler.notificationError, contains('needs retry'));
      expect(refs(), 0);
    },
  );

  test(
    'fair turns alternate source groups behind a long microphone backlog',
    () async {
      job();
      job();
      job();
      job(source: AudioSource.playback);
      automatic = true;
      for (var i = 0; i < 4; i++) {
        await scheduler.runOne();
      }
      expect(admitted.map((job) => job.source), [
        AudioSource.microphone,
        AudioSource.playback,
        AudioSource.microphone,
        AudioSource.microphone,
      ]);
    },
  );

  test(
    'failure waits for physical exit before bounded retry/ref release',
    () async {
      final input = job();
      final run = scheduler.runOne();
      await tick();
      execution.output.completeError(StateError('Backend crashed'));
      await tick();
      expect(refs(), 1);
      expect(audio.job(input.id)!.state, AudioJobState.running);
      execution.exit.complete();
      await run;
      expect(audio.job(input.id)!.state, AudioJobState.retry);
      expect(audio.job(input.id)!.attempts, 1);
      expect(refs(), 0);
      await scheduler.runOne(); // Backoff has not expired.
      expect(admitted, hasLength(1));
    },
  );

  test(
    'missing frozen model blocks work while retaining its raw dependencies',
    () async {
      final input = job();
      final run = scheduler.runOne();
      await tick();
      execution.output.completeError(
        const AudioRecognitionBlocked('model_unavailable'),
      );
      execution.exit.complete();
      await run;
      expect(audio.job(input.id)!.state, AudioJobState.blocked);
      expect(audio.job(input.id)!.error, 'model_unavailable');
      expect(audio.jobChunks(input.id), hasLength(1));
      expect(refs(), 0);
    },
  );

  test(
    'suspend joins cancellation before refunding claim and admitting resume',
    () async {
      final input = job();
      final run = scheduler.runOne();
      await tick();
      final stopped = scheduler.suspend();
      await tick();
      expect(execution.cancellations, 1);
      expect(refs(), 1);
      execution.output.complete(result(input));
      execution.exit.complete();
      await stopped;
      await run;
      expect(audio.job(input.id)!.state, AudioJobState.retry);
      expect(audio.job(input.id)!.attempts, 0);
      expect(committed, 0);
      expect(refs(), 0);
      await scheduler.runOne();
      expect(admitted, hasLength(1));
      scheduler.resume();
      automatic = true;
      await scheduler.runOne();
      expect(audio.job(input.id)!.state, AudioJobState.completed);
    },
  );

  test(
    'failed cancellation callback still joins the real exit fence',
    () async {
      final input = job();
      final run = scheduler.runOne();
      await tick();
      execution.cancelThrows = true;
      final stopped = scheduler.suspend();
      final assertion = expectLater(stopped, throwsStateError);
      await tick();
      expect(refs(), 1);
      execution.output.complete([]);
      execution.exit.complete();
      await assertion;
      await run;
      expect(refs(), 0);
      expect(audio.job(input.id)!.attempts, 0);
    },
  );

  test(
    'unconfirmed native exit quarantines admission and retains reader fences',
    () async {
      final input = job();
      final run = scheduler.runOne();
      await tick();
      execution.output.complete(result(input));
      execution.exit.completeError(StateError('Lost native completion'));
      await expectLater(run, throwsStateError);
      expect(scheduler.restartRequired, isTrue);
      expect(audio.job(input.id)!.state, AudioJobState.running);
      expect(refs(), 1);
      expect(committed, 0);
      await scheduler.runOne();
      expect(admitted, hasLength(1));
      expect(scheduler.resume, throwsStateError);
    },
  );

  test('suspend before first turn prevents worker creation', () async {
    job();
    final run = scheduler.runOne();
    await scheduler.suspend();
    await run;
    expect(admitted, isEmpty);
    expect(refs(), 0);
  });

  test(
    'transcript transaction failure retains retryable audio without publishing text',
    () async {
      final input = job();
      automatic = true;
      database.db.execute(
        "CREATE TRIGGER reject_asr BEFORE INSERT ON transcript BEGIN SELECT RAISE(ABORT,'injected transcript storage failure'); END",
      );
      await expectLater(scheduler.runOne(), throwsA(anything));
      expect(audio.job(input.id)!.state, AudioJobState.retry);
      expect(database.db.select('SELECT 1 FROM transcript'), isEmpty);
      expect(audio.jobChunks(input.id), hasLength(1));
      expect(committed, 0);
      expect(refs(), 0);
    },
  );
}
