import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/gemma_download.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/application_services/model_asset_acquisition.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/fixture_ownership.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Wait up to five seconds for a fixture marker; a timeout names the marker.
Future<void> reached(File marker) => awaitMarker(marker);

Future<File> heldPipeWorker(
  Directory root, {
  bool stderrOnly = false,
  bool skipConfiguration = false,
}) async {
  final worker = File('${root.path}/transport-worker');
  final python = Platform.environment['FORESIGHT_PYTHON'] ?? '/usr/bin/python3';
  worker.writeAsStringSync('''#!$python
import os,pathlib,signal,subprocess,sys,threading,time
root=pathlib.Path(__file__)
def cleanup():
 deadline=time.monotonic()+20
 while not pathlib.Path(str(root)+'.cleanup').exists():
  if time.monotonic()>deadline:break
  time.sleep(.005)
 os._exit(0)
threading.Thread(target=cleanup,daemon=True).start()
if '--held-output-child' in sys.argv:
 pathlib.Path(str(root)+'.pipe-entered').write_text(str(os.getpid()))
 deadline=time.monotonic()+20
 while not pathlib.Path(str(root)+'.release').exists():
  if time.monotonic()>deadline:sys.exit(3)
  time.sleep(.005)
 try:
  for _ in range(128):
   os.write(${stderrOnly ? 2 : 1},b'!'*4096)
   time.sleep(.005)
 except BrokenPipeError:
  pathlib.Path(str(root)+'.pipe-closed').write_text('closed')
  os._exit(0)
 sys.exit(4)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
if not ${skipConfiguration ? 'True' : 'False'}:sys.stdin.buffer.read()
subprocess.Popen([sys.executable,__file__,'--held-output-child'],stdin=subprocess.DEVNULL,stdout=${stderrOnly ? 'subprocess.DEVNULL' : 'None'})
${stderrOnly ? 'os.close(1)' : ''}
pathlib.Path(str(root)+'.leader-entered').write_text(str(os.getpid()))
while True:time.sleep(.1)
''');
  final mode = await Process.run('/bin/chmod', ['700', worker.path]);
  expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
  return worker;
}

Future<void> fixtureDescendantStopped(File worker) async {
  final marker = File('${worker.path}.pipe-entered');
  if (!marker.existsSync()) return;
  final child = int.parse(marker.readAsStringSync());
  final elapsed = Stopwatch()..start();
  while (true) {
    // A zombie has closed its descriptors but may await an external reaper in
    // a job container. Observe stopped state; never signal a potentially reused
    // PID or claim that the test reaped a descendant it does not own.
    final observed = await Process.run('/bin/ps', [
      '-o',
      'stat=',
      '-p',
      '$child',
    ]).timeout(const Duration(seconds: 2));
    expect(
      observed.exitCode,
      anyOf(0, 1),
      reason: '${observed.stdout}\n${observed.stderr}',
    );
    final state = (observed.stdout as String).trim();
    if (state.isEmpty || state.startsWith('Z')) return;
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      throw TestFailure('Fixture descendant is still running after cleanup');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Worker that publishes `.stdin-closed` once it has closed the inherited
/// configuration pipe, then idles. With [closesStdin] false it never publishes,
/// which models a worker that did not reach the barrier. [startupDelay] holds
/// the worker before it closes stdin, deterministically modeling a cold start.
Future<File> closedStdinWorker(
  Directory root, {
  bool closesStdin = true,
  Duration startupDelay = Duration.zero,
}) async {
  final worker = File('${root.path}/transport-worker');
  final python = Platform.environment['FORESIGHT_PYTHON'] ?? '/usr/bin/python3';
  worker.writeAsStringSync('''#!$python
import os,pathlib,time
time.sleep(${startupDelay.inMilliseconds / 1000})
${closesStdin ? 'os.close(0)' : ''}
${closesStdin ? "pathlib.Path(__file__+'.stdin-closed').write_text('closed')" : ''}
time.sleep(20)
''');
  final mode = await Process.run('/bin/chmod', ['700', worker.path]);
  expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
  return worker;
}

/// Start [command] as a child owned by [owned] and hold it until it reports
/// the closed configuration pipe. The child is registered for termination at
/// allocation; a failed barrier also reaps it before the failure propagates,
/// and names the last observed phase rather than only the marker.
Future<OwnedProcess> launchAtClosedStdin(
  OwnedProcesses owned,
  File worker,
  List<String> command,
  PhaseTrace trace, {
  required String name,
  Duration barrier = const Duration(seconds: 5),
  void Function()? entered,
}) async {
  final marker = File('${worker.path}.stdin-closed');
  if (marker.existsSync()) marker.deleteSync();
  trace.enter('launching');
  final process = await owned.start(
    command.first,
    command.skip(1).toList(),
    name: name,
    includeParentEnvironment: false,
  );
  trace.enter('launched');
  process.exitCode.then((_) => trace.enter('exited')).ignore();
  try {
    await awaitMarker(
      marker,
      timeout: barrier,
      trace: trace,
      pending: 'worker closing its inherited stdin',
      owner: process,
    );
    trace.enter('stdin-closed');
    entered?.call();
    return process;
  } catch (_) {
    // Reap before the failure propagates. A failed reap is not raised here, so
    // it cannot mask the barrier failure: the step registered at allocation
    // repeats the termination at teardown and reports its failure beside it.
    await process.terminate().then<void>((_) {}, onError: (Object _) {});
    rethrow;
  }
}

GemmaModel controlModel() => GemmaModel(
  'fixture',
  'fixture/model',
  'revision',
  'fixture.bin',
  List.filled(64, 'a').join(),
  4,
  0,
);

class ProcessView implements Process {
  ProcessView(this.process);
  final Process process;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  int get pid => process.pid;
  @override
  IOSink get stdin => process.stdin;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      process.kill(signal);
}

// Real pipes and a real, reaped child; only its exit acknowledgement is withheld.
class HeldExitAcknowledgement extends ProcessView {
  HeldExitAcknowledgement(super.process);
  final observed = Completer<void>();
  final acknowledgement = Completer<int>();
  @override
  Future<int> get exitCode {
    if (!observed.isCompleted) observed.complete();
    return acknowledgement.future;
  }
}

// Cancel the real reader first, then hold only its cancellation acknowledgement.
class HeldReaderAcknowledgement extends ProcessView {
  HeldReaderAcknowledgement(super.process) {
    _output = StreamController<List<int>>(sync: true);
    _output.onListen = () {
      _subscription = process.stdout.listen(
        _output.add,
        onError: _output.addError,
        onDone: () => _output.close().ignore(),
      );
    };
    _output.onPause = () => _subscription?.pause();
    _output.onResume = () => _subscription?.resume();
    _output.onCancel = () async {
      await _subscription?.cancel();
      if (!observed.isCompleted) observed.complete();
      await acknowledgement.future;
    };
  }
  late final StreamController<List<int>> _output;
  StreamSubscription<List<int>>? _subscription;
  final observed = Completer<void>();
  final acknowledgement = Completer<void>();
  @override
  Stream<List<int>> get stdout => _output.stream;
}

Future<Process> launchAtBarrier(
  OwnedProcesses owned,
  List<String> command,
  File worker,
  void Function(Process process) atBarrier,
) async {
  final process = await owned.start(
    command.first,
    command.skip(1).toList(),
    name: 'held-pipe worker',
    includeParentEnvironment: false,
  );
  try {
    await reached(File('${worker.path}.leader-entered'));
    await reached(File('${worker.path}.pipe-entered'));
    atBarrier(process);
    return process;
  } catch (_) {
    // Reap before the failure propagates; a failed reap is repeated and
    // reported by the cleanup registered at launch, not raised over this one.
    await process.terminate().then<void>((_) {}, onError: (Object _) {});
    rethrow;
  }
}

/// Wait for the worker to report its closed configuration pipe, observing the
/// download immediately. Launch time is setup, bounded by [budget]; it is not
/// evidence about retirement.
Future<void> awaitClosedStdinSetup(
  Future<Object?> download,
  Completer<void> entered,
  PhaseTrace trace,
  String id, {
  required Duration budget,
}) {
  final outcome = download.then<Object?>(
    (value) => value,
    onError: (Object error) => error,
  );
  return Future.any<void>([
    entered.future,
    outcome.then<void>((value) {
      if (!entered.isCompleted) {
        throw TestFailure(
          'Closed-stdin setup settled early: attempt=$id '
          'outcome=${value.runtimeType}; '
          '${trace.describe(pending: 'worker launch or barrier')}',
        );
      }
    }),
  ]).timeout(
    budget,
    onTimeout: () => throw TestFailure(
      'Closed-stdin setup timed out: attempt=$id; '
      '${trace.describe(pending: 'worker launch or barrier')}',
    ),
  );
}

/// The measured phase: the owner retires the worker after its pipe closed. The
/// default is the real five-second deadline; only a control shortens it.
Future<void> expectBrokenPipeRetirement(
  Future<Object?> download,
  PhaseTrace trace,
  String id, {
  Object? expectedFailure,
  Duration budget = const Duration(seconds: 5),
}) {
  return download
      .timeout(
        budget,
        onTimeout: () => throw TestFailure(
          'Broken-pipe retirement timed out: attempt=$id; '
          '${trace.describe(pending: 'owner retiring the worker after a '
              'broken configuration pipe')}',
        ),
      )
      .then<void>(
        (value) => throw TestFailure(
          'Broken-pipe retirement completed without the expected failure: '
          'attempt=$id value=$value',
        ),
        onError: (Object error) {
          if (error is TestFailure) throw error;
          expect(error, expectedFailure ?? anything);
        },
      );
}

/// Drive [attempts] through the owner with a worker that closes its pipe. Setup
/// (launch to the closed-stdin barrier) and retirement are timed separately.
Future<({Duration setup, Duration retirement})> brokenConfigPipeScenario(
  List<String> attempts, {
  Duration startupDelay = Duration.zero,
  Duration setupBudget = const Duration(seconds: 5),
}) async {
  final root = createTestTempDirectorySync('closed-config-');
  // Teardown runs newest first. Registration order below makes it: close the
  // owner, then end the workers, then close the store, then remove the
  // directory. A hung owner close is reported while its worker is alive.
  final store = Store('${root.path}/app.db');
  addTearDown(store.close);
  final owned = OwnedProcesses.forTest();
  final ownerCleanups = OwnedCleanups.forTest();
  final worker = await closedStdinWorker(root, startupDelay: startupDelay);
  runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
  final trace = PhaseTrace();
  late Completer<void> entered;
  var attempt = 'none';
  Future<Process> startWorker(List<String> command) => launchAtClosedStdin(
    owned,
    worker,
    command,
    trace,
    name: 'closed-stdin worker ($attempt)',
    barrier: setupBudget,
    entered: () => entered.complete(),
  );

  final model = controlModel();
  store.setPreference('modelTerms.fixture/model.revision', 'accepted');
  final owner = ModelAssetAcquisitionCoordinator(
    store: store,
    changed: () {},
    catalog: (_) => [model],
    createDownloader: () =>
        PublicModelFileDownloader(startWorkerForTesting: startWorker),
    modelRoot: Directory('${root.path}/models'),
    prepareGemma: (_) async {},
  );
  ownerCleanups.add(
    'close model acquisition owner',
    () => owner.close().timeout(const Duration(seconds: 2)),
  );
  ModelsDownloadAssetRequest request(String id) =>
      decodeOperationRequest(Operation.modelsDownloadAsset, {
            'kind': 'generation',
            'digest': model.digest,
            'requestId': id,
          })
          as ModelsDownloadAssetRequest;
  final invalid = ModelAssetFailure(ModelAssetFailureCode.invalid).toRpcError();
  var setup = Duration.zero, retirement = Duration.zero;
  for (final id in attempts) {
    entered = Completer<void>();
    attempt = id;
    trace.enter('download-requested:$id');
    final clock = Stopwatch()..start();
    final download = owner.download(request(id));
    await awaitClosedStdinSetup(
      download,
      entered,
      trace,
      id,
      budget: setupBudget,
    );
    setup = clock.elapsed;
    clock.reset();
    await expectBrokenPipeRetirement(
      download,
      trace,
      id,
      expectedFailure: isA<RpcError>().having(
        (e) => e.message,
        'ordinary model failure',
        invalid.message,
      ),
    );
    retirement = clock.elapsed;
    expect(owner.restartRequired, isFalse);
    expect(owner.busy, isFalse);
  }
  expect(owned.started, hasLength(attempts.length));
  for (final process in owned.started) {
    expect(
      await process.exitCode.timeout(const Duration(seconds: 2)),
      isNot(0),
    );
  }
  await ownerCleanups.run();
  await owned.close();
  owned.expectNoneRunning(reason: 'Closed-stdin workers left running');
  return (setup: setup, retirement: retirement);
}

void main() {
  bootstrapSqlSupportFixture();
  setUp(() {
    final saved = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
    addTearDown(
      () => runtimeConfiguration.environment
        ..clear()
        ..addAll(saved),
    );
  });

  for (final scenario in [
    (name: 'stdout', stderrOnly: false, duringLaunch: false),
    (
      name: 'stderr with closed leader stdout',
      stderrOnly: true,
      duringLaunch: false,
    ),
    (name: 'stdout during launch', stderrOnly: false, duringLaunch: true),
  ]) {
    test(
      'public cancellation retires owned ${scenario.name} before descendant EOF',
      () async {
        final root = createTestTempDirectorySync('held-transport-');
        final owned = OwnedProcesses.forTest();
        final worker = await heldPipeWorker(
          root,
          stderrOnly: scenario.stderrOnly,
          skipConfiguration: scenario.duringLaunch,
        );
        runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
        late final PublicModelFileDownloader downloader;
        downloader = PublicModelFileDownloader(
          startWorkerForTesting: scenario.duringLaunch
              ? (command) => launchAtBarrier(owned, command, worker, (_) {
                  downloader.cancel();
                })
              : null,
        );
        final work = downloader.download(controlModel(), root);
        final result = work.then<Object?>(
          (value) => value,
          onError: (Object error) => error,
        );
        try {
          await reached(File('${worker.path}.leader-entered'));
          await reached(File('${worker.path}.pipe-entered'));
          downloader.cancel();
          expect(
            await result.timeout(const Duration(seconds: 4)),
            isA<ModelDownloadCancelled>(),
          );
          expect(File('${worker.path}.release').existsSync(), isFalse);
          File('${worker.path}.release').writeAsStringSync('release');
          // The real descendant must observe the closed read end, including
          // cancellation before the parser's first moveNext call.
          await reached(File('${worker.path}.pipe-closed'));
        } finally {
          downloader.cancel();
          File('${worker.path}.release').writeAsStringSync('release');
          // An independent fixture thread exits even when its main thread is
          // blocked writing to an incorrectly retained pipe. No guessed PID
          // signal is needed to clean up a failing regression control.
          File('${worker.path}.cleanup').writeAsStringSync('cleanup');
          try {
            await result.timeout(const Duration(seconds: 5));
          } finally {
            await fixtureDescendantStopped(worker);
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 25)),
    );
  }

  test('failed launch barrier joins its still-owned leader', () async {
    final root = createTestTempDirectorySync('launch-cleanup-');
    final owned = OwnedProcesses.forTest();
    final worker = await heldPipeWorker(root, skipConfiguration: true);
    Process? leader;
    try {
      await expectLater(
        launchAtBarrier(owned, [worker.path], worker, (process) {
          leader = process;
          throw StateError('fixture barrier failure');
        }),
        throwsStateError,
      );
      expect(leader, isNotNull);
      expect(
        await leader!.exitCode.timeout(const Duration(seconds: 2)),
        isNot(0),
      );
    } finally {
      File('${worker.path}.cleanup').writeAsStringSync('cleanup');
      await fixtureDescendantStopped(worker);
    }
  });

  test(
    'lost reader acknowledgement settles close and forbids replacement',
    () async {
      final root = createTestTempDirectorySync('reader-ack-');
      final owned = OwnedProcesses.forTest();
      final worker = await heldPipeWorker(root);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
      final launched = Completer<HeldReaderAcknowledgement>();
      var starts = 0;
      final downloader = PublicModelFileDownloader(
        startWorkerForTesting: (command) async {
          starts++;
          final process = await owned.start(
            command.first,
            command.skip(1).toList(),
            name: 'acknowledgement worker',
            includeParentEnvironment: false,
          );
          final controlled = HeldReaderAcknowledgement(process);
          launched.complete(controlled);
          return controlled;
        },
      );
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final model = controlModel();
      store.setPreference('modelTerms.fixture/model.revision', 'accepted');
      final owner = ModelAssetAcquisitionCoordinator(
        store: store,
        changed: () {},
        catalog: (_) => [model],
        createDownloader: () => downloader,
        modelRoot: Directory('${root.path}/models'),
        prepareGemma: (_) async {},
      );
      ModelsDownloadAssetRequest request(String id) =>
          decodeOperationRequest(Operation.modelsDownloadAsset, {
                'kind': 'generation',
                'digest': model.digest,
                'requestId': id,
              })
              as ModelsDownloadAssetRequest;
      var current = true;
      final work = owner.download(
        request('held-reader'),
        current: () => current,
      );
      final result = work.then<Object?>(
        (value) => value,
        onError: (Object e) => e,
      );
      HeldReaderAcknowledgement? controlled;
      try {
        controlled = await launched.future.timeout(const Duration(seconds: 5));
        await reached(File('${worker.path}.leader-entered'));
        await reached(File('${worker.path}.pipe-entered'));
        current = false;
        await controlled.observed.future.timeout(const Duration(seconds: 2));
        File('${worker.path}.release').writeAsStringSync('release');
        await reached(File('${worker.path}.pipe-closed'));
        expect(
          await result.timeout(const Duration(seconds: 4)),
          isA<RpcError>().having(
            (e) => e.message,
            'restart message',
            modelAcquisitionRestartMessage,
          ),
        );
        expect(owner.busy, isFalse);
        expect(owner.restartRequired, isTrue);
        expect(controlled.acknowledgement.isCompleted, isFalse);
        expect(
          await controlled.process.exitCode.timeout(const Duration(seconds: 2)),
          isNot(0),
        );
        await expectLater(
          owner.download(request('replacement')),
          throwsA(
            isA<RpcError>().having(
              (e) => e.message,
              'restart message',
              modelAcquisitionRestartMessage,
            ),
          ),
        );
        expect(starts, 1);
        await owner.close().timeout(const Duration(seconds: 1));
      } finally {
        current = false;
        File('${worker.path}.release').writeAsStringSync('release');
        File('${worker.path}.cleanup').writeAsStringSync('cleanup');
        if (controlled != null && !controlled.acknowledgement.isCompleted) {
          controlled.acknowledgement.complete();
        }
        try {
          await result.timeout(const Duration(seconds: 5));
          await owner.close().timeout(const Duration(seconds: 2));
        } finally {
          await fixtureDescendantStopped(worker);
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'broken config pipe preserves retry admission after confirmed exit',
    () async {
      await brokenConfigPipeScenario(['initial', 'replacement']);
    },
  );

  test(
    'a cold worker launch is setup with its own budget, not retirement time',
    () async {
      // Deterministic cold start: the worker holds 5.5 s before closing stdin.
      // Launch plus retirement would exceed one 5 s bound; launch has its own
      // 15 s setup budget here, and retirement keeps the real 5 s deadline.
      const startup = Duration(milliseconds: 5500);
      final timings = await brokenConfigPipeScenario(
        ['initial'],
        startupDelay: startup,
        setupBudget: const Duration(seconds: 15),
      );
      expect(timings.setup, greaterThanOrEqualTo(startup));
      expect(timings.retirement, lessThan(const Duration(seconds: 5)));
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test('a retirement that never settles fails at its bound with its phase', () {
    final trace = PhaseTrace()
      ..enter('launched')
      ..enter('stdin-closed');
    return expectLater(
      expectBrokenPipeRetirement(
        Completer<void>().future,
        trace,
        'stuck',
        // Only the control shortens the bound; the real tests use five seconds.
        budget: const Duration(milliseconds: 100),
      ),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Broken-pipe retirement timed out: attempt=stuck'),
            contains('last observed phase: stdin-closed'),
            contains('inferred pending (not observed): owner retiring'),
          ),
        ),
      ),
    );
  });

  test(
    'closed-stdin barrier failure names its phase and reaps the child',
    () async {
      final root = createTestTempDirectorySync('closed-config-barrier-');
      final owned = OwnedProcesses.forTest();
      // This worker never closes stdin, so its marker is never published.
      final worker = await closedStdinWorker(root, closesStdin: false);
      final trace = PhaseTrace();
      Object? failure;
      try {
        await launchAtClosedStdin(
          owned,
          worker,
          [worker.path],
          trace,
          name: 'stalled worker',
          barrier: const Duration(milliseconds: 200),
        );
      } on TestFailure catch (error) {
        failure = error;
      }
      expect(failure, isA<TestFailure>());
      final message = (failure as TestFailure).message!;
      expect(message, contains('${worker.path}.stdin-closed'));
      expect(message, contains('last observed phase: launched'));
      expect(
        message,
        contains('inferred pending (not observed): worker closing its'),
      );
      expect(message, contains('stalled worker'));
      expect(message, contains('still running'));
      // The failed barrier ended and reaped the child before it propagated.
      expect(owned.started, hasLength(1));
      owned.expectNoneRunning(reason: 'Stalled worker survived its barrier');
      expect(owned.started.single.exitStatus, isNotNull);
    },
  );

  test('closed-stdin worker settles cleanup while paused', () async {
    final root = createTestTempDirectorySync('closed-config-paused-');
    final owned = OwnedProcesses.forTest();
    final worker = await closedStdinWorker(root);
    final process = await launchAtClosedStdin(
      owned,
      worker,
      [worker.path],
      PhaseTrace(),
      name: 'paused worker',
    );
    // SIGTERM cannot take effect while stopped; bounded escalation must.
    expect(process.kill(ProcessSignal.sigstop), isTrue);
    await owned.close();
    owned.expectNoneRunning(reason: 'Paused worker survived cleanup');
  });

  test(
    'lost exit acknowledgement settles close and forbids replacement',
    () async {
      final root = createTestTempDirectorySync('exit-ack-');
      final owned = OwnedProcesses.forTest();
      final worker = File('${root.path}/transport-worker');
      final python =
          Platform.environment['FORESIGHT_PYTHON'] ?? '/usr/bin/python3';
      worker.writeAsStringSync('''#!$python
import json,pathlib,sys
sys.stdin.buffer.read()
target=pathlib.Path(__file__+'.asset')
target.write_bytes(b'asset')
body=str(target).encode()
sys.stdout.write(json.dumps({'ok':True,'size':len(body)})+'\\n')
sys.stdout.flush()
sys.stdout.buffer.write(body)
sys.stdout.buffer.flush()
''');
      final mode = await Process.run('/bin/chmod', ['700', worker.path]);
      expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
      final launched = Completer<HeldExitAcknowledgement>();
      var starts = 0;
      final downloader = PublicModelFileDownloader(
        startWorkerForTesting: (command) async {
          starts++;
          final process = await owned.start(
            command.first,
            command.skip(1).toList(),
            name: 'acknowledgement worker',
            includeParentEnvironment: false,
          );
          final controlled = HeldExitAcknowledgement(process);
          launched.complete(controlled);
          return controlled;
        },
      );
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final model = controlModel();
      store.setPreference('modelTerms.fixture/model.revision', 'accepted');
      final owner = ModelAssetAcquisitionCoordinator(
        store: store,
        changed: () {},
        catalog: (_) => [model],
        createDownloader: () => downloader,
        modelRoot: Directory('${root.path}/models'),
        prepareGemma: (_) async {},
      );
      ModelsDownloadAssetRequest request(String id) =>
          decodeOperationRequest(Operation.modelsDownloadAsset, {
                'kind': 'generation',
                'digest': model.digest,
                'requestId': id,
              })
              as ModelsDownloadAssetRequest;
      var current = true;
      final work = owner.download(request('held-ack'), current: () => current);
      final result = work.then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      HeldExitAcknowledgement? controlled;
      try {
        controlled = await launched.future.timeout(const Duration(seconds: 5));
        await controlled.observed.future.timeout(const Duration(seconds: 5));
        expect(await controlled.process.exitCode, 0);
        expect(owner.busy, isTrue);
        current = false;
        expect(
          await result.timeout(const Duration(seconds: 5)),
          isA<RpcError>().having(
            (e) => e.message,
            'restart message',
            modelAcquisitionRestartMessage,
          ),
        );
        expect(owner.busy, isFalse);
        expect(owner.restartRequired, isTrue);
        expect(owner.state.active, isFalse);
        expect(controlled.acknowledgement.isCompleted, isFalse);
        await expectLater(
          owner.download(request('replacement')),
          throwsA(
            isA<RpcError>().having(
              (e) => e.message,
              'restart message',
              modelAcquisitionRestartMessage,
            ),
          ),
        );
        expect(starts, 1);
        await owner.close().timeout(const Duration(seconds: 1));
      } finally {
        current = false;
        if (controlled != null && !controlled.acknowledgement.isCompleted) {
          controlled.acknowledgement.complete(
            await controlled.process.exitCode,
          );
        }
        await result.timeout(const Duration(seconds: 5));
        await owner.close().timeout(const Duration(seconds: 2));
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
