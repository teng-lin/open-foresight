import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/speech_models.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  for (final cpu in [true, false]) {
    test(
      'speech probe owns subprocess and selects ${cpu ? 'CPU' : 'explicit device'} before registration',
      () async {
        final root = createTestTempDirectorySync('speech-probe-boundaries-');
        final environment = Map.of(runtimeConfiguration.environment);
        final store = Store('${root.path}/app.db');
        addTearDown(() {
          store.close();
          runtimeConfiguration.environment
            ..clear()
            ..addAll(environment);
          root.deleteSync(recursive: true);
        });
        final asset = File('${root.path}/model.bin')
          ..writeAsStringSync('fixture model bytes');
        final report = File('${root.path}/probe.json');
        final runner = File('${root.path}/probe-runner')
          ..writeAsStringSync('''#!/usr/bin/env python3
import json,sys,wave
args=sys.argv[1:]
with wave.open(args[args.index('-f')+1], 'rb') as wav:
 info=[wav.getnchannels(),wav.getsampwidth(),wav.getframerate(),wav.getnframes()]
with open(${jsonEncode(report.path)},'w') as output:
 json.dump({'args':args,'audio':info},output)
''');
        expect(
          (await Process.run('/bin/chmod', ['700', runner.path])).exitCode,
          0,
        );
        runtimeConfiguration.environment.remove('FORESIGHT_WHISPER_BACKEND');
        runtimeConfiguration.environment.remove('FORESIGHT_WHISPER_DEVICE');
        if (cpu) {
          runtimeConfiguration.environment['FORESIGHT_WHISPER_BACKEND'] = 'cpu';
        } else {
          runtimeConfiguration.environment['FORESIGHT_WHISPER_DEVICE'] =
              'fixture-device';
        }
        Process? owned;
        await configureSpeech(
          store,
          asset,
          runner.path,
          sha256.convert(asset.readAsBytesSync()).toString(),
          current: () => true,
          onProcess: (process) => owned = process,
        );
        expect(owned, isNotNull);
        expect(await owned!.exitCode, 0);
        final observed = jsonDecode(report.readAsStringSync()) as Map;
        expect(observed['audio'], [1, 2, 16000, 16000]);
        final args = (observed['args'] as List).cast<String>();
        expect(
          args,
          containsAll([
            '-m',
            asset.path,
            '-l',
            'auto',
            '-nt',
            '-np',
            '-t',
            '4',
          ]),
        );
        if (cpu) {
          expect(args, contains('-ng'));
          expect(args, isNot(contains('-dev')));
        } else {
          expect(args, containsAllInOrder(['-dev', 'fixture-device']));
          expect(args, isNot(contains('-ng')));
        }
        expect(File(args[args.indexOf('-f') + 1]).existsSync(), isFalse);
        final previous = Map.of(store.model('speech')!);
        await expectLater(
          configureSpeech(
            store,
            asset,
            '${root.path}/missing-runner',
            'unused',
            current: () => true,
          ),
          throwsStateError,
        );
        expect(store.model('speech'), previous);
      },
    );
  }
}
