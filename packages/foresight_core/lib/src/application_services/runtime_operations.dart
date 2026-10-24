import 'dart:io';
import '../answer_contract.dart' show answerValidationFailures;
import 'audio_operations.dart';
import '../domain.dart';
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../platform_services.dart';
import '../service_compatibility.dart';
import 'answer_coordinator.dart';
import 'generation_coordinator.dart';
import 'google_maintenance.dart';
import 'meeting_workflow_coordinator.dart';
import 'model_registry.dart';
import 'note_enhancement_coordinator.dart';
import 'recording_controller.dart';
import 'summary_coordinator.dart';

/// Shared identity value; reading it never calls the parent application.
final class ApplicationIdentity {
  String? profileId;
}

final class RuntimeOperations {
  RuntimeOperations({
    required this.domain,
    required this.identity,
    required this.generation,
    required this.models,
    required this.workflow,
    required this.summary,
    required this.notes,
    required this.recording,
    required this.accounts,
    required this.answers,
  });
  final Domain domain;
  final ApplicationIdentity identity;
  final GenerationCoordinator generation;
  final ModelRegistry models;
  final MeetingWorkflowCoordinator workflow;
  final SummaryCoordinator summary;
  final NoteEnhancementCoordinator notes;
  final RecordingController recording;
  final GoogleMaintenance accounts;
  final AnswerGateway answers;

  Map<String, Object?> get captureState => {
    'question_detector': models.detectorState,
    'meeting_workflows': workflow.state,
    'meeting_summaries': summary.state,
    'note_enhancements': notes.state,
    ...recording.state,
  };
  Map<String, Object?>? get generationState => domain.generator == null
      ? null
      : {
          ...domain.generator!.effectiveState,
          'generating': domain.generator!.generating,
        };
  Map<String, Object?> status() => {
    'pid': pid,
    'profile_id': identity.profileId,
    'application_api_version': applicationApiVersion,
    'installation_root': configuredInstallationRoot,
    'runtime_revision': runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'],
    'models_busy': generation.modelBusy,
    'query_model_download': models.acquisitionState,
    'capture': captureState,
    'sources_paused': domain.sourcesPaused,
    'helper': domain.helper.snapshot?.toProto3Json(),
    'helper_state': domain.helper.state,
    'generation': generationState,
    'web_search_available': domain.webSearchAvailable,
    'answer_validation_failures': answerValidationFailures,
    'revision': domain.store.dataRevision,
    'google': accounts.state,
    'workspace_epoch': domain.store.workspaceEpoch,
  };
  Future<void> resume() async {
    await domain.helper.recover();
    await domain.resume();
  }

  List<OperationHandler> get handlers => [
    TypedOperationHandler<NotificationsCapabilitiesRequest>(
      Operation.notificationsCapabilities,
      (request, {current}) => notificationCapabilities(),
    ),
    TypedOperationHandler<NotificationsRequestPermissionRequest>(
      Operation.notificationsRequestPermission,
      (request, {current}) => notificationCapabilities(requestPermission: true),
    ),
    ...AudioOperations().handlers,
    TypedOperationHandler<StatusRequest>(
      Operation.status,
      (request, {current}) => status(),
    ),
    TypedOperationHandler<ApplicationResumeRequest>(
      Operation.applicationResume,
      (request, {current}) => resume(),
    ),
    TypedOperationHandler<AnswerRequest>(
      Operation.answer,
      (request, {current}) => answers.answer(request, current: current),
    ),
  ];
}
