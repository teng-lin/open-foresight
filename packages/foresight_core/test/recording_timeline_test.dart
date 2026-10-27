import 'package:foresight_core/src/recording_timeline.dart';
import 'package:test/test.dart';

void main() {
  test('pause removes only intentional intervals from the shared clock', () {
    final timeline = RecordingTimeline([
      RecordingTimeSpan('first', 1000000, 11000000),
      RecordingTimeSpan('resume', 21000000, 26000000),
    ]);
    expect(timeline.durationUs, 15000000);
    expect(timeline.playbackForSession(1000000), 0);
    expect(timeline.playbackForSession(10999999), 9999999);
    expect(timeline.playbackForSession(11000000), isNull);
    expect(timeline.playbackForSession(20000000), isNull);
    expect(timeline.playbackForSession(21000000), 10000000);
    expect(timeline.sessionForPlayback(10000000), 21000000);
    expect(timeline.sessionForPlayback(15000000), 26000000);
    expect(timeline.playbackForSession(26000000), 15000000);
    expect(timeline.playbackForSession(999999), isNull);
    expect(timeline.playbackForSession(26000001), isNull);
    expect(timeline.sessionForPlayback(-1), isNull);
    expect(timeline.sessionForPlayback(15000001), isNull);
  });

  test('a playback read splits at resume without inserting paused PCM', () {
    final timeline = RecordingTimeline([
      RecordingTimeSpan('a', 0, 1000000),
      RecordingTimeSpan('b', 10000000, 12000000),
    ]);
    final slices = timeline.slices(500000, 2000000);
    expect(slices, hasLength(2));
    expect(slices[0].spanId, 'a');
    expect(slices[0].sessionStartUs, 500000);
    expect(slices[0].sessionEndUs, 1000000);
    expect(slices[1].spanId, 'b');
    expect(slices[1].sessionStartUs, 10000000);
    expect(slices[1].sessionEndUs, 11000000);
    expect(slices[1].playbackStartUs, 1000000);
    expect(slices.fold(0, (total, slice) => total + slice.durationUs), 1500000);
    expect(() => slices.clear(), throwsUnsupportedError);
    expect(timeline.slices(1000000, 1000000), isEmpty);
    expect(timeline.slices(3000000, 3000000), isEmpty);
    expect(() => timeline.slices(-1, 1), throwsRangeError);
    expect(() => timeline.slices(1, 0), throwsRangeError);
    expect(() => timeline.slices(0, 3000001), throwsRangeError);
  });

  test('missing source does not shorten the other source or the timeline', () {
    final timeline = RecordingTimeline([RecordingTimeSpan('a', 0, 5000000)]);
    final microphone = RecordingSampleAnchor(
      chunkId: 'mic',
      spanId: 'a',
      source: 'microphone',
      firstFrame: 0,
      frameCount: 240000,
      sampleRate: 48000,
      sessionStartUs: 0,
    );
    final playback = RecordingSampleAnchor(
      chunkId: 'playback',
      spanId: 'a',
      source: 'playback',
      firstFrame: 0,
      frameCount: 96000,
      sampleRate: 48000,
      sessionStartUs: 2000000,
    );
    expect(microphone.frameForSession(1000000), 48000);
    expect(playback.frameForSession(1000000), isNull);
    expect(playback.frameForSession(2000000), 0);
    expect(playback.frameForSession(4500000), isNull);
    expect(timeline.playbackForSession(4500000), 4500000);
  });

  test(
    'nonzero sample origins and nonintegral microsecond rates stay bounded',
    () {
      for (final rate in [16000, 44100, 48000]) {
        final anchor = RecordingSampleAnchor(
          chunkId: 'chunk',
          spanId: 'span',
          source: 'microphone',
          firstFrame: 12345,
          frameCount: rate * 5,
          sampleRate: rate,
          sessionStartUs: 987654321,
        );
        for (
          var frame = anchor.firstFrame;
          frame < anchor.lastFrameExclusive;
          frame += 113
        ) {
          final time = anchor.sessionForFrame(frame)!;
          final restored = anchor.frameForSession(time)!;
          expect(frame - restored, inInclusiveRange(0, 1));
        }
        expect(
          anchor.frameForSession(anchor.sessionEndUs),
          anchor.lastFrameExclusive,
        );
        expect(
          anchor.sessionForFrame(anchor.lastFrameExclusive),
          anchor.sessionEndUs,
        );
        expect(anchor.sessionForFrame(12344), isNull);
        expect(anchor.sessionForFrame(anchor.lastFrameExclusive + 1), isNull);
      }
    },
  );

  test('empty or contiguous spans have defined boundaries', () {
    final empty = RecordingTimeline([]);
    expect(empty.durationUs, 0);
    expect(empty.sessionForPlayback(0), isNull);
    expect(empty.playbackForSession(0), isNull);
    expect(empty.slices(0, 0), isEmpty);
    final input = [
      RecordingTimeSpan('a', 0, 10),
      RecordingTimeSpan('b', 10, 20),
    ];
    final timeline = RecordingTimeline(input);
    input.clear();
    expect(timeline.playbackForSession(10), 10);
    expect(timeline.slices(10, 15).single.spanId, 'b');
    expect(() => timeline.spans.clear(), throwsUnsupportedError);
  });

  test('corrupt span order and identities fail before playback', () {
    expect(() => RecordingTimeSpan('', 0, 1), throwsArgumentError);
    expect(() => RecordingTimeSpan('x', -1, 1), throwsRangeError);
    expect(() => RecordingTimeSpan('x', 1, 1), throwsArgumentError);
    expect(
      () => RecordingTimeline([
        RecordingTimeSpan('x', 0, 2),
        RecordingTimeSpan('y', 1, 3),
      ]),
      throwsArgumentError,
    );
    expect(
      () => RecordingTimeline([
        RecordingTimeSpan('x', 0, 1),
        RecordingTimeSpan('x', 2, 3),
      ]),
      throwsArgumentError,
    );
  });
}
