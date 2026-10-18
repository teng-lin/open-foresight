import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CaptureProcessTimeout extends TimeoutException {
  final int pid;
  CaptureProcessTimeout(this.pid, Duration timeout)
    : super('Capture process $pid exceeded its deadline', timeout);
}

/// Drain both pipes while the owned child runs, and kill and reap on timeout.
Future<ProcessResult> runCaptureProcess(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final elapsed = Stopwatch()..start();
  final process = await Process.start(executable, arguments);
  final output = StringBuffer(), errors = StringBuffer();
  final outputDone = Completer<void>(), errorsDone = Completer<void>();
  Object? pipeError;
  void finish(Completer<void> done) {
    if (!done.isCompleted) done.complete();
  }

  final outputSubscription = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        output.write,
        onDone: () => finish(outputDone),
        onError: (Object error) {
          pipeError = error;
          finish(outputDone);
        },
        cancelOnError: true,
      );
  final errorsSubscription = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        errors.write,
        onDone: () => finish(errorsDone),
        onError: (Object error) {
          pipeError = error;
          finish(errorsDone);
        },
        cancelOnError: true,
      );
  final drained = Future.wait([outputDone.future, errorsDone.future]);
  Duration remaining() {
    final budget = timeout - elapsed.elapsed;
    return budget > Duration.zero ? budget : Duration.zero;
  }

  int? exitCode;
  try {
    exitCode = await process.exitCode.timeout(remaining());
    await drained.timeout(remaining());
    if (pipeError != null) throw StateError('Capture pipe failed: $pipeError');
    return ProcessResult(
      process.pid,
      exitCode,
      output.toString(),
      errors.toString(),
    );
  } on TimeoutException {
    throw CaptureProcessTimeout(process.pid, timeout);
  } finally {
    if (exitCode == null) process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } finally {
      await Future.wait([
        outputSubscription.cancel(),
        errorsSubscription.cancel(),
      ]).timeout(const Duration(seconds: 2));
    }
  }
}
