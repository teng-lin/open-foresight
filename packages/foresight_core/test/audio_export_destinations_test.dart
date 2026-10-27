import 'dart:io';
import 'dart:ffi';
import 'dart:convert';
import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/persistence/audio_export_destinations.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

final _write = DynamicLibrary.process()
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');
void writeFd(int descriptor, List<int> bytes) {
  final data = calloc<Uint8>(bytes.length);
  try {
    data.asTypedList(bytes.length).setAll(0, bytes);
    expect(_write(descriptor, data, bytes.length), bytes.length);
  } finally {
    calloc.free(data);
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late RecordingMedia media;
  late AudioExportDestinations broker;
  late AudioSession session;
  late String output, cache;
  late Object caller;
  var elapsed = Duration.zero;
  const data = 'synthetic validated codec output';
  final bytes = utf8.encode(data),
      digest = sha256.convert(utf8.encode(data)).toString();
  AudioExportDestinations owner({
    int capacity = 64,
    void Function(String)? observer,
  }) => AudioExportDestinations(
    media: media,
    now: () => elapsed,
    forbiddenRoots: [cache],
    capacity: capacity,
    publicationObserver: observer,
  );
  setUp(() {
    final temporary = createTestTempDirectorySync('export-destination-');
    root = Directory('${temporary.path}/private');
    privateDirectory(root.path);
    expect(root.statSync().mode & 0x1ff, 0x1c0);
    final directory = BackupDirectory(root.path, create: false);
    final profile = directory.child('profile');
    final destination = directory.child('chosen');
    final forbidden = directory.child('cache');
    output = '${destination.path}/audio.mp3';
    cache = forbidden.path;
    store = Store('${profile.path}/app.db');
    profile.close();
    destination.close();
    forbidden.close();
    directory.close();
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    session = media.audio.createSession(
      meetingId: store.meeting('Saved audio'),
      startedWallMs: 0,
    );
    final span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final publication = media.audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      sequence: 0,
      id: AudioStore.newIdentity(),
      relativePath:
          'recordings/${session.storageGeneration}/${session.id}/raw.wav',
    );
    media.audio.publishPreallocatedChunk(
      publication.id,
      publicationToken: publication.publicationToken,
      sampleStart: 0,
      sampleCount: 48000,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 1000000,
      byteLength: 96196,
      sha256: 'a' * 64,
    );
    media.audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 1000,
    );
    caller = Object();
    elapsed = Duration.zero;
    broker = owner();
    addTearDown(() {
      broker.close();
      media.close();
      store.close();
    });
  });
  AudioExportDestinationGrant grant({
    String? path,
    bool overwrite = false,
    bool partial = false,
  }) => broker.authorize(
    sessionId: session.id,
    callerIdentity: caller,
    workspaceEpoch: store.workspaceEpoch,
    format: MeetingAudioExportFormat.mp3,
    outputPath: path ?? output,
    overwrite: overwrite,
    allowIncomplete: partial,
    current: () => true,
  );
  AudioExportDestinationLease consume(
    String token, {
    Object? client,
    bool overwrite = false,
    bool partial = false,
  }) => broker.consume(
    token: token,
    sessionId: session.id,
    callerIdentity: client ?? caller,
    workspaceEpoch: store.workspaceEpoch,
    format: MeetingAudioExportFormat.mp3,
    overwrite: overwrite,
    allowIncomplete: partial,
    current: () => true,
  );
  AudioTransformJob bind(AudioExportDestinationLease lease) {
    final job = media.audio.createExportJob(
      sessionId: session.id,
      codec: 'mp3',
      container: 'mp3',
      settingsRevision: 'export-v1',
      settings: lease.frozenJobSettings,
    );
    lease.bindJob(job);
    final claimed = media.audio.claimTransformJob(
      job.id,
      ownerGeneration: media.ownerGeneration,
      nowMs: 0,
    )!;
    lease.fenceTo(claimed);
    return claimed.job;
  }

  Future<Map<String, Object?>> publish(
    AudioExportDestinationLease lease,
  ) async {
    writeFd(lease.outputDescriptor, bytes);
    lease.markWorkerClosed();
    return lease.publish(
      sha256: digest,
      byteLength: bytes.length,
      frames: 48000,
    );
  }

  void commit(AudioTransformJob job, Map<String, Object?> metadata) {
    media.audio.commitTransformResult(
      AudioTransformLease(job, media.ownerGeneration, job.leaseGeneration),
      outputMetadata: metadata,
    );
  }

  AudioTransformJob queue(AudioExportDestinationLease lease) {
    final job = media.audio.createExportJob(
      sessionId: session.id,
      codec: 'mp3',
      container: 'mp3',
      settingsRevision: 'export-v1',
      settings: lease.frozenJobSettings,
    );
    lease.bindJob(job);
    return job;
  }

  Map<String, dynamic> receipt(AudioTransformJob job) =>
      jsonDecode(
            File(
              '${media.sessionDirectory(session.id)}/${job.id}.export-publication.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  test(
    'queued shutdown closes bound leases while exact authorized stage recovers',
    () async {
      final lease = consume(grant().token), job = queue(lease);
      final before = receipt(job);
      final staged = File(
        '${File(output).parent.path}/${before['stage_directory']}/audio.partial',
      );
      expect(staged.existsSync(), true);
      broker.closeBoundLeases();
      expect(lease.current, false);
      expect(broker.leaseForJob(job.id), isNull);
      expect(receipt(job), before);
      expect(staged.existsSync(), true);
      broker.close();
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      broker = owner();
      final claim = media.audio.claimTransformJob(
        job.id,
        ownerGeneration: media.ownerGeneration,
        nowMs: 0,
      )!;
      final recovered = await broker.recover(claim.job, current: () => true);
      addTearDown(recovered.close);
      recovered.fenceTo(claim);
      recovered.beginWorker();
      final metadata = await publish(recovered);
      commit(claim.job, metadata);
      recovered.committed();
      expect(File(output).readAsStringSync(), data);
    },
  );
  test(
    'bound lease teardown refuses all selected leases until actual worker close',
    () {
      final queued = consume(
            grant(path: '${File(output).parent.path}/queued.mp3').token,
          ),
          queuedJob = queue(queued);
      final running = consume(grant().token), runningJob = bind(running);
      addTearDown(queued.close);
      addTearDown(running.close);
      final descriptor = running.outputDescriptor;
      final identity = BackupFile.inspectDescriptorIdentity(descriptor);
      expect(identity, isNotNull);
      writeFd(descriptor, bytes);
      expect(
        () => broker.closeBoundLeases(discardUnpublished: true),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(queued.current, true);
      expect(broker.leaseForJob(queuedJob.id), same(queued));
      expect(broker.leaseForJob(runningJob.id), same(running));
      running.markWorkerClosed();
      broker.closeBoundLeases(discardUnpublished: true);
      expect(broker.leaseForJob(queuedJob.id), isNull);
      expect(broker.leaseForJob(runningJob.id), isNull);
      expect(Directory(File(output).parent.path).listSync(), isEmpty);
      // Other isolates may already reuse a closed descriptor number. Inspect
      // its actual kernel target; never write into a possible unrelated file.
      expect(
        BackupFile.inspectDescriptorIdentity(descriptor),
        isNot(identity),
        reason: 'The original output must no longer occupy this descriptor',
      );
    },
  );
  test(
    'destructive queued cleanup filters the session and preserves original output',
    () {
      File(output).writeAsStringSync('user-owned original');
      final lease = consume(grant(overwrite: true).token, overwrite: true),
          job = queue(lease);
      broker.closeBoundLeases(
        discardUnpublished: true,
        sessionId: AudioStore.newIdentity(),
      );
      expect(broker.leaseForJob(job.id), same(lease));
      broker.closeBoundLeases(discardUnpublished: true, sessionId: session.id);
      expect(broker.leaseForJob(job.id), isNull);
      expect(File(output).readAsStringSync(), 'user-owned original');
      expect(Directory(File(output).parent.path).listSync(), hasLength(1));
      expect(receipt(job)['state'], 'cancelled');
      broker.closeBoundLeases(discardUnpublished: true);
    },
  );
  test(
    'destructive teardown preserves published output and displaced original',
    () async {
      File(output).writeAsStringSync('original');
      final lease = consume(grant(overwrite: true).token, overwrite: true),
          job = bind(lease);
      await publish(lease);
      final staged = File(
        '${File(output).parent.path}/${receipt(job)['stage_directory']}/audio.partial',
      );
      expect(staged.readAsStringSync(), 'original');
      broker.closeBoundLeases(discardUnpublished: true);
      expect(staged.readAsStringSync(), 'original');
      expect(File(output).readAsStringSync(), data);
      expect(receipt(job)['state'], 'published');
    },
  );
  test(
    'destructive teardown preserves validated uncertain exchange artifacts',
    () async {
      File(output).writeAsStringSync('original');
      broker.close();
      broker = owner(
        observer: (phase) {
          if (phase == 'after_exchange') {
            throw StateError('interrupted exchange');
          }
        },
      );
      final lease = consume(grant(overwrite: true).token, overwrite: true),
          job = bind(lease);
      await expectLater(publish(lease), throwsStateError);
      final before = receipt(job);
      final staged = File(
        '${File(output).parent.path}/${before['stage_directory']}/audio.partial',
      );
      broker.closeBoundLeases(discardUnpublished: true);
      expect(staged.readAsStringSync(), 'original');
      expect(File(output).readAsStringSync(), data);
      expect(receipt(job), before);
    },
  );
  test(
    'destructive teardown refuses a swapped staging inode and preserves it',
    () {
      final lease = consume(grant().token), job = queue(lease);
      final staged = File(
        '${File(output).parent.path}/${receipt(job)['stage_directory']}/audio.partial',
      );
      staged.renameSync('${staged.path}.original');
      final directory = BackupDirectory(staged.parent.path, create: false);
      directory.open('audio.partial', create: true)
        ..write(utf8.encode('unexpected bytes'))
        ..close();
      directory.close();
      expect(
        () => broker.closeBoundLeases(discardUnpublished: true),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(staged.readAsStringSync(), 'unexpected bytes');
      expect(File('${staged.path}.original').existsSync(), true);
      expect(broker.leaseForJob(job.id), isNull);
      expect(receipt(job)['state'], 'authorized');
    },
  );
  test(
    'unadmitted consumed destination expires and stale worker cannot publish',
    () async {
      final unused = consume(grant().token);
      elapsed = const Duration(minutes: 16);
      expect(() => bind(unused), throwsA(isA<AudioExportConflict>()));
      unused.close();
      final lease = consume(grant().token);
      addTearDown(lease.close);
      final job = bind(lease);
      writeFd(lease.outputDescriptor, bytes);
      lease.markWorkerClosed();
      media.audio.interruptTransformJob(
        AudioTransformLease(job, media.ownerGeneration, job.leaseGeneration),
        error: 'shutdown',
      );
      await expectLater(
        lease.publish(sha256: digest, byteLength: bytes.length, frames: 48000),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(File(output).existsSync(), false);
      lease.abort();
    },
  );

  test('cancel cannot discard a native output before actual exit', () {
    final lease = consume(grant().token);
    addTearDown(lease.close);
    bind(lease);
    writeFd(lease.outputDescriptor, bytes);
    expect(lease.abort, throwsA(isA<AudioExportConflict>()));
    lease.markWorkerClosed();
    lease.abort();
    expect(Directory(File(output).parent.path).listSync(), isEmpty);
  });

  test(
    'one-use grant matches actual caller and exact partial/overwrite choices',
    () {
      final g = grant(partial: true);
      expect(
        () => consume(g.token, partial: true, client: Object()),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(
        () => consume(g.token, partial: true),
        throwsA(isA<AudioExportConflict>()),
      );
      final h = grant(partial: true);
      expect(
        () => consume(h.token, partial: false),
        throwsA(isA<AudioExportConflict>()),
      );
      final valid = consume(grant().token);
      valid.close();
      expect(
        () => consume(h.token, partial: true),
        throwsA(isA<AudioExportConflict>()),
      );
    },
  );
  test('expiry, capacity and caller invalidation retire unused tokens', () {
    broker.close();
    broker = owner(capacity: 1);
    final g = grant();
    expect(() => grant(), throwsA(isA<AudioExportConflict>()));
    elapsed = const Duration(minutes: 16);
    expect(() => consume(g.token), throwsA(isA<AudioExportConflict>()));
    final h = grant();
    broker.invalidateCaller(caller);
    expect(() => consume(h.token), throwsA(isA<AudioExportConflict>()));
  });
  test(
    'profile/cache targets, symlink parents and hardlinked files are refused',
    () {
      expect(
        () => grant(path: '${store.path}.export'),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(
        () => grant(path: '$cache/audio.mp3'),
        throwsA(isA<AudioExportConflict>()),
      );
      Link('${root.path}/proxy').createSync(File(output).parent.path);
      expect(
        () => grant(path: '${root.path}/proxy/audio.mp3'),
        throwsStateError,
      );
      File(output).writeAsStringSync('old');
      final link = Process.runSync('/bin/ln', [output, '${root.path}/linked']);
      expect(link.exitCode, 0);
      expect(() => grant(overwrite: true), throwsStateError);
    },
  );
  test(
    'an appeared output and changed directory anchor fail before worker admission',
    () {
      final g = grant();
      File(output).writeAsStringSync('new user file');
      expect(() => consume(g.token), throwsA(isA<AudioExportConflict>()));
      expect(File(output).readAsStringSync(), 'new user file');
      File(output).deleteSync();
      final h = grant();
      final chosen = Directory(File(output).parent.path);
      chosen.renameSync('${chosen.path}-moved');
      Directory(chosen.path).createSync();
      expect(() => consume(h.token), throwsStateError);
    },
  );
  test(
    'frozen grant prevents rebinding another destination to an old export job',
    () {
      final first = consume(grant().token);
      final job = bind(first);
      first.markWorkerClosed();
      first.abort();
      first.close();
      final second = consume(grant().token);
      addTearDown(second.close);
      expect(() => second.bindJob(job), throwsA(isA<AudioExportConflict>()));
    },
  );
  test(
    'absent destination publishes atomically after hash and actual-exit fence',
    () async {
      final lease = consume(grant().token);
      addTearDown(lease.close);
      final job = bind(lease);
      writeFd(lease.outputDescriptor, bytes);
      await expectLater(
        lease.publish(sha256: digest, byteLength: bytes.length, frames: 48000),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(File(output).existsSync(), false);
      lease.markWorkerClosed();
      final metadata = await lease.publish(
        sha256: digest,
        byteLength: bytes.length,
        frames: 48000,
      );
      expect(metadata['validated'], true);
      expect(File(output).readAsStringSync(), data);
      commit(job, metadata);
      lease.committed();
    },
  );
  test(
    'explicit overwrite exchanges and cleans only authorized displaced file',
    () async {
      File(output).writeAsStringSync('original user content');
      final lease = consume(grant(overwrite: true).token, overwrite: true);
      addTearDown(lease.close);
      final job = bind(lease);
      final metadata = await publish(lease);
      expect(File(output).readAsStringSync(), data);
      commit(job, metadata);
      lease.committed();
      lease.committed();
      expect(Directory(File(output).parent.path).listSync(), hasLength(1));
    },
  );
  test(
    'checksum mismatch retains original and exact partial can be discarded',
    () async {
      final lease = consume(grant().token);
      addTearDown(lease.close);
      bind(lease);
      writeFd(lease.outputDescriptor, bytes);
      lease.markWorkerClosed();
      await expectLater(
        lease.publish(
          sha256: 'f' * 64,
          byteLength: bytes.length,
          frames: 48000,
        ),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(File(output).existsSync(), false);
      lease.abort();
    },
  );
  test(
    'hostile destination swap at exchange retains both unrelated originals',
    () async {
      File(output).writeAsStringSync('authorized original');
      broker.close();
      broker = owner(
        observer: (phase) {
          if (phase == 'before_exchange') {
            File(output).renameSync('$output.original');
            File(output).writeAsStringSync('unexpected replacement');
          }
        },
      );
      final lease = consume(grant(overwrite: true).token, overwrite: true);
      addTearDown(lease.close);
      bind(lease);
      await expectLater(publish(lease), throwsA(isA<AudioExportConflict>()));
      expect(File(output).readAsStringSync(), 'unexpected replacement');
      expect(
        File('$output.original').readAsStringSync(),
        'authorized original',
      );
      lease.abort();
    },
  );
  test(
    'receipt recovers rename-before-manifest crash using exact job identity',
    () async {
      File(output).writeAsStringSync('original');
      broker.close();
      broker = owner(
        observer: (phase) {
          if (phase == 'after_exchange') throw StateError('simulated crash');
        },
      );
      final lease = consume(grant(overwrite: true).token, overwrite: true);
      final job = bind(lease);
      await expectLater(publish(lease), throwsStateError);
      lease.close();
      broker.close();
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      broker = owner();
      final claimed = media.audio.claimTransformJob(
        job.id,
        ownerGeneration: media.ownerGeneration,
        nowMs: 0,
      )!;
      final recovered = await broker.recover(claimed.job, current: () => true);
      addTearDown(recovered.close);
      recovered.fenceTo(claimed);
      final recoveredMetadata = await recovered.publishValidated();
      expect(recoveredMetadata['sha256'], digest);
      commit(claimed.job, recoveredMetadata);
      expect(File(output).readAsStringSync(), data);
      recovered.committed();
    },
  );
  test('current-process recovery cannot bypass a worker exit fence', () async {
    final lease = consume(grant().token);
    addTearDown(lease.close);
    final job = bind(lease);
    writeFd(lease.outputDescriptor, bytes);
    await expectLater(
      broker.recover(job, current: () => true),
      throwsA(isA<AudioExportConflict>()),
    );
    expect(lease.current, true);
    lease.markWorkerClosed();
    lease.abort();
  });
  test(
    'authorized partial restarts under the new owner without publishing it',
    () async {
      final lease = consume(grant().token);
      final job = bind(lease);
      writeFd(lease.outputDescriptor, utf8.encode('incomplete'));
      lease.close();
      broker.close();
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      broker = owner();
      final claimed = media.audio.claimTransformJob(
        job.id,
        ownerGeneration: media.ownerGeneration,
        nowMs: 0,
      )!;
      final recovered = await broker.recover(claimed.job, current: () => true);
      addTearDown(recovered.close);
      recovered.fenceTo(claimed);
      expect(recovered.hasValidatedOutput, false);
      expect(File(output).existsSync(), false);
      recovered.beginWorker();
      await expectLater(
        broker.recover(claimed.job, current: () => true),
        throwsA(isA<AudioExportConflict>()),
      );
      final metadata = await publish(recovered);
      commit(claimed.job, metadata);
      recovered.committed();
      expect(File(output).readAsStringSync(), data);
    },
  );
  test(
    'committed receipt recovers after its staging directory was removed',
    () async {
      final lease = consume(grant().token);
      final job = bind(lease);
      final metadata = await publish(lease);
      commit(job, metadata);
      lease.committed();
      lease.close();
      broker.close();
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      broker = owner();
      final recovered = await broker.recover(
        media.audio.transformJob(job.id)!,
        current: () => true,
      );
      addTearDown(recovered.close);
      expect((await recovered.publishValidated())['sha256'], digest);
      recovered.committed();
      expect(Directory(File(output).parent.path).listSync(), hasLength(1));
    },
  );
  test(
    'source generation invalidation never resumes a saved output receipt',
    () async {
      final lease = consume(grant().token);
      final job = bind(lease);
      lease.markWorkerClosed();
      lease.close();
      media.audio.recoverLeases(AudioStore.newIdentity());
      media.audio.rotateStorageGeneration(metadataOnly: true);
      await expectLater(
        broker.recover(job, current: () => true),
        throwsA(isA<AudioExportConflict>()),
      );
      expect(File(output).existsSync(), false);
    },
  );
}
