import '../domain.dart';
import '../meeting_speakers.dart';
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../persistence/meeting_operations_queries.dart';
import '../proactive_questions.dart';
import '../rpc_error.dart';
import 'meeting_indexer.dart';
import 'meeting_questions.dart';
import 'meeting_workflow_coordinator.dart';
import 'note_enhancement_coordinator.dart';
import 'recording_controller.dart';
import 'runtime_operations.dart';
import 'summary_coordinator.dart';

final class MeetingOperations {
  MeetingOperations({
    required this.domain,
    required this.proactive,
    required this.notes,
    required this.summary,
    required this.workflow,
    required this.recording,
    required this.indexer,
    required this.questions,
    required this.runtime,
    required this.changed,
  }) : queries = MeetingOperationsQueries(domain.store);
  final Domain domain;
  final ProactiveQuestions proactive;
  final NoteEnhancementCoordinator notes;
  final SummaryCoordinator summary;
  final MeetingWorkflowCoordinator workflow;
  final RecordingController recording;
  final MeetingIndexer indexer;
  final MeetingQuestions questions;
  final RuntimeOperations runtime;
  final void Function() changed;
  final MeetingOperationsQueries queries;

  Object? _once(OperationRequest request, Object? Function() write) => domain
      .store
      .writeOnce(
        request.context.idempotencyKey,
        request.operation.wire,
        write,
        arguments: request.context.idempotencyKey == null
            ? ''
            : request.context.rawArgumentsDigest,
      )
      .result;
  Object? getMeeting(int id) {
    final detail = queries.detail(id);
    return {
      'meeting': detail.meeting.toRow(),
      'notes': detail.notes.map((row) => row.toRow()).toList(),
      'transcript': [
        for (final segment in detail.transcript)
          {
            ...segment.toRow(),
            'speaker_id': MeetingSpeaker.fromSource(segment.source).id,
            'speaker_label': MeetingSpeaker.fromSource(segment.source).label,
          },
      ],
      'artifacts': detail.artifacts.map((row) => row.toRow()).toList(),
      'questions': detail.questions.map((row) => row.toRow()).toList(),
    };
  }

  Future<void> appendTranscript(
    MeetingsTranscriptRequest request, {
    bool Function()? current,
  }) async {
    queries.meeting(request.id);
    final appended = domain.store.writeOnce(
      request.context.idempotencyKey,
      request.operation.wire,
      () {
        domain.store.transcript(
          request.id,
          request.text,
          true,
          request.start,
          request.end,
          request.source,
        );
        return null;
      },
      arguments: request.context.idempotencyKey == null
          ? ''
          : request.context.rawArgumentsDigest,
    );
    if (appended.replayed) {
      queries.reportFailedIndex('meeting-${request.id}');
      return;
    }
    if (recording.recordingMeeting == request.id &&
        recording.recording != null) {
      notes.scheduleLiveTranscript(request.id);
    } else {
      notes.invalidateTranscript(request.id);
    }
    await indexer.indexMeeting(request.id, current: current);
  }

  Future<void> generateMeeting(
    int id,
    String kind, {
    String? requestId,
    bool Function()? current,
  }) async {
    if (current != null && !current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
    }
    if (![
      'summary',
      'actions',
      'action_items',
      'questions',
      'enhanced_notes',
    ].contains(kind)) {
      throw ArgumentError('Unsupported artifact kind');
    }
    switch (kind) {
      case 'enhanced_notes':
        await notes.enhanceNotes(id, requestId: requestId, current: current);
      case 'summary':
        await summary.generateSummary(
          id,
          requestId: requestId,
          current: current,
        );
      case 'actions':
      case 'action_items':
        await workflow.generateActions(
          id,
          requestId: requestId,
          current: current,
        );
      case 'questions':
        await questions.generate(id, requestId: requestId, current: current);
    }
  }

  void editTask(MeetingsEditTaskRequest request) {
    final selected = queries.task(request.id);
    final source = queries.editTask(
      selected,
      task: request.task ?? selected.task,
      owner: request.hasOwner ? request.owner : selected.owner,
      due: request.hasDue ? request.due : selected.due,
      status: request.status,
      editDetails: request.editsDetails,
    );
    if (source != null) workflow.indexSource(source);
  }

  void editArtifact(ArtifactsEditRequest request) {
    if (queries.isStructuredActionsArtifact(request.id)) {
      throw RpcError(
        RpcErrorCode.invalidArgument,
        'Use meetings.edit_task to edit structured action items',
      );
    }
    final before = notes.beforeArtifactEdit(request.id);
    final source = queries.editArtifact(
      request.id,
      request.text,
      lastManualEdit: request.lastManualEdit,
    );
    if (source != null) workflow.indexSource(source);
    notes.afterArtifactEdit(request.id, request.text, before);
  }

  List<OperationHandler> get handlers => [
    ..._meetingHandlers,
    ..._recordingHandlers,
    TypedOperationHandler<ArtifactsEditRequest>(
      Operation.artifactsEdit,
      (request, {current}) => editArtifact(request),
    ),
  ];

  List<OperationHandler> get _meetingHandlers => [
    TypedOperationHandler<MeetingsListRequest>(
      Operation.meetingsList,
      (request, {current}) => queries.list().map((row) => row.toRow()).toList(),
    ),
    TypedOperationHandler<MeetingsCreateRequest>(
      Operation.meetingsCreate,
      (request, {current}) =>
          _once(request, () => {'id': domain.store.meeting(request.title)}),
    ),
    TypedOperationHandler<MeetingsRenameRequest>(
      Operation.meetingsRename,
      (request, {current}) =>
          domain.store.meetingStore.renameMeeting(request.id, request.title),
    ),
    TypedOperationHandler<MeetingsGetRequest>(
      Operation.meetingsGet,
      (request, {current}) => getMeeting(request.id),
    ),
    TypedOperationHandler<MeetingsRetryQuestionRequest>(
      Operation.meetingsRetryQuestion,
      (request, {current}) => proactive.retry(request.id),
    ),
    TypedOperationHandler<MeetingsRetryDetectionRequest>(
      Operation.meetingsRetryDetection,
      (request, {current}) {
        queries.meeting(request.id);
        proactive.notify(request.id);
        return null;
      },
    ),
    TypedOperationHandler<MeetingsLinkAnswerRequest>(
      Operation.meetingsLinkAnswer,
      (request, {current}) {
        queries.meeting(request.id);
        queries.linkAnswer(request.id, request.answer);
        return null;
      },
    ),
    TypedOperationHandler<MeetingsNotesRequest>(
      Operation.meetingsNotes,
      (request, {current}) => notes.saveNotes(
        request.id,
        request.body,
        lastManualEdit: request.lastManualEdit,
      ),
    ),
    TypedOperationHandler<MeetingsTranscriptRequest>(
      Operation.meetingsTranscript,
      (request, {current}) => appendTranscript(request, current: current),
    ),
    TypedOperationHandler<MeetingsIndexRequest>(
      Operation.meetingsIndex,
      (request, {current}) =>
          indexer.indexMeeting(request.id, current: current),
    ),
    TypedOperationHandler<MeetingsGenerateRequest>(Operation.meetingsGenerate, (
      request, {
      current,
    }) {
      queries.meeting(request.id);
      return generateMeeting(
        request.id,
        request.kind,
        requestId: request.context.requestId,
        current: current,
      );
    }),
    TypedOperationHandler<MeetingsCancelSummaryRequest>(
      Operation.meetingsCancelSummary,
      (request, {current}) {
        queries.meeting(request.id);
        summary.cancelMeeting(request.id);
        changed();
        return null;
      },
    ),
    TypedOperationHandler<MeetingsCancelGenerationRequest>(
      Operation.meetingsCancelGeneration,
      (request, {current}) {
        queries.meeting(request.id);
        workflow.cancelMeeting(request.id, request.kind);
        changed();
        return null;
      },
    ),
    TypedOperationHandler<MeetingsTasksRequest>(Operation.meetingsTasks, (
      request, {
      current,
    }) {
      queries.meeting(request.id);
      return queries.tasks(request.id).map((row) => row.toRow()).toList();
    }),
    TypedOperationHandler<MeetingsEditTaskRequest>(
      Operation.meetingsEditTask,
      (request, {current}) => editTask(request),
    ),
    TypedOperationHandler<MeetingsPrepareRequest>(
      Operation.meetingsPrepare,
      (request, {current}) => workflow.prepareMeeting(
        request.id,
        request.sourceIds,
        requestId: request.context.requestId,
        current: current,
      ),
    ),
    TypedOperationHandler<MeetingsEnhanceRequest>(Operation.meetingsEnhance, (
      request, {
      current,
    }) {
      queries.meeting(request.id);
      return notes.enhanceNotes(
        request.id,
        forceRegenerate: request.forceRegenerate,
        requestId: request.context.requestId,
        current: current,
      );
    }),
    TypedOperationHandler<MeetingsCancelEnhanceRequest>(
      Operation.meetingsCancelEnhance,
      (request, {current}) => notes.cancel(request.id, request.targetRequestId),
    ),
  ];

  List<OperationHandler> get _recordingHandlers => [
    TypedOperationHandler<MeetingsStartRequest>(Operation.meetingsStart, (
      request, {
      current,
    }) async {
      await recording.startRecording(request.id);
      return runtime.captureState;
    }),
    TypedOperationHandler<MeetingsStopRequest>(Operation.meetingsStop, (
      request, {
      current,
    }) async {
      await domain.awaitCurrent(recording.stopRecording(), current);
      return runtime.captureState;
    }),
    TypedOperationHandler<MeetingsPauseRequest>(Operation.meetingsPause, (
      request, {
      current,
    }) {
      recording.pauseRecording(request.id);
      return runtime.captureState;
    }),
    TypedOperationHandler<MeetingsResumeRequest>(Operation.meetingsResume, (
      request, {
      current,
    }) {
      recording.resumeRecording(request.id);
      return runtime.captureState;
    }),
  ];
}
