import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/recording.dart';
import 'live_recording_test.dart' show waitFor;

void main() {
  test(
    'real Whisper retains speech across private microphone loss and return',
    () async {
      final env = Platform.environment;
      final sink = 'foresight-live-gap-$pid';
      final source = '$sink-microphone';
      final modules = <String>[];
      final transcripts = <Map<String, Object?>>[];
      final partials = <String>[];
      final gaps = <Map<String, dynamic>>[];
      final states = <String>[];
      Future<String> command(List<String> args) async {
        final result = await Process.run('pactl', args);
        if (result.exitCode != 0) throw StateError('${result.stderr}');
        return result.stdout.toString().trim();
      }

      Future<Map<String, String>> defaults() async => {
        for (final kind in ['sink', 'source'])
          kind: await command(['get-default-$kind']),
      };
      Future<void> addDevices() async {
        modules.add(
          await command([
            'load-module',
            'module-null-sink',
            'sink_name=$sink',
            'channels=1',
            'rate=48000',
            'sink_properties=priority.session=0',
          ]),
        );
        modules.add(
          await command([
            'load-module',
            'module-remap-source',
            'master=$sink.monitor',
            'source_name=$source',
            'channels=1',
            'source_properties=priority.session=0',
          ]),
        );
      }

      Future<void> removeDevices() async {
        for (final module in modules.reversed.toList()) {
          await command(['unload-module', module]);
          modules.remove(module);
        }
      }

      Future<Process> play() async {
        final process = await Process.start('pw-play', [
          '--properties',
          '{ node.dont-fallback = true node.dont-reconnect = true }',
          '--target',
          sink,
          env['FORESIGHT_AUDIO_FIXTURE']!,
        ]);
        // Completion is observed by the owning lifecycle or test fixture.
        // ignore: unawaited_futures
        process.stdout.drain<void>();
        // Completion is observed by the owning lifecycle or test fixture.
        // ignore: unawaited_futures
        process.stderr.drain<void>();
        return process;
      }

      final before = await defaults();
      final recorder = Recording(
        env['FORESIGHT_NATIVE']!,
        states.add,
        (text, start, end, channel) => transcripts.add({
          'text': text,
          'start_ms': start,
          'end_ms': end,
          'source': channel,
        }),
        provisional: (text, _, _, _) {
          if (text.isNotEmpty) partials.add(text);
        },
        interruption: gaps.add,
      );
      Process? player;
      try {
        await addDevices();
        recorder.start(
          env['FORESIGHT_SPEECH_RUNNER']!,
          env['FORESIGHT_SPEECH_MODEL']!,
          playback: false,
          microphoneTarget: source,
        );
        player = await play();
        await waitFor(
          () => partials.isNotEmpty && recorder.sampleCounts.first >= 48000 * 7,
        );
        final samplesAtLoss = recorder.sampleCounts.first;
        await removeDevices();
        await waitFor(() => gaps.isNotEmpty, seconds: 5);
        // Recreate immediately after the native gap, within its retry window.
        await addDevices();
        await waitFor(
          () => recorder.sampleCounts.first > samplesAtLoss + 4800,
          seconds: 8,
        );
        await player.exitCode;
        player = await play();
        expect(await player.exitCode, 0);
        await waitFor(
          () =>
              transcripts.length >= 2 &&
              transcripts.last['end_ms'] as int > samplesAtLoss * 1000 ~/ 48000,
        );
        final beforeStop = List<Map<String, Object?>>.from(transcripts);
        expect(
          beforeStop.first['text'].toString().toLowerCase(),
          contains('fellow'),
        );
        expect(
          beforeStop.last['text'].toString().toLowerCase(),
          contains('country'),
        );
        for (var i = 1; i < beforeStop.length; i++) {
          expect(
            beforeStop[i]['start_ms'] as int,
            greaterThanOrEqualTo(beforeStop[i - 1]['end_ms'] as int),
          );
        }
        expect(recorder.lastError, isEmpty);
        await recorder.stop();
        expect(recorder.captures, isEmpty);
        expect(recorder.speeches, isEmpty);
        await removeDevices();
        final after = await defaults();
        expect(after, before);
        File(env['FORESIGHT_LIVE_GAP_REPORT']!).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'method':
                'Real native/Dart capture, private PipeWire microphone removal/return, actual Whisper and known JFK fixture',
            'final_before_stop': beforeStop,
            'final_after_stop': transcripts,
            'provisional_before_loss': partials.first,
            'gap_events': gaps,
            'captured_samples_at_loss': samplesAtLoss,
            'states': states,
            'nonoverlapping_captured_sample_timeline': true,
            'host_default_audio_devices_preserved': true,
            'physical_spoken_microphone_verified': false,
          }),
        );
      } finally {
        recorder.dispose();
        player?.kill();
        await removeDevices();
      }
    },
    skip: Platform.environment['FORESIGHT_LIVE_GAP_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
