import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_native.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';

import 'diagnostics_owner_ffi.dart' show identity;

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> until(FutureOr<bool> Function() condition) async {
  final clock = Stopwatch()..start();
  while (!await condition()) {
    require(clock.elapsed < const Duration(seconds: 8), 'Owner did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// Every fixture subprocess is joined even on timeout; no Process.run timeout
// can abandon an independently running lock probe or filesystem helper.
Future<ProcessResult> run(String executable, List<String> arguments) async {
  final process = await Process.start(executable, arguments);
  final output = utf8.decoder.bind(process.stdout).join();
  final errors = utf8.decoder.bind(process.stderr).join();
  var exited = false;
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 5));
    exited = true;
    return ProcessResult(process.pid, code, await output, await errors);
  } finally {
    if (!exited) process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5));
    await output.timeout(const Duration(seconds: 2));
    await errors.timeout(const Duration(seconds: 2));
  }
}

Future<bool> locked(String path) async {
  final result =
      await run(Platform.environment['FORESIGHT_PYTHON'] ?? 'python3', [
        '-c',
        'import fcntl,os,sys\n'
            'f=os.open(sys.argv[1],os.O_RDWR)\n'
            'try: fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB); print("FREE")\n'
            'except BlockingIOError: print("BUSY")\n'
            'finally: os.close(f)\n',
        path,
      ]);
  require(result.exitCode == 0, 'Lock probe failed: ${result.stderr}');
  return (result.stdout as String).trim() == 'BUSY';
}

Future<void> main(List<String> args) async {
  final library = args[0],
      launcher = args[1],
      profile = args[2],
      mode = args[3];
  // Original code mapping exists before any profile or SQLite file is opened.
  final functions = DiagnosticNativeFunctions.fromImage(
    DynamicLibrary.open(library),
  );
  Database? database;
  bool? before, after;
  if (mode == 'alias' || mode == 'unsafe-control') {
    final logs = Directory('$profile/logs')..createSync();
    final chmod = await run('chmod', ['700', logs.path]);
    require(chmod.exitCode == 0, 'Private logs directory');
    final path = '$profile/application.db';
    database = openApplicationDatabase(path);
    database.execute('CREATE TABLE held(value INTEGER)');
    database.execute('BEGIN IMMEDIATE');
    final link = await run('ln', [path, '${logs.path}/admission.lock']);
    require(link.exitCode == 0, 'Alias creation');
    before = await locked(path);
    require(before, 'SQLite lock was not held before admission');
  }
  NativeDiagnosticWorkerOwner? owner;
  final session = await LoggingSession.startForTesting(
    configuration: const DiagnosticConfiguration(),
    profilePath: profile,
    sinkFactory: mode == 'unsafe-control' ? DiagnosticStorage.admit : null,
    workerFactory: mode == 'unsafe-control'
        ? null
        : (context) => owner = NativeDiagnosticWorkerOwner(
            context,
            functions,
            resolveCommand: () => DiagnosticStorageCommand(
              nativeId: identity,
              dartId: identity,
              catalogId: identity,
              arguments: [
                launcher,
                identity,
                '$pid',
                Platform.resolvedExecutable,
                '--disable-dart-dev',
                '--packages=${File('.dart_tool/package_config.json').absolute.path}',
                File(
                  'test/fixtures/diagnostics_storage_child.dart',
                ).absolute.path,
                '--diagnostic-storage-worker',
                '$pid',
                '--diagnostic-native-support',
                library,
              ],
            ),
          ),
  );
  try {
    session.expectOwnershipDecision().report(OwnershipDecision.acquired);
    require(
      session.producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.logging,
      ),
      'Producer admission',
    );
    require(
      session.producer.emit(
        DiagnosticEvent.serviceReady,
        DiagnosticComponent.logging,
      ),
      'Second producer admission',
    );
    if (database != null) {
      await until(
        () => session.health.reason != DiagnosticHealthReason.healthy,
      );
      after = await locked('$profile/application.db');
      require(
        after == (mode == 'alias'),
        'Alias changed parent lock ownership',
      );
      database.execute('ROLLBACK');
      database.dispose();
      database = null;
    } else {
      await until(
        () async =>
            session.health.slot != null &&
            (await session.inspectBudgetForTesting()).queuedRecords == 0,
      );
      require(
        session.health.reason == DiagnosticHealthReason.healthy,
        'Storage healthy',
      );
      if (mode == 'idle-death') {
        final deathClock = Stopwatch()..start();
        require(functions.force(1) >= 0, 'Native FORCE');
        await until(
          () =>
              session.health.reason ==
              DiagnosticHealthReason.storageWorkerExited,
        );
        require(owner!.snapshot.childNotLive, 'Actual child exit observed');
        require(
          deathClock.elapsed < const Duration(seconds: 1),
          'Existing 100ms status edge did not observe idle death promptly',
        );
      }
    }
  } finally {
    database?.dispose();
    final clock = Stopwatch()..start();
    final result = await session.close();
    final snapshot = owner?.snapshot;
    stdout.writeln(
      jsonEncode({
        'mode': mode,
        'pid': pid,
        'session': session.identity.value,
        'health': session.health.reason.name,
        'slot': session.health.slot,
        'before': before,
        'after': after,
        'writer_exited': result.writerExited,
        'owner_settled': result.ownerSettled,
        'requires_explicit_exit': result.requiresExplicitExit,
        'flushed': result.flushed,
        'child_not_live': snapshot?.childNotLive,
        'reaped': snapshot?.reaped,
        'close_ms': clock.elapsedMilliseconds,
      }),
    );
    await stdout.flush();
  }
}
