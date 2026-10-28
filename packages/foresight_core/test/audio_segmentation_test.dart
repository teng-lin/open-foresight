import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_segmentation.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late AudioStore audio;
  late AudioSession session;
  late AudioSpan span;
  late AudioSegmentationOwner owner;
  late PublishedPcmWindowReader reader;
  late Map<String, Int16List> media;
  late String path;
  var largestRead = 0;
  const digest =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  AudioStore bind() => AudioStore(
    store.db,
    workspaceEpoch: () => store.workspaceEpoch,
    mediaGeneration: () => store.audioStore.storageGeneration,
  );
  AudioSegmentationOwner newOwner() => AudioSegmentationOwner(
    store: audio,
    ownerGeneration: AudioStore.newIdentity(),
    readPcm: (chunk, {required frameOffset, required frameCount}) =>
        reader(chunk, frameOffset: frameOffset, frameCount: frameCount),
  );
  Future<Int16List> readMedia(
    AudioChunk chunk, {
    required int frameOffset,
    required int frameCount,
  }) async {
    expect(frameCount, lessThanOrEqualTo(4800));
    expect(
      store.rows(
        'SELECT 1 FROM audio_media_references WHERE representation_id=?',
        ['${chunk.id}.raw'],
      ),
      isNotEmpty,
    );
    if (frameCount > largestRead) largestRead = frameCount;
    return Int16List.fromList(
      media[chunk.id]!.sublist(frameOffset, frameOffset + frameCount),
    );
  }

  setUp(() {
    root = createTestTempDirectorySync('audio-segment-');
    path = '${root.path}/application.db';
    store = Store(path);
    audio = bind();
    media = {};
    largestRead = 0;
    session = audio.createSession(
      meetingId: store.meeting('Meeting'),
      startedWallMs: 123,
    );
    span = audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 123,
    );
    reader = readMedia;
    owner = newOwner();
    addTearDown(() => store.close());
  });
  Int16List samples(int count, int value) =>
      Int16List(count)..fillRange(0, count, value);
  List<AudioChunk> capture(
    Int16List pcm, {
    AudioSource source = AudioSource.microphone,
    int initialSample = 0,
    int firstSequence = 0,
    int captureBaseUs = 0,
    bool gapBefore = false,
    int chunkFrames = 240000,
  }) {
    final chunks = <AudioChunk>[];
    for (var offset = 0; offset < pcm.length; offset += chunkFrames) {
      final count = (pcm.length - offset).clamp(0, chunkFrames);
      final id = AudioStore.newIdentity();
      final publication = audio.preallocateChunk(
        sessionId: session.id,
        spanId: span.id,
        source: source,
        sequence: firstSequence + offset ~/ chunkFrames,
        id: id,
        relativePath:
            'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      );
      final chunk = audio.publishPreallocatedChunk(
        id,
        publicationToken: publication.publicationToken,
        sampleStart: initialSample + offset,
        sampleCount: count,
        sampleRate: 48000,
        channels: 1,
        captureStartUs: captureBaseUs + offset * 1000000 ~/ 48000,
        captureEndUs: captureBaseUs + (offset + count) * 1000000 ~/ 48000,
        byteLength: count * 2 + 196,
        sha256: digest,
        gapBefore: gapBefore && offset == 0,
      );
      media[id] = Int16List.fromList(pcm.sublist(offset, offset + count));
      chunks.add(chunk);
    }
    return chunks;
  }

  Future<AudioSegmentationPass> pass({
    bool sealed = false,
    int maxWindows = 20,
    AudioSource source = AudioSource.microphone,
    AudioSegmentationSettings? settings,
  }) => owner.advance(
    sessionId: session.id,
    spanId: span.id,
    source: source,
    modelRevision: 'model-sha256',
    sourceSealed: sealed,
    maxWindows: maxWindows,
    settings: settings,
  );
  Future<List<AudioAsrJob>> drain({
    required int captureEndUs,
    AudioSource source = AudioSource.microphone,
    AudioSegmentationSettings? settings,
  }) async {
    audio.closeSpan(span.id, captureEndUs: captureEndUs, reason: 'stop');
    for (var i = 0; i < 100; i++) {
      if ((await pass(
        sealed: true,
        source: source,
        settings: settings,
      )).flushed) {
        break;
      }
    }
    expect(audio.segmentation(session.id, source, span.id)!.flushed, isTrue);
    return audio
        .pendingJobs(nowMs: 0)
        .where((job) => job.source == source)
        .toList()
      ..sort((a, b) => a.ownedStart.compareTo(b.ownedStart));
  }

  test('capture preparation freezes settings without audio I/O', () async {
    var reads = 0;
    reader = (chunk, {required frameOffset, required frameCount}) async {
      reads++;
      throw StateError('capture preparation must not read audio');
    };
    final cursor = owner.prepare(
      span: span,
      source: AudioSource.microphone,
      modelRevision: 'frozen-model',
      initialSample: 0,
    );
    expect(cursor.modelRevision, 'frozen-model');
    expect(cursor.cursorSample, 0);
    expect(
      AudioSegmentationSettings.fromCursor(cursor).revision,
      const AudioSegmentationSettings().revision,
    );
    expect(reads, 0);
    store.close();
    store = Store(path);
    audio = bind();
    expect(
      AudioSegmentationSettings.fromCursor(
        audio.segmentation(session.id, AudioSource.microphone, span.id)!,
      ).revision,
      const AudioSegmentationSettings().revision,
    );
    expect(
      () => newOwner().prepare(
        span: span,
        source: AudioSource.microphone,
        modelRevision: 'other-model',
        initialSample: 0,
      ),
      throwsStateError,
    );
  });

  test(
    'closed span cannot flush before durable final-publication fence',
    () async {
      owner.prepare(
        span: span,
        source: AudioSource.microphone,
        modelRevision: 'model-sha256',
        initialSample: 0,
      );
      expect(
        () => audio.sealSegmentationPublications(span.id),
        throwsStateError,
      );
      audio.closeSpan(span.id, captureEndUs: 0, reason: 'stop');
      expect(audio.nextSegmentation(), isNull);
      audio.sealSegmentationPublications(span.id);
      store.close();
      store = Store(path);
      audio = bind();
      owner = newOwner();
      final cursor = audio.nextSegmentation()!;
      expect(cursor.publicationSealed, isTrue);
      expect(cursor.flushed, isFalse);
      final result = await pass(sealed: cursor.publicationSealed);
      expect(result.flushed, isTrue);
      expect(audio.nextSegmentation(), isNull);
      expect(audio.pendingJobs(nowMs: 0), isEmpty);
    },
  );

  test(
    'segmentation selection rotates sources and refuses restored metadata',
    () {
      for (final source in AudioSource.values) {
        owner.prepare(
          span: span,
          source: source,
          modelRevision: 'model-sha256',
          initialSample: 0,
        );
      }
      audio.closeSpan(span.id, captureEndUs: 0, reason: 'stop');
      audio.sealSegmentationPublications(span.id);
      final first = audio.nextSegmentation()!;
      final second = audio.nextSegmentation(
        afterSpanId: first.spanId,
        afterSource: first.source,
      )!;
      expect(second.source, isNot(first.source));
      final third = audio.nextSegmentation(
        afterSpanId: second.spanId,
        afterSource: second.source,
      )!;
      expect(third.source, first.source);
      expect(store.audioStore.nextSegmentation(), isNull);
      audio.rotateStorageGeneration(metadataOnly: true);
      expect(audio.nextSegmentation(), isNull);
    },
  );

  test(
    'silence advances durable cursor without transcript jobs in bounded windows',
    () async {
      capture(samples(144000, 0));
      final first = await pass();
      expect(first.processedFrames, 96000);
      final progress = audio.segmentation(
        session.id,
        AudioSource.microphone,
        span.id,
      )!;
      expect(progress.cursorSample, 96000);
      expect(progress.retainFromSample, 91200);
      expect(progress.context.length, lessThan(4096));
      expect(await drain(captureEndUs: 3000000), isEmpty);
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
      expect(largestRead, 4800);
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
    },
  );

  test(
    'RMS threshold preserves quiet audio and admits voiced preroll with one-second tail',
    () async {
      final pcm = samples(62400, 0);
      pcm.fillRange(0, 4800, 98);
      pcm.fillRange(4800, 14400, 99);
      capture(pcm);
      final jobs = await drain(captureEndUs: 1300000);
      expect(jobs, hasLength(1));
      expect(jobs.single.ownedStart, 0);
      expect(jobs.single.ownedEnd, 62400);
      expect(jobs.single.sampleStart, jobs.single.ownedStart);
      expect(jobs.single.sampleEnd, jobs.single.ownedEnd);
    },
  );

  test(
    'long voiced capture has <=20-second nonoverlapping ownership with no missing frames',
    () async {
      capture(samples(2160000, 1200));
      final jobs = await drain(captureEndUs: 45000000);
      expect(jobs.length, greaterThanOrEqualTo(3));
      var through = 0;
      for (final job in jobs) {
        expect(job.ownedStart, through);
        expect(job.sampleStart, job.ownedStart);
        expect(job.ownedEnd - job.ownedStart, lessThanOrEqualTo(960000));
        through = job.ownedEnd;
      }
      expect(through, 2160000);
      expect(largestRead, lessThanOrEqualTo(4800));
      final before = jobs.map((j) => j.id).toList();
      expect((await pass(sealed: true)).admittedJobIds, isEmpty);
      expect(
        audio.pendingJobs(nowMs: 0).map((j) => j.id).toSet(),
        before.toSet(),
      );
    },
  );

  test(
    'publication fence gates final partial-window flush even after span close',
    () async {
      capture(samples(2401, 1000));
      audio.closeSpan(span.id, captureEndUs: 50021, reason: 'stop');
      final waiting = await pass();
      expect(waiting.waitingForPublication, isTrue);
      expect(waiting.processedFrames, 0);
      expect(waiting.flushed, isFalse);
      expect(audio.pendingJobs(nowMs: 0), isEmpty);
      final finalPass = await pass(sealed: true);
      expect(finalPass.flushed, isTrue);
      expect(audio.pendingJobs(nowMs: 0).single.ownedEnd, 2401);
    },
  );

  test(
    'restart resumes open segment with the original frozen settings and bounded context',
    () async {
      capture(samples(240000, 1200));
      await pass(settings: const AudioSegmentationSettings(rmsThreshold: .01));
      final before = audio.segmentation(
        session.id,
        AudioSource.microphone,
        span.id,
      )!;
      expect(before.cursorSample, 96000);
      expect(before.retainFromSample, 0);
      store.close();
      store = Store(path);
      audio = bind();
      owner = newOwner();
      final recovered = AudioSegmentationSettings.fromCursor(before);
      expect(recovered.rmsThreshold, .01);
      expect(await drain(captureEndUs: 5000000), hasLength(1));
      expect(audio.pendingJobs(nowMs: 0).single.ownedEnd, 240000);
    },
  );

  test(
    'first read failure retains recoverable settings without moving the cursor or leaking readers',
    () async {
      capture(samples(48000, 1200));
      reader = (chunk, {required frameOffset, required frameCount}) async =>
          throw StateError('fixture read failure');
      await expectLater(
        pass(settings: const AudioSegmentationSettings(rmsThreshold: .02)),
        throwsStateError,
      );
      final cursor = audio.segmentation(
        session.id,
        AudioSource.microphone,
        span.id,
      )!;
      expect(cursor.cursorSample, 0);
      expect(AudioSegmentationSettings.fromCursor(cursor).rmsThreshold, .02);
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
      reader = readMedia;
      expect(await drain(captureEndUs: 1000000), hasLength(1));
    },
  );

  test(
    'failed cursor/job transaction retries committed files without duplicate text jobs',
    () async {
      capture(samples(72000, 1000));
      audio.closeSpan(span.id, captureEndUs: 1500000, reason: 'stop');
      store.db.execute(
        "CREATE TRIGGER fail_segment BEFORE INSERT ON audio_asr_job_chunks BEGIN SELECT RAISE(ABORT,'fixture segmentation commit'); END",
      );
      await expectLater(pass(sealed: true), throwsA(isA<SqliteException>()));
      expect(audio.pendingJobs(nowMs: 0), isEmpty);
      expect(
        audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .cursorSample,
        0,
      );
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
      store.db.execute('DROP TRIGGER fail_segment');
      expect((await pass(sealed: true)).admittedJobIds, hasLength(1));
      expect((await pass(sealed: true)).admittedJobIds, isEmpty);
    },
  );

  test(
    'media erasure waits until the actual asynchronous PCM read exits',
    () async {
      capture(samples(48000, 1000));
      final entered = Completer<void>(), release = Completer<void>();
      reader = (chunk, {required frameOffset, required frameCount}) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return readMedia(
          chunk,
          frameOffset: frameOffset,
          frameCount: frameCount,
        );
      };
      final active = pass(maxWindows: 1);
      await entered.future;
      expect(
        () => audio.tombstoneSession(session.id),
        throwsA(isA<SqliteException>()),
      );
      release.complete();
      await active;
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
      audio.tombstoneSession(session.id);
      expect(audio.session(session.id), isNull);
    },
  );

  test(
    'concurrent cursor owners cannot double-admit the same final range',
    () async {
      capture(samples(48000, 1000));
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      final both = Completer<void>();
      var entrants = 0;
      reader = (chunk, {required frameOffset, required frameCount}) async {
        if (frameOffset == 0) {
          entrants++;
          if (entrants == 2) both.complete();
          await both.future;
        }
        return readMedia(
          chunk,
          frameOffset: frameOffset,
          frameCount: frameCount,
        );
      };
      final other = newOwner();
      final results = await Future.wait([
        pass(sealed: true).then<Object>((v) => v, onError: (Object e) => e),
        other
            .advance(
              sessionId: session.id,
              spanId: span.id,
              source: AudioSource.microphone,
              modelRevision: 'model-sha256',
              sourceSealed: true,
            )
            .then<Object>((v) => v, onError: (Object e) => e),
      ]);
      expect(results.whereType<AudioSegmentationPass>(), hasLength(1));
      expect(results.whereType<StateError>(), hasLength(1));
      expect(audio.pendingJobs(nowMs: 0), hasLength(1));
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
    },
  );

  test(
    'explicit acquired-time gap splits contiguous samples and forbids cross-gap overlap',
    () async {
      capture(samples(40800, 1000));
      capture(
        samples(40800, 1000),
        initialSample: 40800,
        firstSequence: 1,
        captureBaseUs: 2850000,
        gapBefore: true,
      );
      final jobs = await drain(
        captureEndUs: 3700000,
        settings: const AudioSegmentationSettings(
          overlapSamples: 12000,
          supportsOwnedRangeCropping: true,
        ),
      );
      expect(jobs, hasLength(2));
      expect(jobs.first.ownedEnd, 40800);
      expect(jobs.last.ownedStart, 40800);
      expect(jobs.last.sampleStart, 40800);
      expect(jobs.last.ownedEnd, 81600);
      expect(audio.spans(session.id).single.playbackEndUs, 3700000);
    },
  );

  test(
    'unflagged acquisition jump beyond actual measured uncertainty blocks joining',
    () async {
      audio.recordSourceClock(
        span.id,
        AudioSource.microphone,
        AudioSourceClockQuality.hardwareHostTime,
        observedCaptureUs: 0,
        uncertaintyUs: 10,
      );
      capture(samples(48000, 1000));
      capture(
        samples(48000, 1000),
        initialSample: 48000,
        firstSequence: 1,
        captureBaseUs: 3000000,
      );
      final blocked = await pass();
      expect(blocked.blockedReason, contains('clock discontinuity'));
      expect(blocked.cursorSample, 48000);
      expect(audio.pendingJobs(nowMs: 0).single.ownedEnd, 48000);
      expect(
        audio.segmentation(session.id, AudioSource.microphone, span.id)!.error,
        contains('clock discontinuity'),
      );
      await expectLater(pass(), throwsA(isA<AudioSegmentationUnavailable>()));
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
    },
  );

  test(
    'optional overlap requires timestamp-owned result cropping and stays explicitly bounded',
    () async {
      expect(
        () => const AudioSegmentationSettings(overlapSamples: 1).validate(),
        throwsArgumentError,
      );
      expect(
        () => const AudioSegmentationSettings(
          overlapSamples: 12001,
          supportsOwnedRangeCropping: true,
        ).validate(),
        throwsArgumentError,
      );
      capture(samples(1200000, 1000));
      final jobs = await drain(
        captureEndUs: 25000000,
        settings: const AudioSegmentationSettings(
          overlapSamples: 12000,
          supportsOwnedRangeCropping: true,
        ),
      );
      expect(jobs, hasLength(2));
      expect(jobs.last.sampleStart, jobs.last.ownedStart - 12000);
      expect(jobs.last.ownedStart, jobs.first.ownedEnd);
    },
  );

  test('corrupt settings/context and changed models fail closed', () async {
    capture(samples(48000, 1000));
    await pass(maxWindows: 1);
    await expectLater(
      owner.advance(
        sessionId: session.id,
        spanId: span.id,
        source: AudioSource.microphone,
        modelRevision: 'other-model',
      ),
      throwsStateError,
    );
    final cursor = audio.segmentation(
      session.id,
      AudioSource.microphone,
      span.id,
    )!;
    store.db.execute('UPDATE audio_segmentation_progress SET context=?', [
      Uint8List.fromList(utf8.encode('{invalid')),
    ]);
    await expectLater(pass(), throwsStateError);
    expect(
      audio
          .segmentation(session.id, AudioSource.microphone, span.id)!
          .cursorSample,
      cursor.cursorSample,
    );
  });

  test(
    'restart exactly at a native gap resumes after the frozen boundary once',
    () async {
      capture(samples(40800, 1000));
      capture(
        samples(40800, 1000),
        initialSample: 40800,
        firstSequence: 1,
        captureBaseUs: 2850000,
        gapBefore: true,
      );
      final prefix = await pass(maxWindows: 9);
      expect(prefix.cursorSample, 40800);
      expect(prefix.admittedJobIds, hasLength(1));
      final firstJob = audio.pendingJobs(nowMs: 0).single.id;
      store.close();
      store = Store(path);
      audio = bind();
      owner = newOwner();
      final jobs = await drain(captureEndUs: 3700000);
      expect(jobs, hasLength(2));
      expect(jobs.first.id, firstJob);
      expect(jobs.last.sampleStart, 40800);
      expect(jobs.last.ownedEnd, 81600);
    },
  );

  test(
    'real durable open context prevents compressed raw purge until flush and ASR commit',
    () async {
      final chunks = capture(samples(192000, 1000), chunkFrames: 48000);
      final raw = chunks.first;
      audio.publishRepresentation(
        AudioRepresentation(
          id: '${raw.id}.opus',
          chunkId: raw.id,
          codec: 'opus',
          container: 'ogg',
          settingsRevision: 'opus-v1',
          relativePath: '${raw.relativePath}.ogg',
          byteLength: 4096,
          sha256: digest,
          decodedSamples: 48000,
          state: AudioRepresentationState.published,
          validated: true,
        ),
      );
      await pass();
      expect(
        audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .retainFromSample,
        0,
      );
      expect(audio.beginRawPurge(raw.id), isNull);
      final jobs = await drain(captureEndUs: 4000000);
      expect(jobs, hasLength(1));
      expect(audio.beginRawPurge(raw.id), isNull);
      final lease = audio.claimJob(
        jobs.single.id,
        ownerGeneration: AudioStore.newIdentity(),
        nowMs: 0,
      )!;
      audio.commitAsrResult(lease, []);
      expect(audio.beginRawPurge(raw.id), isNotNull);
    },
  );

  test(
    'pause resumes both source cursors in a new span without paused PCM or timestamp reset',
    () async {
      capture(samples(48000, 1000));
      capture(samples(48000, 1000), source: AudioSource.playback);
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'pause');
      await pass(sealed: true);
      await pass(sealed: true, source: AudioSource.playback);
      audio.setCaptureState(session.id, AudioCaptureState.paused);
      span = audio.startSpan(
        session.id,
        captureStartUs: 10000000,
        playbackStartUs: 1000000,
        wallAnchorMs: 5000,
      );
      capture(
        samples(48000, 1000),
        initialSample: 48000,
        firstSequence: 1,
        captureBaseUs: 10000000,
      );
      capture(
        samples(48000, 1000),
        source: AudioSource.playback,
        initialSample: 48000,
        firstSequence: 1,
        captureBaseUs: 10000000,
      );
      audio.closeSpan(span.id, captureEndUs: 11000000, reason: 'stop');
      await pass(sealed: true);
      await pass(sealed: true, source: AudioSource.playback);
      final jobs = audio.pendingJobs(nowMs: 0);
      expect(jobs, hasLength(4));
      for (final source in AudioSource.values) {
        expect(
          jobs
              .where((job) => job.source == source)
              .map((job) => job.ownedStart)
              .toSet(),
          {0, 48000},
        );
      }
      expect(audio.spans(session.id).last.playbackEndUs, 2000000);
    },
  );

  test(
    'unknown clock uncertainty never invents a gap at a normal chunk rollover',
    () async {
      capture(samples(240000, 1000));
      capture(
        samples(48000, 1000),
        initialSample: 240000,
        firstSequence: 1,
        captureBaseUs: 5001000,
      );
      expect(await drain(captureEndUs: 6001000), hasLength(1));
      expect(audio.pendingJobs(nowMs: 0).single.ownedEnd, 288000);
      expect(
        audio.latestSourceClock(span.id, AudioSource.microphone)!.uncertaintyUs,
        isNull,
      );
    },
  );

  test(
    'short verified-window reads persist an error and release the file reader fence',
    () async {
      capture(samples(48000, 1000));
      reader = (chunk, {required frameOffset, required frameCount}) async =>
          Int16List(frameCount - 1);
      await expectLater(pass(), throwsA(isA<AudioSegmentationUnavailable>()));
      expect(
        audio.segmentation(session.id, AudioSource.microphone, span.id)!.error,
        contains('invalid extent'),
      );
      expect(
        audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .cursorSample,
        0,
      );
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
      reader = readMedia;
      await drain(captureEndUs: 1000000);
      expect(
        audio.segmentation(session.id, AudioSource.microphone, span.id)!.error,
        isEmpty,
      );
    },
  );

  test(
    'source/sample holes and unavailable canonical media fail without inventing frames',
    () async {
      capture(samples(4800, 1000), initialSample: 4800);
      await expectLater(pass(), throwsA(isA<AudioSegmentationUnavailable>()));
    },
  );
}
