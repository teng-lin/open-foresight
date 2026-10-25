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
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Future<void> reached(File marker) async {
  final elapsed = Stopwatch()..start();
  while (!marker.existsSync()) {
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      throw TestFailure(
        'Owned transport barrier did not settle: ${marker.path}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

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
  List<String> command,
  File worker,
  void Function(Process process) atBarrier,
) async {
  final process = await Process.start(
    command.first,
    command.skip(1).toList(),
    includeParentEnvironment: false,
  );
  try {
    await reached(File('${worker.path}.leader-entered'));
    await reached(File('${worker.path}.pipe-entered'));
    atBarrier(process);
    return process;
  } catch (_) {
    // This wrapper still owns the returned Process until both barriers pass.
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 2));
    rethrow;
  }
}

void main() {
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
        final worker = await heldPipeWorker(
          root,
          stderrOnly: scenario.stderrOnly,
          skipConfiguration: scenario.duringLaunch,
        );
        runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
        late final PublicModelFileDownloader downloader;
        downloader = PublicModelFileDownloader(
          startWorkerForTesting: scenario.duringLaunch
              ? (command) => launchAtBarrier(command, worker, (_) {
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
    final worker = await heldPipeWorker(root, skipConfiguration: true);
    Process? leader;
    try {
      await expectLater(
        launchAtBarrier([worker.path], worker, (process) {
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
      final worker = await heldPipeWorker(root);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
      final launched = Completer<HeldReaderAcknowledgement>();
      var starts = 0;
      final downloader = PublicModelFileDownloader(
        startWorkerForTesting: (command) async {
          starts++;
          final process = await Process.start(
            command.first,
            command.skip(1).toList(),
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
      final root = createTestTempDirectorySync('closed-config-');
      final worker = File('${root.path}/transport-worker');
      final python =
          Platform.environment['FORESIGHT_PYTHON'] ?? '/usr/bin/python3';
      worker.writeAsStringSync('''#!$python
import os,pathlib,time
os.close(0)
pathlib.Path(__file__+'.stdin-closed').write_text('closed')
time.sleep(20)
''');
      final mode = await Process.run('/bin/chmod', ['700', worker.path]);
      expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
      final processes = <Process>[];
      final exited = <Process>{};
      Future<Process> startWorker(List<String> command) async {
        final marker = File('${worker.path}.stdin-closed');
        if (marker.existsSync()) {
          marker.deleteSync();
        }
        final process = await Process.start(
          command.first,
          command.skip(1).toList(),
          includeParentEnvironment: false,
        );
        processes.add(process);
        process.exitCode.then((_) => exited.add(process)).ignore();
        try {
          await reached(File('${worker.path}.stdin-closed'));
          return process;
        } catch (_) {
          if (!exited.contains(process)) {
            process.kill(ProcessSignal.sigkill);
          }
          await process.exitCode.timeout(const Duration(seconds: 2));
          rethrow;
        }
      }

      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
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
      ModelsDownloadAssetRequest request(String id) =>
          decodeOperationRequest(Operation.modelsDownloadAsset, {
                'kind': 'generation',
                'digest': model.digest,
                'requestId': id,
              })
              as ModelsDownloadAssetRequest;
      final invalid = ModelAssetFailure(
        ModelAssetFailureCode.invalid,
      ).toRpcError();
      try {
        for (final id in ['initial', 'replacement']) {
          await expectLater(
            owner.download(request(id)).timeout(const Duration(seconds: 5)),
            throwsA(
              isA<RpcError>().having(
                (e) => e.message,
                'ordinary model failure',
                invalid.message,
              ),
            ),
          );
          expect(owner.restartRequired, isFalse);
          expect(owner.busy, isFalse);
        }
        expect(processes, hasLength(2));
        for (final process in processes) {
          expect(
            await process.exitCode.timeout(const Duration(seconds: 2)),
            isNot(0),
          );
        }
      } finally {
        try {
          await owner.close().timeout(const Duration(seconds: 2));
        } finally {
          for (final process in processes) {
            if (!exited.contains(process)) {
              process.kill(ProcessSignal.sigkill);
            }
            await process.exitCode.timeout(const Duration(seconds: 2));
          }
        }
      }
    },
  );

  test(
    'lost exit acknowledgement settles close and forbids replacement',
    () async {
      final root = createTestTempDirectorySync('exit-ack-');
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
          final process = await Process.start(
            command.first,
            command.skip(1).toList(),
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
