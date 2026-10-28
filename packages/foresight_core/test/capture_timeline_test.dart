import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/capture_timeline.dart';
import 'package:test/test.dart';

const mic = AudioSource.microphone;
const remote = AudioSource.playback;

/// One second of 48 kHz samples per run unless stated otherwise.
void second(
  CaptureTimeline timeline,
  AudioSource source,
  int index, {
  required int startUs,
  int rate = 48000,
  bool discontinuous = false,
  int? sampleStart,
}) {
  timeline.addRun(
    source,
    sampleStart: sampleStart ?? index * rate,
    sampleCount: rate,
    sampleRate: rate,
    startUs: startUs,
    endUs: startUs + 1000000,
    discontinuousBefore: discontinuous,
  );
}

void main() {
  test('maps a sample range inside one run linearly', () {
    final timeline = CaptureTimeline();
    second(timeline, remote, 0, startUs: 5000000);
    final mapped = timeline.map(remote, sampleStart: 12000, sampleEnd: 36000)!;
    expect(mapped.startUs, 5250000);
    expect(mapped.endUs, 5750000);
    expect(mapped.hasDiscontinuity, false);
    expect(mapped.gapUs, 0);
    expect(mapped.pieces, hasLength(1));
  });

  test('contiguous runs read as one piece sequence without a gap', () {
    final timeline = CaptureTimeline();
    second(timeline, remote, 0, startUs: 1000000);
    second(timeline, remote, 1, startUs: 2000000);
    final mapped = timeline.map(remote, sampleStart: 24000, sampleEnd: 72000)!;
    expect(mapped.startUs, 1500000);
    expect(mapped.endUs, 2500000);
    expect(mapped.hasDiscontinuity, false);
    expect(mapped.pieces, hasLength(2));
  });

  test('capture gaps are excluded from sample time but reported', () {
    // Samples 0..1s then a 4 s outage; sample counting continues.
    final timeline = CaptureTimeline();
    second(timeline, remote, 0, startUs: 0);
    second(timeline, remote, 1, startUs: 5000000, discontinuous: true);
    final mapped = timeline.map(remote, sampleStart: 24000, sampleEnd: 72000)!;
    expect(mapped.startUs, 500000);
    expect(mapped.endUs, 5500000);
    expect(mapped.hasDiscontinuity, true);
    expect(mapped.gapUs, 4000000);
    expect(mapped.pieces, hasLength(2));
    // A range wholly inside one side of the gap is not discontinuous.
    expect(
      timeline
          .map(remote, sampleStart: 48000, sampleEnd: 60000)!
          .hasDiscontinuity,
      false,
    );
  });

  test('a timestamp jump is a gap even without an explicit marker', () {
    final timeline = CaptureTimeline();
    second(timeline, mic, 0, startUs: 0);
    second(timeline, mic, 1, startUs: 3000000);
    final mapped = timeline.map(mic, sampleStart: 40000, sampleEnd: 60000)!;
    expect(mapped.hasDiscontinuity, true);
    expect(mapped.gapUs, 2000000);
  });

  test('small timestamp jitter is not a gap and widens uncertainty', () {
    final timeline = CaptureTimeline(jitterToleranceUs: 50000);
    second(timeline, mic, 0, startUs: 0);
    second(timeline, mic, 1, startUs: 1030000);
    final mapped = timeline.map(mic, sampleStart: 40000, sampleEnd: 60000)!;
    expect(mapped.hasDiscontinuity, false);
    expect(mapped.uncertaintyUs, greaterThanOrEqualTo(30000));
  });

  test('pause and resume discontinuity is explicit', () {
    final timeline = CaptureTimeline();
    second(timeline, remote, 0, startUs: 0);
    timeline.markDiscontinuity(remote);
    // The resumed run starts only slightly later, so only the marker says gap.
    second(timeline, remote, 1, startUs: 1000000);
    final mapped = timeline.map(remote, sampleStart: 40000, sampleEnd: 60000)!;
    expect(mapped.hasDiscontinuity, true);
    expect(mapped.gapUs, 0);
    // The marker applies once.
    second(timeline, remote, 2, startUs: 2000000);
    expect(
      timeline
          .map(remote, sampleStart: 100000, sampleEnd: 110000)!
          .hasDiscontinuity,
      false,
    );
  });

  test('channels have independent startup offsets and runs', () {
    final timeline = CaptureTimeline();
    second(timeline, mic, 0, startUs: 100000);
    second(timeline, remote, 0, startUs: 400000);
    expect(timeline.map(mic, sampleStart: 0, sampleEnd: 4800)!.startUs, 100000);
    expect(
      timeline.map(remote, sampleStart: 0, sampleEnd: 4800)!.startUs,
      400000,
    );
  });

  test('sample-rate epochs map each run by its own rate', () {
    final timeline = CaptureTimeline();
    second(timeline, remote, 0, startUs: 0);
    // 16 kHz run continues the sample counter at 48000.
    timeline.addRun(
      remote,
      sampleStart: 48000,
      sampleCount: 16000,
      sampleRate: 16000,
      startUs: 1000000,
      endUs: 2000000,
    );
    final inside = timeline.map(remote, sampleStart: 56000, sampleEnd: 64000)!;
    expect(inside.startUs, 1500000);
    expect(inside.endUs, 2000000);
    expect(inside.crossesRateChange, false);
    final across = timeline.map(remote, sampleStart: 36000, sampleEnd: 56000)!;
    expect(across.crossesRateChange, true);
    expect(across.startUs, 750000);
    expect(across.endUs, 1500000);
  });

  test('uncovered, dropped or empty ranges do not map', () {
    final timeline = CaptureTimeline();
    expect(timeline.map(mic, sampleStart: 0, sampleEnd: 10), isNull);
    second(timeline, mic, 0, startUs: 0);
    expect(timeline.map(mic, sampleStart: 40000, sampleEnd: 50000), isNull);
    expect(timeline.map(mic, sampleStart: 47000, sampleEnd: 49000), isNull);
    // A hole in the sample counter is not interpolated.
    timeline.addRun(
      mic,
      sampleStart: 60000,
      sampleCount: 48000,
      sampleRate: 48000,
      startUs: 2000000,
      endUs: 3000000,
    );
    expect(timeline.map(mic, sampleStart: 40000, sampleEnd: 70000), isNull);
    expect(timeline.map(mic, sampleStart: 60000, sampleEnd: 70000), isNotNull);
    expect(
      () => timeline.map(mic, sampleStart: 5, sampleEnd: 5),
      throwsArgumentError,
    );
    expect(
      () => timeline.map(mic, sampleStart: -1, sampleEnd: 5),
      throwsArgumentError,
    );
  });

  test('timestamps never move backward', () {
    final timeline = CaptureTimeline();
    second(timeline, remote, 0, startUs: 1000000);
    // The next run reports a start earlier than the previous run's end.
    second(timeline, remote, 1, startUs: 1900000);
    final mapped = timeline.map(remote, sampleStart: 0, sampleEnd: 96000)!;
    var previousEnd = -1;
    for (final piece in mapped.pieces) {
      expect(piece.startUs, greaterThanOrEqualTo(previousEnd));
      expect(piece.endUs, greaterThanOrEqualTo(piece.startUs));
      previousEnd = piece.endUs;
    }
    expect(mapped.uncertaintyUs, greaterThanOrEqualTo(100000));
  });

  test('native frame emission anchors widen uncertainty', () {
    final timeline = CaptureTimeline();
    timeline.addEmission(
      remote,
      sampleStart: 0,
      sampleCount: 4800,
      sampleRate: 48000,
      emittedUs: 600000,
      uncertaintyUs: 40000,
    );
    final mapped = timeline.map(remote, sampleStart: 0, sampleEnd: 4800)!;
    expect(mapped.endUs, 600000);
    expect(mapped.startUs, 500000);
    expect(mapped.uncertaintyUs, 40000);
  });

  test('an AudioChunk is a run with its own timestamps and gap flag', () {
    final timeline = CaptureTimeline();
    AudioChunk chunk(int sequence, int start, int us, {bool gap = false}) =>
        AudioChunk(
          id: 'c$sequence',
          sessionId: 's',
          spanId: 'p',
          source: remote,
          sequence: sequence,
          relativePath: 'x',
          publicationToken: 't',
          storageGeneration: 'g',
          sampleStart: start,
          sampleCount: 48000,
          sampleRate: 48000,
          channels: 1,
          captureStartUs: us,
          captureEndUs: us + 1000000,
          state: AudioChunkState.published,
          gapBefore: gap,
        );
    timeline.addChunk(chunk(0, 0, 10000000));
    timeline.addChunk(chunk(1, 48000, 12000000, gap: true));
    final mapped = timeline.map(remote, sampleStart: 40000, sampleEnd: 56000)!;
    expect(mapped.hasDiscontinuity, true);
    expect(mapped.gapUs, 1000000);
  });

  test('drift between run duration and timestamps adds uncertainty', () {
    final timeline = CaptureTimeline();
    timeline.addRun(
      mic,
      sampleStart: 0,
      sampleCount: 48000,
      sampleRate: 48000,
      startUs: 0,
      endUs: 1020000,
    );
    expect(
      timeline.map(mic, sampleStart: 0, sampleEnd: 100)!.uncertaintyUs,
      20000,
    );
  });

  test(
    'a sample counter reset discards aliasing history instead of throwing',
    () {
      final timeline = CaptureTimeline();
      second(timeline, mic, 0, startUs: 0);
      second(timeline, mic, 1, startUs: 1000000);
      expect(timeline.counterResets(mic), 0);
      // Device recovery restarts the counter at zero.
      final result = timeline.addRun(
        mic,
        sampleStart: 0,
        sampleCount: 48000,
        sampleRate: 48000,
        startUs: 9000000,
        endUs: 10000000,
      );
      expect(result, CaptureRunResult.counterReset);
      expect(timeline.counterResets(mic), 1);
      expect(timeline.runCount(mic), 1);
      expect(
        timeline.map(mic, sampleStart: 0, sampleEnd: 100)!.startUs,
        9000000,
      );
      // The other channel is untouched.
      second(timeline, remote, 0, startUs: 0);
      expect(timeline.counterResets(remote), 0);
    },
  );

  test('a reset invalidates ranges recorded before it', () {
    final timeline = CaptureTimeline();
    second(timeline, mic, 0, startUs: 0);
    final before = timeline.generation(mic);
    expect(
      timeline
          .mapOutcome(mic, sampleStart: 0, sampleEnd: 100, generation: before)
          .range,
      isNotNull,
    );
    timeline.addRun(
      mic,
      sampleStart: 0,
      sampleCount: 48000,
      sampleRate: 48000,
      startUs: 9000000,
      endUs: 10000000,
    );
    final stale = timeline.mapOutcome(
      mic,
      sampleStart: 0,
      sampleEnd: 100,
      generation: before,
    );
    expect(stale.range, isNull);
    expect(stale.miss, TimelineMiss.counterReset);
    expect(
      timeline.map(mic, sampleStart: 0, sampleEnd: 100, generation: before),
      isNull,
    );
    final current = timeline.mapOutcome(
      mic,
      sampleStart: 0,
      sampleEnd: 100,
      generation: timeline.generation(mic),
    );
    expect(current.range!.startUs, 9000000);
    // Other channels keep their own generation.
    expect(timeline.generation(remote), 0);
  });

  test('says why a range does not map', () {
    final timeline = CaptureTimeline();
    TimelineMiss? miss(int a, int b) =>
        timeline.mapOutcome(mic, sampleStart: a, sampleEnd: b).miss;
    expect(miss(0, 10), TimelineMiss.unknownSource);
    second(timeline, mic, 0, startUs: 0);
    timeline.addRun(
      mic,
      sampleStart: 60000,
      sampleCount: 48000,
      sampleRate: 48000,
      startUs: 2000000,
      endUs: 3000000,
    );
    expect(miss(0, 10), isNull);
    expect(miss(40000, 70000), TimelineMiss.sampleGap);
    expect(miss(200000, 300000), TimelineMiss.notYetCaptured);
    timeline.releaseBefore(mic, 48000);
    expect(miss(0, 10), TimelineMiss.trimmed);
    timeline.releaseBefore(mic, 1 << 40);
    expect(miss(0, 10), TimelineMiss.trimmed);
  });

  test('rejects invalid runs', () {
    final timeline = CaptureTimeline();
    second(timeline, mic, 0, startUs: 0);
    for (final bad in [
      (48000, 10, 48000, 5, 4), // end before start
      (48000, 0, 48000, 0, 1), // no samples
      (48000, 10, 0, 0, 1), // no rate
      (-1, 10, 48000, 0, 1),
      (48000, 10, 48000, -5, 1),
    ]) {
      expect(
        () => timeline.addRun(
          mic,
          sampleStart: bad.$1,
          sampleCount: bad.$2,
          sampleRate: bad.$3,
          startUs: bad.$4,
          endUs: bad.$5,
        ),
        throwsArgumentError,
        reason: '$bad',
      );
    }
  });

  test('history is bounded and releasing older samples drops mappings', () {
    final timeline = CaptureTimeline(maxRunsPerChannel: 3);
    for (var i = 0; i < 5; i++) {
      second(timeline, remote, i, startUs: i * 1000000);
    }
    expect(timeline.runCount(remote), 3);
    expect(timeline.map(remote, sampleStart: 0, sampleEnd: 10), isNull);
    expect(
      timeline.map(remote, sampleStart: 96000, sampleEnd: 100000),
      isNotNull,
    );
    expect(timeline.oldestSample(remote), 96000);
    timeline.releaseBefore(remote, 192000);
    expect(timeline.runCount(remote), 1);
    expect(timeline.map(remote, sampleStart: 96000, sampleEnd: 100000), isNull);
    expect(timeline.runCount(mic), 0);
    expect(timeline.oldestSample(mic), isNull);
    expect(timeline.endSample(remote), 240000);
  });

  test('many runs stay efficient and exact', () {
    final timeline = CaptureTimeline(maxRunsPerChannel: 100000);
    for (var i = 0; i < 20000; i++) {
      timeline.addRun(
        remote,
        sampleStart: i * 480,
        sampleCount: 480,
        sampleRate: 48000,
        startUs: i * 10000,
        endUs: i * 10000 + 10000,
      );
    }
    final mapped = timeline.map(
      remote,
      sampleStart: 480 * 12345,
      sampleEnd: 480 * 12346,
    )!;
    expect(mapped.startUs, 123450000);
    expect(mapped.endUs, 123460000);
  });

  test('clear forgets everything', () {
    final timeline = CaptureTimeline();
    second(timeline, mic, 0, startUs: 0);
    timeline.clear();
    expect(timeline.map(mic, sampleStart: 0, sampleEnd: 10), isNull);
    second(timeline, mic, 0, startUs: 0);
    expect(timeline.map(mic, sampleStart: 0, sampleEnd: 10), isNotNull);
  });

  test('compacts dropped history without disturbing lookups', () {
    final timeline = CaptureTimeline(maxRunsPerChannel: 1500);
    for (var i = 0; i < 6000; i++) {
      timeline.addRun(
        remote,
        sampleStart: i * 480,
        sampleCount: 480,
        sampleRate: 48000,
        startUs: i * 10000,
        endUs: i * 10000 + 10000,
      );
    }
    expect(timeline.runCount(remote), 1500);
    expect(timeline.oldestSample(remote), 4500 * 480);
    expect(
      timeline.map(remote, sampleStart: 4499 * 480, sampleEnd: 4499 * 480 + 1),
      isNull,
    );
    final mapped = timeline.map(
      remote,
      sampleStart: 5999 * 480,
      sampleEnd: 6000 * 480,
    )!;
    expect(mapped.startUs, 59990000);
  });

  test('rejects invalid bounds', () {
    expect(() => CaptureTimeline(maxRunsPerChannel: 0), throwsArgumentError);
    expect(() => CaptureTimeline(jitterToleranceUs: -1), throwsArgumentError);
  });
}
