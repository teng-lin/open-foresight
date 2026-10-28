import 'dart:async';
import 'dart:io';

import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart' show addTearDown;

import 'poll.dart';

/// Ordered phase evidence for a fixture.
///
/// A trace records only phases the fixture itself observed. [describe] keeps
/// that separate from [pending], which the caller infers from the observed
/// phase; an inference is never reported as an observation.
final class PhaseTrace {
  PhaseTrace({this.limit = 16});

  /// Oldest entries are dropped beyond this bound.
  final int limit;
  final _clock = Stopwatch()..start();
  final _entries = <(String, Duration)>[];
  var _dropped = 0;

  void enter(String phase) {
    _entries.add((phase, _clock.elapsed));
    if (_entries.length > limit) {
      _entries.removeAt(0);
      _dropped++;
    }
  }

  /// How many older phases were dropped to stay within [limit].
  int get dropped => _dropped;

  /// The most recently observed phase, or null before the first.
  String? get last => _entries.isEmpty ? null : _entries.last.$1;

  List<String> get phases => [for (final entry in _entries) entry.$1];

  String describe({String? pending}) {
    final latest = _entries.isEmpty ? null : _entries.last;
    final observed = latest == null
        ? 'last observed phase: none'
        : 'last observed phase: ${latest.$1} '
              '(+${latest.$2.inMilliseconds}ms of ${_clock.elapsed.inMilliseconds}ms)';
    final earlier = _dropped == 0 ? '' : '(+$_dropped earlier) > ';
    final path = _entries.isEmpty
        ? ''
        : '; path: $earlier${phases.join(' > ')}';
    final inferred = pending == null
        ? ''
        : '; inferred pending (not observed): $pending';
    return '$observed$path$inferred';
  }
}

/// One failed cleanup step, kept so a later failure cannot replace it.
final class CleanupStepFailure {
  CleanupStepFailure(this.step, this.error, this.stackTrace);
  final String step;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => '$step: ${error.runtimeType}: $error';
}

/// Every cleanup failure from one [OwnedCleanups.run], in execution order.
final class FixtureCleanupFailure implements Exception {
  FixtureCleanupFailure(this.failures);
  final List<CleanupStepFailure> failures;

  @override
  String toString() =>
      'Fixture cleanup failed in ${failures.length} step(s):\n'
      '${failures.join('\n')}';
}

/// Cleanup registered at allocation and run in reverse dependency order.
///
/// Register each step immediately after the resource exists, so a failure
/// during the rest of setup still releases it. [run] always attempts every
/// step, bounds each by [stepTimeout], and reports all failures together.
/// [OwnedCleanups.forTest] runs once at the current test's teardown; create it
/// before the resources it owns, since teardowns run in reverse registration.
final class OwnedCleanups {
  OwnedCleanups({this.stepTimeout = const Duration(seconds: 5)});

  factory OwnedCleanups.forTest({
    Duration stepTimeout = const Duration(seconds: 5),
  }) {
    final cleanups = OwnedCleanups(stepTimeout: stepTimeout);
    addTearDown(cleanups.run);
    return cleanups;
  }

  final Duration stepTimeout;
  final _steps = <(String, FutureOr<void> Function())>[];

  void add(String step, FutureOr<void> Function() cleanup) =>
      _steps.add((step, cleanup));

  /// Steps registered and not yet run.
  List<String> get pending => [for (final step in _steps) step.$1];

  /// Run pending steps newest first. Throws [FixtureCleanupFailure] after all
  /// steps were attempted. A hung step is abandoned at [stepTimeout].
  Future<void> run() async {
    final failures = <CleanupStepFailure>[];
    while (_steps.isNotEmpty) {
      final (name, cleanup) = _steps.removeLast();
      try {
        await Future.sync(cleanup).timeout(
          stepTimeout,
          onTimeout: () => throw TimeoutException(
            'cleanup step exceeded its bound',
            stepTimeout,
          ),
        );
      } catch (error, stack) {
        failures.add(CleanupStepFailure(name, error, stack));
      }
    }
    if (failures.isNotEmpty) throw FixtureCleanupFailure(failures);
  }
}

/// A child process this fixture started and is responsible for ending.
///
/// It delegates to the real [Process], so it can be handed to production code
/// that expects one. Signals go only to this handle, and never after its exit
/// was observed, so a reused pid is not signaled.
final class OwnedProcess implements Process {
  OwnedProcess._(this._process, this.name) {
    _process.exitCode.then((code) => _exitStatus = code).ignore();
  }

  final Process _process;
  final String name;
  int? _exitStatus;

  /// The kernel exit status once its exit was observed, else null.
  int? get exitStatus => _exitStatus;
  bool get hasExited => _exitStatus != null;

  @override
  int get pid => _process.pid;
  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  IOSink get stdin => _process.stdin;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      hasExited ? false : _process.kill(signal);

  /// End the child within [grace] + [reap]: SIGTERM, then SIGKILL, then wait
  /// for the kernel exit. SIGKILL ends a stopped or TERM-ignoring child. An
  /// already-exited child is a success; no signal is sent. Throws if the exit
  /// is not observed, instead of reporting an unreaped child as clean.
  Future<int> terminate({
    Duration grace = const Duration(seconds: 2),
    Duration reap = const Duration(seconds: 2),
  }) async {
    if (!hasExited) {
      _process.kill(ProcessSignal.sigterm);
      try {
        return await _process.exitCode.timeout(grace);
      } on TimeoutException {
        // Escalate below.
      }
      if (!hasExited) _process.kill(ProcessSignal.sigkill);
    }
    try {
      return await _process.exitCode.timeout(reap);
    } on TimeoutException {
      throw StateError(
        'Owned child "$name" (pid $pid) was not reaped within $reap of SIGKILL',
      );
    }
  }
}

/// Starts and tracks the children one fixture owns.
///
/// Only processes started here are tracked, signaled or reported. Nothing is
/// discovered through `ps` or process groups, so unrelated processes (and
/// other test files running concurrently) are never inspected.
final class OwnedProcesses {
  OwnedProcesses(this._cleanups);

  /// Tracks processes in the current test; terminated at its teardown.
  factory OwnedProcesses.forTest() => OwnedProcesses(OwnedCleanups.forTest());

  final OwnedCleanups _cleanups;
  final _started = <OwnedProcess>[];

  List<OwnedProcess> get started => List.unmodifiable(_started);

  /// Owned children whose exit has not been observed.
  List<OwnedProcess> get running => [
    for (final process in _started)
      if (!process.hasExited) process,
  ];

  /// Start a child and register its termination before returning it.
  Future<OwnedProcess> start(
    String executable,
    List<String> arguments, {
    String? name,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      workingDirectory: workingDirectory,
    );
    return adopt(process, name: name ?? executable);
  }

  /// Take ownership of a process the fixture started itself.
  OwnedProcess adopt(Process process, {required String name}) {
    final owned = OwnedProcess._(process, name);
    _started.add(owned);
    _cleanups.add('terminate $name (pid ${process.pid})', owned.terminate);
    return owned;
  }

  /// Fail naming any owned child whose exit is unobserved.
  void expectNoneRunning({String? reason}) {
    final left = running;
    if (left.isEmpty) return;
    fail(
      '${reason ?? 'Owned children left running'}: '
      '${left.map((p) => '${p.name} (pid ${p.pid})').join(', ')}',
    );
  }

  /// Terminate every owned child and any other registered cleanup now.
  Future<void> close() => _cleanups.run();
}

/// Wait for a fixture's marker file within [timeout].
///
/// Failure names the marker and, when given, the [trace]'s last observed phase,
/// the inferred [pending] operation and whether the [owner] child already
/// exited. The deadline is exactly [timeout].
Future<void> awaitMarker(
  File marker, {
  Duration timeout = const Duration(seconds: 5),
  PhaseTrace? trace,
  String? pending,
  OwnedProcess? owner,
}) {
  return eventually(
    marker.existsSync,
    timeout: timeout,
    label: 'marker ${marker.path}',
    describe: () {
      final parts = <String>[
        if (trace != null) trace.describe(pending: pending),
        if (owner != null)
          owner.hasExited
              ? '${owner.name} (pid ${owner.pid}) exited with ${owner.exitStatus}'
              : '${owner.name} (pid ${owner.pid}) still running',
      ];
      return parts.isEmpty ? 'marker absent' : parts.join('; ');
    },
  );
}
