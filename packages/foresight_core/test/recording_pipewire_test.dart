import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
// Opt-in integration: production Recording/native capture, private PipeWire
// devices, synthetic tones, and an ASR waveform inspector (not a speech model).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:foresight_core/src/recording.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private PipeWire overlap, pause exclusion and pinned route recovery',
    () async {
      // Require a hardware-free private server; never open a host microphone.
      expect(Directory('/dev/snd').existsSync(), false);
      final privateRuntime = Platform.environment['PIPEWIRE_RUNTIME_DIR'];
      expect(privateRuntime, isNotEmpty);
      expect(Platform.environment['XDG_RUNTIME_DIR'], privateRuntime);
      expect(
        Platform.environment['PIPEWIRE_REMOTE'],
        anyOf(isNull, 'pipewire-0'),
      );
      expect(
        Platform.environment['PULSE_SERVER'],
        anyOf(isNull, 'unix:$privateRuntime/pulse/native'),
      );
      final library = Platform.environment['FORESIGHT_NATIVE']!;
      final directory = createTestTempDirectorySync('foresight-pipewire-');
      final prefix = 'foresight-$pid';
      final modules = <String>[];
      final players = <Process>[];
      final rows = <Map<String, Object>>[];
      final gaps = <Map<String, dynamic>>[];
      final states = <String>[];
      final report = <String, Object>{
        'method':
            'Production Dart Recording and native pw-record capture; private virtual devices and synthetic tones; waveform inspector replaces ASR',
        'physical_audio': 'not_run',
        'echo_cancellation_quality': 'not_run',
        'passed': false,
      };
      Recording? recording;
      Future<String> command(String name, List<String> arguments) async {
        final result = await Process.run(name, arguments);
        if (result.exitCode != 0) {
          throw StateError('$name failed: ${result.stderr}');
        }
        return '${result.stdout}'.trim();
      }

      Future<Map<String, String>> defaults() async => {
        for (final kind in ['sink', 'source'])
          kind: await command('pactl', ['get-default-$kind']),
      };
      Future<String> sink(String name) async {
        final id = await command('pactl', [
          'load-module',
          'module-null-sink',
          'sink_name=$name',
          'channels=1',
          'rate=48000',
          'sink_properties=priority.session=0',
        ]);
        modules.add(id);
        return id;
      }

      Future<String> microphone() async {
        final id = await command('pactl', [
          'load-module',
          'module-remap-source',
          'master=$prefix-local.monitor',
          'source_name=$prefix-input',
          'channels=1',
          'source_properties=priority.session=0',
        ]);
        modules.add(id);
        return id;
      }

      Future<void> remove(String id) async {
        await command('pactl', ['unload-module', id]);
        modules.remove(id);
      }

      Future<void> waitFor(bool Function() condition, String message) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        expect(
          condition(),
          true,
          reason: '$message; states=$states gaps=$gaps',
        );
      }

      File tone(int frequency) {
        const rate = 48000, seconds = 30;
        final bytes = ByteData(44 + rate * seconds * 2);
        final header = bytes.buffer.asUint8List();
        header.setRange(0, 4, ascii.encode('RIFF'));
        bytes.setUint32(4, header.length - 8, Endian.little);
        header.setRange(8, 16, ascii.encode('WAVEfmt '));
        bytes.setUint32(16, 16, Endian.little);
        bytes.setUint16(20, 1, Endian.little);
        bytes.setUint16(22, 1, Endian.little);
        bytes.setUint32(24, rate, Endian.little);
        bytes.setUint32(28, rate * 2, Endian.little);
        bytes.setUint16(32, 2, Endian.little);
        bytes.setUint16(34, 16, Endian.little);
        header.setRange(36, 40, ascii.encode('data'));
        bytes.setUint32(40, header.length - 44, Endian.little);
        for (var i = 0; i < rate * seconds; i++) {
          bytes.setInt16(
            44 + i * 2,
            (9000 * sin(2 * pi * frequency * i / rate)).round(),
            Endian.little,
          );
        }
        return File('${directory.path}/$frequency.wav')
          ..writeAsBytesSync(header);
      }

      final tones = {
        for (final f in [0, 437, 997, 1699]) f: tone(f),
      };
      Future<Process> play(String target, int frequency) async {
        final process = await Process.start('pw-play', [
          '--properties',
          '{ node.dont-fallback = true node.dont-reconnect = true }',
          '--target',
          target,
          tones[frequency]!.path,
        ]);
        players.add(process);
        // Consume diagnostics without putting sample data in the report.
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        return process;
      }

      Future<void> stopPlayer(Process player) async {
        player.kill();
        await player.exitCode.timeout(const Duration(seconds: 5));
        players.remove(player);
      }

      Future<void> drainPausedRoutes(List<int> pausedCounts) async {
        final targets = ['$prefix-input', '$prefix-remote'];
        final probes = <Process>[];
        final silencePlayers = <Process>[];
        final files = <File>[];
        final diagnostics = <StringBuffer>[];
        final diagnosticReads = <Future<void>>[];
        final exits = <int, int>{};
        final silenceExits = <int, int>{};
        final offsets = [0, 0], silentSamples = [0, 0];
        final evidence = <String, Object>{};
        report['pause_drain'] = evidence;
        try {
          for (final target in ['$prefix-local', '$prefix-remote']) {
            final player = await play(target, 0);
            final index = silencePlayers.length;
            silencePlayers.add(player);
            unawaited(
              player.exitCode.then<void>((code) => silenceExits[index] = code),
            );
          }
          for (var channel = 0; channel < targets.length; channel++) {
            final file = File('${directory.path}/pause-drain-$channel.raw');
            files.add(file);
            final diagnostic = StringBuffer();
            diagnostics.add(diagnostic);
            final probe = await Process.start('pw-record', [
              '--format',
              's16',
              '--rate',
              '48000',
              '--channels',
              '1',
              '--target',
              targets[channel],
              '--properties',
              '{ ${channel == 1 ? 'stream.capture.sink = true ' : ''}'
                  'node.dont-fallback = true node.dont-reconnect = true }',
              file.path,
            ]);
            probes.add(probe);
            final index = channel;
            unawaited(probe.exitCode.then<void>((code) => exits[index] = code));
            // Like production capture, .raw owns PCM; stdout is diagnostics.
            for (final stream in [probe.stdout, probe.stderr]) {
              diagnosticReads.add(
                stream.transform(utf8.decoder).forEach((text) {
                  final remaining = 4096 - diagnostic.length;
                  if (remaining > 0) {
                    diagnostic.write(
                      text.length > remaining
                          ? text.substring(0, remaining)
                          : text,
                    );
                  }
                }),
              );
            }
          }
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (true) {
            expect(recording!.sampleCounts, pausedCounts);
            expect(recording.captures, isEmpty);
            if (silenceExits.isNotEmpty) {
              throw StateError('Silence playback exited early: $silenceExits');
            }
            for (var channel = 0; channel < probes.length; channel++) {
              if (exits.containsKey(channel)) {
                throw StateError(
                  'Pause drain ${targets[channel]} exited ${exits[channel]}: '
                  '${diagnostics[channel]}',
                );
              }
              final file = files[channel];
              if (file.existsSync()) {
                final input = file.openSync();
                try {
                  input.setPositionSync(offsets[channel]);
                  final length = (input.lengthSync() - offsets[channel]) & ~1;
                  final bytes = ByteData.sublistView(input.readSync(length));
                  for (var i = 0; i < bytes.lengthInBytes; i += 2) {
                    silentSamples[channel] =
                        bytes.getInt16(i, Endian.little).abs() <= 16
                        ? silentSamples[channel] + 1
                        : 0;
                  }
                  offsets[channel] += bytes.lengthInBytes;
                } finally {
                  input.closeSync();
                }
              }
              evidence[targets[channel]] = {
                'samples': offsets[channel] ~/ 2,
                'trailing_silent_samples': silentSamples[channel],
              };
            }
            // Observe 500ms of contiguous downstream PCM, rather than an
            // upstream sink IDLE state that can retain remap-source audio.
            if (silentSamples.every((count) => count >= 24000)) break;
            if (DateTime.now().isAfter(deadline)) {
              throw StateError(
                'Owned capture routes did not drain to silence: $evidence; '
                'diagnostics=$diagnostics',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } finally {
          for (final probe in probes) {
            probe.kill();
          }
          for (final probe in probes) {
            try {
              await probe.exitCode.timeout(const Duration(seconds: 5));
            } on TimeoutException {
              probe.kill(ProcessSignal.sigkill);
              await probe.exitCode.timeout(const Duration(seconds: 5));
            }
          }
          await Future.wait(
            diagnosticReads,
          ).timeout(const Duration(seconds: 5));
          for (final player in silencePlayers) {
            await stopPlayer(player);
          }
          expect(recording!.sampleCounts, pausedCounts);
        }
      }

      final before = await defaults();
      try {
        var localSink = await sink('$prefix-local');
        final remoteSink = await sink('$prefix-remote');
        var localSource = await microphone();
        await eventually(
          () async => (await command('pactl', [
            'list',
            'short',
            'sources',
          ])).contains('$prefix-input'),
          timeout: const Duration(seconds: 10),
        );
        // Establish defaults only inside the caller's dedicated, hardware-free
        // server. This lets the pinned-route check detect accidental fallback.
        await command('pactl', ['set-default-sink', '$prefix-remote']);
        await command('pactl', [
          'set-default-source',
          '$prefix-remote.monitor',
        ]);
        final selectedDefaults = await defaults();
        final inspector = File('${directory.path}/inspect-wave');
        inspector.writeAsStringSync('''#!/usr/bin/python3
import array, math, sys, wave
with wave.open(sys.argv[sys.argv.index('-f') + 1]) as wav:
    rate = wav.getframerate()
    assert rate == 16000 and wav.getnchannels() == 1 and wav.getsampwidth() == 2
    samples = array.array('h', wav.readframes(wav.getnframes()))
    assert len(samples) > 1600 and max(map(abs, samples)) <= 10000, 'Non-PCM data or invalid fixture amplitude'
# Independent spectral inspection of actual captured/resampled PCM. Require
# energy at the candidate frequency; silence must not become a fabricated token.
labels = []
for f in (437, 997, 1699):
    a = sum(x * math.cos(2 * math.pi * f * i / rate) for i, x in enumerate(samples))
    b = sum(x * math.sin(2 * math.pi * f * i / rate) for i, x in enumerate(samples))
    if samples and math.hypot(a, b) / len(samples) > 100:
        labels.append('tone_' + str(f))
print(' '.join(labels))
''');
        await command('chmod', ['700', inspector.path]);
        final model = File('${directory.path}/model')
          ..writeAsStringSync('Waveform inspector fixture; not an ASR model');
        recording = Recording(library, states.add, (text, start, end, source) {
          rows.add({
            'text': text,
            'start': start,
            'end': end,
            'source': source,
          });
        }, interruption: gaps.add);
        recording.start(
          inspector.path,
          model.path,
          microphoneTarget: '$prefix-input',
          playbackTarget: '$prefix-remote',
        );
        var localPlayer = await play('$prefix-local', 437);
        var remotePlayer = await play('$prefix-remote', 997);
        await waitFor(
          () => recording!.peakVolumes.every((v) => v > .05),
          'both overlapping channels receive real PCM',
        );
        await waitFor(
          () => recording!.sampleCounts.every((count) => count >= 96000),
          'two seconds of measured PCM are buffered',
        );
        recording.pause();
        final pausedCounts = List<int>.from(recording.sampleCounts);
        expect(recording.captures, isEmpty);
        await stopPlayer(localPlayer);
        await stopPlayer(remotePlayer);
        localPlayer = await play('$prefix-local', 1699);
        remotePlayer = await play('$prefix-remote', 1699);
        // Observe the full paused playback window and fail on the first leak.
        final pausedWindow = Stopwatch()..start();
        while (pausedWindow.elapsed < const Duration(seconds: 2)) {
          expect(recording.sampleCounts, pausedCounts);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(recording.sampleCounts, pausedCounts);
        await stopPlayer(localPlayer);
        await stopPlayer(remotePlayer);
        await drainPausedRoutes(pausedCounts);
        recording.resume();
        localPlayer = await play('$prefix-local', 437);
        remotePlayer = await play('$prefix-remote', 997);
        await waitFor(
          () => recording!.sampleCounts[0] > pausedCounts[0] + 48000,
          'resume reacquires original microphone route',
        );
        final priorGapCount = gaps.length;
        await remove(localSource);
        await remove(localSink);
        await waitFor(
          () =>
              gaps.skip(priorGapCount).any((g) => g['source'] == 'microphone'),
          'selected microphone loss emits gap',
        );
        // A different live default source is available. A pinned route must not
        // capture it while the selected device is absent.
        final lostCounts = List<int>.from(recording.sampleCounts);
        await waitFor(
          () => recording!.sampleCounts[1] > lostCounts[1] + 48000,
          'remote channel delivers another measured second while microphone is absent',
        );
        expect(recording.sampleCounts[0], lostCounts[0]);
        expect(recording.sampleCounts[1], greaterThan(lostCounts[1]));
        await stopPlayer(localPlayer);
        localSink = await sink('$prefix-local');
        localSource = await microphone();
        localPlayer = await play('$prefix-local', 437);
        await waitFor(
          () => recording!.sampleCounts[0] > lostCounts[0] + 48000,
          'selected route recovers after return',
        );
        await waitFor(
          () =>
              rows.any((row) => row['source'] == 'microphone') &&
              rows.any((row) => row['source'] == 'playback'),
          'both channel transcript fixtures complete',
        );
        await recording.stop();
        expect(rows.where((r) => r['source'] == 'microphone'), isNotEmpty);
        expect(rows.where((r) => r['source'] == 'playback'), isNotEmpty);
        for (final row in rows) {
          expect(
            row['text'],
            row['source'] == 'microphone' ? 'tone_437' : 'tone_997',
          );
        }
        expect(await defaults(), selectedDefaults);
        report.addAll({
          'passed': true,
          'rows': rows,
          'gaps': gaps,
          'paused_sample_counts': pausedCounts,
          'lost_sample_counts': lostCounts,
          'default_routes_preserved_during_capture': true,
          'overlap_channel_isolation': true,
          'paused_marker_excluded': true,
          'pinned_route_did_not_fallback': true,
          'selected_route_recovered': true,
        });
        // Referenced to make explicit that these remain owned until final cleanup.
        expect(modules, containsAll([localSink, localSource, remoteSink]));
      } finally {
        report['rows'] = rows;
        report['gaps'] = gaps;
        report['states'] = states;
        recording?.dispose();
        for (final player in players.toList()) {
          await stopPlayer(player);
        }
        for (final module in modules.reversed.toList()) {
          await remove(module);
        }
        report['initial_defaults'] = before;
        report['final_defaults'] = await defaults();
        expect(report['final_defaults'], before);
        final output = Platform.environment['FORESIGHT_PIPEWIRE_REPORT'];
        if (output != null) {
          File(output).writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          );
        }
        directory.deleteSync(recursive: true);
      }
    },
    skip:
        !(Platform.isLinux &&
            Platform.environment['FORESIGHT_PRIVATE_PIPEWIRE'] == '1'),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
