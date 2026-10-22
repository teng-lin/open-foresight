import 'native.dart';
import 'web_search.dart';
import 'answer_source_scope.dart';
import 'read_models.dart';
import 'persistence/conversation_queries.dart';
import 'generated/rag_service.pbgrpc.dart';

final class AnswerPhaseRequest {
  AnswerPhaseRequest({
    required this.question,
    required this.conversation,
    required this.scopeIdentity,
    required this.privateScope,
    required this.useWeb,
    this.requestId,
    AnswerSourceScope? sourceScope,
  }) : sourceIds = sourceScope?.ids == null
           ? null
           : Set.unmodifiable(sourceScope!.ids!);
  final String question, conversation, scopeIdentity;
  final String? requestId;
  final Set<String>? sourceIds;
  final bool privateScope, useWeb;
}

final class AnswerPhaseDependencies {
  const AnswerPhaseDependencies({
    required this.queries,
    required this.runtime,
    required this.ensureCurrent,
    required this.retrieveCurrent,
    required this.readPassages,
    required this.searchCallbacks,
    required this.estimateMessage,
    required this.memoryKey,
    required this.canPersistFailure,
    this.generationStarted,
    this.retrievalStarted,
  });
  final ConversationQueries queries;
  final NativeRuntime? Function() runtime;
  final void Function() ensureCurrent;
  final Future<RetrieveResponse> Function(RetrieveRequest) retrieveCurrent;
  final Future<List<Map<String, Object?>>> Function(
    String,
    Map<String, Object?>,
    List<Map<String, Object?>>,
  )
  readPassages;
  final SearchCallbacks Function() searchCallbacks;
  final Future<int> Function(Map<String, dynamic>) estimateMessage;
  final String Function() memoryKey;
  final bool Function() canPersistFailure;
  final void Function(String)? generationStarted;
  final void Function()? retrievalStarted;
}

typedef SaveConversationAnswer =
    void Function(
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
    });

List<Map<String, Object?>> freezeAnswerRows(
  Iterable<Map<String, Object?>> rows,
) => List.unmodifiable(rows.map(immutableReadMap));

final class AnswerRetrievalSnapshot {
  AnswerRetrievalSnapshot({
    required this.terminal,
    required this.previousQuestion,
    required this.followUp,
    required this.localGrounding,
    required Iterable<Map<String, Object?>> citations,
    required Iterable<(String, String)> chatSources,
    required Map<(String, String), Map<String, Object?>> chatMetadata,
    required this.context,
  }) : citations = freezeAnswerRows(citations),
       chatSources = List.unmodifiable(chatSources),
       chatMetadata = Map.unmodifiable(
         chatMetadata.map(
           (key, value) => MapEntry(key, immutableReadMap(value)),
         ),
       );
  final bool terminal, followUp, localGrounding;
  final String? previousQuestion;
  final List<Map<String, Object?>> citations;
  final List<(String, String)> chatSources;
  final Map<(String, String), Map<String, Object?>> chatMetadata;
  final String context;
}

final class AnswerMemorySnapshot {
  AnswerMemorySnapshot(
    Iterable<Map<String, dynamic>> messages,
    Iterable<int> counts,
  ) : messages = List.unmodifiable(
        messages.map((message) => immutableReadMap(message)),
      ),
      tokenCounts = List.unmodifiable(counts);
  final List<Map<String, dynamic>> messages;
  final List<int> tokenCounts;
}

final class AnswerPromptSnapshot {
  AnswerPromptSnapshot({
    required this.through,
    required Iterable<SavedAnswer> historyRows,
    required this.memory,
    required this.requestDate,
    required this.prompt,
    required this.generationId,
  }) : historyRows = List.unmodifiable(historyRows);
  final int through;
  final List<SavedAnswer> historyRows;
  final AnswerMemorySnapshot? memory;
  final DateTime? requestDate;
  final String prompt, generationId;
}
