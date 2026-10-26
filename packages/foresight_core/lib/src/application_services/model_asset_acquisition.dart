import '../model_asset_failure.dart';
import '../cancellation.dart';
import 'dart:async';
import 'dart:io';

import '../model_acquisition.dart';
import '../model_asset_status.dart';
import '../model_cache.dart';
import '../model_catalog.dart';
import '../model_download_contract.dart';
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../platform_services.dart';
import '../rpc_error.dart';
import '../runtime_execution_policy.dart';
import '../speech_model_catalog.dart';
import '../store.dart';

class _AssetDownload {
  _AssetDownload(
    this.requestId,
    this.model,
    this.downloader,
    this.stopPreflight,
  );
  final Future<void> Function(Process) stopPreflight;
  final cancelledSignal = Completer<void>();
  final String requestId;
  final GemmaModel model;
  final ModelDownloader downloader;
  final finished = Completer<void>();
  Process? preflight;
  Future<void>? stopping;
  bool cancelled = false, active = true;
  ModelDownloadPhase phase = ModelDownloadPhase.checkingCache;
  int received = 0, total = 0;
  final notice = Stopwatch()..start();
  void cancel() {
    cancelled = true;
    if (!cancelledSignal.isCompleted) cancelledSignal.complete();
    downloader.cancel();
    if (preflight case final process?) {
      (stopping ??= stopPreflight(process)).ignore();
    }
  }
}

Future<void> _stopProcess(Process process) async {
  process.kill();
  try {
    await process.exitCode.timeout(const Duration(milliseconds: 250));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 2));
  }
}

/// Owns public asset work until the transfer and preflight have actually settled.
/// Native model activation remains in the existing separately reserved service
/// operations. Cancellation never releases another request's owner.
final class ModelAssetAcquisitionCoordinator {
  ModelAssetAcquisitionCoordinator({
    required this.store,
    required this.changed,
    ModelDownloader Function()? createDownloader,
    Future<void> Function(bool Function())? prepareGemma,
    Directory? modelRoot,
    Iterable<GemmaModel> Function(String kind)? catalog,
    this.startPreflight,
    this.stopPreflight = _stopProcess,
    RuntimeConfiguration? configuration,
    RuntimeConfiguration Function()? ownerConfiguration,
  }) : _configuration = configuration?.snapshot(),
       _ownerConfiguration = ownerConfiguration,
       createDownloader = createDownloader ?? PublicModelFileDownloader.new,
       _prepareGemma = prepareGemma,
       _catalog = catalog,
       modelRoot =
           modelRoot ?? Directory('${File(store.path).parent.path}/models');
  final Future<Process> Function(String runner)? startPreflight;
  final Future<void> Function(Process) stopPreflight;

  /// An injected snapshot is fixed at construction. Without one this is a
  /// legacy direct construction: each access returns a fresh immutable snapshot
  /// of the boundary, as it read the boundary before injection.
  /// An owner may supply its own snapshot instead ([ownerConfiguration]).
  RuntimeConfiguration get configuration =>
      _configuration ?? _ownerConfiguration?.call() ?? runtimeSnapshot();
  final RuntimeConfiguration? _configuration;
  final RuntimeConfiguration Function()? _ownerConfiguration;
  final Store store;
  final void Function() changed;
  final Directory modelRoot;
  final ModelDownloader Function() createDownloader;
  final Future<void> Function(bool Function())? _prepareGemma;
  final Iterable<GemmaModel> Function(String kind)? _catalog;
  _AssetDownload? _active, _last;
  bool _closed = false, _restartRequired = false;
  bool get restartRequired => _restartRequired;
  Future<void>? _closing;
  bool get busy => _active != null;
  ModelAssetDownloadPresentation get state {
    final job = _active ?? _last;
    return job == null
        ? ModelAssetDownloadPresentation(restartRequired: _restartRequired)
        : ModelAssetDownloadPresentation(
            restartRequired: _restartRequired,
            requestId: job.requestId,
            digest: job.model.digest,
            active: job.active,
            phase: job.phase,
            received: job.received,
            total: job.total,
          );
  }

  GemmaModel _model(String kind, String digest) {
    final models =
        _catalog?.call(kind) ??
        (switch (kind) {
          'generation' => gemmaModels,
          'embedding' => [embeddingGemmaModel],
          'speech' => speechModels,
          _ => <GemmaModel>[],
        });
    return models.where((model) => model.digest == digest).firstOrNull ??
        (throw RpcError(
          RpcErrorCode.invalidArgument,
          'Unsupported pinned model asset',
        ));
  }

  Directory _root(String kind) => Directory(
    '${modelRoot.path}/${switch (kind) {
      'generation' => 'gemma4',
      'embedding' => 'embeddinggemma2',
      _ => 'whisper',
    }}',
  );
  Future<File?> _local(
    String kind,
    GemmaModel model, {
    bool Function()? current,
  }) => localModelFile(
    model,
    _root(kind),
    registration: store.sourceQueries.model(kind)?.toRow(),
    current: current,
  );
  Future<Object?> inspect(
    ModelsInspectAssetRequest request, {
    bool Function()? current,
  }) async {
    if (_closed) {
      throw RpcError(RpcErrorCode.unavailable, modelAcquisitionClosedMessage);
    }
    try {
      final file = await _local(
        request.kind,
        _model(request.kind, request.digest),
        current: () => !_closed && (current?.call() ?? true),
      );
      if (_closed || !(current?.call() ?? true)) throw operationCancelled();
      return ModelAssetLocation(file?.path).toWire();
    } on ModelDownloadCancelled {
      throw operationCancelled();
    }
  }

  Future<Object?> download(
    ModelsDownloadAssetRequest request, {
    bool Function()? current,
  }) async {
    if (_closed) {
      throw RpcError(RpcErrorCode.unavailable, modelAcquisitionClosedMessage);
    }
    if (_restartRequired) {
      throw RpcError(RpcErrorCode.unavailable, modelAcquisitionRestartMessage);
    }
    if (busy) {
      throw RpcError(RpcErrorCode.busy, modelDownloadBusyMessage);
    }
    final model = _model(request.kind, request.digest);
    final job = _active = _AssetDownload(
      request.progressKey ?? request.context.requestId!,
      model,
      createDownloader(),
      stopPreflight,
    );
    void check() {
      if (_closed || job.cancelled || !(current?.call() ?? true)) {
        job.cancel();
        throw operationCancelled();
      }
    }

    void notify({bool force = false}) {
      if (force || job.notice.elapsedMilliseconds >= 100) {
        job.notice.reset();
        if (!_closed) changed();
      }
    }

    final monitor = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_closed || !(current?.call() ?? true)) job.cancel();
    });
    try {
      notify(force: true);
      check();
      final existing = await _local(
        request.kind,
        model,
        current: () => !_closed && !job.cancelled && (current?.call() ?? true),
      );
      check();
      if (existing == null &&
          store.preference(
                'modelTerms.${model.repository}.${model.revision}',
              ) !=
              'accepted') {
        throw RpcError(RpcErrorCode.invalidArgument, modelTermsRequiredMessage);
      }
      if (request.kind != 'speech') await _prepare(job, check);
      check();
      final file = await job.downloader.download(
        model,
        _root(request.kind),
        existingFile: existing,
        progress: (received, total) {
          check();
          job.received = received;
          job.total = total;
          notify();
        },
        phase: (phase) {
          check();
          job.phase = phase;
          notify(force: true);
        },
      );
      check();
      return ModelAssetLocation(file.path).toWire();
    } on ModelDownloadCancelled {
      throw operationCancelled();
    } on ModelAssetFailure catch (failure) {
      throw failure.toRpcError();
    } on RpcError {
      rethrow;
    } on ModelTransportException catch (failure) {
      if (failure.failureType == 'worker_exit_unknown') {
        _restartRequired = true;
        throw RpcError(
          RpcErrorCode.unavailable,
          modelAcquisitionRestartMessage,
        );
      }
      throw ModelAssetFailure(
        failure.failureType == 'total_timeout'
            ? ModelAssetFailureCode.interrupted
            : ModelAssetFailureCode.invalid,
      ).toRpcError();
    } catch (_) {
      throw ModelAssetFailure(ModelAssetFailureCode.invalid).toRpcError();
    } finally {
      monitor.cancel();
      try {
        try {
          job.downloader.cancel();
        } finally {
          await _retirePreflight(job);
        }
      } finally {
        job.active = false;
        _last = job;
        if (identical(_active, job)) _active = null;
        if (!job.finished.isCompleted) job.finished.complete();
        if (!_closed) changed();
      }
    }
  }

  Future<void> _retirePreflight(_AssetDownload job) async {
    final process = job.preflight;
    if (process == null) return;
    try {
      await (job.stopping ??= stopPreflight(process));
    } catch (_) {
      // We cannot claim reaping or admit a replacement child after an unknown
      // physical outcome. Bookkeeping and shutdown still settle finitely.
      _restartRequired = true;
    } finally {
      job.preflight = null;
    }
  }

  Future<void> _prepare(_AssetDownload job, void Function() check) async {
    if (_prepareGemma case final prepare?) {
      await prepare(() => !_closed && !job.cancelled);
      check();
      return;
    }
    final config = configuration;
    final runner = config['FORESIGHT_LITERT_RUNNER'];
    if (runner == null || runner.isEmpty) {
      throw RpcError(RpcErrorCode.unavailable, modelRuntimeUnavailableMessage);
    }
    final process = await _launchPreflight(runner, config);
    job.preflight = process;
    final out = process.stdout.listen((_) {}, onError: (Object _) {});
    final error = process.stderr.listen((_) {}, onError: (Object _) {});
    try {
      check();
      final code = await Future.any<int>([
        process.exitCode,
        job.cancelledSignal.future.then<int>((_) => throw operationCancelled()),
      ]).timeout(const Duration(seconds: 30));
      check();
      if (code != 0) {
        throw RpcError(RpcErrorCode.unavailable, modelRuntimeNotReadyMessage);
      }
    } on TimeoutException {
      throw RpcError(RpcErrorCode.unavailable, modelRuntimeNotReadyMessage);
    } finally {
      await _retirePreflight(job);
      // Output is discarded; close our pipe subscriptions instead of waiting
      // for EOF from a descendant that may have inherited the runner's pipes.
      try {
        await Future.wait([
          out.cancel(),
          error.cancel(),
        ]).timeout(const Duration(seconds: 2));
      } catch (_) {
        _restartRequired = true;
      }
      if (_restartRequired) {
        throw RpcError(
          RpcErrorCode.unavailable,
          modelAcquisitionRestartMessage,
        );
      }
    }
  }

  Future<Process> _launchPreflight(
    String runner,
    RuntimeConfiguration config,
  ) async {
    try {
      return await (startPreflight?.call(runner) ??
          Process.start(
            requireInstalledRuntime(runner, configuration: config),
            ['--check'],
            environment: config.environment,
          ));
    } catch (_) {
      throw RpcError(RpcErrorCode.unavailable, modelRuntimeUnavailableMessage);
    }
  }

  void stop() {
    _closed = true;
    _active?.cancel();
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stop();
    await _active?.finished.future;
  });
  List<OperationHandler> get handlers => [
    TypedOperationHandler<ModelsDownloadAssetRequest>(
      Operation.modelsDownloadAsset,
      download,
    ),
    TypedOperationHandler<ModelsInspectAssetRequest>(
      Operation.modelsInspectAsset,
      inspect,
    ),
  ];
}
