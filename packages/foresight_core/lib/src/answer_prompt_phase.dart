import 'dart:convert';
import 'answer_phase_values.dart';
import 'native.dart';
import 'desktop_read_models.dart';
import 'persistence/conversation_queries.dart';
import 'answer_prompt.dart';
import 'reference_chat_prompt.dart';
import 'reference_chat_history.dart';
import 'text_budget.dart';

class AnswerPromptPhase {
  AnswerPromptPhase(this.request, this.dependencies, this.retrieval);
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
  String get context => retrieval.context;
  String get memoryKey => dependencies.memoryKey();
  Future<int> estimateMessage(Map<String, dynamic> message) =>
      dependencies.estimateMessage(message);
  late int through;
  late List<SavedAnswer> historyRows;
  ReferenceChatMemory? memory;
  DateTime? requestDate;
  late String prompt, generationId;
  Future<AnswerPromptSnapshot> run() async {
    final memoryRows = useWeb
        ? queries.checkpoint(memoryKey, conversation)
        : <ConversationCheckpoint>[];
    through = memoryRows.isEmpty ? 0 : memoryRows.single.throughAnswerId;
    historyRows = queries.history(
      conversation,
      web: useWeb,
      through: through,
      privateScope: privateScope,
      scopeIdentity: scopeIdentity,
    );
    final checkpointMessages = memoryRows.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            jsonDecode(memoryRows.single.messages) as List,
          );
    final checkpointCounts =
        memoryRows.isEmpty || memoryRows.single.tokenCounts == null
        ? List<int?>.filled(checkpointMessages.length, null)
        : List<int?>.from(jsonDecode(memoryRows.single.tokenCounts!) as List);
    final tailMessages = useWeb
        ? referenceChatHistory(historyRows.map((answer) => answer.toRow()))
        : <Map<String, dynamic>>[];
    memory = useWeb
        ? await ReferenceChatMemory.load(
            [...checkpointMessages, ...tailMessages],
            estimate: estimateMessage,
            tokenCounts: [
              ...checkpointCounts,
              ...List<int?>.filled(tailMessages.length, null),
            ],
          )
        : null;
    ensureCurrent();
    final history = historyRows
        .map(
          (a) => 'User: ${a.question}\nAssistant: ${runePrefix(a.body, 1500)}',
        )
        .join('\n');
    final boundedHistory = boundUtf8(history, 500);
    final boundedQuestion = boundUtf8(question, 400);
    requestDate = useWeb ? DateTime.now() : null;
    prompt = useWeb
        ? referenceChatPrompt(
            question,
            context: context.toString(),
            now: requestDate,
          )
        : groundedAnswerPrompt(
            boundedHistory,
            context.toString(),
            boundedQuestion,
          );
    generationId = requestId ?? 'ask-${DateTime.now().microsecondsSinceEpoch}';
    dependencies.generationStarted?.call(generationId);
    await _pruneMemory();
    return AnswerPromptSnapshot(
      through: through,
      historyRows: historyRows,
      memory: memory == null
          ? null
          : AnswerMemorySnapshot(memory!.messages, memory!.tokenCounts),
      requestDate: requestDate,
      prompt: prompt,
      generationId: generationId,
    );
  }

  Future<void> _pruneMemory() async {
    if (memory != null) {
      await memory!.prune(
        incomingTokens: await estimateMessage(
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
            if (event['type'] == 'delta') {
              summary += event['text'] as String? ?? '';
            }
            if (event['type'] == 'error') {
              throw StateError('Memory compression failed');
            }
            if (event['type'] == 'done') {
              summaryStatus = event['status'] as String;
            }
          }
          ensureCurrent();
          if (summaryStatus != 'completed') {
            throw StateError('Memory compression failed');
          }
          return summary;
        },
      );
      ensureCurrent();
    }
  }
}
