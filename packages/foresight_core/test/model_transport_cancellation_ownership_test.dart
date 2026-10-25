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

Future<File> heldPipeWorker(Directory root) async {
  final worker = File('${root.path}/transport-worker');
  final python = Platform.environment['FORESIGHT_PYTHON'] ?? '/usr/bin/python3';
  worker.writeAsStringSync('''#!$python
import os,pathlib,signal,subprocess,sys,time
root=pathlib.Path(__file__)
if '--held-output-child' in sys.argv:
 pathlib.Path(str(root)+'.pipe-entered').write_text(str(os.getpid()))
 deadline=time.monotonic()+20
 while not pathlib.Path(str(root)+'.release').exists():
  if time.monotonic()>deadline:sys.exit(3)
  time.sleep(.005)
 try:
  for _ in range(128):
   os.write(1,b'!'*4096)
   time.sleep(.005)
 except BrokenPipeError:
  pathlib.Path(str(root)+'.pipe-closed').write_text('closed')
  os._exit(0)
 sys.exit(4)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
sys.stdin.buffer.read()
subprocess.Popen([sys.executable,__file__,'--held-output-child'],stdin=subprocess.DEVNULL)
pathlib.Path(str(root)+'.leader-entered').write_text(str(os.getpid()))
while True:time.sleep(.1)
''');
  final mode = await Process.run('/bin/chmod', ['700', worker.path]);
  expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
  return worker;
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

// Real pipes and a real, reaped child; only its exit acknowledgement is withheld
// to exercise the owner's unconfirmed outcome without creating unkillable I/O.
class HeldExitAcknowledgement implements Process {
  HeldExitAcknowledgement(this.process);
  final Process process;
  final observed = Completer<void>();
  final acknowledgement = Completer<int>();
  @override
  Future<int> get exitCode {
    if (!observed.isCompleted) observed.complete();
    return acknowledgement.future;
  }

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

  test(
    'public cancellation retires the owned stdout before a descendant EOF',
    () async {
      final root = createTestTempDirectorySync('held-transport-');
      final worker = await heldPipeWorker(root);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = worker.path;
      final downloader = PublicModelFileDownloader();
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
        // EOF is deliberately withheld until after cancellation has settled.
        expect(File('${worker.path}.release').existsSync(), isFalse);
      } finally {
        downloader.cancel();
        File('${worker.path}.release').writeAsStringSync('release');
        await result.timeout(const Duration(seconds: 5));
        // The real descendant observes our closed read end, rather than being
        // silently abandoned or allowed to hold the producer's close Future.
        await reached(File('${worker.path}.pipe-closed'));
      }
    },
    timeout: const Timeout(Duration(seconds: 25)),
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
        startWorker: (command) async {
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
        store.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
