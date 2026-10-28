import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One adapter child at a time. A timeout owns actual termination and reaping;
/// repeated refreshes share the in-flight enumeration instead of adding children.
final class AudioDeviceProcessRunner {
  AudioDeviceProcessRunner({
    this.timeout = const Duration(seconds: 10),
    this.startProcess = Process.start,
  });
  final Duration timeout;
  final Future<Process> Function(String, List<String>) startProcess;
  Future<ProcessResult>? _active;
  bool _restartRequired = false;

  Future<ProcessResult> run(String executable, List<String> arguments) {
    if (_restartRequired) {
      return Future.error(
        StateError(
          'Audio device discovery could not confirm child exit. Restart the application service.',
        ),
      );
    }
    return _active ??= _run(
      executable,
      arguments,
    ).whenComplete(() => _active = null);
  }

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    final process = await startProcess(executable, arguments);
    Stream<List<int>> bounded(Stream<List<int>> stream, int maximum) {
      var received = 0;
      return stream.map((chunk) {
        received += chunk.length;
        if (received > maximum) {
          throw StateError('Audio device adapter output exceeded its limit.');
        }
        return chunk;
      });
    }

    final output = StringBuffer(), errors = StringBuffer();
    final out = bounded(
      process.stdout,
      16 * 1024 * 1024,
    ).transform(utf8.decoder).listen(output.write);
    final error = bounded(
      process.stderr,
      64 * 1024,
    ).transform(utf8.decoder).listen(errors.write);
    try {
      final settled = await Future.wait<Object?>([
        process.exitCode,
        out.asFuture<void>(),
        error.asFuture<void>(),
      ], eagerError: true).timeout(timeout);
      final code = settled.first as int;
      return ProcessResult(
        process.pid,
        code,
        output.toString(),
        errors.toString(),
      );
    } finally {
      try {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(milliseconds: 250));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 2));
        }
      } catch (_) {
        _restartRequired = true;
        throw StateError(
          'Audio device discovery could not confirm child exit. Restart the application service.',
        );
      } finally {
        await out.cancel();
        await error.cancel();
      }
    }
  }
}
