import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/recording.dart';

Future<void> waitFor(bool Function() ready, String label) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 10)) {
      throw StateError('Actual native recording did not settle: $label');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> main(List<String> arguments) async {
  final library = arguments[0], root = Directory(arguments[1]);
  final worker = '${root.path}/speech-worker';
  final rows = <String>[];
  final recording = Recording(
    library,
    (_) {},
    (text, _, _, _) => rows.add(text),
  );
  try {
    await recording.start(worker, '${root.path}/model', playback: false);
    await waitFor(
      () => rows.length == 1 && recording.speeches.isEmpty,
      'first joined segment',
    );
    await File('${root.path}/capture.next').writeAsString('continue');
    await waitFor(
      () => rows.length == 2 && recording.speeches.isEmpty,
      'second joined segment',
    );
    await recording.stop();
    if (rows.join('|') != 'native segment 1|native segment 2' ||
        recording.lastError.isNotEmpty ||
        recording.captures.isNotEmpty ||
        recording.speeches.isNotEmpty ||
        !File('$worker.closed').existsSync() ||
        File('$worker.starts').readAsLinesSync().length != 1 ||
        File('$worker.requests').readAsStringSync() != '2') {
      throw StateError(
        'Actual native recording lost worker reuse or cleanup: $rows ${recording.lastError}',
      );
    }
    print(
      jsonEncode({'segments': rows, 'worker_starts': 1, 'worker_closed': true}),
    );
  } finally {
    recording.dispose();
    await recording.closed;
  }
}
