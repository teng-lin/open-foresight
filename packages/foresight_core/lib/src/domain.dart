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
import 'web_search.dart';
import 'web_content.dart';
import 'reference_tools.dart';
import 'chat_sources.dart';
import 'reference_chat_prompt.dart';
import 'reference_chat_history.dart';
import 'generated/rag_service.pbgrpc.dart';

class Domain {
  final Store store;
  final Helper helper;
  NativeRuntime? generator;
  Domain(this.store, this.helper, {SearchCallbacks? webSearch})
    : _webSearch = webSearch;
  SearchCallbacks? _webSearch;
  WebContentService? _ownedWebContent;
  bool get webSearchAvailable =>
      _webSearch != null ||
      ((runtimeConfiguration['FORESIGHT_SEARCH_API_KEY'] ?? '').isNotEmpty &&
          (runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'] ?? '')
              .isNotEmpty);

  SearchCallbacks _searchCallbacks() {
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
    if (_ownedWebContent != null) unawaited(_ownedWebContent!.close());
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
    bool Function()? current,
  }) => _askInConversation(
    question,
    conversation,
    requestId: requestId,
    meetingId: meetingId,
    current: current,
  );

  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => _askInConversation(
    question,
    conversation,
    useWeb: true,
    requestId: requestId,
    meetingId: meetingId,
    current: current,
  );

  Stream<String> _askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
    bool useWeb = false,
  }) async* {
    void ensureCurrent() {
      _checkOpen();
      if (current != null && !current()) throw StateError('Answer cancelled');
    }

    ensureCurrent();
    if (useWeb && !webSearchAvailable) {
      throw StateError('Web search is unavailable in this build.');
    }
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
      Map<String, dynamic>? modelResponse,
      List<Map<String, dynamic>>? memoryMessages,
      int? historyThroughAnswerId,
    }) {
      ensureCurrent();
      store.db.execute('SAVEPOINT persist_conversation_answer');
      try {
        store.answer(
          question,
          body,
          status,
          citations,
          model,
          conversation: conversation,
          requestId: requestId,
          modelResponse: modelResponse,
        );
        // Capture before checkpoint writes can change lastInsertRowId.
        final answerId = store.db.lastInsertRowId;
        if (memoryMessages != null) {
          // A completed turn may have arrived while this request was generating.
          // Keep it between the replayed snapshot and this request's own pair.
          final intervening = referenceChatHistory(
            store.rows(
              "SELECT question,body,model_response FROM answers WHERE conversation=? AND status='completed' AND id>? AND id<? ORDER BY id",
              [conversation, historyThroughAnswerId!, answerId],
            ),
          );
          final committedMessages = [
            ...memoryMessages.take(memoryMessages.length - 2),
            ...intervening,
            ...memoryMessages.skip(memoryMessages.length - 2),
          ];
          store.db.execute(
            'INSERT INTO conversation_memory(conversation,through_answer_id,messages) VALUES(?,?,?) '
            'ON CONFLICT(conversation) DO UPDATE SET through_answer_id=excluded.through_answer_id,messages=excluded.messages',
            [conversation, answerId, jsonEncode(committedMessages)],
          );
        }
        if (meetingId != null) {
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
    if (scope.isEmpty && !useWeb) {
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
    final r = scope.isEmpty
        ? RetrieveResponse()
        : await helper.client.retrieveContext(
            RetrieveRequest(
              query: Query(textQuery: retrievalQuestion),
              maxResults: 24,
              minSimilarityScore: 0.0,
              userId: 'local_user',
              allowedDocumentIds: scope.map((s) => s['id'] as String),
            ),
          );
    final citations = <Map<String, Object?>>[];
    final chatSources = ReferenceChatSources();
    final chatMetadata = <(String, String), Map<String, Object?>>{};
    ensureCurrent();
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
    ensureCurrent();
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
    var budget = useWeb
        ? 6000
        : authored || localGrounding
        ? 16000
        : 6000;
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
      if (!useWeb && budget <= 0) break;
      final text = useWeb
          ? passage['excerpt'] as String
          : boundUtf8(
              passage['excerpt'] as String,
              budget.clamp(
                0,
                !useWeb && authored
                    ? 16000
                    : !useWeb && localGrounding
                    ? 4000
                    : 1000,
              ),
            );
      budget -= utf8.encode(text).length;
      final sourceUri =
          scope.firstWhere((s) => s['id'] == documentId)['uri'] as String? ??
          documentId;
      final pair = (passage['title'] as String, sourceUri);
      final id = useWeb
          ? 'Source:${chatSources.add(pair)}'
          : 'S${citations.length + 1}';
      final citation = <String, Object?>{
        'citation': id,
        'title': passage['title'],
        'document_id': documentId,
        'revision': revisions[documentId],
        'excerpt': text,
        'score': passage['score'],
        'rank_score': passage['rank_score'],
      };
      citations.add(citation);
      if (useWeb) chatMetadata.putIfAbsent(pair, () => citation);
      context.writeln(
        '[$id] ${boundUtf8(passage['title'] as String, 160)}\n$text',
      );
    }
    if (citations.isEmpty && !useWeb) {
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
    if (authored && !useWeb) {
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
    final memoryRows = useWeb
        ? store.rows(
            'SELECT through_answer_id,messages FROM conversation_memory WHERE conversation=?',
            [conversation],
          )
        : <Map<String, Object?>>[];
    final through = memoryRows.isEmpty
        ? 0
        : memoryRows.single['through_answer_id'] as int;
    final historyRows = useWeb
        ? store.rows(
            "SELECT id,question,body,model_response FROM answers WHERE conversation=? AND status='completed' AND id>? ORDER BY id",
            [conversation, through],
          )
        : store
              .rows(
                "SELECT question,body,model_response FROM answers WHERE conversation=? AND status='completed' ORDER BY id DESC LIMIT 4",
                [conversation],
              )
              .reversed
              .toList();
    final memory = useWeb
        ? await ReferenceChatMemory.load([
            if (memoryRows.isNotEmpty)
              ...List<Map<String, dynamic>>.from(
                jsonDecode(memoryRows.single['messages'] as String) as List,
              ),
            ...referenceChatHistory(historyRows),
          ])
        : null;
    ensureCurrent();
    final history = historyRows
        .map(
          (a) =>
              'User: ${a['question']}\nAssistant: ${(a['body'] as String).substring(0, (a['body'] as String).length.clamp(0, 1500))}',
        )
        .join('\n');
    final boundedHistory = boundUtf8(history, 500);
    final boundedQuestion = boundUtf8(question, 400);
    final prompt = useWeb
        ? referenceChatPrompt(question, context: context.toString())
        : groundedAnswerPrompt(
            boundedHistory,
            context.toString(),
            boundedQuestion,
          );
    final generationId =
        requestId ?? 'ask-${DateTime.now().microsecondsSinceEpoch}';
    if (memory != null) {
      await memory.prune(
        incomingTokens: await estimateReferenceHistoryTokens(
          referenceTextMessage('user', prompt),
        ),
        tokenLimit: generator!.effectiveState['context_length'] as int? ?? 4096,
        checkCurrent: ensureCurrent,
        summarize: (summaryPrompt) async {
          ensureCurrent();
          var summary = '', summaryStatus = 'failed';
          await for (final event in generator!.generateConversation(
            generationId,
            summaryPrompt,
          )) {
            ensureCurrent();
            if (event['type'] == 'delta')
              summary += event['text'] as String? ?? '';
            if (event['type'] == 'error')
              throw StateError('Memory compression failed');
            if (event['type'] == 'done')
              summaryStatus = event['status'] as String;
          }
          ensureCurrent();
          if (summaryStatus != 'completed')
            throw StateError('Memory compression failed');
          return summary;
        },
      );
      ensureCurrent();
    }
    var body = '', raw = '', status = 'failed';
    Map<String, dynamic>? modelResponse;
    final allowed = citations.map((c) => c['citation'] as String).toSet();
    final schema = useWeb ? <String, dynamic>{} : groundedAnswerSchema(allowed);
    if (localGrounding && !useWeb) {
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
      final events = useWeb
          ? generator!.generateWithTools(
              generationId,
              prompt,
              tools: [referenceGoogleSearchTool()],
              messages: memory!.messages,
              systemPrompt: referenceChatInstructions,
              dispatcher: ReferenceToolDispatcher({
                'google_search': (args) async {
                  ensureCurrent();
                  final result = await _searchCallbacks().handleGoogleSearch(
                    args,
                  );
                  ensureCurrent();
                  for (var i = 0; i < result.sources.length; i++) {
                    final pair = result.sources[i];
                    chatMetadata.putIfAbsent(
                      pair,
                      () => {
                        'kind': 'web',
                        'title': pair.$1,
                        'url': pair.$2,
                        'excerpt': result.results[i],
                        'query': args['query'],
                        'retrieved_at': DateTime.now()
                            .toUtc()
                            .toIso8601String(),
                      },
                    );
                  }
                  return chatSources.formatSearch(result);
                },
              }),
              maxOutputTokens: 1024,
            )
          : generator!.generate(
              generationId,
              prompt,
              systemPrompt: groundedAnswerInstructions,
              responseSchema: schema,
              maxOutputTokens: localGrounding ? 1536 : 1024,
            );
      await for (final event in events) {
        ensureCurrent();
        if (event['type'] == 'delta') {
          if (useWeb && event['response'] is Map<String, dynamic>) {
            modelResponse = event['response'] as Map<String, dynamic>;
          }
          raw += event['text'] as String? ?? '';
          body = useWeb ? raw : provisionalAnswer(raw) ?? body;
          yield body;
        }
        if (event['type'] == 'error') {
          body = 'Answer generation failed: ${event['message']}';
          yield body;
        }
        if (event['type'] == 'done') status = event['status'] as String;
      }
      ensureCurrent();
      if (status == 'completed' && !useWeb) {
        final answer = GroundedAnswer.parse(raw, allowed);
        body = answer.rendered;
        if (!answer.sufficient) status = 'insufficient_context';
        final selected = answer.citations.toSet();
        citations.removeWhere((c) => !selected.contains(c['citation']));
        yield body;
      }
      if (status == 'completed' && useWeb) {
        final resolved = resolveChatCitations(raw, chatSources.values.length);
        body = resolved.text;
        citations
          ..clear()
          ..addAll([
            for (var i = 0; i < resolved.sourceIndices.length; i++)
              {
                ...chatMetadata[chatSources.values[resolved.sourceIndices[i] -
                    1]]!,
                'citation': 'Source:${i + 1}',
              },
          ]);
        yield body;
      }
      // Preserve pinned excerpts even if their source changes; live navigation checks revision.
      final result = status == 'completed' && !useWeb
          ? jsonDecode(raw) as Map<String, dynamic>
          : null;
      saveAnswer(
        question,
        body,
        status,
        citations,
        result?['method'] == 'source-fallback' ? 'source-fallback' : model,
        conversation: conversation,
        modelResponse: useWeb && status == 'completed' ? modelResponse : null,
        memoryMessages: useWeb && status == 'completed'
            ? [
                ...memory!.messages,
                referenceTextMessage('user', question),
                modelResponse ?? referenceTextMessage('assistant', raw),
              ]
            : null,
        historyThroughAnswerId: useWeb && historyRows.isNotEmpty
            ? historyRows.last['id'] as int
            : through,
      );
    } catch (e) {
      if (!_closed && (current == null || current()))
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
