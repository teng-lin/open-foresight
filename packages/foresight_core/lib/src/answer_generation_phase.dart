import 'dart:convert';
import 'answer_phase_values.dart';
import 'native.dart';
import 'read_models.dart';
import 'persistence/conversation_queries.dart';
import 'answer_contract.dart';
import 'answer_prompt.dart';
import 'reference_chat_prompt.dart';
import 'reference_chat_history.dart';
import 'reference_chat_response.dart';
import 'chat_sources.dart';

/// Generation owns only its stream accumulation. Earlier phase inputs remain
/// immutable even as final citation selection and model previews evolve.
class AnswerGenerationPhase {
  AnswerGenerationPhase(
    this.request,
    this.dependencies,
    this.retrieval,
    this.prepared,
    this.saveAnswer,
  ) : citations = retrieval.citations
          .map((row) => Map<String, Object?>.of(row))
          .toList();
  final AnswerPhaseRequest request;
  final AnswerPhaseDependencies dependencies;
  String get question => request.question;
  String get conversation => request.conversation;
  String? get requestId => request.requestId;
  bool get useWeb => request.useWeb;
  bool get privateScope => request.privateScope;
  String get scopeIdentity => request.scopeIdentity;
  ConversationQueries get queries => dependencies.queries;
  NativeRuntime? get generator => dependencies.runtime();
  void ensureCurrent() => dependencies.ensureCurrent();
  final AnswerRetrievalSnapshot retrieval;
  final AnswerPromptSnapshot prepared;
  final SaveConversationAnswer saveAnswer;
  final List<Map<String, Object?>> citations;
  bool get localGrounding => retrieval.localGrounding;
  bool get followUp => retrieval.followUp;
  String? get previousQuestion => retrieval.previousQuestion;
  String get context => retrieval.context;
  List<(String, String)> get chatSources => retrieval.chatSources;
  Map<(String, String), Map<String, Object?>> get chatMetadata =>
      retrieval.chatMetadata;
  int get through => prepared.through;
  List<SavedAnswer> get historyRows => prepared.historyRows;
  AnswerMemorySnapshot? get memory => prepared.memory;
  DateTime? get requestDate => prepared.requestDate;
  String get prompt => prepared.prompt;
  String get generationId => prepared.generationId;
  Future<int> estimateMessage(Map<String, dynamic> message) =>
      dependencies.estimateMessage(message);
  Stream<String> run() async* {
    var body = '', raw = '', status = 'failed';
    var verifiedLocalAnswer = false;
    Map<String, dynamic>? modelResponse;
    final allowed = citations.map((c) => c['citation'] as String).toSet();
    final schema = _responseSchema(allowed);
    final model = queries.generationDigest;
    try {
      final events = useWeb
          ? generator!.generateWebAnswer(
              generationId,
              prompt,
              messages: memory!.messages,
              systemPrompt: referenceChatInstructions,
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
        if (useWeb && event['type'] == 'preview') {
          final preview = provisionalReferenceChatResponse(
            event['text'] as String? ?? '',
          );
          if (preview != null) {
            body = preview;
            yield body;
          }
        }
        if (event['type'] == 'delta') {
          if (useWeb && event['response'] is Map<String, dynamic>) {
            modelResponse = event['response'] as Map<String, dynamic>;
          }
          raw += event['text'] as String? ?? '';
          body = useWeb
              ? sanitizeReferenceChatResponse(raw)
              : provisionalAnswer(raw) ?? body;
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
        verifiedLocalAnswer = true;
        if (!answer.sufficient) status = 'insufficient_context';
        final selected = answer.citations.toSet();
        citations.removeWhere((c) => !selected.contains(c['citation']));
        yield body;
      }
      if (status == 'completed' && useWeb) {
        final completed = _completeWeb(raw, modelResponse);
        body = completed.body;
        raw = completed.raw;
        modelResponse = completed.modelResponse;
        yield body;
      }
      final validatedInsufficientContext =
          !useWeb && verifiedLocalAnswer && status == 'insufficient_context';
      if ((status != 'completed' && !validatedInsufficientContext) ||
          (!useWeb && !verifiedLocalAnswer)) {
        if (!useWeb &&
            !verifiedLocalAnswer &&
            status == 'insufficient_context') {
          status = 'failed';
        }
        body = 'Answer generation failed. Please retry.';
        citations.clear();
        yield body;
      }
      await _persistGeneration(body, raw, status, modelResponse, model);
    } catch (e) {
      if (dependencies.canPersistFailure()) {
        saveAnswer(
          question,
          'Answer generation failed. Please retry.',
          'failed',
          [],
          model,
          conversation: conversation,
        );
      }
      rethrow;
    }
  }

  Map<String, dynamic> _responseSchema(Set<String> allowed) {
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
              'trust': 'untrusted',
              'provenance': citations[i]['provenance'],
            },
        ],
      };
    }
    return schema;
  }

  ({String body, String raw, Map<String, dynamic> modelResponse}) _completeWeb(
    String raw,
    Map<String, dynamic>? modelResponse,
  ) {
    final decodedRaw = raw;
    final payload = parseReferenceChatResponse(decodedRaw);
    raw = alignReferenceResponseNumbers(
      payload['text'] as String,
      truncateChatToolResult(context.toString(), 3000),
    );
    modelResponse = referenceResponseWithText(
      modelResponse ?? referenceTextMessage('assistant', raw),
      jsonEncode({...payload, 'text': raw}),
    );
    final resolved = resolveChatCitations(
      completeReferenceChatResponse(
        raw,
        raw: decodedRaw,
        question: question,
        now: requestDate!,
      ),
      chatSources.length,
    );
    final body = resolved.text;
    citations
      ..clear()
      ..addAll([
        for (var i = 0; i < resolved.sourceIndices.length; i++)
          {
            ...chatMetadata[chatSources[resolved.sourceIndices[i] - 1]]!,
            'citation': 'Source:${i + 1}',
          },
      ]);
    return (body: body, raw: raw, modelResponse: modelResponse);
  }

  Future<void> _persistGeneration(
    String body,
    String raw,
    String status,
    Map<String, dynamic>? modelResponse,
    String model,
  ) async {
    // Preserve pinned excerpts even if their source changes; live navigation checks revision.
    final result = status == 'completed' && !useWeb
        ? jsonDecode(raw) as Map<String, dynamic>
        : null;
    final newMemoryPair = useWeb && status == 'completed'
        ? [
            referenceTextMessage('user', question),
            modelResponse ?? referenceTextMessage('assistant', raw),
          ]
        : <Map<String, dynamic>>[];
    final newMemoryCounts = [
      for (final message in newMemoryPair) await estimateMessage(message),
    ];
    ensureCurrent();
    saveAnswer(
      question,
      body,
      status,
      citations,
      result?['method'] == 'source-fallback' ? 'source-fallback' : model,
      conversation: conversation,
      modelResponse: useWeb && status == 'completed' ? modelResponse : null,
      memoryMessages: useWeb && status == 'completed'
          ? [...memory!.messages, ...newMemoryPair]
          : null,
      memoryTokenCounts: useWeb && status == 'completed'
          ? [...memory!.tokenCounts, ...newMemoryCounts]
          : null,
      historyThroughAnswerId: useWeb && historyRows.isNotEmpty
          ? historyRows.last.id
          : through,
    );
  }
}
