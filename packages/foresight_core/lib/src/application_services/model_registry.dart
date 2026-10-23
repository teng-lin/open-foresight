import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';

import '../dedicated_query_acquisition.dart';
import '../dedicated_query_runtime.dart';
import '../domain.dart';
import '../encrypted_query_runtime.dart';
import '../gemma_download.dart' show ModelDownloadCancelled;
import '../generated/rag_service.pb.dart';
import '../model_setup.dart';
import '../native.dart' show liteRtRunner;
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../platform_services.dart';
import '../portable_query_setup.dart';
import '../reference_query_detector.dart';
import '../rpc_error.dart';
import '../runtime_execution_policy.dart';
import '../speech_models.dart';
import '../store.dart';

/// Model registration and the dedicated question runtime share this owner.
/// Generation admission is managed by the application generation gate; network
/// account maintenance is independent of this resource lifetime.
final class ModelRegistry {
  ModelRegistry({
    required this.domain,
    required this.changed,
    required this.ownsDetection,
    required this.wakeDetection,
    required this.invalidateEmbeddings,
    QueryCompletionRuntime? queryRuntime,
  }) : _queryRuntime = queryRuntime,
       providedQueryRuntime = queryRuntime != null;

  final Domain domain;
  final void Function() changed, wakeDetection, invalidateEmbeddings;
  final bool Function(String) ownsDetection;
  final bool providedQueryRuntime;
  QueryCompletionRuntime? _queryRuntime;
  DedicatedQueryAcquisition? _acquisition;
  ResponseFuture<UpdateModelPathsResponse>? _embeddingUpdate;
  String? _queryRegistration;
  int _downloadReceived = 0, _downloadTotal = 0;
  bool _closed = false;
  Future<void>? _closing;
  Store get store => domain.store;

  String get generationDigest =>
      store.sourceQueries.model('generation')?.digest ?? 'unknown';
  bool get acquiring => _acquisition != null;
  Map<String, Object?> get acquisitionState => {
    'active': acquiring,
    'received': _downloadReceived,
    'total': _downloadTotal,
  };
  Map<String, Object?> get detectorState => {
    'configured':
        store.sourceQueries.model(dedicatedQueryModelKind) != null ||
        providedQueryRuntime,
    'ready': _queryRuntime is QueryRuntimeReadiness
        ? (_queryRuntime as QueryRuntimeReadiness).ready
        : _queryRuntime != null,
    'backend': store.sourceQueries.model(dedicatedQueryModelKind)?.backend,
    'output_policy': store.preference('queryOutputPolicy', 'unicode-v2'),
  };

  bool _current(bool Function()? current) =>
      !_closed && (current?.call() ?? true);

  void _notify() {
    if (!_closed) changed();
  }

  void cancelDetection(String request) => _queryRuntime?.cancel(request);

  Future<List<String>> detectQuestions(String text, String request) async {
    if (!providedQueryRuntime) {
      if (store.sourceQueries.model(dedicatedQueryModelKind) == null) {
        await discoverDedicatedQueryModel(store, current: () => !_closed);
      }
      final model = store.sourceQueries.model(dedicatedQueryModelKind);
      final worker = model?.backend == portableQueryBackend
          ? model?.runtime
          : runtimeConfiguration['FORESIGHT_QUERY_WORKER'];
      if (model == null ||
          worker == null ||
          (model.backend != dedicatedQueryBackend &&
              model.backend != portableQueryBackend &&
              model.backend != dedicatedEncryptedQueryBackend)) {
        await _queryRuntime?.close();
        _queryRuntime = null;
        _queryRegistration = null;
        throw StateError(
          'Dedicated question detector is not ready: register its model and runtime',
        );
      }
      final registration = jsonEncode([
        model.path,
        model.digest,
        model.runtime,
        model.backend,
        worker,
      ]);
      if (_queryRegistration != registration) {
        await _queryRuntime?.close();
        _queryRuntime = model.backend == dedicatedEncryptedQueryBackend
            ? EncryptedDedicatedQueryRuntime(
                python: model.runtime,
                worker: worker,
                encryptedModel: model.path,
                vaultRoot: File(model.path).parent,
              )
            : DedicatedQueryRuntime(
                python: model.runtime,
                worker: worker,
                model: model.path,
              );
        _queryRegistration = registration;
      }
    }
    if (_closed || !ownsDetection(request)) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Dedicated query detection cancelled',
      );
    }
    return ReferenceQueryDetector(
      _queryRuntime!.complete,
      preserveUnicode:
          store.preference('queryOutputPolicy', 'unicode-v2') == 'unicode-v2',
    ).detect(text, request);
  }

  Future<void> acquireQuery({bool Function()? current}) async {
    if (dedicatedQueryTermsUri() == null ||
        store.preference(dedicatedQueryTermsKey) != 'accepted') {
      throw RpcError(
        RpcErrorCode.denied,
        'Review and accept the configured question model terms for this revision before downloading.',
      );
    }
    final acquisition = DedicatedQueryAcquisition.distribution(store);
    _acquisition = acquisition;
    _downloadReceived = _downloadTotal = 0;
    _notify();
    try {
      await acquisition.run(
        current: () => _current(current),
        onProgress: (received, total) {
          _downloadReceived = received;
          _downloadTotal = total;
          _notify();
        },
      );
    } finally {
      _acquisition = null;
      _notify();
    }
  }

  Future<void> configureSpeechModel(
    ModelsSpeechRequest request, {
    bool Function()? current,
  }) async {
    try {
      await configureSpeech(
        store,
        File(request.path),
        request.runtime,
        request.digest,
        current: () => _current(current),
      );
    } on ModelDownloadCancelled catch (error) {
      throw RpcError(RpcErrorCode.cancelled, error.toString());
    }
  }

  Future<void> register(
    ModelsRegisterRequest request, {
    bool Function()? current,
  }) async {
    if (request.kind == dedicatedQueryModelKind) {
      if (request.backend == portableQueryBackend) {
        await configurePortableQuery(
          store,
          request.path,
          request.runtime!,
          request.digest!,
          current: () => _current(current),
        );
        await _queryRuntime?.close();
        _queryRuntime = null;
        _queryRegistration = null;
        wakeDetection();
        return;
      }
      if (request.backend != null && request.backend != dedicatedQueryBackend) {
        throw StateError('Unsupported dedicated question model backend');
      }
      await configureDedicatedQuery(
        store,
        request.path,
        runtime: request.runtime,
        expectedDigest: request.digest,
        current: () => _current(current),
      );
      return;
    }
    final runtime =
        request.kind == 'generation' && request.backend == 'litert_lm'
        ? requireInstalledRuntime(liteRtRunner(request.runtime ?? ''))
        : request.runtime ?? '';
    await store.register(
      request.kind,
      request.path,
      runtime,
      backend: request.backend,
      expectedDigest: request.digest,
      modelType: request.modelType,
      current: () => _current(current),
    );
  }

  Future<void> configureGenerationModel(
    ModelsGenerationRequest request, {
    bool Function()? current,
  }) async {
    final candidate = await configureGeneration(
      store,
      runtimeConfiguration.nativeLibrary,
      request.path,
      request.runtime,
      backend: request.backend,
      modelType: request.modelType,
      current: () => _current(current),
    );
    domain.generator?.close();
    domain.generator = candidate;
  }

  Future<void> configureEmbeddingModel(
    ModelsEmbeddingRequest request, {
    bool Function()? current,
  }) async {
    requireEmbeddingBundle(request.path);
    final update = domain.helper.client.updateModelPaths(
      UpdateModelPathsRequest(
        embeddingModelPath: request.path,
        sentencePieceModelPath: request.runtime,
        useGpu: request.gpu,
      ),
      options: CallOptions(timeout: const Duration(minutes: 30)),
    );
    _embeddingUpdate = update;
    late final UpdateModelPathsResponse result;
    try {
      result = await update;
    } on GrpcError catch (error) {
      if (error.code == StatusCode.cancelled && !_current(current)) {
        throw RpcError(RpcErrorCode.cancelled, 'Model configuration cancelled');
      }
      rethrow;
    } finally {
      if (identical(_embeddingUpdate, update)) _embeddingUpdate = null;
    }
    if (!result.success) throw StateError(result.errorMessage);
    // Adoption already changed the vector space even if registration fails.
    invalidateEmbeddings();
    await store.register(
      'embedding',
      request.path,
      request.runtime,
      backend: request.gpu
          ? 'litert_lm_embedding_gpu'
          : 'litert_lm_embedding_cpu',
      expectedDigest: request.digest,
      current: () => _current(current),
    );
    domain.schedulePendingSources();
  }

  Future<void> cancelAcquisition() async {
    final acquisition = _acquisition;
    await acquisition?.close();
    if (acquisition != null) {
      try {
        await acquisition.done;
      } catch (_) {
        // The owned acquisition has settled after cancellation.
      }
    }
  }

  void stop() {
    _closed = true;
    // Cancel only this owner's adoption RPC. Its future must settle so the
    // configuration reservation can join before the helper is shut down.
    _embeddingUpdate?.cancel().ignore();
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stop();
    await cancelAcquisition();
    await _queryRuntime?.close();
  });

  List<OperationHandler> get handlers => [
    TypedOperationHandler<ModelsCancelQueryAcquisitionRequest>(
      Operation.modelsCancelQueryAcquisition,
      (request, {current}) => cancelAcquisition(),
    ),
    TypedOperationHandler<ModelsAcquireQueryRequest>(
      Operation.modelsAcquireQuery,
      (request, {current}) => acquireQuery(current: current),
    ),
    TypedOperationHandler<ModelsSpeechRequest>(
      Operation.modelsSpeech,
      configureSpeechModel,
    ),
    TypedOperationHandler<ModelsRegisterRequest>(
      Operation.modelsRegister,
      register,
    ),
    TypedOperationHandler<ModelsGenerationRequest>(
      Operation.modelsGeneration,
      configureGenerationModel,
    ),
    TypedOperationHandler<ModelsEmbeddingRequest>(
      Operation.modelsEmbedding,
      configureEmbeddingModel,
    ),
  ];
}
