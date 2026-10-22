import 'operation_descriptor.dart';
import 'operation_tool_projection.dart';
import 'operation_descriptors.dart' as contracts;
import 'package:mcp_dart/mcp_dart.dart';
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

class RpcTool {
  final String name;
  final Operation operation;
  final String description;
  final Map<String, JsonSchema> properties;
  final List<String> required;
  final bool readOnly, destructive, openWorld;
  RpcTool(
    this.name,
    this.operation,
    this.description,
    this.properties,
    this.required, {
    this.readOnly = false,
    this.destructive = false,
    this.openWorld = false,
  });
  JsonSchema get schema => JsonSchema.object(
    properties: properties,
    required: required,
    additionalProperties: false,
  );
}

RpcTool _projectedTool(
  String name,
  Operation operation,
  String description, {
  bool destructive = false,
  bool openWorld = false,
}) {
  final projection = operationToolProjections.singleWhere(
    (projection) =>
        projection.operation == operation && projection.name == name,
  );
  return RpcTool(
    name,
    operation,
    description,
    projection.properties,
    projection.required,
    readOnly: operation.descriptor.readOnly,
    destructive: destructive,
    openWorld: openWorld,
  );
}

List<RpcTool> get rpcTools {
  const retry =
      ' If a call fails with reason outcomeUnknown, retry with the same idempotency_key.'
      ' Pass workspace_epoch from get_status too, so a retry after a workspace clear fails instead of applying the change again.';
  return [
    _projectedTool(
      'audio_capabilities',
      Operation.audioCapabilities,
      'Inspect audio backend and permission state without requesting permission or starting capture.',
    ),
    _projectedTool(
      'audio_request_microphone',
      Operation.audioRequestMicrophone,
      'Explicitly request microphone permission for the application service. May show macOS system consent UI; requires an interactive logged-in session.',
    ),
    _projectedTool(
      'audio_request_system',
      Operation.audioRequestSystem,
      'Explicitly request system audio recording consent for the application service. May show macOS consent UI; requires an interactive logged-in session. CoreAudio cannot verify authorization: completed or unknown does not prove permission or audible input. Inspect the returned message and settings guidance.',
    ),
    _projectedTool(
      'get_status',
      Operation.status,
      'Get local model readiness, indexing state, and active recording.',
    ),
    _projectedTool(
      'list_sources',
      Operation.sourcesList,
      'List active source metadata and revisions.',
    ),
    _projectedTool(
      'get_source',
      Operation.sourcesGet,
      'Read a complete active source by ID.',
    ),
    _projectedTool(
      'search',
      Operation.sourcesSearch,
      'Search indexed local knowledge. Returns passages, source IDs, titles, revisions, and scores.',
    ),
    _projectedTool(
      'import_text',
      Operation.sourcesImport,
      'Create or update a text source and index it. Supplying the ID of an existing source replaces its content and increments its revision; an ID that names no source fails with notFound.$retry',
    ),
    _projectedTool(
      'import_file',
      Operation.sourcesImportFile,
      'Request desktop approval to import a regular local UTF-8, PDF, or RTF file (up to 10 MiB) within a folder selected in the desktop. The application profile is excluded.',
    ),
    _projectedTool(
      'import_url',
      Operation.sourcesImportUrl,
      'Fetch and index an HTTP or HTTPS text/HTML page.',
      openWorld: true,
    ),
    _projectedTool(
      'import_directory',
      Operation.sourcesImportDirectory,
      'Import supported text, Markdown, PDF, and RTF files recursively from a local directory.',
    ),
    _projectedTool(
      'refresh_sources',
      Operation.sourcesRefresh,
      'Refresh imported sources and connected Google sources, then update the index.',
      openWorld: true,
    ),
    _projectedTool(
      'delete_source',
      Operation.sourcesDelete,
      'Delete a source from the application and search index.',
      destructive: true,
    ),
    _projectedTool(
      'list_notes',
      Operation.notesList,
      'Read saved personal notes.',
    ),
    _projectedTool(
      'save_note',
      Operation.notesSave,
      'Create a personal note or update an existing note by ID.$retry',
    ),
    _projectedTool(
      'list_meetings',
      Operation.meetingsList,
      'List meetings and their states.',
    ),
    _projectedTool(
      'create_meeting',
      Operation.meetingsCreate,
      'Create a meeting without starting audio capture.$retry',
    ),
    _projectedTool(
      'get_meeting',
      Operation.meetingsGet,
      'Read meeting notes, transcript segments, and generated/edited artifacts.',
    ),
    _projectedTool(
      'save_meeting_notes',
      Operation.meetingsNotes,
      'Save original meeting notes. Live enhancement uses final transcript evidence when enabled.',
    ),
    _projectedTool(
      'import_transcript',
      Operation.meetingsTranscript,
      'Append a final transcript segment and index the meeting.$retry',
    ),
    _projectedTool(
      'generate_meeting_artifact',
      Operation.meetingsGenerate,
      'Generate a summary or actions from final transcript evidence using the configured local model.',
    ),
    _projectedTool(
      'enhance_meeting_notes',
      Operation.meetingsEnhance,
      'Generate an enhanced version of original meeting notes using final transcript evidence.',
    ),
    _projectedTool(
      'get_meeting_tasks',
      Operation.meetingsTasks,
      'Read evidence-backed tasks, edits, completion and stale status.',
    ),
    _projectedTool(
      'edit_meeting_task',
      Operation.meetingsEditTask,
      'Edit a task or change its status while preserving extraction evidence.',
    ),
    _projectedTool(
      'prepare_meeting',
      Operation.meetingsPrepare,
      'Generate a preparation brief from explicitly selected already-imported local documents. Does not fetch attachments or enable network access.',
    ),
    _projectedTool(
      'cancel_meeting_generation',
      Operation.meetingsCancelGeneration,
      'Cancel active task extraction or preparation for this meeting.',
    ),
    _projectedTool(
      'edit_artifact',
      Operation.artifactsEdit,
      'Save an edited version of a meeting artifact while retaining its generated text.',
    ),
    _projectedTool(
      'start_recording',
      Operation.meetingsStart,
      'Request visible desktop confirmation to start microphone and playback recording. Requires an open desktop with a recording indicator. Only one meeting can record per profile.',
    ),
    _projectedTool(
      'pause_recording',
      Operation.meetingsPause,
      'Pause microphone and playback capture, retaining pre-pause transcription. An optional meeting ID guards ownership.',
    ),
    _projectedTool(
      'resume_recording',
      Operation.meetingsResume,
      'Request visible desktop confirmation to resume a paused recording with the same audio routes and transcript timeline.',
    ),
    _projectedTool(
      'stop_recording',
      Operation.meetingsStop,
      'Stop the current recording, finish transcription, and index final transcript evidence.',
    ),
    _projectedTool(
      'ask',
      Operation.answerStream,
      'Generate a grounded, cited answer from indexed local sources. Uses the shared local generation worker.',
    ),
  ];
}
