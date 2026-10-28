import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/application_services/audio_saved_work.dart';
import 'package:foresight_core/src/application_services/audio_recognition_scheduler.dart';
import 'package:foresight_core/src/application_services/audio_speech_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/recording_capture.dart';
import 'package:foresight_core/src/recording_recovery.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

final class SavedExecution implements AudioRecognitionExecution {
  SavedExecution() {
    results.future.ignore();
    exited.future.ignore();
  }
  final results = Completer<List<AudioTranscriptResult>>();
  final exited = Completer<void>();
  @override
  Future<List<AudioTranscriptResult>> get result => results.future;
  @override
  Future<void> get closed => exited.future;
  @override
  void cancel() {
    if (!results.isCompleted) results.completeError(StateError('Cancelled'));
    if (!exited.isCompleted) exited.complete();
  }
}

final class ForkLeaseFixture {
  ForkLeaseFixture(this.process, this.lines, this.errors);
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  bool closed = false;
  static Future<ForkLeaseFixture> start(
    String executable,
    String path, {
    required bool retained,
  }) async {
    final process = await Process.start(executable, [
      path,
      retained ? 'retained' : 'cloexec',
    ]);
    final fixture = ForkLeaseFixture(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      utf8.decoder.bind(process.stderr).join(),
    );
    addTearDown(fixture.close);
    await fixture.expectLine('forked');
    return fixture;
  }

  Future<void> expectLine(String expected) async {
    expect(await lines.moveNext().timeout(const Duration(seconds: 3)), true);
    expect(lines.current, expected);
  }

  Future<void> exec({required bool retained}) async {
    process.stdin.add([69]);
    await process.stdin.flush();
    await expectLine(retained ? 'exec held alive' : 'exec closed alive');
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    process.stdin.add([81]);
    await process.stdin.close();
    try {
      expect(
        await process.exitCode.timeout(const Duration(seconds: 3)),
        0,
        reason: await errors,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      rethrow;
    } finally {
      await lines.cancel();
    }
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late RecordingMedia media;
  late AudioSession session;
  late AudioSpan span;

  late String forkFixture;
  setUpAll(() async {
    final compiled = createTestTempDirectorySync('media-fork-');
    forkFixture = '${compiled.path}/fixture';
    final build = await Process.run('cc', [
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      'test/fixtures/media_lease_fork.c',
      '-o',
      forkFixture,
    ]).timeout(const Duration(seconds: 30));
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
  });

  setUp(() {
    root = createTestTempDirectorySync('recording-media-');
    store = Store('${root.path}/application.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    media.admitNewCapture();
    session = media.audio.createSession(
      meetingId: store.meeting('Meeting'),
      startedWallMs: 123,
    );
    span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 123,
    );
    addTearDown(() {
      media.close();
      store.close();
    });
  });

  test(
    'bounded acquisition waits for CLOEXEC exec while the child remains alive',
    () async {
      media.close();
      final fixture = await ForkLeaseFixture.start(
        forkFixture,
        '${root.path}/recording-control/media-owner.lock',
        retained: false,
      );
      expect(
        () => RecordingMedia.open(
          store,
          ownerGeneration: AudioStore.newIdentity(),
        ),
        throwsA(isA<MediaOwnerContended>()),
      );
      var settled = false;
      final acquired =
          RecordingMedia.acquire(
            store,
            ownerGeneration: AudioStore.newIdentity(),
          ).then((value) {
            settled = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(settled, false);
      await fixture.exec(retained: false);
      media = await acquired;
      // No Q/exit was sent: the fixture proved its child is still alive after exec.
      expect(media.audio.storageGeneration, session.storageGeneration);
      await fixture.close();
    },
  );

  test(
    'retained worker descriptor times out without admission until actual exit',
    () async {
      media.close();
      final fixture = await ForkLeaseFixture.start(
        forkFixture,
        '${root.path}/recording-control/media-owner.lock',
        retained: true,
      );
      await fixture.exec(retained: true);
      await expectLater(
        RecordingMedia.acquire(
          store,
          ownerGeneration: AudioStore.newIdentity(),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<MediaOwnerContended>()),
      );
      expect(
        () => RecordingMedia.open(
          store,
          ownerGeneration: AudioStore.newIdentity(),
        ),
        throwsA(isA<MediaOwnerContended>()),
      );
      final acquired = RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      await fixture
          .close(); // The C supervisor waits for the actual child exit.
      media = await acquired;
    },
  );

  test(
    'acquisition cancellation closes a newly acquired owner and waiting owners',
    () async {
      media.close();
      final fixture = await ForkLeaseFixture.start(
        forkFixture,
        '${root.path}/recording-control/media-owner.lock',
        retained: true,
      );
      var current = true;
      final refused = expectLater(
        RecordingMedia.acquire(
          store,
          ownerGeneration: AudioStore.newIdentity(),
          current: () => current,
        ),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      await refused;
      await fixture.close();
      var checks = 0;
      await expectLater(
        RecordingMedia.acquire(
          store,
          ownerGeneration: AudioStore.newIdentity(),
          current: () => ++checks == 1,
        ),
        throwsStateError,
      );
      checks = 0;
      await expectLater(
        RecordingMedia.acquire(
          store,
          ownerGeneration: AudioStore.newIdentity(),
          current: () {
            if (++checks == 2) throw StateError('Caller retired');
            return true;
          },
        ),
        throwsStateError,
      );
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
    },
  );

  test('invalid owner lock fails without contention retries', () async {
    media.close();
    final lock = File('${root.path}/recording-control/media-owner.lock');
    lock.writeAsStringSync('invalid');
    var checks = 0;
    await expectLater(
      RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
        current: () {
          checks++;
          return true;
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error is MediaOwnerContended,
          'contention',
          false,
        ),
      ),
    );
    expect(checks, 1);
    lock.writeAsBytesSync([]);
    media = await RecordingMedia.acquire(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
  });

  AudioChunkPublication reserve() => media
      .preallocate(
        span: span,
        source: AudioSource.microphone,
        firstSequence: 0,
        count: 1,
      )
      .single;

  RecordingChunkNotice notice(
    AudioChunkPublication authority, {
    bool gapBefore = false,
    bool interrupted = false,
    int sourceSample = 0,
    int captureStartUs = 0,
  }) => RecordingChunkNotice.fromJson({
    'chunk_id': authority.id,
    'session_id': authority.sessionId,
    'generation': authority.storageGeneration,
    'source': authority.source.index,
    'sequence': authority.sequence,
    'span': span.ordinal,
    'source_sample': sourceSample,
    'frames': 4800,
    'sample_rate': 48000,
    'channels': 1,
    'capture_start_us': captureStartUs,
    'bytes': 9796,
    'relative_path': '${authority.id}.wav',
    'interrupted': interrupted,
    'gap_before': gapBefore,
    'contents_synced': true,
    'directory_synced': true,
  });

  Uint8List wav(RecordingChunkNotice value) {
    final bytes = Uint8List(value.byteLength);
    final data = ByteData.sublistView(bytes);
    void text(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, ascii.encode(value));
    void u16(int offset, int value) =>
        data.setUint16(offset, value, Endian.little);
    void u32(int offset, int value) =>
        data.setUint32(offset, value, Endian.little);
    void u64(int offset, int value) =>
        data.setUint64(offset, value, Endian.little);
    text(0, 'RIFF');
    u32(4, bytes.length - 8);
    text(8, 'WAVEfmt ');
    u32(16, 16);
    u16(20, 1);
    u16(22, 1);
    u32(24, 48000);
    u32(28, 96000);
    u16(32, 2);
    u16(34, 16);
    text(36, 'fsid');
    u32(40, 144);
    text(44, value.sessionId);
    text(80, value.generation);
    text(116, value.chunkId);
    u32(
      152,
      value.source.index |
          (value.gapBefore ? 0x40000000 : 0) |
          (value.interrupted ? 0x80000000 : 0),
    );
    u64(156, value.sequence);
    u64(164, value.span);
    u64(172, value.sourceSample);
    u64(180, value.captureStartUs);
    text(188, 'data');
    u32(192, value.frames * 2);
    // Deliberate silence is retained as PCM, not omitted by VAD.
    return bytes;
  }

  void writeWav(RecordingChunkNotice value, Uint8List bytes) {
    final directory = BackupDirectory(
      media.sessionDirectory(value.sessionId),
      create: false,
    );
    try {
      final file = directory.open('${value.chunkId}.wav', create: true);
      try {
        file.write(bytes);
        file.sync();
      } finally {
        file.close();
      }
      directory.sync();
    } finally {
      directory.close();
    }
  }

  Future<void> until(bool Function() condition) async {
    final deadline = Stopwatch()..start();
    while (!condition()) {
      if (deadline.elapsed > const Duration(seconds: 5)) {
        fail('saved audio work did not reach its expected fence');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  AudioSavedWork savedWork({
    AudioRecognitionExecution Function(AudioAsrLease)? start,
    void Function(AudioResultCommit)? committed,
  }) {
    final work = AudioSavedWork(
      media: media,
      bindings: NativeLibrary(DynamicLibrary.process()),
      changed: () {},
      committed: committed ?? (_) {},
      nowMs: () => 0,
      models: AudioSpeechModels(
        registration: () => null,
        createCache: (_, _, _) async =>
            throw StateError('Unexpected model admission'),
      ),
      startRecognition:
          start ?? (_) => throw StateError('Silence should not run ASR'),
    );
    addTearDown(work.close);
    return work;
  }

  test(
    'saved work freezes before capture and completes stopped silence',
    () async {
      final work = savedWork();
      expect(
        () => work.prepareSpan(
          span,
          modelRevision: 'frozen',
          sourceStarts: {AudioSource.microphone: 0},
        ),
        throwsStateError,
      );
      work.activate();
      work.prepareSpan(
        span,
        modelRevision: 'frozen',
        sourceStarts: {AudioSource.microphone: 0},
      );
      final value = notice(reserve());
      writeWav(value, wav(value));
      final chunk = await media.publish(value);
      work.published(chunk);
      media.audio.closeSpan(span.id, captureEndUs: 100000, reason: 'stop');
      work.spanSealed(media.audio.spans(session.id).single);
      work.captureStopped(session);
      await until(
        () => media.audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .flushed,
      );
      expect(media.audio.pendingJobs(nowMs: 0), isEmpty);
      expect(media.audio.chunk(chunk.id)!.state, AudioChunkState.published);
      expect(
        media.audio.representations(chunk.id).single.byteLength,
        value.byteLength,
      );
      await work.close();
    },
  );

  test(
    'capture stop leaves saved ASR running until actual worker exit',
    () async {
      final execution = SavedExecution();
      AudioAsrLease? running;
      var commits = 0;
      final work = savedWork(
        start: (lease) {
          running = lease;
          return execution;
        },
        committed: (_) => commits++,
      );
      work.activate();
      work.prepareSpan(
        span,
        modelRevision: 'frozen',
        sourceStarts: {AudioSource.microphone: 0},
      );
      final value = notice(reserve());
      final bytes = wav(value);
      final pcm = ByteData.sublistView(bytes);
      for (var offset = 196; offset < bytes.length; offset += 2) {
        pcm.setInt16(offset, 2000, Endian.little);
      }
      writeWav(value, bytes);
      work.published(await media.publish(value));
      media.audio.closeSpan(span.id, captureEndUs: 100000, reason: 'stop');
      work.spanSealed(media.audio.spans(session.id).single);
      work.captureStopped(session);
      await until(() => running != null);
      final job = running!.job;
      execution.results.complete([
        AudioTranscriptResult(
          text: 'Saved speech',
          sampleStart: job.ownedStart,
          sampleEnd: job.ownedEnd,
          startMs: 0,
          endMs: 100,
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(commits, 0);
      expect(media.audio.job(job.id)!.state, AudioJobState.running);
      expect(store.rows('SELECT 1 FROM audio_media_references'), isNotEmpty);
      execution.exited.complete();
      await until(() => commits == 1);
      expect(media.audio.job(job.id)!.state, AudioJobState.completed);
      expect(store.rows('SELECT 1 FROM audio_media_references'), isEmpty);
      await work.close();
    },
  );

  final native = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  test(
    'native recovery adopts authorized partials across distinct spans without capture',
    () async {
      final first = reserve();
      final firstNotice = notice(first);
      writeWav(firstNotice, wav(firstNotice));
      media.audio.closeSpan(span.id, captureEndUs: 100000, reason: 'pause');
      span = media.audio.startSpan(
        session.id,
        captureStartUs: 500000,
        playbackStartUs: 100000,
        wallAnchorMs: 500,
      );
      final second = media
          .preallocate(
            span: span,
            source: AudioSource.microphone,
            firstSequence: 1,
            count: 1,
          )
          .single;
      final secondNotice = notice(
        second,
        sourceSample: 4800,
        captureStartUs: 500000,
      );
      writeWav(secondNotice, wav(secondNotice));
      final directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      try {
        for (final item in [firstNotice, secondNotice]) {
          final header = Uint8List.fromList(wav(item).sublist(0, 196));
          final data = ByteData.sublistView(header);
          data.setUint32(4, 188, Endian.little);
          data.setUint32(152, item.source.index, Endian.little);
          data.setUint64(164, 0, Endian.little);
          data.setUint64(172, 0, Endian.little);
          data.setUint64(180, 0, Endian.little);
          data.setUint32(192, 0, Endian.little);
          final intent = directory.open('${item.chunkId}.intent', create: true);
          try {
            intent.write(header);
            intent.sync();
          } finally {
            intent.close();
          }
        }
        directory.publish('${first.id}.wav', '${first.id}.partial');
        directory.sync();
      } finally {
        directory.close();
      }
      final result = await RecordingRecovery.reconcileBatch(
        bindings: NativeLibrary(DynamicLibrary.open(native!)),
        media: media,
        publications: [first, second],
        current: () => true,
      );
      expect(result, hasLength(2));
      expect(result.first.id, first.id);
      expect(result.first.interrupted, isTrue);
      expect(result.last.id, second.id);
      expect(result.last.spanId, second.spanId);
      expect(result.last.sampleStart, 4800);
      expect(result.last.captureStartUs, 500000);
      expect(media.audio.pendingPublications(), isEmpty);
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${first.id}.partial',
        ).existsSync(),
        isFalse,
      );
      expect(
        (await media.readPcm(result.first, frameOffset: 0, frameCount: 4800)),
        hasLength(4800),
      );
    },
    skip: native == null
        ? 'Requires fresh native recording recovery ABI; no devices'
        : false,
  );

  test(
    'fresh binding and durable preallocation survive service reopen',
    () async {
      final reservation = reserve();
      final generation = media.audio.storageGeneration;
      media.close();
      store.close();
      store = Store('${root.path}/application.db');
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      expect(media.audio.storageGeneration, generation);
      expect(media.audio.pendingPublications().single.id, reservation.id);
      expect(media.audio.mediaAdmitted, isTrue);
    },
  );

  test('allocating a span cannot acknowledge physical capture', () {
    expect(
      media.audio.session(session.id)!.captureState,
      AudioCaptureState.starting,
    );
    media.audio.setCaptureState(session.id, AudioCaptureState.recording);
    expect(
      media.audio.session(session.id)!.captureState,
      AudioCaptureState.recording,
    );
  });

  test('PipeWire provenance does not invent a physical timing bound', () {
    media.audio.recordSourceClock(
      span.id,
      AudioSource.microphone,
      AudioSourceClockQuality.pipewireGraphTime,
      observedCaptureUs: 0,
    );
    final evidence = media.audio.latestSourceClock(
      span.id,
      AudioSource.microphone,
    )!;
    expect(evidence.quality, AudioSourceClockQuality.pipewireGraphTime);
    expect(evidence.uncertaintyUs, isNull);
  });

  test(
    'a copied database with identical generation cannot reauthorize old media',
    () async {
      reserve();
      final oldGeneration = media.audio.storageGeneration;
      media.close();
      store.close();
      final database = File('${root.path}/application.db');
      database.copySync('${root.path}/restored.db');
      File('${root.path}/restored.db').renameSync(database.path);
      store = Store(database.path);
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      expect(media.audio.storageGeneration, isNot(oldGeneration));
      expect(media.audio.mediaAdmitted, isFalse);
      expect(
        media.audio.session(session.id)!.terminalError,
        'restored_without_audio',
      );
      media.admitNewCapture();
      expect(media.audio.mediaAdmitted, isTrue);
      expect(() => media.sessionDirectory(session.id), throwsStateError);
      expect(media.audio.session(session.id)!.storageGeneration, oldGeneration);
    },
  );

  test(
    'valid native WAV publishes exact bytes and repeated notices are idempotent',
    () async {
      final value = notice(reserve());
      final bytes = wav(value);
      writeWav(value, bytes);
      final first = await media.publish(value);
      expect(first.sampleCount, 4800);
      expect(first.sha256, sha256.convert(bytes).toString());
      expect(first.byteLength, bytes.length);
      expect(media.audio.pendingPublications(), isEmpty);
      final duplicate = await media.publish(value);
      expect(duplicate.id, first.id);
      expect(media.audio.representations(first.id), hasLength(1));
    },
  );

  test('header validation binds every byte to identity, extent or format', () {
    final value = notice(reserve());
    final header = wav(value).sublist(0, 196);
    validateRecordingWavHeader(header, value);
    for (var i = 0; i < header.length; i++) {
      final changed = Uint8List.fromList(header)..[i] ^= 1;
      expect(
        () => validateRecordingWavHeader(changed, value),
        throwsFormatException,
        reason: 'header offset $i',
      );
    }
    expect(
      () => validateRecordingWavHeader(header.sublist(1), value),
      throwsFormatException,
    );
  });

  test(
    'gap and interrupted tail flags survive publication and replay',
    () async {
      final value = notice(reserve(), gapBefore: true, interrupted: true);
      writeWav(value, wav(value));
      final chunk = await media.publish(value);
      expect(chunk.gapBefore, isTrue);
      expect(chunk.interrupted, isTrue);
      expect((await media.publish(value)).gapBefore, isTrue);
    },
  );

  test(
    'changed payload cannot replace a committed immutable representation',
    () async {
      final value = notice(reserve());
      final bytes = wav(value);
      writeWav(value, bytes);
      final original = await media.publish(value);
      final path =
          '${root.path}/${media.audio.publication(value.chunkId)!.relativePath}';
      final file = File(path).openSync(mode: FileMode.writeOnlyAppend);
      try {
        file.setPositionSync(196);
        file.writeByteSync(1);
      } finally {
        file.closeSync();
      }
      await expectLater(media.publish(value), throwsStateError);
      expect(media.audio.chunk(value.chunkId)!.sha256, original.sha256);
    },
  );

  test(
    'truncated or identity-mismatched file never becomes published metadata',
    () async {
      final value = notice(reserve());
      writeWav(value, wav(value).sublist(0, 196));
      await expectLater(media.publish(value), throwsFormatException);
      expect(media.audio.chunk(value.chunkId), isNull);
      final path =
          '${root.path}/${media.audio.publication(value.chunkId)!.relativePath}';
      final file = File(path).openSync(mode: FileMode.write);
      try {
        final bytes = wav(value)..[44] ^= 1;
        file.writeFromSync(bytes);
      } finally {
        file.closeSync();
      }
      await expectLater(media.publish(value), throwsFormatException);
      expect(media.audio.chunk(value.chunkId), isNull);
    },
  );

  test('symlink and permissive media files are refused', () async {
    final value = notice(reserve());
    final path =
        '${root.path}/${media.audio.publication(value.chunkId)!.relativePath}';
    File('${root.path}/outside.wav').writeAsBytesSync(wav(value));
    Link(path).createSync('${root.path}/outside.wav');
    await expectLater(media.publish(value), throwsA(anything));
    expect(media.audio.chunk(value.chunkId), isNull);
    Link(path).deleteSync();
    File(path).writeAsBytesSync(
      wav(value),
    ); // Normal umask yields public-readable bytes.
    final chmod = await Process.run('chmod', ['0644', path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stdout}\n${chmod.stderr}');
    await expectLater(media.publish(value), throwsA(anything));
    expect(media.audio.chunk(value.chunkId), isNull);
  });

  test(
    'generation changes while validation runs fence its eventual callback',
    () async {
      final value = notice(reserve());
      writeWav(value, wav(value));
      final publication = media.publish(value);
      media.audio.rotateStorageGeneration(metadataOnly: true);
      await expectLater(publication, throwsStateError);
      expect(media.audio.chunk(value.chunkId), isNull);
    },
  );

  test('closing owner refuses subsequent allocation and admission', () {
    media.close();
    media.close();
    expect(reserve, throwsStateError);
    expect(media.admitNewCapture, throwsStateError);
  });

  test(
    'inherited worker lease blocks recovery until actual last descriptor close',
    () async {
      final libc = DynamicLibrary.process();
      final duplicate = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('dup');
      final close = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      final childLease = duplicate(media.ownerLockDescriptor);
      expect(childLease, greaterThanOrEqualTo(0));
      try {
        media.close();
        expect(
          () => RecordingMedia.open(
            store,
            ownerGeneration: AudioStore.newIdentity(),
          ),
          throwsStateError,
        );
      } finally {
        close(childLease);
      }
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      expect(media.audio.mediaAdmitted, isTrue);
    },
  );

  test('bounded PCM reads pin actual input and join before close', () async {
    final value = notice(reserve());
    final bytes = wav(value);
    final data = ByteData.sublistView(bytes);
    data.setInt16(196 + 4, -32768, Endian.little);
    data.setInt16(196 + 6, 32767, Endian.little);
    writeWav(value, bytes);
    final chunk = await media.publish(value);
    final read = media.readPcm(chunk, frameOffset: 2, frameCount: 2);
    expect(
      store.db.select('SELECT 1 FROM audio_media_references'),
      hasLength(1),
    );
    expect(media.close, throwsStateError);
    expect(await read, [-32768, 32767]);
    await media.fencePublications(sessionId: chunk.sessionId);
    expect(store.db.select('SELECT 1 FROM audio_media_references'), isEmpty);
  });

  test('corrupt reads fail without leaking deletion references', () async {
    final value = notice(reserve());
    writeWav(value, wav(value));
    final chunk = await media.publish(value);
    final file = File(
      '${root.path}/${chunk.relativePath}',
    ).openSync(mode: FileMode.write);
    try {
      file.writeFromSync(wav(value)..[196] = 1);
    } finally {
      file.closeSync();
    }
    await expectLater(
      media.readPcm(chunk, frameOffset: 0, frameCount: 1),
      throwsFormatException,
    );
    await media.fencePublications();
    expect(store.db.select('SELECT 1 FROM audio_media_references'), isEmpty);
    expect(media.audio.chunk(chunk.id)!.sha256, chunk.sha256);
  });

  test('invalid windows never acquire a reader reference', () async {
    final value = notice(reserve());
    writeWav(value, wav(value));
    final chunk = await media.publish(value);
    for (final range in [(-1, 1), (0, 0), (4799, 2), (0, 240001)]) {
      await expectLater(
        media.readPcm(chunk, frameOffset: range.$1, frameCount: range.$2),
        throwsArgumentError,
      );
    }
    expect(store.db.select('SELECT 1 FROM audio_media_references'), isEmpty);
  });
}
