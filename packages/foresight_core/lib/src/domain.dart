import 'platform_services.dart';
import 'dart:async';
import 'application.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';
import 'store.dart';
import 'helper.dart';
import 'native.dart';
import 'answer_contract.dart';
import 'answer_retrieval.dart';
import 'answer_prompt.dart';
import 'generated/rag_service.pbgrpc.dart';

class Domain {
  final Store store;
  final Helper helper;
  NativeRuntime? generator;
  Domain(this.store, this.helper);
  late final Application application = Application(this);
  Future<Object?> command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) => application.call(method, args);
  Future<Object?> commandCurrent(
    String method,
    Map<String, dynamic> args,
    bool Function() current,
  ) => application.call(method, args, current: current);
  bool _closed = false;
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
    _wakeSourceWork();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Workspace closed');
  }

  Future<void> _mutationTail = Future<void>.value();
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final task = _mutationTail.then((_) {
      _checkOpen();
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
    while (true) {
      // Wait outside the mutation queue so deletions can still proceed.
      await waitForSourceWork();
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
      _checkOpen();
      if (!r.success) throw StateError(r.errorMessage);
      store.db.execute(
        "UPDATE sources SET state='indexed',error='' WHERE id=? AND revision=? AND deleted=0",
        [id, source['revision']],
      );
    } catch (e) {
      if (_closed) rethrow;
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
    try {
      final r = await helper.client.deleteDocument(
        DeleteRequest(documentId: id, userId: 'local_user'),
      );
      _checkOpen();
      if (!r.success) throw StateError(r.errorMessage);
      store.state(id, 'deleted');
    } catch (e) {
      if (_closed) rethrow;
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
    if (generator == null) {
      final gen = store.model('generation');
      if (gen != null) {
        generator = NativeRuntime(runtimeConfiguration.nativeLibrary);
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

  Stream<String> ask(String question) => askInConversation(question, 'desktop');
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
  }) async* {
    if (meetingId != null) {
      if (store.rows('SELECT id FROM meetings WHERE id=?', [
        meetingId,
      ]).isEmpty) {
        throw StateError('Meeting not found: $meetingId');
      }
      conversation = 'meeting:$meetingId';
    }
    void saveAnswer(
      String question,
      String body,
      String status,
      List<Map<String, Object?>> citations,
      String model, {
      required String conversation,
    }) {
      store.db.execute('SAVEPOINT persist_conversation_answer');
      try {
        store.answer(
          question,
          body,
          status,
          citations,
          model,
          conversation: conversation,
        );
        if (meetingId != null) {
          // Capture the exact inserted row before any other client can write.
          final answerId = store.db.lastInsertRowId;
          store.db.execute(
            'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
            [meetingId, answerId],
          );
        }
        store.db.execute('RELEASE persist_conversation_answer');
      } catch (_) {
        store.db.execute('ROLLBACK TO persist_conversation_answer');
        store.db.execute('RELEASE persist_conversation_answer');
        rethrow;
      }
    }

    if (application.modelBusy) throw StateError('Model configuration is busy');
    final scope = store.sourceSummaries
        .where((s) => s['state'] == 'indexed')
        .toList();
    if (scope.isEmpty) {
      const text = 'Insufficient context: import and index a source first.';
      saveAnswer(
        question,
        text,
        'insufficient_context',
        [],
        'none',
        conversation: conversation,
      );
      yield text;
      return;
    }
    final previousQuestion =
        store.rows(
              'SELECT question FROM answers WHERE conversation=? ORDER BY id DESC LIMIT 1',
              [conversation],
            ).firstOrNull?['question']
            as String?;
    final followUp =
        question.split(RegExp(r'\s+')).length <= 12 &&
        RegExp(
          r'\b(it|its|that|those|this|they|them|more|again)\b',
          caseSensitive: false,
        ).hasMatch(question);
    final retrievalQuestion = followUp && previousQuestion != null
        ? '$previousQuestion\nFollow-up question: $question'
        : question;
    final revisions = {for (final s in scope) s['id']: s['revision']};
    final r = await helper.client.retrieveContext(
      RetrieveRequest(
        query: Query(textQuery: retrievalQuestion),
        maxResults: 24,
        minSimilarityScore: 0.0,
        userId: 'local_user',
        allowedDocumentIds: scope.map((s) => s['id'] as String),
      ),
    );
    final citations = <Map<String, Object?>>[];
    final context = StringBuffer();
    final passages = await retrieveAnswerPassages(
      store.path,
      retrievalQuestion,
      {for (final s in scope) s['id'] as String: s['revision']},
      r.chunks
          .map(
            (c) => <String, Object?>{
              'document_id': c.documentId,
              'text': c.text,
              'score': c.relevanceScore,
            },
          )
          .toList(),
    );
    _checkOpen();
    final completeProcedure =
        passages.length == 1 && passages.single['complete_procedure'] == true;
    final completeExamples =
        passages.isNotEmpty &&
        passages.every((p) => p['complete_example'] == true);
    final authored = completeProcedure || completeExamples;
    final localGrounding =
        generator != null &&
        (generator!.effectiveState['backend'] as String? ?? '').startsWith(
          'litert-lm-',
        );
    var budget = authored || localGrounding ? 16000 : 6000;
    for (final passage in passages) {
      final documentId = passage['document_id'] as String;
      final live = store.rows(
        'SELECT revision,deleted,state FROM sources WHERE id=?',
        [documentId],
      );
      if (live.isEmpty ||
          live.first['deleted'] != 0 ||
          live.first['revision'] != revisions[documentId] ||
          live.first['state'] != 'indexed')
        continue;
      if (budget <= 0) break;
      final text = boundUtf8(
        passage['excerpt'] as String,
        budget.clamp(
          0,
          authored
              ? 16000
              : localGrounding
              ? 4000
              : 1000,
        ),
      );
      budget -= utf8.encode(text).length;
      final id = 'S${citations.length + 1}';
      citations.add({
        'citation': id,
        'title': passage['title'],
        'document_id': documentId,
        'revision': revisions[documentId],
        'excerpt': text,
        'score': passage['score'],
        'rank_score': passage['rank_score'],
      });
      context.writeln(
        '[$id] ${boundUtf8(passage['title'] as String, 160)}\n$text',
      );
    }
    if (citations.isEmpty) {
      const text =
          'Insufficient context: no current source excerpts were retrieved.';
      saveAnswer(
        question,
        text,
        'insufficient_context',
        [],
        'none',
        conversation: conversation,
      );
      yield text;
      return;
    }
    if (authored) {
      // If a source changed during retrieval, never claim the requested count.
      if (citations.length != passages.length) {
        throw StateError('Source changed during retrieval; please retry.');
      }
      final rendered = completeProcedure
          ? renderProcedureGuide(
              citations.single['excerpt'] as String,
              citations.single['citation'] as String,
            )
          : 'From your source examples (quoted sections):\n\n${citations.map((c) => '${c['excerpt']}\n\n[${c['citation']}]').join('\n\n')}';
      final ids = citations.map((c) => c['citation'] as String).toList();
      final answer = GroundedAnswer.parse(
        jsonEncode({'answer': rendered, 'citations': ids}),
        ids.toSet(),
      );
      saveAnswer(
        question,
        answer.rendered,
        'completed',
        citations,
        completeProcedure ? 'source-guide' : 'source-examples',
        conversation: conversation,
      );
      yield answer.rendered;
      return;
    }
    if (generator == null)
      throw StateError(
        'Generation model unavailable. Retrieved ${citations.length} excerpts; configure a local generator.',
      );
    final history = store
        .rows(
          'SELECT question,body FROM answers WHERE conversation=? AND status=\'completed\' ORDER BY id DESC LIMIT 4',
          [conversation],
        )
        .reversed
        .map(
          (a) =>
              'User: ${a['question']}\nAssistant: ${(a['body'] as String).substring(0, (a['body'] as String).length.clamp(0, 1500))}',
        )
        .join('\n');
    final boundedHistory = boundUtf8(history, 500);
    final boundedQuestion = boundUtf8(question, 400);
    final prompt = groundedAnswerPrompt(
      boundedHistory,
      context.toString(),
      boundedQuestion,
    );
    var body = '', raw = '', status = 'failed';
    final allowed = citations.map((c) => c['citation'] as String).toSet();
    final schema = groundedAnswerSchema(allowed);
    if (localGrounding) {
      schema['x-foresight-grounded-request'] = {
        'version': 1,
        'question': question,
        if (followUp && previousQuestion != null)
          'previous_question': previousQuestion,
        // Prior generated answers are not evidence and must not contaminate
        // evidence selection. Explicit questions use the current source scope.
        'sources': [
          for (var i = 0; i < citations.length; i++)
            {
              'citation': citations[i]['citation'],
              'title': citations[i]['title'],
              'excerpt': citations[i]['excerpt'],
            },
        ],
      };
    }
    final model =
        store
                .rows('SELECT digest FROM models WHERE kind=\'generation\'')
                .firstOrNull?['digest']
            as String? ??
        'unknown';
    try {
      await for (final event in generator!.generate(
        requestId ?? 'ask-${DateTime.now().microsecondsSinceEpoch}',
        prompt,
        systemPrompt: groundedAnswerInstructions,
        responseSchema: schema,
        maxOutputTokens: localGrounding ? 1536 : 1024,
      )) {
        if (event['type'] == 'delta') {
          raw += event['text'] as String? ?? '';
          body = provisionalAnswer(raw) ?? body;
          yield body;
        }
        if (event['type'] == 'error') {
          body = 'Answer generation failed: ${event['message']}';
          yield body;
        }
        if (event['type'] == 'done') status = event['status'] as String;
      }
      if (status == 'completed') {
        final answer = GroundedAnswer.parse(raw, allowed);
        body = answer.rendered;
        if (!answer.sufficient) status = 'insufficient_context';
        final selected = answer.citations.toSet();
        citations.removeWhere((c) => !selected.contains(c['citation']));
        yield body;
      }
      // Preserve pinned excerpts even if their source changes; live navigation checks revision.
      final result = status == 'completed'
          ? jsonDecode(raw) as Map<String, dynamic>
          : null;
      saveAnswer(
        question,
        body,
        status,
        citations,
        result?['method'] == 'source-fallback' ? 'source-fallback' : model,
        conversation: conversation,
      );
    } catch (e) {
      saveAnswer(
        question,
        body,
        'failed',
        citations,
        model,
        conversation: conversation,
      );
      rethrow;
    }
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
