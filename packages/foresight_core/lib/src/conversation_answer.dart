import 'rpc_error.dart';
import 'cancellation.dart';
import 'answer_phase_values.dart';
import 'answer_retrieval_phase.dart';
import 'answer_prompt_phase.dart';
import 'answer_generation_phase.dart';
import 'dart:io';
import 'profile_paths.dart';
import 'package:grpc/grpc.dart' show CallOptions;
import 'domain.dart';
import 'dart:convert';
import 'store.dart';
import 'persistence/conversation_queries.dart';
import 'sqlite_store_reader.dart';
import 'store_read_queries.dart';
import 'helper.dart';
import 'native.dart';
import 'web_search.dart';
import 'reference_chat_history.dart';
import 'answer_source_scope.dart';
import 'summary_generator.dart';
import 'model_gate.dart';
import 'generated/rag_service.pbgrpc.dart';

/// One answer lifecycle, separate from workspace indexing and worker ownership.
class ConversationAnswer {
  final Domain domain;
  final String question;
  String conversation;
  final String? requestId;
  final int? meetingId;
  final String? profileId;
  final bool Function()? current;
  final bool Function()? ownsGenerationReservation;
  final void Function(String)? onGenerationId;
  final void Function()? onRetrievalStarted;
  final bool useWeb;
  final AnswerSourceScope? sourceScope;
  String get scopeIdentity =>
      sourceScope?.identity ?? AnswerSourceScope('workspace', null).identity;
  bool get privateScope => sourceScope?.ids != null;
  String get memoryKey =>
      'web-memory-v2:${summaryDigest(jsonEncode([queries.model('generation')?.toRow(), generator?.effectiveState['context_length'], 'utf8-byte-history-v1', scopeIdentity]))}:$conversation';
  late final int generation = domain.workspaceGeneration;
  ConversationAnswer(
    this.domain,
    this.question,
    this.conversation, {
    this.requestId,
    this.meetingId,
    this.profileId,
    this.current,
    this.ownsGenerationReservation,
    this.onGenerationId,
    this.onRetrievalStarted,
    this.useWeb = false,
    AnswerSourceScope? sourceScope,
  }) : sourceScope = sourceScope == null
           ? null
           : AnswerSourceScope(
               sourceScope.mode,
               sourceScope.ids == null
                   ? null
                   : Set.unmodifiable(sourceScope.ids!),
             );
  Store get store => domain.store;
  late final queries = ConversationQueries(store);
  Helper get helper => domain.helper;
  NativeRuntime? get generator => domain.generator;
  bool get webSearchAvailable => domain.webSearchAvailable;
  int get workspaceGeneration => domain.workspaceGeneration;
  bool get _closed => domain.closed;
  bool get modelBusy =>
      domain.modelGate.modelBusy ||
      (domain.modelGate is GenerationReservationGate &&
          (domain.modelGate as GenerationReservationGate).generationReserved &&
          !(ownsGenerationReservation?.call() ?? false));
  SearchCallbacks _searchCallbacks() => domain.searchCallbacks();
  void ensureCurrent() {
    domain.checkWorkspace(generation);
    if (modelBusy) {
      throw RpcError(
        RpcErrorCode.busy,
        'Another workflow owns the generation model',
      );
    }
    if (current != null && !current!()) {
      throw RpcError(RpcErrorCode.cancelled, 'Answer cancelled');
    }
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
    List<int>? memoryTokenCounts,
    int? historyThroughAnswerId,
  }) {
    ensureCurrent();
    queries.save(
      question,
      body,
      status,
      citations,
      model,
      conversation: conversation,
      scopeIdentity: scopeIdentity,
      privateScope: privateScope,
      memoryKey: memoryKey,
      requestId: requestId,
      meetingId: meetingId,
      modelResponse: modelResponse,
      memoryMessages: memoryMessages,
      memoryTokenCounts: memoryTokenCounts,
      historyThroughAnswerId: historyThroughAnswerId,
    );
  }

  Future<int> estimateMessage(Map<String, dynamic> message) async {
    ensureCurrent();
    final count = await estimateReferenceHistoryTokens(
      message,
      tokenize: (text) async => utf8.encode(text).length,
    );
    ensureCurrent();
    return count;
  }

  Stream<String> run() async* {
    ensureCurrent();
    if (useWeb && !webSearchAvailable) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Web search is unavailable in this build.',
      );
    }
    if (meetingId != null) {
      if (!queries.meetingExists(meetingId!)) {
        throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $meetingId');
      }
      conversation = 'meeting:$meetingId';
    }

    if (modelBusy) {
      throw RpcError(RpcErrorCode.busy, 'Model configuration is busy');
    }
    final request = AnswerPhaseRequest(
      question: question,
      conversation: conversation,
      scopeIdentity: scopeIdentity,
      privateScope: privateScope,
      useWeb: useWeb,
      requestId: requestId,
      sourceScope: sourceScope,
    );
    final dependencies = AnswerPhaseDependencies(
      queries: queries,
      generationStarted: onGenerationId,
      retrievalStarted: onRetrievalStarted,
      runtime: () => generator,
      ensureCurrent: ensureCurrent,
      retrieveCurrent: _retrieveCurrent,
      readPassages: _readPassages,
      searchCallbacks: _searchCallbacks,
      estimateMessage: estimateMessage,
      memoryKey: () => memoryKey,
      canPersistFailure: () =>
          !_closed &&
          generation == workspaceGeneration &&
          (current == null || current!()),
    );
    final retrieval = AnswerRetrievalPhase(request, dependencies, saveAnswer);
    yield* retrieval.run();
    if (retrieval.result.terminal) return;
    final prepared = await AnswerPromptPhase(
      request,
      dependencies,
      retrieval.result,
    ).run();
    yield* AnswerGenerationPhase(
      request,
      dependencies,
      retrieval.result,
      prepared,
      saveAnswer,
    ).run();
  }

  Future<RetrieveResponse> _retrieveCurrent(RetrieveRequest request) async {
    ensureCurrent();
    final call = helper.client.retrieveContext(
      request,
      options: CallOptions(timeout: const Duration(seconds: 15)),
    );
    return awaitCancellable(
      call,
      ensureCurrent: ensureCurrent,
      cancel: call.cancel,
    );
  }

  Future<List<Map<String, Object?>>> _readPassages(
    String retrievalQuestion,
    Map<String, Object?> revisions,
    List<Map<String, Object?>> semantic,
  ) async {
    ensureCurrent();
    final reader = SqliteStoreReader.service(
      store,
      profile:
          profileId ?? ProfilePaths(File(store.path).parent.path, '').identity,
      connection: 'answer:$conversation:$generation',
    );
    try {
      final result = await reader.read(
        StoreReadQueries.answerPassages(
          retrievalQuestion,
          revisions,
          semantic,
          scope: scopeIdentity,
        ),
      );
      ensureCurrent();
      if (result.error != null) throw result.error!;
      return result.value ??
          (throw RpcError(
            RpcErrorCode.busy,
            'Answer retrieval is busy; retry.',
          ));
    } finally {
      await reader.close();
    }
  }
}
