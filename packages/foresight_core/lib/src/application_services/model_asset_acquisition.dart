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
  _AssetDownload(this.requestId, this.model, this.downloader);
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
    downloader.cancel();
    if (preflight case final process?) {
      (stopping ??= _stopProcess(process)).ignore();
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
  }) : createDownloader = createDownloader ?? PublicModelFileDownloader.new,
       _prepareGemma = prepareGemma,
       _catalog = catalog,
       modelRoot =
           modelRoot ?? Directory('${File(store.path).parent.path}/models');
  final Store store;
  final void Function() changed;
  final Directory modelRoot;
  final ModelDownloader Function() createDownloader;
  final Future<void> Function(bool Function())? _prepareGemma;
  final Iterable<GemmaModel> Function(String kind)? _catalog;
  _AssetDownload? _active, _last;
  bool _closed = false;
  Future<void>? _closing;
  bool get busy => _active != null;
  ModelAssetDownloadPresentation get state {
    final job = _active ?? _last;
    return job == null
        ? const ModelAssetDownloadPresentation()
        : ModelAssetDownloadPresentation(
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
  Future<File?> _local(String kind, GemmaModel model) => localModelFile(
    model,
    _root(kind),
    registration: store.sourceQueries.model(kind)?.toRow(),
  );
  Future<Object?> inspect(
    ModelsInspectAssetRequest request, {
    bool Function()? current,
  }) async {
    if (_closed) {
      throw RpcError(RpcErrorCode.unavailable, 'Model acquisition is closed');
    }
    final file = await _local(
      request.kind,
      _model(request.kind, request.digest),
    );
    if (_closed || !(current?.call() ?? true)) throw operationCancelled();
    return ModelAssetLocation(file?.path).toWire();
  }

  Future<Object?> download(
    ModelsDownloadAssetRequest request, {
    bool Function()? current,
  }) async {
    if (_closed) {
      throw RpcError(RpcErrorCode.unavailable, 'Model acquisition is closed');
    }
    if (busy) {
      throw RpcError(RpcErrorCode.busy, 'A model download is already active');
    }
    final model = _model(request.kind, request.digest);
    final job = _active = _AssetDownload(
      request.context.requestId!,
      model,
      createDownloader(),
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
      final existing = await _local(request.kind, model);
      check();
      if (existing == null &&
          store.preference(
                'modelTerms.${model.repository}.${model.revision}',
              ) !=
              'accepted') {
        throw RpcError(
          RpcErrorCode.invalidArgument,
          'Review and accept the pinned model terms before downloading',
        );
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
    } finally {
      monitor.cancel();
      job.downloader.cancel();
      if (job.preflight case final process?) {
        await (job.stopping ??= _stopProcess(process));
      }
      job.active = false;
      _last = job;
      if (identical(_active, job)) _active = null;
      if (!job.finished.isCompleted) job.finished.complete();
      if (!_closed) changed();
    }
  }

  Future<void> _prepare(_AssetDownload job, void Function() check) async {
    if (_prepareGemma case final prepare?) {
      await prepare(() => !_closed && !job.cancelled);
      check();
      return;
    }
    final runner = runtimeConfiguration['FORESIGHT_LITERT_RUNNER'];
    if (runner == null || runner.isEmpty) {
      throw StateError('The local Gemma runtime is unavailable');
    }
    final process = await Process.start(
      requireInstalledRuntime(runner),
      ['--check'],
      environment: runtimeConfiguration.environment,
    );
    job.preflight = process;
    final out = process.stdout.drain<void>(),
        error = process.stderr.drain<void>();
    try {
      check();
      final code = await process.exitCode.timeout(const Duration(seconds: 30));
      check();
      if (code != 0) throw StateError('The local Gemma runtime is not ready');
    } finally {
      await (job.stopping ??= _stopProcess(process));
      await Future.wait([out, error]);
      job.preflight = null;
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
