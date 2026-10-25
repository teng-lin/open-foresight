import 'generation_runtime_slot.dart';
import 'application_services/service_runtime_ports.dart';
import 'package:meta/meta.dart';
import 'cancellation.dart';
export 'cancellation.dart' show CancellationWatch;
import 'text_budget.dart' show boundUtf8;
export 'text_budget.dart' show boundUtf8;
import 'rpc_error.dart';
import 'package:clock/clock.dart';
import 'model_setup.dart';
import 'model_asset_lifecycle.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:developer' as developer;
import 'model_gate.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';
import 'package:grpc/service_api.dart' as grpc_api;
import 'store.dart';
import 'persistence/domain_queries.dart';
import 'helper.dart';
import 'native.dart';
import 'web_search.dart';
import 'web_content.dart';
import 'generated/rag_service.pbgrpc.dart';
import 'generated/transcript_index.pbgrpc.dart' as transcript;

typedef GenerationRuntimeDiscovery =
    Future<NativeRuntime?> Function(
      Store store,
      String library, {
      bool Function()? current,
      void Function(NativeRuntime)? onCandidate,
      Future<void> Function(NativeRuntime)? retire,
    });

class Domain implements RecordingWorkspace, SummaryWorkspace, ModelWorkspace {
  @override
  final Store store;
  @override
  final Helper helper;
  late final _queries = DomainQueries(store);
  @override
  late final GenerationRuntimeSlot<NativeRuntime> generationRuntimes =
      GenerationRuntimeSlot<NativeRuntime>(
        closeRuntime: (runtime) => runtime.close(),
        runtimeClosed: (runtime) => runtime.closed,
        runtimeBusy: (runtime) => runtime.generating,
        checkRuntime: (runtime) => runtime.checkAvailable(),
        watchRuntime: (runtime, changed) =>
            runtime.onOwnershipChanged = changed,
        changed: () => onBackgroundSettled?.call(),
      );
  @override
  NativeRuntime? get generator => generationRuntimes.visible;
  @visibleForTesting
  set generator(NativeRuntime? runtime) =>
      generationRuntimes.installForTesting(runtime);
  bool get generationBusy => generationRuntimes.busy;
  Object? get generationFailure => generationRuntimes.failure;
  bool get generationRestartRequired => generationRuntimes.restartRequired;
  void stopGeneration() => generationRuntimes.stop();
  @override
  final Clock clock;
  @override
  final Timer Function(Duration, void Function()) createTimer;
  final GenerationRuntimeDiscovery _discoverGeneration;
  Domain(
    this.store,
    this.helper, {
    SearchCallbacks? webSearch,
    ModelGate? modelGate,
    Clock? clock,
    Timer Function(Duration, void Function())? createTimer,
    GenerationRuntimeDiscovery? discoverGeneration,
  }) : modelGate = modelGate ?? const IdleModelGate(),
       _webSearch = webSearch,
       clock = clock ?? const Clock(),
       createTimer = createTimer ?? Timer.new,
       _discoverGeneration = discoverGeneration ?? discoverGenerationRuntime;
  Future<void> Function(int, {bool Function()? current})?
  indexMeetingTranscript;
  ModelGate modelGate;
  SearchCallbacks? _webSearch;
  WebContentService? _ownedWebContent;
  bool get webSearchAvailable =>
      _webSearch != null ||
      ((runtimeConfiguration['FORESIGHT_SEARCH_API_KEY'] ?? '').isNotEmpty &&
          (runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'] ?? '')
              .isNotEmpty);

  SearchCallbacks searchCallbacks() {
    if (!webSearchAvailable) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Web search is unavailable in this build.',
      );
    }
    return _webSearch ??= SearchCallbacks(
      search: SearchService(
        apiKey: runtimeConfiguration['FORESIGHT_SEARCH_API_KEY']!,
      ).search,
      summarize: (_ownedWebContent ??= WebContentService(
        apiKey: runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY']!,
      )).summarizeSearchPage,
    );
  }

  bool _closed = false;
  @override
  bool get closed => _closed;
  int _workspaceGeneration = 0;
  @override
  int get workspaceGeneration => _workspaceGeneration;

  @override
  void checkWorkspace(int generation) {
    _checkOpen();
    if (generation != _workspaceGeneration) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Workspace was cleared; retry the operation',
      );
    }
  }

  /// Invalidate work before deleting local data.
  void invalidateWorkspace() {
    _workspaceGeneration++;
    checkCancellations();
  }

  final _cancellations = <CancellationWatch>{};

  /// Test-only observation that every shared-work waiter disposes its watch.
  int get cancellationWatchCount => _cancellations.length;
  CancellationWatch whenCancelled(bool Function() current) {
    final watch = CancellationWatch(current, _cancellations.remove);
    _cancellations.add(watch);
    watch.check();
    return watch;
  }

  void checkCancellations() {
    for (final watch in _cancellations.toList()) {
      watch.check();
    }
  }

  Future<T> awaitCurrent<T>(Future<T> shared, bool Function()? current) async {
    if (current == null) return shared;
    shared.ignore();
    final watch = whenCancelled(current);
    try {
      return await Future.any<T>([
        shared,
        watch.future.then<T>(
          (_) => throw StateError('Cancellation waiter completed'),
        ),
      ]);
    } finally {
      watch.dispose();
    }
  }

  /// Durable deletes survive helper downtime and are retried on reconnect.
  Future<void> retryPendingHelperDeletes() => _serialize(() async {
    final generation = workspaceGeneration;
    for (final id in _queries.pendingHelperDeletes()) {
      try {
        checkWorkspace(generation);
        final result = await helper.client.deleteDocument(
          DeleteRequest(documentId: id, userId: helperUserId),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        );
        // The owner may have closed its Store or cleared again during the RPC.
        checkWorkspace(generation);
        if (result.success) {
          _queries.acknowledgeHelperDelete(id);
        }
      } on GrpcError catch (error) {
        // Keep unacknowledged rows. A transport failure affects the entire
        // helper, so do not spend another RPC deadline on each queued row.
        if (error.code == StatusCode.deadlineExceeded ||
            error.code == StatusCode.unavailable ||
            error.code == StatusCode.cancelled) {
          break;
        }
        // Document-level errors must not starve the remaining rows.
      } catch (_) {
        // Unknown failures cannot establish that further RPCs are safe.
        break;
      }
    }
  });

  void cleanupClearedSources(List<String> sourceIds) {
    unawaited(retryPendingHelperDeletes().catchError((Object _) {}));
  }

  bool _sourcesPaused = false;
  bool get sourcesPaused => _sourcesPaused;
  Completer<void>? _sourceWorkResumed;
  void pauseSources() {
    _checkOpen();
    _sourcesPaused = true;
  }

  void resumeSources() {
    _checkOpen();
    _sourcesPaused = false;
    _wakeSourceWork();
  }

  void _wakeSourceWork() {
    final signal = _sourceWorkResumed;
    _sourceWorkResumed = null;
    signal?.complete();
  }

  Future<void> waitForSourceWork({bool Function()? current}) async {
    void check() {
      _checkOpen();
      if (current != null && !current()) {
        throw operationCancelled();
      }
    }

    check();
    while (sourcesPaused) {
      await awaitCurrent(
        (_sourceWorkResumed ??= Completer<void>()).future,
        current,
      );
      checkCancellations();
      check();
    }
  }

  void close() {
    _closed = true;
    stopGeneration();
    indexMeetingTranscript = null;
    checkCancellations();
    if (_ownedWebContent != null) unawaited(_ownedWebContent!.close());
    _wakeSourceWork();
  }

  /// Join owned RPC cancellation and channel teardown before the helper or
  /// Store is released. Call [close] first to refuse later mutation admission.
  Future<void> drain() async {
    if (!_closed) throw StateError('Close Domain before draining its work');
    checkCancellations();
    await Future.wait<void>([_mutationTail, generationRuntimes.drain()]);
  }

  void _checkOpen() {
    if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Workspace closed');
  }

  int mutating = 0;
  void Function()? onBackgroundSettled;
  Future<void> _mutationTail = Future<void>.value();
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final generation = workspaceGeneration;
    final task = _mutationTail.then((_) async {
      checkWorkspace(generation);
      mutating++;
      try {
        return await operation();
      } finally {
        mutating--;
        onBackgroundSettled?.call();
      }
    });
    _mutationTail = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) async {
    _checkOpen();
    final identity = helper.snapshot?.model.writeToJson();
    if (helper.snapshot?.pipeline != 'ready' || sourcesPaused) return {};
    final result = <String, List<double>>{};
    for (final source in sources) {
      _checkOpen();
      if (sourcesPaused || helper.snapshot?.pipeline != 'ready') return {};
      final response = await helper.client.computeEmbedding(
        ComputeEmbeddingRequest(
          text:
              source['content'] as String? ??
              _queries.graphSourceContent(source['id']),
        ),
      );
      _checkOpen();
      if (helper.snapshot?.model.writeToJson() != identity) return {};
      result[source['id'] as String] = Float32List.fromList(
        response.embedding,
      ).toList();
    }
    return result;
  }

  /// One bounded operation-owned channel under the mutation queue isolates late
  /// frames from a canceled stream from unrelated helper/control clients. The
  /// pinned HTTP/2 transport otherwise treats late canceled response headers as
  /// a connection error. No request or sibling is replayed to mask that race.
  Future<T> _ownedIndexCall<T>(
    ResponseFuture<T> Function(grpc_api.ClientChannel) invoke, {
    bool Function()? current,
  }) async {
    if (_closed || (current != null && !current())) throw operationCancelled();
    final channel = helperChannel(helper.socket);
    try {
      return await _awaitIndexResponse(invoke(channel), current: current);
    } finally {
      try {
        await channel.terminate();
      } catch (_) {
        // Transport cleanup cannot replace the original operation outcome.
      }
    }
  }

  /// This watch belongs to the producer, not a subscriber racing its result.
  /// Cancel the actual gRPC request, then join its response and cancellation
  /// before the mutation queue releases the producer's reservation.
  Future<T> _awaitIndexResponse<T>(
    ResponseFuture<T> request, {
    bool Function()? current,
  }) async {
    final generation = workspaceGeneration;
    bool valid() =>
        !_closed &&
        generation == workspaceGeneration &&
        (current?.call() ?? true);
    final watch = whenCancelled(valid);
    Future<void>? cancellation;
    watch.future
        .then<void>(
          (_) {},
          onError: (Object _) {
            cancellation = Future<void>.sync(request.cancel);
            cancellation!.ignore();
          },
        )
        .ignore();
    try {
      final result = await request;
      if (!valid()) throw operationCancelled();
      return result;
    } catch (_) {
      if (!valid()) throw operationCancelled();
      rethrow;
    } finally {
      watch.dispose();
      try {
        if (cancellation != null) await cancellation;
      } catch (_) {
        // Preserve the response/cancellation outcome after cleanup was tried.
      }
    }
  }

  /// Read the helper's committed incremental cursor after any durable purge.
  /// The cursor is advisory; ApplyDelta checks it atomically before mutation.
  Future<transcript.TranscriptCursor> transcriptCursor(
    String id, {
    bool Function()? current,
  }) => _serialize(() async {
    if (current != null && !current()) throw operationCancelled();
    final generation = workspaceGeneration;
    if (_queries.helperDeletePending(id)) {
      final deleted = await _ownedIndexCall(
        (channel) => helperClient(channel).deleteDocument(
          DeleteRequest(documentId: id, userId: helperUserId),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        ),
        current: current,
      );
      checkWorkspace(generation);
      if (!deleted.success) throw StateError('Helper purge has not completed');
      _queries.acknowledgeHelperDelete(id);
    }
    final result = await _ownedIndexCall(
      (channel) => transcript.TranscriptIndexClient(channel).getCursor(
        transcript.TranscriptCursorRequest(documentId: id),
        options: CallOptions(timeout: const Duration(seconds: 5)),
      ),
      current: current,
    );
    checkWorkspace(generation);
    return result;
  });

  /// Send only changed immutable transcript segments. No full source body is
  /// read, concatenated or tokenized on this path. Cancellation retains the
  /// mutation reservation until the actual helper RPC has settled.
  Future<transcript.TranscriptDeltaResult> applyTranscriptDelta(
    transcript.TranscriptDelta delta, {
    bool Function()? current,
  }) async {
    final generation = workspaceGeneration;
    while (true) {
      await waitForSourceWork(current: current);
      checkWorkspace(generation);
      final result = await _serialize(() async {
        if (sourcesPaused) return null;
        if (current != null && !current()) throw operationCancelled();
        if (_queries.helperDeletePending(delta.documentId)) {
          throw operationCancelled();
        }
        final result = await _ownedIndexCall(
          (channel) => transcript.TranscriptIndexClient(channel).applyDelta(
            delta,
            options: CallOptions(timeout: const Duration(seconds: 45)),
          ),
          current: current,
        );
        checkWorkspace(generation);
        return result;
      });
      if (result != null) return result;
    }
  }

  @override
  Future<void> index(String id, {bool Function()? current}) async {
    _checkOpen();
    checkCancellations();
    final route = indexMeetingTranscript;
    if (route != null) {
      final meeting = _queries.generatedTranscriptMeeting(id);
      if (meeting != null) return route(meeting, current: current);
    }
    final generation = workspaceGeneration;
    while (true) {
      // Wait outside the mutation queue so deletions can still proceed.
      await waitForSourceWork(current: current);
      checkWorkspace(generation);
      final completed = await _serialize(() async {
        // Pause may have happened while an earlier mutation was finishing.
        if (sourcesPaused) return false;
        await _index(id, current: current);
        return true;
      });
      if (completed) return;
    }
  }

  Future<void> _index(String id, {bool Function()? current}) async {
    if (current != null && !current()) throw operationCancelled();
    final generation = workspaceGeneration;
    final source = _queries.activeSource(id);
    if (source == null) return;
    // Imports can arrive during first-run setup.
    // Keep their content durable until a model is configured instead of sending
    // an IndexDocument request to an explicitly unconfigured helper.
    if (!_queries.hasModel('embedding') &&
        helper.snapshot?.pipeline == 'unconfigured') {
      _queries.sourceState(id, 'pending');
      return;
    }
    // A deterministic Calendar/meeting ID can be reused after clear. Delete the
    // old helper copy before indexing its replacement, within the mutation queue.
    if (_queries.helperDeletePending(id)) {
      final deleted = await _ownedIndexCall(
        (channel) => helperClient(channel).deleteDocument(
          DeleteRequest(documentId: id, userId: helperUserId),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        ),
        current: current,
      );
      checkWorkspace(generation);
      if (!deleted.success) throw StateError('Helper purge has not completed');
      _queries.acknowledgeHelperDelete(id);
    }
    _queries.sourceState(id, 'indexing');
    try {
      final r = await _ownedIndexCall(
        (channel) => helperClient(channel).indexDocument(
          IndexRequest(
            documentId: id,
            content: source.content,
            mimeType: source.mime,
            userId: helperUserId,
            maxTokensPerChunk: 480,
            chunkOverlap: 5,
          ),
          options: CallOptions(timeout: const Duration(minutes: 30)),
        ),
        current: current,
      );
      checkWorkspace(generation);
      if (!r.success) throw StateError(r.errorMessage);
      _queries.sourceRevisionState(id, source.revision, 'indexed');
    } catch (e) {
      checkWorkspace(generation);
      if (current != null && !current()) {
        _queries.sourceRevisionState(id, source.revision, 'pending');
        throw operationCancelled();
      }
      // Cover the race before the first helper state event arrives. Other
      // preconditions and configured-model failures retain their normal errors.
      if (!_queries.hasModel('embedding') &&
          e is GrpcError &&
          e.code == StatusCode.failedPrecondition &&
          e.message == 'Pipeline not initialized') {
        _queries.sourceRevisionState(id, source.revision, 'pending');
        return;
      }
      _queries.sourceRevisionState(id, source.revision, 'failed', e.toString());
      rethrow;
    }
  }

  Future<void> delete(String id) {
    _checkOpen();
    store.tombstone(id);
    checkCancellations();
    return _serialize(() => _delete(id));
  }

  Future<void> _delete(String id) async {
    final generation = workspaceGeneration;
    try {
      final r = await helper.client.deleteDocument(
        DeleteRequest(documentId: id, userId: helperUserId),
      );
      checkWorkspace(generation);
      if (!r.success) throw StateError(r.errorMessage);
      _queries.sourceState(id, 'deleted');
    } catch (e) {
      checkWorkspace(generation);
      _queries.sourceState(id, 'delete_failed', e.toString());
      rethrow;
    }
  }

  Future<void> reconcile() async {
    for (final id in _queries.unreconciledDeletes()) {
      await delete(id);
    }
  }

  Future<void>? _noteServiceInitialization;

  /// The note producer's lazy service getter shares an initialization future.
  /// Readiness policy and the single reset/reacquisition live in its caller.
  Future<NativeRuntime?> noteEnhancementService() async {
    _checkOpen();
    if (generator?.loaded == true) return generator;
    final pending = _noteServiceInitialization;
    if (pending != null) {
      await pending;
      _checkOpen();
      if (generator?.loaded == true) return generator;
      if (identical(_noteServiceInitialization, pending)) {
        _noteServiceInitialization = null;
      }
    }
    final work = _initializeNoteEnhancementService();
    _noteServiceInitialization = work;
    try {
      await work;
      _checkOpen();
      return generator;
    } finally {
      if (generator?.loaded != true &&
          identical(_noteServiceInitialization, work)) {
        _noteServiceInitialization = null;
      }
    }
  }

  /// Separate construction allows fixture runtimes to exercise real ownership.
  NativeRuntime createNoteEnhancementRuntime() =>
      NativeRuntime(runtimeConfiguration.nativeLibrary);

  Future<void> _initializeNoteEnhancementService() async {
    final workspace = workspaceGeneration;
    await generationRuntimes.replace((attempt) async {
      final model = _queries.generationRegistration();
      if (model == null) {
        return discoverGenerationRuntime(
          store,
          runtimeConfiguration.nativeLibrary,
          current: attempt.current,
          onCandidate: attempt.own,
          retire: attempt.retire,
        );
      }
      final candidate = createNoteEnhancementRuntime();
      attempt.own(candidate);
      candidate.modelType =
          model.modelType ?? referenceGenerationModelType(model.digest);
      await candidate.load(
        model.runtime,
        model.path,
        backend: model.backend ?? 'llama_cpp',
      );
      attempt.check();
      return candidate;
    }, current: () => !_closed && workspace == workspaceGeneration);
  }

  Future<void> resetNoteEnhancementService() async {
    _checkOpen();
    _noteServiceInitialization = null;
    await generationRuntimes.reset();
  }

  Future<void>? _resuming;
  Future<void>? _initialization;
  bool _initializationDone = false;
  bool get initializationPending =>
      _initialization != null && !_initializationDone;
  bool get resumeInProgress => _resuming != null;
  void initialize(Future<void> task) {
    _initializationDone = false;
    _initialization = task.whenComplete(() {
      _initializationDone = true;
      onBackgroundSettled?.call();
    });
    // The restore path reports failures; attaching a listener also covers a
    // bootstrap failure before a helper connection has been established.
    unawaited(_initialization!.catchError((Object _) {}));
  }

  bool get restoring => _resuming != null || _initialization != null;
  Future<void> resume() => _resuming ??= _resume().whenComplete(() {
    _resuming = null;
    onBackgroundSettled?.call();
  });
  Future<void> _resume() async {
    _checkOpen();
    await retryPendingHelperDeletes();
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } finally {
        _initialization = null;
      }
    }
    _checkOpen();
    final embedding = _queries.embeddingRegistration();
    if (embedding != null) {
      final ready = await helper.hasActiveModel(
        embedding.path,
        embedding.digest,
        embedding.backend == 'litert_lm_embedding_gpu',
      );
      _checkOpen();
      if (!ready) {
        final result = await helper.client.updateModelPaths(
          UpdateModelPathsRequest(
            embeddingModelPath: embedding.path,
            sentencePieceModelPath: embedding.runtime,
            useGpu: embedding.backend == 'litert_lm_embedding_gpu',
          ),
          options: CallOptions(timeout: const Duration(minutes: 30)),
        );
        _checkOpen();
        if (!result.success) throw StateError(result.errorMessage);
      }
    }
    if (generator == null) {
      final workspace = workspaceGeneration;
      await generationRuntimes.replace((attempt) async {
        if (!_queries.hasModel('generation')) {
          final candidate = await _discoverGeneration(
            store,
            runtimeConfiguration.nativeLibrary,
            current: attempt.current,
            onCandidate: attempt.own,
            retire: attempt.retire,
          );
          if (candidate != null) {
            attempt.own(candidate);
            return candidate;
          }
          attempt.check();
        }
        final gen = _queries.generationRegistration();
        if (gen == null) return null;
        final candidate = createNoteEnhancementRuntime();
        attempt.own(candidate);
        candidate.modelType =
            gen.modelType ?? referenceGenerationModelType(gen.digest);
        await candidate.load(
          gen.runtime,
          gen.path,
          backend: gen.backend ?? 'llama_cpp',
        );
        attempt.check();
        return candidate;
      }, current: () => !_closed && workspace == workspaceGeneration);
    }
    _checkOpen();
    await reconcile();
    _checkOpen();
    schedulePendingSources();
  }

  @override
  void schedulePendingSources() {
    unawaited(
      indexPendingSources().catchError((Object error) {
        if (!closed) developer.log('Queued source indexing', error: error);
      }),
    );
  }

  Future<void>? _pendingSourceIndexing;

  /// Retry saved imports after model setup, including the specific setup error
  /// persisted by older versions. Document contents/revisions stay unchanged.
  Future<void> indexPendingSources() => _pendingSourceIndexing ??=
      _drainPendingSources().whenComplete(() => _pendingSourceIndexing = null);

  Future<void> _drainPendingSources() async {
    _checkOpen();
    final generation = workspaceGeneration;
    _queries.retryUnconfiguredSources();
    // Snapshot identifiers only; a large library's document bodies must not be
    // materialized on the startup/model-registration path.
    for (final id in _queries.pendingSources()) {
      if (closed || generation != workspaceGeneration) break;
      try {
        await index(id);
      } catch (error) {
        if (closed || generation != workspaceGeneration) break;
        // index() persists document failures. Keep processing unrelated imports.
        developer.log('Queued source $id', error: error);
      }
    }
  }

  bool citationCurrent(Map<String, Object?> citation) =>
      _queries.citationCurrent(citation['document_id'], citation['revision']);
}

/// UTF-8 bytes conservatively bound tokenizer input. Select the beginning,
/// midpoint and ending rather than silently discarding the end of a meeting.
String balancedTranscriptWindow(String text, int budget) {
  if (utf8.encode(text).length <= budget) return text;
  const omitted =
      '\n[Transcript abridged: balanced beginning, middle and ending excerpts; omitted passages are not evidence.]\n';
  final share = (budget - utf8.encode(omitted).length - 20) ~/ 3;
  if (share < 1) {
    throw StateError('Model context is too small for transcript excerpts');
  }
  final runes = text.runes.toList();
  final head = boundUtf8(text, share);
  final middle = boundUtf8(
    String.fromCharCodes(runes.skip(runes.length ~/ 2)),
    share,
  );
  final reverse = String.fromCharCodes(runes.reversed);
  final tail = String.fromCharCodes(
    boundUtf8(reverse, share).runes.toList().reversed,
  );
  return '$omitted$head\n[… ]\n$middle\n[… ]\n$tail';
}
