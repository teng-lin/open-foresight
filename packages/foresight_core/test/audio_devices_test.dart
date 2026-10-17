import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/audio_devices.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';

void main() {
  String? previous;
  setUp(() {
    previous = runtimeConfiguration.environment['FORESIGHT_AUDIO_DEVICES'];
    runtimeConfiguration.environment['FORESIGHT_AUDIO_DEVICES'] =
        '/fixture/audio adapter';
  });
  tearDown(() {
    if (previous == null) {
      runtimeConfiguration.environment.remove('FORESIGHT_AUDIO_DEVICES');
    } else {
      runtimeConfiguration.environment['FORESIGHT_AUDIO_DEVICES'] = previous!;
    }
  });

  test(
    'Mac adapter receives exact arguments and preserves IDs, labels and routes',
    () async {
      final devices = await audioDevices(
        macOS: true,
        runProcess: (executable, arguments) async {
          expect(executable, '/fixture/audio adapter');
          expect(arguments, ['--list-devices']);
          return ProcessResult(
            0,
            0,
            jsonEncode([
              {'id': 'output:uid', 'label': 'Speakers 日本語', 'playback': true},
              {
                'id': 'input:uid',
                'label': 'Microphone café',
                'playback': false,
              },
            ]),
            '',
          );
        },
      );
      expect(devices.map((device) => device.name), ['input:uid', 'output:uid']);
      expect(devices.map((device) => device.label), [
        'Microphone café',
        'Speakers 日本語',
      ]);
      expect(devices.map((device) => device.playback), [false, true]);
    },
  );

  test('missing Mac adapter fails without launching a process', () async {
    runtimeConfiguration.environment.remove('FORESIGHT_AUDIO_DEVICES');
    await expectLater(
      audioDevices(
        macOS: true,
        runProcess: (_, _) async {
          fail('No process should launch without a configured adapter');
        },
      ),
      throwsStateError,
    );
  });

  test(
    'PipeWire discovery filters non-audio and incomplete records and sorts descriptions',
    () async {
      Map<String, dynamic> node(Map<String, dynamic> properties) => {
        'info': {'props': properties},
      };
      final devices = await audioDevices(
        macOS: false,
        runProcess: (executable, arguments) async {
          expect(executable, 'pw-dump');
          expect(arguments, isEmpty);
          return ProcessResult(
            0,
            0,
            jsonEncode([
              {},
              {'info': null},
              {'info': {}},
              {
                'info': {'props': null},
              },
              node({'media.class': 'Video/Source', 'node.name': 'camera'}),
              node({'media.class': 'Audio/Source', 'node.name': 7}),
              node({
                'media.class': 'Audio/Source',
                'node.name': 'microphone',
                'node.description': 'A microphone',
                'node.nick': 'ignored',
              }),
              node({
                'media.class': 'Audio/Sink',
                'node.name': 'speakers',
                'node.nick': 'B speakers',
              }),
              node({'media.class': 'Audio/Source', 'node.name': 'C fallback'}),
              node({
                'media.class': 'Audio/Source',
                'node.name': 'numeric',
                'node.description': 12,
              }),
            ]),
            '',
          );
        },
      );
      expect(devices.map((device) => device.name), [
        'numeric',
        'microphone',
        'speakers',
        'C fallback',
      ]);
      expect(devices.map((device) => device.label), [
        '12',
        'A microphone',
        'B speakers',
        'C fallback',
      ]);
      expect(devices.map((device) => device.playback), [
        false,
        false,
        true,
        false,
      ]);
    },
  );

  for (final macOS in [false, true]) {
    test(
      '${macOS ? 'Mac' : 'PipeWire'} process failure preserves an actionable error',
      () async {
        await expectLater(
          audioDevices(
            macOS: macOS,
            runProcess: (_, _) async =>
                ProcessResult(0, 1, '', 'adapter disconnected'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains(macOS ? 'adapter disconnected' : 'PipeWire'),
            ),
          ),
        );
      },
    );

    test(
      '${macOS ? 'Mac' : 'PipeWire'} rejects malformed JSON and invalid payload shapes',
      () async {
        await expectLater(
          audioDevices(
            macOS: macOS,
            runProcess: (_, _) async => ProcessResult(0, 0, '{broken', ''),
          ),
          throwsFormatException,
        );
        await expectLater(
          audioDevices(
            macOS: macOS,
            runProcess: (_, _) async => ProcessResult(0, 0, '{}', ''),
          ),
          throwsA(isA<TypeError>()),
        );
        await expectLater(
          audioDevices(
            macOS: macOS,
            runProcess: (_, _) async => ProcessResult(0, 0, '[7]', ''),
          ),
          throwsA(isA<TypeError>()),
        );
      },
    );

    test(
      '${macOS ? 'Mac' : 'PipeWire'} discovery retries after an adapter disappears',
      () async {
        var calls = 0;
        Future<ProcessResult> run(
          String executable,
          List<String> arguments,
        ) async {
          if (++calls == 1)
            throw ProcessException(
              executable,
              arguments,
              'adapter disappeared',
            );
          return ProcessResult(0, 0, '[]', '');
        }

        await expectLater(
          audioDevices(macOS: macOS, runProcess: run),
          throwsA(isA<ProcessException>()),
        );
        expect(await audioDevices(macOS: macOS, runProcess: run), isEmpty);
        expect(calls, 2);
      },
    );
  }
}
