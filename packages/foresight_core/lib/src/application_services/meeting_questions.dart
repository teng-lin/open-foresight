import '../text_budget.dart' show balancedTranscriptWindow;
import 'dart:convert';

import 'service_workflow_ports.dart';
import '../meeting_speakers.dart';
import '../persistence/meeting_queries.dart';
import '../persistence/workflow_queries.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'generation_coordinator.dart';

/// Preserves the internal transcript-window/plain Questions artifact path.
/// It deliberately uses neither Summary checkpoints nor workflow manifests.
final class MeetingQuestions {
  MeetingQuestions({
    required this.domain,
    required this.coordinator,
    required this.meetings,
    required this.modelDigest,
  }) : queries = WorkflowQueries(domain.store);
  final MeetingGenerationPort domain;
  final GenerationCoordinator coordinator;
  final MeetingQueries meetings;
  final WorkflowQueries queries;
  final String Function() modelDigest;
  Store get store => domain.store;
  bool get modelBusy => coordinator.modelBusy;
  bool get generationReserved => coordinator.generationReserved;

  Future<void> generate(
    int id, {
    String? requestId,
    bool Function()? current,
  }) async {
    const kind = 'questions';
    final generation = domain.workspaceGeneration;
    if (current != null && !current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
    }
    final meeting = queries.meeting(id);
    final previous = jsonEncode(
      store.contentHistory.meetingArtifacts(id, kind),
    );
    final text = meetings.finalTranscriptText(id).join('\n');
    if (text.isEmpty) throw StateError('No final transcript');
    final contextTokens =
        domain.generator?.effectiveState['context_length'] as int? ?? 4096;
    const outputTokens = 1024;
    final instructions =
        'Produce $kind from this transcript only. Use ${store.preference('noteStyle', 'Standard') == 'Concise' ? 'brief phrases' : 'complete sentences'}. Do not invent details. $meetingSpeakerInstructions\n';
    // A byte is an upper bound on byte-tokenizer cost; reserve output and
    // framing tokens as well as the instructions before selecting evidence.
    final transcriptBudget =
        contextTokens - outputTokens - utf8.encode(instructions).length - 128;
    if (transcriptBudget < 256) {
      throw StateError('Model context is too small for meeting generation');
    }
    final selected = balancedTranscriptWindow(text, transcriptBudget);
    await _generate(
      'meeting',
      '$instructions$selected',
      requestId: requestId,
      current: current,
      accept: (result) {
        domain.checkWorkspace(generation);
        if (current != null && !current()) {
          throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
        }
        if (jsonEncode(store.contentHistory.meetingArtifacts(id, kind)) !=
            previous) {
          throw RpcError(
            RpcErrorCode.cancelled,
            'Questions changed during generation; retry to review the current revision',
          );
        }
        store.artifact(
          id,
          kind,
          result,
          modelDigest(),
          inputRevision: meeting.revision,
        );
      },
    );
  }

  Future<void> _generate(
    String prefix,
    String prompt, {
    required void Function(String) accept,
    int maxTokens = 1024,
    String? requestId,
    Map<String, dynamic>? responseSchema,
    bool Function()? current,
    void Function(String text)? onText,
  }) async {
    final generation = domain.workspaceGeneration;
    var cancelled = false;
    void checkCurrent() {
      domain.checkWorkspace(generation);
      if (cancelled || coordinator.closed() || !(current?.call() ?? true)) {
        throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
      }
    }

    await Future<void>.value();
    checkCurrent();
    if (modelBusy) {
      throw RpcError(RpcErrorCode.busy, 'Model configuration is busy');
    }
    if (generationReserved) {
      throw RpcError(RpcErrorCode.busy, 'Meeting summary in progress');
    }
    final generator = domain.generator;
    if (generator == null) {
      throw RpcError(RpcErrorCode.unavailable, 'Generation model unavailable');
    }
    final child =
        requestId ?? '$prefix-${domain.clock.now().microsecondsSinceEpoch}';
    final reservation = coordinator.reserve(
      child,
      cancel: () {
        cancelled = true;
        generator.cancel(requestId: child);
      },
    );
    try {
      var result = '', status = 'failed', failure = '';
      await for (final event in generator.generate(
        child,
        prompt,
        responseSchema: responseSchema,
        maxOutputTokens: maxTokens,
      )) {
        checkCurrent();
        if (event['type'] == 'delta') {
          result += event['text'] as String;
          onText?.call(result);
        }
        if (event['type'] == 'done') status = event['status'] as String;
        if (event['type'] == 'error') failure = event['message'].toString();
      }
      checkCurrent();
      if (status != 'completed') {
        throw RpcError(
          status == 'cancelled'
              ? RpcErrorCode.cancelled
              : RpcErrorCode.internal,
          'Generation $status: $failure',
        );
      }
      accept(result);
    } finally {
      reservation.settle();
    }
  }
}
