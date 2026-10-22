import '../answer_source_scope.dart';
import '../conversation_answer.dart';
import '../domain.dart';
import '../native.dart';
import '../operation_requests.dart';
import '../proactive_questions.dart';
import '../rpc_error.dart';
import 'generation_coordinator.dart';
import 'note_enhancement_coordinator.dart';

/// The application boundary can inject this narrow answer capability in tests;
/// feature handlers never receive or bind their parent Application.
abstract class AnswerGateway {
  Stream<String> ask(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
    bool useWeb = false,
  });

  Future<Object?> answer(
    AnswerRequest request, {
    bool Function()? current,
  }) async => {
    'text': await ask(
      request.question,
      request.context.conversation ?? 'desktop',
      requestId: request.context.requestId,
      meetingId: request.meetingId,
      current: current,
      useWeb: request.webSearch,
    ).last,
  };
}

/// Foreground preemption and source scope belong to this answer owner. Its
/// generation reservation lasts through retrieval, streaming and actual cleanup.
final class AnswerCoordinator extends AnswerGateway {
  AnswerCoordinator({
    required this.domain,
    required this.proactive,
    required this.notes,
    required this.generation,
    required this.profileId,
  });
  final Domain domain;
  final ProactiveQuestions proactive;
  final NoteEnhancementCoordinator notes;
  final GenerationCoordinator generation;
  final String? Function() profileId;

  @override
  Stream<String> ask(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
    bool useWeb = false,
  }) async* {
    if (proactive.running && !proactive.ownsRequest(requestId ?? '')) {
      await proactive.yieldToForeground();
    }
    if (!proactive.ownsRequest(requestId ?? '') && notes.hasLiveWork) {
      await notes.yieldToForeground();
    }
    if (generation.closed() || domain.closed) {
      throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    }
    if (generation.generationReserved) {
      throw RpcError(RpcErrorCode.busy, 'Meeting summary in progress');
    }
    final automatic = proactive.ownsRequest(requestId ?? '');
    var cancelled = false;
    String? nativeId;
    NativeRuntime? native;
    GenerationReservation? reservation;
    bool ownsReservation() =>
        reservation != null && generation.owns(reservation!);
    void reserve() {
      late final GenerationReservation token;
      token = generation.reserve(
        'answer:${requestId ?? conversation}',
        cancel: () {
          cancelled = true;
          if (generation.owns(token) && nativeId != null) {
            native?.cancel(requestId: nativeId);
          }
        },
      );
      reservation = token;
    }

    // Automatic retrieval remains preemptible without blocking configuration.
    // Foreground calls claim before their first retrieval await; empty-context
    // terminal answers never borrow a native resource.
    try {
      final scopeConversation = meetingId == null
          ? conversation
          : 'meeting:$meetingId';
      final sourceScope = AnswerSourceScope.read(
        domain.store,
        scopeConversation,
        meeting: meetingId,
        automatic: automatic,
      );
      bool scopeCurrent() =>
          !cancelled &&
          (current?.call() ?? true) &&
          sourceScope.identity ==
              AnswerSourceScope.read(
                domain.store,
                scopeConversation,
                meeting: meetingId,
                automatic: automatic,
              ).identity;
      yield* ConversationAnswer(
        domain,
        question,
        conversation,
        requestId: requestId,
        meetingId: meetingId,
        current: scopeCurrent,
        useWeb: useWeb,
        sourceScope: sourceScope,
        profileId: profileId(),
        ownsGenerationReservation: ownsReservation,
        onRetrievalStarted: () {
          if (!automatic) reserve();
        },
        onGenerationId: (id) {
          nativeId = id;
          native = domain.generator;
          if (automatic) reserve();
          if (cancelled && ownsReservation()) {
            native?.cancel(requestId: id);
          }
        },
      ).run();
    } finally {
      reservation?.settle();
    }
  }
}
