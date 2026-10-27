import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/foresight_core.dart'
    show ProfilePaths, createPrivateTempDirectory;
// Lifecycle fixtures drive the real wire client and endpoint lookup.
// ignore: implementation_imports
import 'package:foresight_core/src/service.dart'
    show ServiceClient, serviceEndpoint;
import 'package:test_api/scaffolding.dart' show addTearDown;

import 'poll.dart';
import 'test_paths.dart';

/// A disposable directory for a [HookedServiceProcess] profile, by its
/// canonical path. The child resolves FORESIGHT_DATA and records that path,
/// and a record must name the reader's own `profile.data`. On macOS the test
/// roots (/tmp, /var/tmp) are symbolic links, so a profile built from the
/// uncanonical path would reject the child's record as another profile's.
Directory createServiceTestDirectorySync(String prefix) =>
    Directory(createTestTempDirectorySync(prefix).resolveSymbolicLinksSync());

/// Test-side control of `serviceGate` points in one gate directory.
///
/// A service reaching a point publishes `<point>.reached` (its pid). It waits
/// there only if the point was armed with [hold], until [release] or
/// [releaseAll]. Releases are sticky: later arrivals pass straight through
/// until the point is armed again.
///
/// `<point>.reached` names only the latest arrival. When an owner and the
/// services a launcher starts share one directory, pass `pid` to [reached],
/// or give the launcher its own [ServiceGates].
class ServiceGates {
  ServiceGates(this.directory);
  final Directory directory;

  static Future<ServiceGates> create(Directory parent) async {
    final directory = Directory('${parent.path}/gates');
    await directory.create();
    return ServiceGates(directory);
  }

  /// Arm [point]; set this before the service can reach it. Arming clears an
  /// earlier arrival and release, so [reached] cannot report a stale one.
  void hold(String point) {
    for (final stale in ['$point.reached', '$point.release']) {
      final file = File('${directory.path}/$stale');
      if (file.existsSync()) file.deleteSync();
    }
    _touch('$point.hold');
  }

  void release(String point) => _touch('$point.release');

  /// Release every point, now and later. Teardown calls this before stopping.
  void releaseAll() => _touch('release-all');

  bool isReached(String point) =>
      File('${directory.path}/$point.reached').existsSync();

  /// The pid of the latest process to reach [point], or, with [pid], wait
  /// for that process to reach it. The timeout only bounds the wait; it is
  /// not part of what a test asserts.
  Future<int> reached(
    String point, {
    int? pid,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final file = File('${directory.path}/$point.reached');
    int? arrival() =>
        file.existsSync() ? int.tryParse(file.readAsStringSync()) : null;
    await eventually(() {
      final found = arrival();
      return found != null && (pid == null || found == pid);
    }, timeout: timeout);
    return arrival()!;
  }

  /// Every point reached so far, for diagnostics and hook-free checks.
  List<String> get reachedPoints => [
    for (final entry in directory.listSync())
      if (entry.path.endsWith('.reached'))
        entry.uri.pathSegments.last.replaceFirst(RegExp(r'\.reached$'), ''),
  ]..sort();

  void _touch(String name) =>
      File('${directory.path}/$name').writeAsStringSync('');
}

/// Source fixture authority is selected at compilation, before runtime lookups.
/// The default remains context-only. [verifiedWorker] requires a prebuilt,
/// matching AOT worker and forwards only the producer's verified define vector;
/// it never invents identities, builds a shared worker, or falls back on failure.
Future<List<String>> sourceServiceCompileDefines({
  bool verifiedWorker = false,
}) async {
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:foresight_core/foresight_core.dart'),
  );
  if (library == null) throw StateError('Cannot locate foresight_core');
  final root = File(library.toFilePath()).parent.parent.path;
  final checkout = Directory('$root/../..').resolveSymbolicLinksSync();
  final build = Directory(
    Platform.environment['FORESIGHT_BUILD_DIR'] ?? '$checkout/build',
  ).resolveSymbolicLinksSync();
  if (verifiedWorker) {
    final temporary = await createPrivateTempDirectory(
      shortTestTempRoot,
      'of-defines-',
    );
    try {
      final output = File('${temporary.path}/defines');
      final sdk = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
      final result = await Process.run(
        Platform.environment['FORESIGHT_PYTHON'] ?? 'python3',
        [
          '$checkout/tools/build_diagnostic_worker.py',
          '--root',
          checkout,
          '--build',
          build,
          '--sdk',
          File(sdk).parent.parent.path,
          '--package-config',
          '$root/.dart_tool/package_config.json',
          '--mode',
          'aot',
          '--verify',
          '--defines-output',
          output.path,
        ],
      ).timeout(const Duration(seconds: 300));
      if (result.exitCode != 0) {
        throw StateError(
          'Cannot verify source worker: ${result.stdout}${result.stderr}',
        );
      }
      final values = utf8.decode(await output.readAsBytes()).split('\u0000');
      if (values.length < 2 ||
          values.last.isNotEmpty ||
          values
              .take(values.length - 1)
              .any((value) => !value.startsWith('-D'))) {
        throw StateError('Invalid verified source worker defines');
      }
      return values.take(values.length - 1).toList();
    } finally {
      await temporary.delete(recursive: true);
    }
  }
  return [
    '-DFORESIGHT_DIAGNOSTIC_TEST_CONTEXT=true',
    '-DFORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR=$checkout',
    '-DFORESIGHT_DIAGNOSTIC_BUILD_ROOT=$build',
  ];
}

/// The real `bin/service.dart` compiled once, normally with
/// `-DFORESIGHT_ENABLE_TEST_HOOKS=true`. `dart compile kernel` evaluates the
/// define at compile time, so the child keeps its test hooks however the
/// test runner itself was started. Compile in `setUpAll` and [dispose] in
/// `tearDownAll`. Requires the Dart VM (`dart test`), not flutter_tester.
class HookedServiceBuild {
  HookedServiceBuild._(this.directory, this.kernel, this.testHooks);
  final Directory directory;
  final String kernel;
  final bool testHooks;

  static Future<HookedServiceBuild> compile({
    bool testHooks = true,
    String entryPoint = 'bin/service.dart',
  }) async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:foresight_core/foresight_core.dart'),
    );
    if (library == null) throw StateError('Cannot locate foresight_core');
    final root = File(library.toFilePath()).parent.parent.path;
    final packages =
        (await Isolate.packageConfig)?.toFilePath() ??
        '$root/.dart_tool/package_config.json';
    final directory = await createPrivateTempDirectory(
      shortTestTempRoot,
      'of-build-',
    );
    final kernel = '${directory.path}/service.dill';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      if (testHooks) '-DFORESIGHT_ENABLE_TEST_HOOKS=true',
      ...await sourceServiceCompileDefines(),
      '--packages=$packages',
      '$root/$entryPoint',
      '-o',
      kernel,
    ]);
    if (result.exitCode != 0) {
      await directory.delete(recursive: true);
      throw StateError(
        'Cannot compile $entryPoint: ${result.stdout}${result.stderr}',
      );
    }
    return HookedServiceBuild._(directory, kernel, testHooks);
  }

  /// A FORESIGHT_SERVICE executable for `ensureService`. Each launch records
  /// its pid, appends its output to a log, and uses [gates] when given. The
  /// current test's teardown stops every launched service.
  Future<ServiceLauncher> launcher(
    Directory directory, {
    ServiceGates? gates,
  }) async {
    final launches = File('${directory.path}/launched-pids');
    final log = File('${directory.path}/launched.log');
    final script = File('${directory.path}/launch-service')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        // exec keeps this pid, so the record names the service itself.
        'printf \'%s\\n\' "\$\$" >> ${_quote(launches.path)}\n'
        '${testHooks ? 'FORESIGHT_TEST_DESKTOP_EXECUTABLE=${_quote(Platform.resolvedExecutable)}; export FORESIGHT_TEST_DESKTOP_EXECUTABLE\n' : ''}'
        '${gates == null ? '' : 'FORESIGHT_SERVICE_GATES=${_quote(gates.directory.path)}; export FORESIGHT_SERVICE_GATES\n'}'
        'exec ${_quote(Platform.resolvedExecutable)} ${_quote(kernel)} "\$@" '
        '>> ${_quote(log.path)} 2>&1\n',
      );
    final protect = await Process.run('/bin/chmod', ['700', script.path]);
    if (protect.exitCode != 0) {
      throw StateError('Cannot make ${script.path} executable');
    }
    final launcher = ServiceLauncher._(
      script.path,
      launches,
      log,
      gates,
      kernel,
    );
    addTearDown(launcher.stopAll);
    return launcher;
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

/// Services started by `ensureService` through a [HookedServiceBuild.launcher].
class ServiceLauncher {
  ServiceLauncher._(
    this.executable,
    this._launches,
    this.log,
    this.gates,
    this._kernel,
  );

  /// Set `FORESIGHT_SERVICE` to this.
  final String executable;
  final File _launches;
  final File log;

  /// The gates every launched service uses, if any.
  final ServiceGates? gates;
  final String _kernel;

  /// Pids of every launched service, in launch order.
  List<int> get launched => _launches.existsSync()
      ? [for (final line in _launches.readAsLinesSync()) int.parse(line)]
      : const [];

  /// Release the launch gates, SIGTERM every launched service still running
  /// and wait for it to exit, then SIGKILL any that do not. Detached launches
  /// are not our children, so this polls their process state.
  Future<void> stopAll({Duration timeout = const Duration(seconds: 30)}) async {
    if (gates?.directory.existsSync() ?? false) gates!.releaseAll();
    // Never signal a reused pid: it must still run this build's service.
    Future<bool> ours(int pid) async =>
        (await _command(pid))?.contains(_kernel) ?? false;
    for (final pid in launched) {
      if (!await ours(pid)) continue;
      Process.killPid(pid, ProcessSignal.sigterm);
      try {
        await eventually(() async => !await ours(pid), timeout: timeout);
      } catch (_) {
        if (await ours(pid)) Process.killPid(pid, ProcessSignal.sigkill);
        await eventually(() async => !await ours(pid), timeout: timeout);
      }
    }
  }
}

/// Whether [pid] is a live process (a zombie counts as gone).
Future<bool> isRunning(int pid) async {
  final result = await Process.run('/bin/ps', ['-p', '$pid', '-o', 'stat=']);
  final state = result.stdout.toString().trim();
  return result.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
}

/// The command line of a live (non-zombie) [pid], or null.
Future<String?> _command(int pid) async {
  if (!await isRunning(pid)) return null;
  final result = await Process.run('/bin/ps', ['-p', '$pid', '-o', 'command=']);
  final command = result.stdout.toString().trim();
  return result.exitCode == 0 && command.isNotEmpty ? command : null;
}

/// A real application service process: `bin/service.dart`, hence
/// `IsolatedApplicationService`, from a [HookedServiceBuild].
///
/// ```dart
/// final owner = await HookedServiceProcess.start(build, profile,
///     hold: ['close.before_record_delete']);
/// await owner.ready();
/// owner.signal(ProcessSignal.sigterm);
/// await owner.reached('close.before_record_delete');
/// // ... observe the service at that moment ...
/// owner.release('close.before_record_delete');
/// expect(await owner.exitCode, 0);
/// ```
class HookedServiceProcess {
  HookedServiceProcess._(this.process, this.profile, this.gates, this._owned);

  final Process process;
  final ProfilePaths profile;
  final ServiceGates gates;
  final Directory? _owned;
  final _output = StringBuffer();

  int get pid => process.pid;
  Future<int> get exitCode => process.exitCode;

  /// Everything the service wrote to stdout and stderr so far.
  String get output => _output.toString();

  /// Start the service for [profile]. Only non-`FORESIGHT_` variables are
  /// inherited, together with the qualified application SQLite library;
  /// [environment] adds or overrides service configuration. The
  /// helper is disabled unless [environment] sets `FORESIGHT_HELPER`. The
  /// current test's teardown calls [stop].
  static Future<HookedServiceProcess> start(
    HookedServiceBuild build,
    ProfilePaths profile, {
    Map<String, String> environment = const {},
    ServiceGates? gates,
    Iterable<String> hold = const [],
  }) async {
    final owned = gates == null
        ? await createPrivateTempDirectory(shortTestTempRoot, 'of-gates-')
        : null;
    final control = gates ?? await ServiceGates.create(owned!);
    hold.forEach(control.hold);
    final process = await Process.start(
      Platform.resolvedExecutable,
      [build.kernel],
      environment: {
        for (final entry in Platform.environment.entries)
          if (!entry.key.startsWith('FORESIGHT_') ||
              entry.key == 'FORESIGHT_SQLITE_LIBRARY')
            entry.key: entry.value,
        'FORESIGHT_DATA': profile.data,
        'FORESIGHT_RUNTIME': profile.runtime,
        'FORESIGHT_HELPER': '',
        'FORESIGHT_SERVICE_GATES': control.directory.path,
        if (build.testHooks)
          'FORESIGHT_TEST_DESKTOP_EXECUTABLE': Platform.resolvedExecutable,
        ...environment,
      },
      includeParentEnvironment: false,
    );
    final service = HookedServiceProcess._(process, profile, control, owned);
    for (final stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).listen(service._output.write);
    }
    addTearDown(service.stop);
    return service;
  }

  /// Wait until this process answers status at the profile's endpoint.
  Future<void> ready({Duration timeout = const Duration(seconds: 90)}) async {
    var exited = false;
    unawaited(exitCode.then((_) => exited = true));
    final record = File('${profile.data}/.application-endpoint.json');
    await eventually(() async {
      if (exited) throw StateError('Service exited during startup:\n$output');
      // The record precedes the public socket; skip the costlier lookup.
      if (!record.existsSync()) return false;
      try {
        final client = await ServiceClient.connect(serviceEndpoint(profile));
        try {
          final status = await client
              .call('status')
              .timeout(const Duration(seconds: 10));
          return (status as Map)['pid'] == pid;
        } finally {
          await client.close();
        }
      } on Object {
        return false;
      }
    }, timeout: timeout);
  }

  void hold(String point) => gates.hold(point);
  void release(String point) => gates.release(point);

  /// Wait for this process to reach [point]; returns its pid.
  Future<int> reached(String point) => gates.reached(point, pid: pid);

  /// The exit code, waiting at most [timeout] (a bound, not an assertion).
  Future<int> exited({Duration timeout = const Duration(seconds: 60)}) =>
      exitCode.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'Service $pid did not exit within $timeout:\n$output',
        ),
      );

  void signal(ProcessSignal signal) => process.kill(signal);

  /// Release every gate, SIGTERM, and return the exit code. SIGKILL only if
  /// the service does not exit within [timeout].
  Future<int> stop({Duration timeout = const Duration(seconds: 30)}) async {
    if (gates.directory.existsSync()) gates.releaseAll();
    process.kill(ProcessSignal.sigterm);
    try {
      return await exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return await exitCode.timeout(timeout);
    } finally {
      if (_owned != null && _owned.existsSync()) {
        _owned.deleteSync(recursive: true);
      }
    }
  }
}

String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
