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
import 'store.dart';
import 'helper.dart';
import 'native.dart';
import 'web_search.dart';
import 'web_content.dart';
import 'generated/rag_service.pbgrpc.dart';

/// An independently disposable waiter on shared, uncancelled work.
class CancellationWatch {
  final bool Function() current;
  final _signal = Completer<void>();
  final void Function(CancellationWatch) _remove;
  CancellationWatch(this.current, this._remove);
  Future<void> get future => _signal.future;
  void dispose() => _remove(this);
  void check() {
    if (!current() && !_signal.isCompleted) {
      _signal.completeError(
        RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      );
    }
  }
}

class Domain {
  final Store store;
  final Helper helper;
  NativeRuntime? generator;
  final Clock clock;
  final Timer Function(Duration, void Function()) createTimer;
  Domain(
    this.store,
    this.helper, {
    SearchCallbacks? webSearch,
    ModelGate? modelGate,
    Clock? clock,
    Timer Function(Duration, void Function())? createTimer,
  }) : modelGate = modelGate ?? const IdleModelGate(),
       _webSearch = webSearch,
       clock = clock ?? const Clock(),
       createTimer = createTimer ?? Timer.new;
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
  bool get closed => _closed;
  int _workspaceGeneration = 0;
  int get workspaceGeneration => _workspaceGeneration;

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
    for (final row in store.rows(
      'SELECT document_id FROM pending_helper_deletes',
    )) {
      final id = row['document_id'] as String;
      try {
        final result = await helper.client.deleteDocument(
          DeleteRequest(documentId: id, userId: helperUserId),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        );
        if (result.success) {
          store.db.execute(
            'DELETE FROM pending_helper_deletes WHERE document_id=?',
            [id],
          );
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
        throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
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
    if (_ownedWebContent != null) unawaited(_ownedWebContent!.close());
    _wakeSourceWork();
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
              store.rows(
                    'SELECT content FROM sources WHERE id=? AND deleted=0',
                    [source['id']],
                  ).single['content']
                  as String,
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

  Future<void> index(String id, {bool Function()? current}) async {
    final generation = workspaceGeneration;
    while (true) {
      // Wait outside the mutation queue so deletions can still proceed.
      await waitForSourceWork(current: current);
      checkWorkspace(generation);
      final completed = await _serialize(() async {
        // Pause may have happened while an earlier mutation was finishing.
        if (sourcesPaused) return false;
        await _index(id);
        return true;
      });
      if (completed) return;
    }
  }

  Future<void> _index(String id) async {
    final generation = workspaceGeneration;
    final current = store.rows(
      'SELECT * FROM sources WHERE id=? AND deleted=0',
      [id],
    );
    if (current.isEmpty) return;
    final source = current.first;
    // Imports can arrive during first-run setup.
    // Keep their content durable until a model is configured instead of sending
    // an IndexDocument request to an explicitly unconfigured helper.
    if (store.model('embedding') == null &&
        helper.snapshot?.pipeline == 'unconfigured') {
      store.state(id, 'pending');
      return;
    }
    // A deterministic Calendar/meeting ID can be reused after clear. Delete the
    // old helper copy before indexing its replacement, within the mutation queue.
    if (store.rows(
      'SELECT document_id FROM pending_helper_deletes WHERE document_id=?',
      [id],
    ).isNotEmpty) {
      final deleted = await helper.client.deleteDocument(
        DeleteRequest(documentId: id, userId: helperUserId),
        options: CallOptions(timeout: const Duration(seconds: 5)),
      );
      checkWorkspace(generation);
      if (!deleted.success) throw StateError('Helper purge has not completed');
      store.db.execute(
        'DELETE FROM pending_helper_deletes WHERE document_id=?',
        [id],
      );
    }
    store.state(id, 'indexing');
    try {
      final r = await helper.client.indexDocument(
        IndexRequest(
          documentId: id,
          content: source['content'] as String,
          mimeType: source['mime'] as String,
          userId: helperUserId,
          maxTokensPerChunk: 480,
          chunkOverlap: 5,
        ),
        options: CallOptions(timeout: const Duration(minutes: 30)),
      );
      checkWorkspace(generation);
      if (!r.success) throw StateError(r.errorMessage);
      store.db.execute(
        "UPDATE sources SET state='indexed',error='' WHERE id=? AND revision=? AND deleted=0",
        [id, source['revision']],
      );
    } catch (e) {
      checkWorkspace(generation);
      // Cover the race before the first helper state event arrives. Other
      // preconditions and configured-model failures retain their normal errors.
      if (store.model('embedding') == null &&
          e is GrpcError &&
          e.code == StatusCode.failedPrecondition &&
          e.message == 'Pipeline not initialized') {
        store.db.execute(
          "UPDATE sources SET state='pending',error='' WHERE id=? AND revision=? AND deleted=0",
          [id, source['revision']],
        );
        return;
      }
      store.db.execute(
        "UPDATE sources SET state='failed',error=? WHERE id=? AND revision=? AND deleted=0",
        [e.toString(), id, source['revision']],
      );
      rethrow;
    }
  }

  Future<void> delete(String id) {
    _checkOpen();
    store.tombstone(id);
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
      store.state(id, 'deleted');
    } catch (e) {
      checkWorkspace(generation);
      store.state(id, 'delete_failed', e.toString());
      rethrow;
    }
  }

  Future<void> reconcile() async {
    for (final s in store.rows(
      'SELECT id FROM sources WHERE deleted=1 AND state!=\'deleted\'',
    )) {
      await delete(s['id'] as String);
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
    final model = store.model('generation');
    if (model == null) {
      final candidate = await discoverGenerationRuntime(
        store,
        runtimeConfiguration.nativeLibrary,
        current: () => !_closed,
      );
      if (_closed) {
        candidate?.close();
        _checkOpen();
      }
      if (candidate != null) generator = candidate;
      return;
    }
    final candidate = createNoteEnhancementRuntime();
    candidate.modelType =
        model['model_type'] as int? ??
        referenceGenerationModelType(model['digest'] as String);
    generator?.close();
    generator = candidate;
    try {
      await candidate.load(
        model['runtime'] as String,
        model['path'] as String,
        backend: model['backend'] as String? ?? 'llama_cpp',
      );
      if (_closed || !identical(generator, candidate)) {
        candidate.close();
        _checkOpen();
      }
    } catch (_) {
      if (_closed || !identical(generator, candidate)) candidate.close();
      rethrow;
    }
  }

  Future<void> resetNoteEnhancementService() async {
    _checkOpen();
    generator?.close();
    generator = null;
    _noteServiceInitialization = null;
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
    final embedding = store
        .rows("SELECT * FROM models WHERE kind='embedding'")
        .firstOrNull;
    if (embedding != null) {
      final ready = await helper.hasActiveModel(
        embedding['path'] as String,
        embedding['digest'] as String,
        embedding['backend'] == 'litert_lm_embedding_gpu',
      );
      _checkOpen();
      if (!ready) {
        final result = await helper.client.updateModelPaths(
          UpdateModelPathsRequest(
            embeddingModelPath: embedding['path'] as String,
            sentencePieceModelPath: embedding['runtime'] as String,
            useGpu: embedding['backend'] == 'litert_lm_embedding_gpu',
          ),
          options: CallOptions(timeout: const Duration(minutes: 30)),
        );
        _checkOpen();
        if (!result.success) throw StateError(result.errorMessage);
      }
    }
    if (generator == null && store.model('generation') == null) {
      generator = await discoverGenerationRuntime(
        store,
        runtimeConfiguration.nativeLibrary,
        current: () => !_closed,
      );
    }
    if (generator == null) {
      final gen = store.model('generation');
      if (gen != null) {
        generator = NativeRuntime(runtimeConfiguration.nativeLibrary);
        generator!.modelType =
            gen['model_type'] as int? ??
            referenceGenerationModelType(gen['digest'] as String);
        await generator!.load(
          gen['runtime'] as String,
          gen['path'] as String,
          backend: gen['backend'] as String? ?? 'llama_cpp',
        );
      }
    }
    _checkOpen();
    await reconcile();
    _checkOpen();
    schedulePendingSources();
  }

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
    store.db.execute(
      "UPDATE sources SET state='pending',error='' WHERE deleted=0 AND state='failed' AND error LIKE 'gRPC Error%Pipeline not initialized%'",
    );
    // Snapshot identifiers only; a large library's document bodies must not be
    // materialized on the startup/model-registration path.
    for (final source in store.rows(
      "SELECT id FROM sources WHERE deleted=0 AND state IN ('indexing','pending') ORDER BY title",
    )) {
      if (closed || generation != workspaceGeneration) break;
      try {
        await index(source['id'] as String);
      } catch (error) {
        if (closed || generation != workspaceGeneration) break;
        // index() persists document failures. Keep processing unrelated imports.
        developer.log('Queued source ${source['id']}', error: error);
      }
    }
  }

  bool citationCurrent(Map<String, Object?> citation) {
    final source = store.rows(
      'SELECT revision,deleted FROM sources WHERE id=?',
      [citation['document_id']],
    );
    return source.isNotEmpty &&
        source.first['deleted'] == 0 &&
        source.first['revision'] == citation['revision'];
  }
}

/// UTF-8 byte limit is conservative for byte-level model tokenizers; no silent Unicode corruption.
String boundUtf8(String text, int budget) {
  final output = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final part = String.fromCharCode(rune);
    final size = utf8.encode(part).length;
    if (used + size > budget) break;
    output.write(part);
    used += size;
  }
  return output.toString();
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
