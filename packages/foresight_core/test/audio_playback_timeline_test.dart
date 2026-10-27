import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_playback_timeline.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late AudioStore audio;
  late AudioSession session;
  late AudioPlaybackTimelinePlanner planner;
  setUp(() {
    final root = createTestTempDirectorySync('sample-timeline-');
    store = Store('${root.path}/application.db');
    audio = AudioStore(
      store.db,
      workspaceEpoch: () => store.workspaceEpoch,
      mediaGeneration: () => store.audioStore.storageGeneration,
    );
    session = audio.createSession(
      meetingId: store.meeting('Timeline'),
      startedWallMs: 0,
    );
    planner = AudioPlaybackTimelinePlanner(store.db);
    addTearDown(store.close);
  });
  AudioSpan span(int capture, int playback) => audio.startSpan(
    session.id,
    captureStartUs: capture,
    playbackStartUs: playback,
    wallAnchorMs: 0,
  );
  AudioChunk chunk(
    AudioSpan span,
    int sequence,
    int sample,
    int frames,
    int capture, {
    AudioSource source = AudioSource.microphone,
    bool gap = false,
  }) {
    final id = AudioStore.newIdentity();
    final publication = audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: source,
      sequence: sequence,
      id: id,
      relativePath:
          'recordings/${session.storageGeneration}/${session.id}/$id.wav',
    );
    return audio.publishPreallocatedChunk(
      publication.id,
      publicationToken: publication.publicationToken,
      sampleStart: sample,
      sampleCount: frames,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: capture,
      captureEndUs: capture + frames * 1000000 ~/ 48000,
      byteLength: 196 + frames * 2,
      sha256: 'a' * 64,
      gapBefore: gap,
    );
  }

  List<AudioPlaybackChunk> positions(AudioPlaybackTimeline plan) {
    final cursor = plan.cursor();
    return planner.acquiredChunks(session.id).map(cursor.accept).toList();
  }

  test(
    '4801 retained samples and a one-frame clip survive floored microseconds',
    () {
      final first = span(0, 0);
      chunk(first, 0, 0, 4801, 0);
      audio.closeSpan(first.id, captureEndUs: 100020, reason: 'pause');
      final second = span(500000, 100020);
      chunk(second, 1, 4801, 1, 500000);
      audio.closeSpan(second.id, captureEndUs: 500020, reason: 'stop');
      final plan = planner.resolve(session.id), rows = positions(plan);
      expect(plan.totalFrames, 4802);
      expect(plan.spans.map((s) => s.startFrame), [0, 4801]);
      expect(rows.map((r) => (r.startFrame, r.frameCount)), [
        (0, 4801),
        (4801, 1),
      ]);
    },
  );

  test(
    'adjacent irregular partitions use one source anchor without sample loss',
    () {
      final owner = span(0, 0);
      var sample = 0;
      for (final frames in [1, 4801, 7, 13, 4801]) {
        chunk(owner, sample, sample, frames, sample * 1000000 ~/ 48000);
        sample += frames;
      }
      audio.closeSpan(
        owner.id,
        captureEndUs: sample * 1000000 ~/ 48000,
        reason: 'stop',
      );
      final plan = planner.resolve(session.id), rows = positions(plan);
      expect(plan.totalFrames, sample);
      expect(rows.fold<int>(0, (n, r) => n + r.frameCount), sample);
      for (var i = 1; i < rows.length; i++) {
        expect(
          rows[i].startFrame,
          rows[i - 1].startFrame + rows[i - 1].frameCount,
        );
      }
    },
  );

  test(
    'two sources share maximum extent and intentional pauses compact globally',
    () {
      final first = span(0, 0);
      chunk(first, 0, 0, 4801, 0);
      chunk(first, 0, 0, 4801, 33, source: AudioSource.playback);
      audio.closeSpan(first.id, captureEndUs: 100053, reason: 'pause');
      final second = span(200000, 100053);
      chunk(second, 1, 4801, 1, 200000);
      chunk(second, 1, 4801, 2, 200020, source: AudioSource.playback);
      audio.closeSpan(second.id, captureEndUs: 200061, reason: 'stop');
      final plan = planner.resolve(session.id), rows = positions(plan);
      expect(plan.spans.map((s) => s.frameCount), [4802, 2]);
      expect(plan.totalFrames, 4804);
      expect(rows.map((r) => (r.startFrame, r.frameCount)), [
        (0, 4801),
        (4802, 1),
        (1, 4801),
        (4802, 2),
      ]);
    },
  );

  test('an acquisition outage remains a hole in the shared span', () {
    final owner = span(0, 0);
    chunk(owner, 0, 0, 4801, 0);
    chunk(owner, 1, 4801, 1, 100044, gap: true);
    audio.closeSpan(owner.id, captureEndUs: 100064, reason: 'stop');
    final plan = planner.resolve(session.id), rows = positions(plan);
    expect(plan.totalFrames, 4803);
    expect(rows.last.startFrame, 4802);
    expect(rows.first.startFrame + rows.first.frameCount, 4801);
  });

  test(
    'ambiguous new-run overlap is rejected without changing original metadata',
    () {
      final owner = span(0, 0);
      final first = chunk(owner, 0, 0, 4801, 0);
      final second = chunk(owner, 1, 4801, 1, 100020, gap: true);
      audio.closeSpan(owner.id, captureEndUs: 100040, reason: 'stop');
      expect(
        () => planner.resolve(session.id),
        throwsA(isA<AudioPlaybackTimelineError>()),
      );
      expect(audio.chunk(first.id)!.sampleCount, 4801);
      expect(audio.chunk(second.id)!.state, AudioChunkState.published);
    },
  );

  test(
    'known missing and quarantined chunks keep geometry; reservations do not',
    () {
      final owner = span(0, 0);
      chunk(owner, 0, 0, 1, 0);
      final missing = chunk(owner, 1, 1, 4801, 20);
      final quarantined = chunk(owner, 2, 4802, 7, 100041);
      store.db.execute("UPDATE audio_chunks SET state='missing' WHERE id=?", [
        missing.id,
      ]);
      store.db.execute(
        "UPDATE audio_chunks SET state='quarantined' WHERE id=?",
        [quarantined.id],
      );
      final id = AudioStore.newIdentity();
      audio.preallocateChunk(
        sessionId: session.id,
        spanId: owner.id,
        source: AudioSource.playback,
        sequence: 0,
        id: id,
        relativePath:
            'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      );
      audio.closeSpan(owner.id, captureEndUs: 100187, reason: 'stop');
      final plan = planner.resolve(session.id);
      expect(plan.totalFrames, 4809);
      expect(positions(plan).length, 3);
    },
  );

  test(
    'late publication invalidates geometry while unrelated transcript work does not',
    () {
      final owner = span(0, 0);
      chunk(owner, 0, 0, 4801, 0);
      final id = AudioStore.newIdentity();
      final pending = audio.preallocateChunk(
        sessionId: session.id,
        spanId: owner.id,
        source: AudioSource.microphone,
        sequence: 1,
        id: id,
        relativePath:
            'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      );
      audio.closeSpan(owner.id, captureEndUs: 100041, reason: 'stop');
      final first = planner.resolve(session.id);
      store.db.execute(
        "INSERT INTO preferences(key,value) VALUES('timeline_test','asr-write')",
      );
      expect(identical(first, planner.resolve(session.id)), isTrue);
      audio.publishPreallocatedChunk(
        pending.id,
        publicationToken: pending.publicationToken,
        sampleStart: 4801,
        sampleCount: 1,
        sampleRate: 48000,
        channels: 1,
        captureStartUs: 100020,
        captureEndUs: 100040,
        byteLength: 198,
        sha256: 'b' * 64,
      );
      final second = planner.resolve(session.id);
      expect(identical(first, second), isFalse);
      expect(second.totalFrames, 4802);
    },
  );

  test('bounded plan eviction keeps exact scalar durations', () {
    final owner = span(0, 0);
    chunk(owner, 0, 0, 1, 0);
    audio.closeSpan(owner.id, captureEndUs: 20, reason: 'pause');
    final second = span(100000, 20);
    chunk(second, 1, 1, 1, 100000);
    audio.closeSpan(second.id, captureEndUs: 100020, reason: 'stop');
    final bounded = AudioPlaybackTimelinePlanner(
      store.db,
      maximumCachedSpans: 1,
    );
    expect(bounded.resolve(session.id).totalFrames, 2);
    expect(bounded.durationFrames(session.id), 2);
    expect(bounded.durationFrames(session.id, authority: 'new-workspace'), 2);
  });
}
