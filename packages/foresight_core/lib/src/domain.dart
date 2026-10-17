import 'model_setup.dart';
import 'model_asset_lifecycle.dart';
import 'platform_services.dart';
import 'dart:async';
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

class Domain {
  final Store store;
  final Helper helper;
  NativeRuntime? generator;
  Domain(
    this.store,
    this.helper, {
    SearchCallbacks? webSearch,
    ModelGate? modelGate,
  }) : modelGate = modelGate ?? const IdleModelGate(),
       _webSearch = webSearch;
  ModelGate modelGate;
  SearchCallbacks? _webSearch;
  WebContentService? _ownedWebContent;
  bool get webSearchAvailable =>
      _webSearch != null ||
      ((runtimeConfiguration['FORESIGHT_SEARCH_API_KEY'] ?? '').isNotEmpty &&
          (runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'] ?? '')
              .isNotEmpty);

  SearchCallbacks searchCallbacks() {
    if (!webSearchAvailable)
      throw StateError('Web search is unavailable in this build.');
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
    if (generation != _workspaceGeneration)
      throw StateError('Workspace was cleared; retry the operation');
  }

  /// Invalidate work before deleting local data.
  void invalidateWorkspace() => _workspaceGeneration++;

  /// Run after committing local deletion and any helper mutation in progress.
  void cleanupClearedSources(List<String> sourceIds) {
    unawaited(
      _serialize(() async {
        for (final id in sourceIds) {
          try {
            await helper.client.deleteDocument(
              DeleteRequest(documentId: id, userId: 'local_user'),
              options: CallOptions(timeout: const Duration(seconds: 5)),
            );
          } catch (_) {
            // Offline helper data is excluded by the now-empty local source scope.
          }
        }
      }).catchError((Object _) {}),
    );
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

  Future<void> waitForSourceWork() async {
    _checkOpen();
    while (sourcesPaused) {
      await (_sourceWorkResumed ??= Completer<void>()).future;
      _checkOpen();
    }
  }

  void close() {
    _closed = true;
    if (_ownedWebContent != null) unawaited(_ownedWebContent!.close());
    _wakeSourceWork();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Workspace closed');
  }

  Future<void> _mutationTail = Future<void>.value();
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final generation = workspaceGeneration;
    final task = _mutationTail.then((_) {
      checkWorkspace(generation);
      return operation();
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
        ComputeEmbeddingRequest(text: source['content'] as String),
      );
      _checkOpen();
      if (helper.snapshot?.model.writeToJson() != identity) return {};
      result[source['id'] as String] = Float32List.fromList(
        response.embedding,
      ).toList();
    }
    return result;
  }

  Future<void> index(String id) async {
    final generation = workspaceGeneration;
    while (true) {
      // Wait outside the mutation queue so deletions can still proceed.
      await waitForSourceWork();
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
    store.state(id, 'indexing');
    try {
      final r = await helper.client.indexDocument(
        IndexRequest(
          documentId: id,
          content: source['content'] as String,
          mimeType: source['mime'] as String,
          userId: 'local_user',
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
        DeleteRequest(documentId: id, userId: 'local_user'),
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
  void initialize(Future<void> task) {
    _initialization = task;
    // The restore path reports failures; attaching a listener also covers a
    // bootstrap failure before a helper connection has been established.
    unawaited(task.catchError((Object _) {}));
  }

  bool get restoring => _resuming != null || _initialization != null;
  Future<void> resume() =>
      _resuming ??= _resume().whenComplete(() => _resuming = null);
  Future<void> _resume() async {
    _checkOpen();
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
    for (final source in store.sources.where(
      (s) => s['state'] == 'indexing' || s['state'] == 'pending',
    )) {
      await index(source['id'] as String);
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
