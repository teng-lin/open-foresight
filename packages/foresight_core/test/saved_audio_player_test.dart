import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:foresight_core/src/application_services/audio_playback_source.dart';
import 'package:foresight_core/src/application_services/saved_audio_player.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/recording_playback.dart';
import 'package:test/test.dart';

class Source implements AudioPlaybackSource {
  Source(this.totalFrames);
  @override
  final int totalFrames;
  final ranges = <(int, int)>[];
  Completer<Int16List>? decodeGate;
  Completer<void>? closeGate;
  Future<void>? _closing;
  int cancellations = 0, closes = 0;
  @override
  Future<Int16List> decode(int start, int count) async {
    ranges.add((start, count));
    return decodeGate?.future ??
        Int16List.fromList(List.generate(count, (i) => (start + i) % 30000));
  }

  @override
  void cancel() {
    cancellations++;
  }

  @override
  Future<void> close() => _closing ??= () async {
    closes++;
    await closeGate?.future;
  }();
}

class Output implements PcmPlaybackOutput {
  Output(this.generation, {this.capacity = 76800});
  @override
  int generation;
  int capacity, queued = 0, rendered = 0, resumes = 0, closes = 0;
  bool stopped = false, paused = true;
  String? error;
  final delivered = <int>[];
  Completer<void>? closeGate;
  Future<void>? _closing;
  void consume(int frames) {
    final take = math.min(frames, queued);
    queued -= take;
    rendered += take;
  }

  @override
  PcmOutputSnapshot snapshot() => PcmOutputSnapshot.fromJson({
    'version': 1,
    'generation': generation,
    'queued_frames': queued,
    'rendered_frames': rendered,
    'underruns': 0,
    'start_token': 1,
    'ready': true,
    'paused': paused,
    'stopped': stopped,
    'buffering': false,
    'error': error,
  });
  @override
  int push(Int16List stereo, {required int generation}) {
    if (stopped || generation != this.generation) return -2;
    final accepted = math.min(stereo.length ~/ 2, capacity - queued);
    delivered.addAll(stereo.take(accepted * 2));
    queued += accepted;
    return accepted;
  }

  @override
  Future<void> pauseFlush(int next) async {
    generation = next;
    queued = rendered = 0;
    paused = true;
  }

  @override
  Future<void> resume() async {
    resumes++;
    paused = false;
  }

  @override
  Future<void> close() => _closing ??= () async {
    closes++;
    stopped = true;
    queued = 0;
    await closeGate?.future;
  }();
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Controlled player did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late SavedAudioPlayer player;
  late List<Source> sources;
  late List<Output> outputs;
  var total = 1000, capacity = 76800;
  Source Function()? sourceFactory;
  Output Function(int)? outputFactory;
  setUp(() {
    sources = [];
    outputs = [];
    total = 1000;
    capacity = 76800;
    sourceFactory = null;
    outputFactory = null;
    player = SavedAudioPlayer(
      openSource: (session, current) async {
        if (!current()) throw StateError('Admission cancelled');
        final source = sourceFactory?.call() ?? Source(total);
        sources.add(source);
        return source;
      },
      openOutput: (generation, current) async {
        if (!current()) throw StateError('Admission cancelled');
        final output =
            outputFactory?.call(generation) ??
            Output(generation, capacity: capacity);
        outputs.add(output);
        return output;
      },
      changed: () {},
    );
    addTearDown(() async {
      for (final source in sources) {
        if (source.decodeGate case final gate?) {
          if (!gate.isCompleted) gate.completeError(StateError('Test closed'));
        }
        if (source.closeGate case final gate?) {
          if (!gate.isCompleted) gate.complete();
        }
      }
      for (final output in outputs) {
        if (output.closeGate case final gate?) {
          if (!gate.isCompleted) gate.complete();
        }
      }
      try {
        await player.close();
      } catch (_) {
        /* Controlled unconfirmed-owner case. */
      }
    });
  });
  test(
    'mono frames are duplicated to stereo with bounded output backpressure',
    () async {
      capacity = 3;
      await player.play('session', current: () => true);
      expect(outputs.single.delivered, [0, 0, 1, 1, 2, 2]);
      outputs.single.consume(3);
      await until(() => outputs.single.delivered.length >= 12);
      expect(outputs.single.delivered.take(12), [
        0,
        0,
        1,
        1,
        2,
        2,
        3,
        3,
        4,
        4,
        5,
        5,
      ]);
      expect(sources.single.ranges, [(0, 1000)]);
      expect(player.presentation.positionUs, 3 * 1000000 ~/ 48000);
    },
  );
  test(
    'pause closes real owners before acknowledging and resumes at consumed position',
    () async {
      await player.play('session', current: () => true);
      outputs.single.consume(17);
      final gate = Completer<void>();
      sources.single.closeGate = gate;
      var settled = false;
      final pause = player
          .pause('session', current: () => true)
          .then((_) => settled = true);
      await until(() => sources.single.closes == 1);
      expect(outputs.single.stopped, isTrue);
      expect(settled, isFalse);
      gate.complete();
      await pause;
      expect(player.busy, isFalse);
      expect(player.presentation.positionUs, 17 * 1000000 ~/ 48000);
      await player.play('session', current: () => true);
      expect(sources.last.ranges.single, (17, 983));
      expect(outputs.last.generation, 2);
    },
  );
  test(
    'seek cancels held startup decode and stale PCM never reaches output',
    () async {
      final decode = Completer<Int16List>();
      sourceFactory = () => Source(total)..decodeGate = decode;
      final playing = player.play('session', current: () => true);
      playing.ignore();
      await until(() => sources.isNotEmpty && sources.first.ranges.isNotEmpty);
      sourceFactory = null;
      final seek = player.seek('session', 10000, current: () => true);
      expect(outputs.single.stopped, isTrue);
      decode.complete(Int16List(total));
      await expectLater(playing, throwsA(anything));
      await seek;
      expect(outputs.single.delivered, isEmpty);
      expect(player.presentation.state, MeetingAudioPlaybackState.paused);
      expect(player.presentation.positionUs, 10000);
      await player.play('session', current: () => true);
      expect(sources.last.ranges.single, (480, 520));
    },
  );
  test(
    'transcript frame seek preserves a one-sample tail while paused and playing',
    () async {
      total = 4802;
      await player.seekFrame('session', 4801, current: () => true);
      expect(outputs, isEmpty);
      expect(player.presentation.state, MeetingAudioPlaybackState.paused);
      await player.play('session', current: () => true);
      expect(sources.last.ranges.single, (4801, 1));
      expect(outputs.last.delivered, [4801, 4801]);
      await player.seekFrame('session', 4800, current: () => true);
      expect(sources.last.ranges.single, (4800, 2));
      expect(outputs.last.delivered, [4800, 4800, 4801, 4801]);
    },
  );
  test(
    'service playback survives request settlement until an explicit control',
    () async {
      var request = true;
      await player.play('session', current: () => request);
      request = false;
      outputs.single.consume(5);
      await until(() => player.presentation.positionUs == 5 * 1000000 ~/ 48000);
      expect(player.presentation.state, MeetingAudioPlaybackState.playing);
      await player.pause('session', current: () => true);
    },
  );
  test(
    'cancelled queued command fences existing owners before rejecting',
    () async {
      await player.play('session', current: () => true);
      await expectLater(
        player.seek('session', 1, current: () => false),
        throwsA(anything),
      );
      expect(player.busy, isFalse);
      expect(outputs.single.stopped, isTrue);
      expect(sources.single.closes, 1);
    },
  );
  test('end follows consumed samples and releases playback readers', () async {
    total = 100;
    await player.play('session', current: () => true);
    outputs.single.consume(100);
    await until(() => !player.busy);
    expect(player.presentation.positionUs, 100 * 1000000 ~/ 48000);
    expect(player.presentation.state, MeetingAudioPlaybackState.paused);
    expect(sources.single.closes, 1);
    expect(outputs.single.closes, 1);
  });
  test(
    'one decode is at most five seconds and following ranges retain continuity',
    () async {
      total = 240010;
      capacity = 76800;
      await player.play('session', current: () => true);
      expect(sources.single.ranges.first, (0, 240000));
      while (sources.single.ranges.length == 1) {
        outputs.single.consume(76800);
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(sources.single.ranges.last, (240000, 10));
    },
  );
  test(
    'unconfirmed output close poisons replacement admission and retains owners',
    () async {
      final close = Completer<void>();
      close.future.ignore();
      outputFactory = (generation) => Output(generation)..closeGate = close;
      await player.play('session', current: () => true);
      final pause = player.pause('session', current: () => true);
      pause.ignore();
      close.completeError(StateError('Native exit unconfirmed'));
      await expectLater(pause, throwsStateError);
      expect(player.restartRequired, isTrue);
      expect(player.busy, isTrue);
      await expectLater(
        player.play('other', current: () => true),
        throwsA(anything),
      );
      expect(outputs.length, 1);
      expect(sources.length, 1);
    },
  );
}
