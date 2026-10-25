import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';

Future<void> waitFor(bool Function() ready, {int seconds = 40}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  expect(ready(), true, reason: 'Real live transcription timed out');
}

void main() {
  test(
    'real Whisper hypotheses and final segments arrive before Stop on microphone capture',
    () async {
      final env = Platform.environment;
      final finalText = <Map<String, Object?>>[],
          partialText = <Map<String, Object?>>[];
      final states = <String>[];
      var stopped = false, callbacksAfterClose = 0;
      final recorder = Recording(
        env['FORESIGHT_NATIVE']!,
        states.add,
        (text, start, end, source) {
          if (stopped) callbacksAfterClose++;
          finalText.add({
            'text': text,
            'start_ms': start,
            'end_ms': end,
            'source': source,
          });
        },
        provisional: (text, start, end, source) {
          if (text.isNotEmpty)
            partialText.add({
              'text': text,
              'start_ms': start,
              'end_ms': end,
              'source': source,
            });
        },
      );
      try {
        await recorder.start(
          env['FORESIGHT_SPEECH_RUNNER']!,
          env['FORESIGHT_SPEECH_MODEL']!,
          playback: false,
          microphoneTarget: env['FORESIGHT_MICROPHONE_TARGET']!,
        );
        await waitFor(() => recorder.sampleCounts.any((n) => n > 0));
        final player = await Process.start('pw-play', [
          '--target',
          env['FORESIGHT_LIVE_SINK']!,
          env['FORESIGHT_AUDIO_FIXTURE']!,
        ]);
        // Completion is observed by the owning lifecycle or test fixture.
        // ignore: unawaited_futures
        player.stdout.drain<void>();
        // Completion is observed by the owning lifecycle or test fixture.
        // ignore: unawaited_futures
        player.stderr.drain<void>();
        expect(await player.exitCode, 0);
        await waitFor(() => partialText.isNotEmpty && finalText.isNotEmpty);
        expect(recorder.captures, isNotEmpty);
        expect(recorder.finishing, false);
        final beforeStop = List<Map<String, Object?>>.from(finalText);
        expect(
          beforeStop.map((row) => row['text']).join(' ').toLowerCase(),
          contains('country'),
        );
        expect(finalText.every((row) => row['source'] == 'microphone'), true);
        for (var i = 1; i < finalText.length; i++) {
          expect(
            finalText[i]['start_ms'] as int,
            greaterThanOrEqualTo(finalText[i - 1]['end_ms'] as int),
          );
        }
        await recorder.stop();
        stopped = true;
        await Future<void>(() {});
        expect(recorder.timer?.isActive, false);
        expect(callbacksAfterClose, 0);
        expect(recorder.speeches, isEmpty);
        expect(recorder.captures, isEmpty);
        final report = env['FORESIGHT_LIVE_REPORT'];
        if (report != null)
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'workflow':
                  'Real PipeWire virtual microphone -> Whisper rolling hypotheses -> final segments while capture continues',
              'provisional_before_stop': partialText,
              'final_before_stop': beforeStop,
              'final_after_stop': finalText,
              'states': states,
              'callbacks_after_close': callbacksAfterClose,
              'limit':
                  'Known spoken fixture routed to a virtual microphone; physical spoken microphone still requires coordinated acceptance',
            }),
          );
      } finally {
        recorder.dispose();
        await recorder.closed;
      }
    },
    skip: Platform.environment['FORESIGHT_LIVE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
