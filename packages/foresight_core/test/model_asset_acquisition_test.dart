import 'package:foresight_core/src/model_acquisition.dart'
    show ModelTransportException;
import 'package:foresight_core/src/model_asset_failure.dart';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/model_asset_acquisition.dart';
import 'package:foresight_core/src/model_asset_status.dart';
import 'package:foresight_core/src/model_catalog.dart';
import 'package:foresight_core/src/model_download_contract.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class HeldDownload implements ModelDownloader {
  final entered = Completer<void>(), cancelled = Completer<void>();
  final result = Completer<File>();
  int calls = 0;
  @override
  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }

  @override
  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int, int)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
    File? existingFile,
  }) async {
    calls++;
    phase?.call(ModelDownloadPhase.downloading);
    progress?.call(2, model.bytes);
    entered.complete();
    return result.future;
  }
}

class NeverSettledPreflight implements Process {
  final entered = Completer<void>();
  final outcome = Completer<int>();
  @override
  Future<int> get exitCode {
    if (!entered.isCompleted) entered.complete();
    return outcome.future;
  }

  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Store store;
  late Directory root;
  late GemmaModel model;
  late HeldDownload downloader;
  late ModelAssetAcquisitionCoordinator owner;
  var preparations = 0;
  setUp(() {
    final saved = Map.of(runtimeConfiguration.environment);
    addTearDown(
      () => runtimeConfiguration.environment
        ..clear()
        ..addAll(saved),
    );
    runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
    root = createTestTempDirectorySync('asset-owner-');
    store = Store('${root.path}/app.db');
    addTearDown(store.close);
    model = GemmaModel(
      'fixture',
      'fixture/model',
      'revision',
      'fixture.bin',
      sha256.convert([1, 2, 3, 4]).toString(),
      4,
      0,
    );
    downloader = HeldDownload();
    preparations = 0;
    owner = ModelAssetAcquisitionCoordinator(
      store: store,
      changed: () {},
      catalog: (_) => [model],
      modelRoot: Directory('${root.path}/models'),
      createDownloader: () => downloader,
      prepareGemma: (_) async {
        preparations++;
      },
    );
    addTearDown(() async {
      owner.stop();
      if (owner.busy && !downloader.result.isCompleted) {
        downloader.result.completeError(const ModelDownloadCancelled());
      }
      await owner.close();
    });
  });
  ModelsDownloadAssetRequest request([String id = 'owner']) =>
      decodeOperationRequest(Operation.modelsDownloadAsset, {
            'kind': 'generation',
            'digest': model.digest,
            'requestId': id,
          })
          as ModelsDownloadAssetRequest;
  void consent() =>
      store.setPreference('modelTerms.fixture/model.revision', 'accepted');

  test(
    'unknown physical preflight settlement latches restart and settles close',
    () async {
      consent();
      final process = NeverSettledPreflight();
      var starts = 0, stops = 0;
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] =
          '/fixture/runner';
      owner = ModelAssetAcquisitionCoordinator(
        store: store,
        changed: () {},
        catalog: (_) => [model],
        startPreflight: (_) async {
          starts++;
          return process;
        },
        stopPreflight: (_) async {
          stops++;
          throw TimeoutException('fixture stop timeout');
        },
        createDownloader: () => downloader,
      );
      var current = true;
      final work = owner.download(request(), current: () => current);
      final failure = expectLater(
        work,
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            modelAcquisitionRestartMessage,
          ),
        ),
      );
      await process.entered.future;
      current = false;
      await failure.timeout(const Duration(seconds: 2));
      expect(owner.busy, false);
      expect(owner.restartRequired, true);
      expect(owner.state.restartRequired, true);
      expect(owner.state.active, false);
      await expectLater(
        owner.download(request('replacement')),
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            modelAcquisitionRestartMessage,
          ),
        ),
      );
      expect(starts, 1);
      expect(stops, 1, reason: 'never re-await the same failed stop');
      await owner.close().timeout(const Duration(seconds: 1));
      expect(downloader.calls, 0);
      // No fake claim of physical reaping: the process future is still pending.
      expect(process.outcome.isCompleted, false);
    },
  );

  test(
    'known public asset failures become safe actionable RpcErrors',
    () async {
      consent();
      final work = owner.download(request());
      final failure = expectLater(
        work,
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            contains('Not enough free disk space'),
          ),
        ),
      );
      await downloader.entered.future;
      downloader.result.completeError(
        ModelAssetFailure(
          ModelAssetFailureCode.diskSpace,
          requiredBytes: 2000000000,
        ),
      );
      await failure;
      expect(owner.busy, false);
    },
  );

  test(
    'unknown worker retirement blocks replacement downloads and settles close',
    () async {
      consent();
      final work = owner.download(request());
      final rejected = expectLater(
        work,
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            modelAcquisitionRestartMessage,
          ),
        ),
      );
      await downloader.entered.future;
      downloader.result.completeError(
        const ModelTransportException('worker_exit_unknown'),
      );
      await rejected;
      expect(owner.busy, false);
      expect(owner.restartRequired, true);
      await expectLater(
        owner.download(request('replacement')),
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            modelAcquisitionRestartMessage,
          ),
        ),
      );
      await owner.close().timeout(const Duration(seconds: 1));
      expect(downloader.calls, 1);
    },
  );

  test('terms are checked before preflight or transfer', () async {
    await expectLater(
      owner.download(request()),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          RpcErrorCode.invalidArgument,
        ),
      ),
    );
    expect(preparations, 0);
    expect(downloader.calls, 0);
    expect(owner.busy, false);
  });
  test(
    'cancelled subscriber retains ownership until the producer settles',
    () async {
      consent();
      var current = true;
      final work = owner.download(request(), current: () => current);
      final rejected = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await downloader.entered.future;
      expect(owner.state.requestId, 'owner');
      expect(owner.state.received, 2);
      await expectLater(
        owner.download(request('peer')),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      expect(downloader.cancelled.isCompleted, false);
      current = false;
      await downloader.cancelled.future;
      expect(owner.busy, true);
      var closed = false;
      final closing = owner.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      downloader.result.complete(File('${root.path}/completed.bin'));
      await rejected;
      await closing;
      expect(owner.busy, false);
      expect(owner.state.active, false);
    },
  );
  test(
    'verified cache inspection preserves bytes and requires no terms',
    () async {
      final file =
          File(
              '${root.path}/models/gemma4/${model.directory}/${model.filename}',
            )
            ..createSync(recursive: true)
            ..writeAsBytesSync([1, 2, 3, 4]);
      final inspect =
          decodeOperationRequest(Operation.modelsInspectAsset, {
                'kind': 'generation',
                'digest': model.digest,
              })
              as ModelsInspectAssetRequest;
      final result = ModelAssetLocation.fromWire(
        await owner.inspect(inspect),
        requiredPath: false,
      );
      expect(result.path, file.path);
      expect(file.readAsBytesSync(), [1, 2, 3, 4]);
      expect(downloader.calls, 0);
      expect(preparations, 0);
      file.writeAsBytesSync([4, 3, 2, 1]);
      expect(
        ModelAssetLocation.fromWire(
          await owner.inspect(inspect),
          requiredPath: false,
        ).path,
        isNull,
      );
    },
  );
  for (final runner in ['/usr/bin/true', '/usr/bin/false']) {
    test('service preflight $runner settles before transfer', () async {
      consent();
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] = runner;
      owner = ModelAssetAcquisitionCoordinator(
        store: store,
        changed: () {},
        catalog: (_) => [model],
        modelRoot: Directory('${root.path}/models'),
        createDownloader: () => downloader,
      );
      final work = owner.download(request());
      if (runner.endsWith('/false')) {
        await expectLater(
          work,
          throwsA(
            isA<RpcError>().having(
              (e) => e.message,
              'message',
              modelRuntimeNotReadyMessage,
            ),
          ),
        );
        expect(downloader.calls, 0);
      } else {
        await downloader.entered.future;
        final file = File('${root.path}/verified.bin')
          ..writeAsBytesSync([1, 2, 3, 4]);
        downloader.result.complete(file);
        expect(
          ModelAssetLocation.fromWire(await work, requiredPath: true).path,
          file.path,
        );
      }
      expect(owner.busy, false);
    });
  }
  test(
    'shutdown kills and reaps a preflight that ignores TERM before releasing its owner',
    () async {
      consent();
      final pidFile = File('${root.path}/preflight.pid');
      final runner = File('${root.path}/runner')
        ..writeAsStringSync(
          '#!/bin/sh\ntrap "" TERM\nprintf "%s" "\$\$" > "${pidFile.path}"\nwhile :; do read value; done\n',
        );
      final mode = await Process.run('/bin/chmod', [
        '700',
        runner.path,
      ]).timeout(const Duration(seconds: 5));
      expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] = runner.path;
      owner = ModelAssetAcquisitionCoordinator(
        store: store,
        changed: () {},
        catalog: (_) => [model],
        modelRoot: Directory('${root.path}/models'),
        createDownloader: () => downloader,
      );
      final work = owner.download(request());
      final rejected = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await eventually(() => pidFile.existsSync());
      final pid = int.parse(pidFile.readAsStringSync());
      final closing = owner.close();
      expect(owner.busy, true);
      await closing.timeout(const Duration(seconds: 5));
      await rejected;
      final alive = await Process.run('/bin/kill', [
        '-0',
        '$pid',
      ]).timeout(const Duration(seconds: 5));
      expect(
        alive.exitCode,
        isNot(0),
        reason: 'Preflight PID must be reaped: $pid',
      );
      expect(owner.busy, false);
      expect(downloader.calls, 0);
    },
  );

  test(
    'malformed sent results retain unknown outcome rather than retry authority',
    () {
      for (final result in [
        null,
        {},
        {'path': 1},
        {'path': ''},
      ]) {
        expect(
          () => ModelAssetLocation.fromWire(result, requiredPath: true),
          throwsA(
            isA<RpcError>()
                .having(
                  (e) => e.reason,
                  'reason',
                  RpcErrorReason.outcomeUnknown,
                )
                .having((e) => e.code, 'code', RpcErrorCode.internal),
          ),
        );
      }
      expect(
        ModelAssetLocation.fromWire({'path': null}, requiredPath: false).path,
        isNull,
      );
    },
  );
}
