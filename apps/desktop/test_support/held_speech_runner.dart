import 'dart:convert';
import 'dart:io';

/// Observe an actual CLI transcription invocation without changing its PCM,
/// arguments or result. Probes pass through; only -f work waits for release.
final class HeldSpeechRunner {
  HeldSpeechRunner(Directory directory, String runtime)
    : runner = File('${directory.path}/speech-runner'),
      entered = File('${directory.path}/entered'),
      released = File('${directory.path}/released'),
      timedOut = File('${directory.path}/timed-out') {
    runner.writeAsStringSync('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
released = Path(${jsonEncode(released.path)})
entered = Path(${jsonEncode(entered.path)})
if '-f' in args and not released.exists():
    index = args.index('-f') + 1
    if index >= len(args) or Path(args[index]).stat().st_size <= 0:
        sys.exit(121)
    os.umask(0o077)
    partial = entered.with_name(entered.name + '.' + str(os.getpid()))
    with partial.open('x') as witness:
        witness.write(str(os.getpid()) + '\\n')
    os.replace(partial, entered)
    deadline = time.monotonic() + 45
    while not released.exists():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            Path(${jsonEncode(timedOut.path)}).write_text('timeout\\n')
            sys.exit(124)
        time.sleep(min(0.05, remaining))
os.execv(${jsonEncode(runtime)}, [${jsonEncode(runtime)}, *args])
''');
  }

  final File runner, entered, released, timedOut;

  Future<void> makeExecutable() async {
    final result = await Process.run('chmod', [
      '700',
      runner.parent.path,
      runner.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Cannot prepare owned speech gate: ${result.stderr}');
    }
  }

  bool get hasEntered {
    if (timedOut.existsSync()) throw StateError('Owned speech gate timed out');
    if (!entered.existsSync()) return false;
    final pid = int.tryParse(entered.readAsStringSync().trim());
    if (pid == null || pid <= 0)
      throw StateError('Invalid speech entry witness');
    return true;
  }

  void release() {
    if (!released.existsSync()) released.writeAsStringSync('release\n');
  }

  void assertReleasedBeforeTimeout() {
    if (!hasEntered || !released.existsSync()) {
      throw StateError('Speech gate was not entered and released');
    }
  }
}
