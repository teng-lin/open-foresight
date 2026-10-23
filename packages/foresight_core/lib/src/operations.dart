import 'operation_descriptor.dart';
import 'operation_descriptors.dart' as contracts;
import 'rpc_error.dart';

/// The single wire operation registry. Dispatch is exhaustive over this enum.
enum Operation {
  notificationsCapabilities(
    'notifications.capabilities',
    contracts.notificationsCapabilitiesDescriptor,
  ),
  notificationsRequestPermission(
    'notifications.request_permission',
    contracts.notificationsRequestPermissionDescriptor,
  ),
  audioCapabilities(
    'audio.capabilities',
    contracts.audioCapabilitiesDescriptor,
  ),
  audioRequestSystem(
    'audio.request_system',
    contracts.audioRequestSystemDescriptor,
  ),
  audioRequestMicrophone(
    'audio.request_microphone',
    contracts.audioRequestMicrophoneDescriptor,
  ),
  status('status', contracts.statusDescriptor),
  sourcesList('sources.list', contracts.sourcesListDescriptor),
  sourcesGet('sources.get', contracts.sourcesGetDescriptor),
  sourcesImport('sources.import', contracts.sourcesImportDescriptor),
  sourcesImportUrl('sources.import_url', contracts.sourcesImportUrlDescriptor),
  sourcesImportDirectory(
    'sources.import_directory',
    contracts.sourcesImportDirectoryDescriptor,
  ),
  sourcesRefresh('sources.refresh', contracts.sourcesRefreshDescriptor),
  sourcesImportFile(
    'sources.import_file',
    contracts.sourcesImportFileDescriptor,
  ),
  sourcesIndex('sources.index', contracts.sourcesIndexDescriptor),
  sourcesDelete('sources.delete', contracts.sourcesDeleteDescriptor),
  sourcesPause('sources.pause', contracts.sourcesPauseDescriptor),
  sourcesResume('sources.resume', contracts.sourcesResumeDescriptor),
  sourcesSearch('sources.search', contracts.sourcesSearchDescriptor),
  answer('answer', contracts.answerDescriptor),
  googleStatus('google.status', contracts.googleStatusDescriptor),
  googleConfigure('google.configure', contracts.googleConfigureDescriptor),
  googleCompleteSignIn(
    'google.complete_sign_in',
    contracts.googleCompleteSignInDescriptor,
  ),
  googleCancelSignIn(
    'google.cancel_sign_in',
    contracts.googleCancelSignInDescriptor,
  ),
  googleDisconnect('google.disconnect', contracts.googleDisconnectDescriptor),
  googleSwitchAccount(
    'google.switch_account',
    contracts.googleSwitchAccountDescriptor,
  ),
  googleSignOutAccount(
    'google.sign_out_account',
    contracts.googleSignOutAccountDescriptor,
  ),
  googleDriveFiles('google.drive_files', contracts.googleDriveFilesDescriptor),
  googleImportFile('google.import_file', contracts.googleImportFileDescriptor),
  googleImportFolder(
    'google.import_folder',
    contracts.googleImportFolderDescriptor,
  ),
  googleImportYear('google.import_year', contracts.googleImportYearDescriptor),
  googleRefresh('google.refresh', contracts.googleRefreshDescriptor),
  googleCalendar('google.calendar', contracts.googleCalendarDescriptor),
  googleAttachments(
    'google.attachments',
    contracts.googleAttachmentsDescriptor,
  ),
  notesList('notes.list', contracts.notesListDescriptor),
  notesSave('notes.save', contracts.notesSaveDescriptor),
  preferencesSet('preferences.set', contracts.preferencesSetDescriptor),
  meetingsList('meetings.list', contracts.meetingsListDescriptor),
  meetingsCreate('meetings.create', contracts.meetingsCreateDescriptor),
  meetingsGet('meetings.get', contracts.meetingsGetDescriptor),
  meetingsRetryQuestion(
    'meetings.retry_question',
    contracts.meetingsRetryQuestionDescriptor,
  ),
  meetingsRetryDetection(
    'meetings.retry_detection',
    contracts.meetingsRetryDetectionDescriptor,
  ),
  meetingsLinkAnswer(
    'meetings.link_answer',
    contracts.meetingsLinkAnswerDescriptor,
  ),
  workspaceClear('workspace.clear', contracts.workspaceClearDescriptor),
  meetingsNotes('meetings.notes', contracts.meetingsNotesDescriptor),
  meetingsTranscript(
    'meetings.transcript',
    contracts.meetingsTranscriptDescriptor,
  ),
  meetingsIndex('meetings.index', contracts.meetingsIndexDescriptor),
  meetingsGenerate('meetings.generate', contracts.meetingsGenerateDescriptor),
  meetingsTasks('meetings.tasks', contracts.meetingsTasksDescriptor),
  meetingsEditTask('meetings.edit_task', contracts.meetingsEditTaskDescriptor),
  meetingsPrepare('meetings.prepare', contracts.meetingsPrepareDescriptor),
  meetingsCancelGeneration(
    'meetings.cancel_generation',
    contracts.meetingsCancelGenerationDescriptor,
  ),
  meetingsEnhance('meetings.enhance', contracts.meetingsEnhanceDescriptor),
  meetingsCancelEnhance(
    'meetings.cancel_enhance',
    contracts.meetingsCancelEnhanceDescriptor,
  ),
  meetingsCancelSummary(
    'meetings.cancel_summary',
    contracts.meetingsCancelSummaryDescriptor,
  ),
  meetingsStart('meetings.start', contracts.meetingsStartDescriptor),
  meetingsStop('meetings.stop', contracts.meetingsStopDescriptor),
  meetingsPause('meetings.pause', contracts.meetingsPauseDescriptor),
  meetingsResume('meetings.resume', contracts.meetingsResumeDescriptor),
  artifactsEdit('artifacts.edit', contracts.artifactsEditDescriptor),
  modelsCancelQueryAcquisition(
    'models.cancel_query_acquisition',
    contracts.modelsCancelQueryAcquisitionDescriptor,
  ),
  modelsAcquireQuery(
    'models.acquire_query',
    contracts.modelsAcquireQueryDescriptor,
  ),
  modelsSpeech('models.speech', contracts.modelsSpeechDescriptor),
  modelsRegister('models.register', contracts.modelsRegisterDescriptor),
  modelsGeneration('models.generation', contracts.modelsGenerationDescriptor),
  modelsEmbedding('models.embedding', contracts.modelsEmbeddingDescriptor),
  applicationResume(
    'application.resume',
    contracts.applicationResumeDescriptor,
  ),
  graphEmbeddings('graph.embeddings', contracts.graphEmbeddingsDescriptor),
  labelsAutoAssign('labels.auto_assign', contracts.labelsAutoAssignDescriptor),
  labelsPut('labels.put', contracts.labelsPutDescriptor),
  labelsSet('labels.set', contracts.labelsSetDescriptor),
  labelsCluster('labels.cluster', contracts.labelsClusterDescriptor),
  labelsDelete('labels.delete', contracts.labelsDeleteDescriptor),
  graphInvalidate('graph.invalidate', contracts.graphInvalidateDescriptor),
  graphAcknowledge('graph.acknowledge', contracts.graphAcknowledgeDescriptor),
  graphSave('graph.save', contracts.graphSaveDescriptor),
  answerStream('answer.stream', contracts.answerStreamDescriptor),
  googleSignIn('google.sign_in', contracts.googleSignInDescriptor),
  googleAddAccount('google.add_account', contracts.googleAddAccountDescriptor),
  securityAttachDesktop(
    'security.attach_desktop',
    contracts.securityAttachDesktopDescriptor,
  ),
  securityDetachDesktop(
    'security.detach_desktop',
    contracts.securityDetachDesktopDescriptor,
  ),
  securityDesktopVisibility(
    'security.desktop_visibility',
    contracts.securityDesktopVisibilityDescriptor,
  ),
  securityDecide('security.decide', contracts.securityDecideDescriptor),
  securityAllowImportRoot(
    'security.allow_import_root',
    contracts.securityAllowImportRootDescriptor,
  ),
  serviceStopIfIdle(
    'service.stop_if_idle',
    contracts.serviceStopIfIdleDescriptor,
  );

  const Operation(this.wire, this.descriptor);
  final OperationDescriptor descriptor;
  final String wire;
  bool requiresApproval({bool webSearch = false}) =>
      descriptor.requiresApproval(webSearch: webSearch);
  bool get acceptsIdempotencyKey => descriptor.acceptsIdempotencyKey;
  bool get carriesWorkspaceEpoch => descriptor.carriesWorkspaceEpoch;

  /// [args] with [epoch] added when this call edits an existing row by ID, or
  /// is a keyed create that a retry must not replay into a cleared workspace,
  /// and does not already name the epoch it was prepared in.
  Map<String, dynamic> scopedToWorkspace(
    Map<String, dynamic> args,
    String? epoch,
  ) {
    final scoped =
        (carriesWorkspaceEpoch && args['id'] != null) ||
        (acceptsIdempotencyKey && args['idempotency_key'] != null);
    return epoch != null && scoped && !args.containsKey('workspace_epoch')
        ? {...args, 'workspace_epoch': epoch}
        : args;
  }

  bool get notifiesChanges => descriptor.notifiesChanges;
  bool get requiresHelper => descriptor.requiresHelper;

  static Operation parse(String method) => values.firstWhere(
    (operation) => operation.wire == method,
    orElse: () => throw RpcError(
      RpcErrorCode.notFound,
      'Unknown application operation: $method',
    ),
  );
}
