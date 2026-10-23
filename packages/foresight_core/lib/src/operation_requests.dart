import 'operations.dart';
import 'operation_requests/request_context.dart';
import 'operation_requests/application.dart';
import 'operation_requests/sources.dart';
import 'operation_requests/google.dart';
import 'operation_requests/meetings.dart';
import 'operation_requests/models.dart';
import 'operation_requests/graph.dart';
import 'operation_requests/labels.dart';
import 'operation_requests/security.dart';
export 'operation_requests/request_context.dart';
export 'operation_requests/graph_inputs.dart';
export 'operation_requests/application.dart';
export 'operation_requests/sources.dart';
export 'operation_requests/google.dart';
export 'operation_requests/meetings.dart';
export 'operation_requests/models.dart';
export 'operation_requests/graph.dart';
export 'operation_requests/labels.dart';
export 'operation_requests/security.dart';

/// Decode once before admission. Requests preserve the original raw identity.
OperationRequest decodeOperationRequest(
  Operation operation,
  Map<String, dynamic> raw,
) {
  final context = OperationRequestContext.decode(operation, raw);
  return switch (operation) {
    Operation.notificationsCapabilities =>
      NotificationsCapabilitiesRequest.decode(context),
    Operation.notificationsRequestPermission =>
      NotificationsRequestPermissionRequest.decode(context),
    Operation.audioCapabilities => AudioCapabilitiesRequest.decode(context),
    Operation.audioRequestSystem => AudioRequestSystemRequest.decode(context),
    Operation.audioRequestMicrophone => AudioRequestMicrophoneRequest.decode(
      context,
    ),
    Operation.status => StatusRequest.decode(context),
    Operation.sourcesList => SourcesListRequest.decode(context),
    Operation.sourcesGet => SourcesGetRequest.decode(context),
    Operation.sourcesImport => SourcesImportRequest.decode(context),
    Operation.sourcesImportUrl => SourcesImportUrlRequest.decode(context),
    Operation.sourcesImportDirectory => SourcesImportDirectoryRequest.decode(
      context,
    ),
    Operation.sourcesRefresh => SourcesRefreshRequest.decode(context),
    Operation.sourcesImportFile => SourcesImportFileRequest.decode(context),
    Operation.sourcesIndex => SourcesIndexRequest.decode(context),
    Operation.sourcesDelete => SourcesDeleteRequest.decode(context),
    Operation.sourcesPause => SourcesPauseRequest.decode(context),
    Operation.sourcesResume => SourcesResumeRequest.decode(context),
    Operation.sourcesSearch => SourcesSearchRequest.decode(context),
    Operation.answer => AnswerRequest.decode(context),
    Operation.googleStatus => GoogleStatusRequest.decode(context),
    Operation.googleConfigure => GoogleConfigureRequest.decode(context),
    Operation.googleCompleteSignIn => GoogleCompleteSignInRequest.decode(
      context,
    ),
    Operation.googleCancelSignIn => GoogleCancelSignInRequest.decode(context),
    Operation.googleDisconnect => GoogleDisconnectRequest.decode(context),
    Operation.googleSwitchAccount => GoogleSwitchAccountRequest.decode(context),
    Operation.googleSignOutAccount => GoogleSignOutAccountRequest.decode(
      context,
    ),
    Operation.googleDriveFiles => GoogleDriveFilesRequest.decode(context),
    Operation.googleImportFile => GoogleImportFileRequest.decode(context),
    Operation.googleImportFolder => GoogleImportFolderRequest.decode(context),
    Operation.googleImportYear => GoogleImportYearRequest.decode(context),
    Operation.googleRefresh => GoogleRefreshRequest.decode(context),
    Operation.googleCalendar => GoogleCalendarRequest.decode(context),
    Operation.googleAttachments => GoogleAttachmentsRequest.decode(context),
    Operation.notesList => NotesListRequest.decode(context),
    Operation.notesSave => NotesSaveRequest.decode(context),
    Operation.preferencesSet => PreferencesSetRequest.decode(context),
    Operation.meetingsList => MeetingsListRequest.decode(context),
    Operation.meetingsCreate => MeetingsCreateRequest.decode(context),
    Operation.meetingsRename => MeetingsRenameRequest.decode(context),
    Operation.meetingsGet => MeetingsGetRequest.decode(context),
    Operation.meetingsRetryQuestion => MeetingsRetryQuestionRequest.decode(
      context,
    ),
    Operation.meetingsRetryDetection => MeetingsRetryDetectionRequest.decode(
      context,
    ),
    Operation.meetingsLinkAnswer => MeetingsLinkAnswerRequest.decode(context),
    Operation.workspaceClear => WorkspaceClearRequest.decode(context),
    Operation.meetingsNotes => MeetingsNotesRequest.decode(context),
    Operation.meetingsTranscript => MeetingsTranscriptRequest.decode(context),
    Operation.meetingsIndex => MeetingsIndexRequest.decode(context),
    Operation.meetingsGenerate => MeetingsGenerateRequest.decode(context),
    Operation.meetingsTasks => MeetingsTasksRequest.decode(context),
    Operation.meetingsEditTask => MeetingsEditTaskRequest.decode(context),
    Operation.meetingsPrepare => MeetingsPrepareRequest.decode(context),
    Operation.meetingsCancelGeneration =>
      MeetingsCancelGenerationRequest.decode(context),
    Operation.meetingsEnhance => MeetingsEnhanceRequest.decode(context),
    Operation.meetingsCancelEnhance => MeetingsCancelEnhanceRequest.decode(
      context,
    ),
    Operation.meetingsCancelSummary => MeetingsCancelSummaryRequest.decode(
      context,
    ),
    Operation.meetingsStart => MeetingsStartRequest.decode(context),
    Operation.meetingsStop => MeetingsStopRequest.decode(context),
    Operation.meetingsPause => MeetingsPauseRequest.decode(context),
    Operation.meetingsResume => MeetingsResumeRequest.decode(context),
    Operation.artifactsEdit => ArtifactsEditRequest.decode(context),
    Operation.modelsCancelQueryAcquisition =>
      ModelsCancelQueryAcquisitionRequest.decode(context),
    Operation.modelsAcquireQuery => ModelsAcquireQueryRequest.decode(context),
    Operation.modelsSpeech => ModelsSpeechRequest.decode(context),
    Operation.modelsRegister => ModelsRegisterRequest.decode(context),
    Operation.modelsGeneration => ModelsGenerationRequest.decode(context),
    Operation.modelsEmbedding => ModelsEmbeddingRequest.decode(context),
    Operation.applicationResume => ApplicationResumeRequest.decode(context),
    Operation.graphEmbeddings => GraphEmbeddingsRequest.decode(context),
    Operation.labelsAutoAssign => LabelsAutoAssignRequest.decode(context),
    Operation.labelsPut => LabelsPutRequest.decode(context),
    Operation.labelsSet => LabelsSetRequest.decode(context),
    Operation.labelsCluster => LabelsClusterRequest.decode(context),
    Operation.labelsDelete => LabelsDeleteRequest.decode(context),
    Operation.graphInvalidate => GraphInvalidateRequest.decode(context),
    Operation.graphAcknowledge => GraphAcknowledgeRequest.decode(context),
    Operation.graphSave => GraphSaveRequest.decode(context),
    Operation.answerStream => AnswerStreamRequest.decode(context),
    Operation.googleSignIn => GoogleSignInRequest.decode(context),
    Operation.googleAddAccount => GoogleAddAccountRequest.decode(context),
    Operation.securityAttachDesktop => SecurityAttachDesktopRequest.decode(
      context,
    ),
    Operation.securityDetachDesktop => SecurityDetachDesktopRequest.decode(
      context,
    ),
    Operation.securityDesktopVisibility =>
      SecurityDesktopVisibilityRequest.decode(context),
    Operation.securityDecide => SecurityDecideRequest.decode(context),
    Operation.securityAllowImportRoot => SecurityAllowImportRootRequest.decode(
      context,
    ),
    Operation.serviceStopIfIdle => ServiceStopIfIdleRequest.decode(context),
  };
}
