import 'dart:io';
import '../domain.dart';
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../persistence/workspace_operations_queries.dart';
import '../proactive_questions.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'google_maintenance.dart';
import 'meeting_workflow_coordinator.dart';
import 'note_enhancement_coordinator.dart';
import 'recording_controller.dart';
import 'summary_coordinator.dart';
import 'workspace_admin.dart';

final class WorkspaceOperations {
  WorkspaceOperations({
    required this.domain,
    required this.proactive,
    required this.recording,
    required this.notes,
    required this.summary,
    required this.workflow,
    required this.workspace,
    required this.accounts,
  }) : queries = WorkspaceOperationsQueries(domain.store);
  final Domain domain;
  final ProactiveQuestions proactive;
  final RecordingController recording;
  final NoteEnhancementCoordinator notes;
  final SummaryCoordinator summary;
  final MeetingWorkflowCoordinator workflow;
  final WorkspaceAdmin workspace;
  final GoogleMaintenance accounts;
  final WorkspaceOperationsQueries queries;

  Object? saveNote(NotesSaveRequest request) => domain.store
      .writeOnce(
        request.context.idempotencyKey,
        request.operation.wire,
        () => {
          'id': domain.store.saveNote(request.id, request.title, request.body),
        },
        arguments: request.context.idempotencyKey == null
            ? ''
            : request.context.rawArgumentsDigest,
      )
      .result;
  void setPreference(PreferencesSetRequest request) {
    if (request.key == Store.workspaceEpochKey) {
      throw RpcError(
        RpcErrorCode.invalidArgument,
        'The workspace epoch is renewed only by a workspace clear',
      );
    }
    if (request.key == 'echoCancellation') {
      final enabled = request.value == 'true';
      if (enabled && !Platform.isMacOS) {
        throw StateError('Native echo cancellation is available on macOS');
      }
      recording.recording?.setEchoCancellation(enabled);
    }
    domain.store.setPreference(request.key, request.value);
    if (request.key == 'proactiveAnswers') proactive.wake();
  }

  Future<void> clear() async {
    accounts.initialize();
    if (recording.recording != null) {
      throw RpcError(
        RpcErrorCode.busy,
        'Stop recording before clearing the workspace',
      );
    }
    notes.clear();
    summary.clear();
    workflow.clear();
    await workspace.clear();
  }

  List<OperationHandler> get handlers => [
    TypedOperationHandler<NotesListRequest>(
      Operation.notesList,
      (request, {current}) =>
          queries.notes().map((note) => note.toRow()).toList(),
    ),
    TypedOperationHandler<NotesSaveRequest>(
      Operation.notesSave,
      (request, {current}) => saveNote(request),
    ),
    TypedOperationHandler<PreferencesSetRequest>(
      Operation.preferencesSet,
      (request, {current}) => setPreference(request),
    ),
    TypedOperationHandler<WorkspaceClearRequest>(
      Operation.workspaceClear,
      (request, {current}) => clear(),
    ),
  ];
}
