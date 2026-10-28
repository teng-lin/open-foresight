import 'dart:async';
import 'package:foresight_core/src/application_services/audio_transform_scheduler.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

const encoded = AudioEncodedResult(
  sha256: 'synthetic',
  byteLength: 10,
  frames: 4800,
  preSkip: 312,
  finalGranule: 5112,
  workerBuildId: 'synthetic',
  workerSha256: 'synthetic',
);

class Execution implements AudioTransformExecution {
  Execution() {
    output.future.ignore();
    exit.future.ignore();
  }
  final output = Completer<AudioEncodedResult>(), exit = Completer<void>();
  int cancellations = 0;
  bool cancelThrows = false;
  @override
  Future<AudioEncodedResult> get result => output.future;
  @override
  Future<void> get closed => exit.future;
  @override
  void cancel() {
    cancellations++;
    if (cancelThrows) throw StateError('Control failed');
  }
}

class Operation implements AudioTransformOperation {
  Operation(this.output);
  final AudioTransformOutput output;
  final execution = Execution();
  bool validated = false, closed = false;
  bool cleanupThrows = false;
  int published = 0, cleaned = 0, reset = 0, aborted = 0, starts = 0;
  Future<AudioTransformExecution> Function()? delayedStart;
  @override
  bool get hasValidatedOutput => validated;
  @override
  Future<AudioTransformExecution> start() async {
    starts++;
    return delayedStart == null ? execution : await delayedStart!();
  }

  @override
  void markWorkerClosed() {}
  @override
  Future<AudioTransformOutput> publish(AudioEncodedResult? value) async {
    validated = true;
    published++;
    return output;
  }

  @override
  void committed() {
    cleaned++;
    if (cleanupThrows) throw StateError('Cleanup retry needed');
  }

  @override
  void resetForRetry() {
    reset++;
  }

  @override
  void abort() {
    aborted++;
  }

  @override
  void close() {
    closed = true;
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  bootstrapSqlSupportFixture();
  late Store database;
  late AudioStore store;
  late AudioTransformJob job;
  late AudioTransformScheduler scheduler;
  late Operation operation;
  var now = 0, notifications = 0;
  Future<AudioTransformOperation> Function(
    AudioTransformLease,
    bool Function(),
  )?
  preparation;
  setUp(() {
    final root = createTestTempDirectorySync('transform-owner-');
    database = Store('${root.path}/application.db');
    store = AudioStore(
      database.db,
      workspaceEpoch: () => database.workspaceEpoch,
      mediaGeneration: () => database.audioStore.storageGeneration,
    );
    final session = store.createSession(
      meetingId: database.meeting('Meeting'),
      startedWallMs: 0,
    );
    final span = store.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final raw = store.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      sequence: 0,
      id: AudioStore.newIdentity(),
      relativePath: 'raw.wav',
    );
    store.publishPreallocatedChunk(
      raw.id,
      publicationToken: raw.publicationToken,
      sampleStart: 0,
      sampleCount: 4800,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 100000,
      byteLength: 9796,
      sha256: 'a' * 64,
    );
    job = store.createTransformJob(
      sessionId: session.id,
      kind: AudioTransformKind.compression,
      inputs: store.representations(raw.id).map((r) => r.id).toList(),
      codec: 'opus',
      container: 'ogg',
      settingsRevision: 'test-v1',
      settings: const {},
    );
    operation = Operation(
      AudioTransformOutput(
        representation: AudioRepresentation(
          id: '${job.id}.opus',
          chunkId: raw.id,
          codec: 'opus',
          container: 'ogg',
          settingsRevision: 'test-v1',
          relativePath: 'retained.opus',
          byteLength: 10,
          sha256: 'b' * 64,
          decodedSamples: 4800,
          state: AudioRepresentationState.published,
          validated: true,
        ),
        metadata: const {},
      ),
    );
    now = notifications = 0;
    preparation = null;
    scheduler = AudioTransformScheduler(
      store: store,
      ownerGeneration: AudioStore.newIdentity(),
      prepare: (lease, current) =>
          preparation?.call(lease, current) ?? Future.value(operation),
      nowMs: () => now,
      committed: (_) {
        notifications++;
      },
      changed: () {},
    );
    addTearDown(() async {
      if (!operation.execution.output.isCompleted) {
        operation.execution.output.complete(encoded);
      }
      if (!operation.execution.exit.isCompleted) {
        operation.execution.exit.complete();
      }
      try {
        await scheduler.close();
      } catch (_) {
        /* Unconfirmed fixture. */
      }
      database.close();
    });
  });
  int references() =>
      database.db
              .select('SELECT COUNT(*) AS n FROM audio_media_references')
              .single['n']
          as int;
  Future<void> started() async {
    while (operation.starts == 0) {
      await tick();
    }
  }

  test(
    'result alone retains inputs; actual closed permits durable publication',
    () async {
      final work = scheduler.runOne();
      await started();
      operation.execution.output.complete(encoded);
      await tick();
      expect(references(), 1);
      expect(operation.published, 0);
      operation.execution.exit.complete();
      await work;
      expect(store.transformJob(job.id)!.state, AudioJobState.completed);
      expect(references(), 0);
      expect(operation.cleaned, 1);
      expect(notifications, 1);
      await scheduler.runOne();
      expect(operation.starts, 1);
    },
  );
  test(
    'suspend through async prepare refunds claim without starting a worker',
    () async {
      final ready = Completer<AudioTransformOperation>();
      preparation = (_, current) => ready.future;
      final work = scheduler.runOne();
      await tick();
      expect(references(), 1);
      final stopping = scheduler.suspend();
      await tick();
      expect(references(), 1);
      ready.complete(operation);
      await work;
      await stopping;
      expect(operation.starts, 0);
      expect(operation.reset, 1);
      expect(store.transformJob(job.id)!.attempts, 0);
      expect(store.transformJob(job.id)!.state, AudioJobState.retry);
      expect(references(), 0);
    },
  );
  test(
    'suspend during start settlement cancels returned owner and awaits exit',
    () async {
      final ready = Completer<AudioTransformExecution>();
      operation.delayedStart = () => ready.future;
      final work = scheduler.runOne();
      await started();
      final stopping = scheduler.suspend();
      await tick();
      ready.complete(operation.execution);
      await tick();
      expect(operation.execution.cancellations, 1);
      expect(references(), 1);
      operation.execution.output.completeError(StateError('cancelled'));
      await tick();
      expect(references(), 1);
      operation.execution.exit.complete();
      await work;
      await stopping;
      expect(store.transformJob(job.id)!.attempts, 0);
      expect(references(), 0);
    },
  );
  test(
    'worker failure backs off and explicit cancellation waits then abandons',
    () async {
      final work = scheduler.runOne();
      await started();
      operation.execution.output.completeError(StateError('codec'));
      operation.execution.exit.complete();
      await work;
      expect(store.transformJob(job.id)!.state, AudioJobState.retry);
      expect(operation.reset, 1);
      expect(references(), 0);
      expect(store.nextPendingTransformJob(nowMs: 0), isNull);
      await scheduler.cancel(job.id);
      expect(store.transformJob(job.id)!.state, AudioJobState.abandoned);
    },
  );
  test(
    'explicit running cancellation waits for exit before abandoning inputs',
    () async {
      final work = scheduler.runOne();
      await started();
      final cancelled = scheduler.cancel(job.id);
      await tick();
      expect(references(), 1);
      expect(operation.aborted, 0);
      operation.execution.output.completeError(StateError('cancelled'));
      operation.execution.exit.complete();
      await work;
      await cancelled;
      expect(operation.aborted, 1);
      expect(references(), 0);
      expect(store.transformJob(job.id)!.state, AudioJobState.abandoned);
    },
  );
  test('unconfirmed retirement retains operation and DB references', () async {
    final work = scheduler.runOne();
    await started();
    operation.execution.output.complete(encoded);
    operation.execution.exit.completeError(StateError('not retired'));
    await expectLater(work, throwsStateError);
    expect(scheduler.restartRequired, true);
    expect(operation.closed, false);
    expect(references(), 1);
    expect(store.transformJob(job.id)!.state, AudioJobState.running);
    await scheduler.runOne();
    expect(operation.starts, 1);
  });
  test('failed cancel control still waits for actual retirement', () async {
    final work = scheduler.runOne();
    await started();
    operation.execution.cancelThrows = true;
    final cancelled = scheduler.cancel(job.id);
    final expectation = expectLater(cancelled, throwsStateError);
    await tick();
    expect(references(), 1);
    operation.execution.output.completeError(StateError('cancelled'));
    operation.execution.exit.complete();
    await work;
    await expectation;
    expect(references(), 0);
    expect(operation.aborted, 1);
  });
  test('manifest failure keeps validated output for receipt retry', () async {
    database.db.execute(
      "CREATE TEMP TRIGGER refuse_audio_commit BEFORE UPDATE OF state ON audio_transform_jobs WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'simulated disk commit failure'); END",
    );
    final work = scheduler.runOne();
    await started();
    operation.execution.output.complete(encoded);
    operation.execution.exit.complete();
    await work;
    expect(store.transformJob(job.id)!.state, AudioJobState.retry);
    expect(operation.validated, true);
    expect(operation.reset, 0);
    expect(references(), 0);
    database.db.execute('DROP TRIGGER refuse_audio_commit');
    operation.closed = false;
    now = 100000;
    await scheduler.runOne();
    expect(operation.starts, 1);
    expect(store.transformJob(job.id)!.state, AudioJobState.completed);
  });
  test('postcommit observers cannot convert saved output to retry', () async {
    await scheduler.close();
    scheduler = AudioTransformScheduler(
      store: store,
      ownerGeneration: AudioStore.newIdentity(),
      prepare: (_, current) async => operation,
      nowMs: () => 0,
      committed: (_) => throw StateError('observer'),
      changed: () => throw StateError('view'),
    );
    final work = scheduler.runOne();
    await started();
    operation.execution.output.complete(encoded);
    operation.execution.exit.complete();
    await work;
    expect(store.transformJob(job.id)!.state, AudioJobState.completed);
    expect(scheduler.notificationError, isNotEmpty);
    expect(references(), 0);
  });
  test(
    'unsupported frozen codec settings block before worker admission',
    () async {
      preparation = (_, current) async =>
          throw const AudioTransformBlocked('codec_unavailable');
      await scheduler.runOne();
      expect(store.transformJob(job.id)!.state, AudioJobState.blocked);
      expect(store.transformJob(job.id)!.error, 'codec_unavailable');
      expect(operation.starts, 0);
      expect(references(), 0);
    },
  );
  test(
    'suspended owner resumes durable work and closed owner refuses resume',
    () async {
      await scheduler.suspend();
      expect(scheduler.suspended, true);
      expect(scheduler.busy, false);
      await scheduler.runOne();
      expect(operation.starts, 0);
      scheduler.resume();
      expect(scheduler.suspended, false);
      final work = scheduler.runOne();
      await started();
      expect(scheduler.busy, true);
      expect(scheduler.runningJobId, job.id);
      operation.execution.output.complete(encoded);
      operation.execution.exit.complete();
      await work;
      expect(scheduler.runningJobId, '');
      await scheduler.close();
      expect(scheduler.resume, throwsStateError);
    },
  );
  test(
    'postcommit cleanup failure retains completed job rather than reencoding',
    () async {
      operation.cleanupThrows = true;
      final work = scheduler.runOne();
      await started();
      operation.execution.output.complete(encoded);
      operation.execution.exit.complete();
      await work;
      expect(store.transformJob(job.id)!.state, AudioJobState.completed);
      expect(scheduler.notificationError, 'Saved audio cleanup needs retry');
      await scheduler.runOne();
      expect(operation.starts, 1);
      expect(references(), 0);
    },
  );
}
