import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_native.dart';

const identity =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      throw StateError('FFI owner barrier did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> main(List<String> args) async {
  final image = DynamicLibrary.open(args[0]);
  final functions = DiagnosticNativeFunctions.fromImage(image);
  final root = args[1], mode = args[2];
  NativeDiagnosticWorkerOwner? owner;
  final session = await LoggingSession.startForTesting(
    configuration: const DiagnosticConfiguration(),
    profilePath: '$root-profile',
    workerFactory: (context) => owner = NativeDiagnosticWorkerOwner(
      context,
      functions,
      resolveCommand: () => DiagnosticStorageCommand(
        nativeId: identity,
        dartId: identity,
        catalogId: identity,
        arguments: [
          '/fixture-launcher',
          identity,
          '$pid',
          '/fixture-worker',
          root,
          mode,
        ],
      ),
    ),
  );
  if (!session.producer.emit(
    DiagnosticEvent.runtimeFailed,
    DiagnosticComponent.logging,
  )) {
    throw StateError('No producer admission');
  }
  if (mode == 'ack-exit' || mode == 'ack-exit-race') {
    final appends = image.lookupFunction<Int32 Function(), int Function()>(
      'fs_diag_fixture_append_calls',
    );
    await until(() => appends() == 1);
  } else {
    await until(() => File('$root.entered').existsSync());
  }
  final clock = Stopwatch()..start();
  final result = await session.close();
  stdout.writeln(
    jsonEncode({
      'phase': 'close',
      'mode': mode,
      'writer_exited': result.writerExited,
      'owner_settled': result.ownerSettled,
      'requires_explicit_exit': result.requiresExplicitExit,
      'flushed': result.flushed,
      'elapsed_ms': clock.elapsedMilliseconds,
    }),
  );
  await stdout.flush();
  await until(() => owner!.snapshot.parentSettled);
  final count = image.lookupFunction<Int32 Function(), int Function()>(
    'fs_diag_fixture_spawn_calls',
  )();
  stdout.writeln(jsonEncode({'phase': 'settled', 'spawn_calls': count}));
  await stdout.flush();
  // Natural exit requires all actual parent writer/spawn VM owners to exit.
}
