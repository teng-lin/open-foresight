import 'package:mcp_dart/mcp_dart.dart';
import 'rpc_error.dart';

/// The single wire operation registry. Dispatch is exhaustive over this enum.
enum Operation {
  notificationsCapabilities('notifications.capabilities'),
  notificationsRequestPermission('notifications.request_permission'),
  audioCapabilities('audio.capabilities'),
  audioRequestSystem('audio.request_system'),
  audioRequestMicrophone('audio.request_microphone'),
  status('status'),
  sourcesList('sources.list'),
  sourcesGet('sources.get'),
  sourcesImport('sources.import'),
  sourcesImportUrl('sources.import_url'),
  sourcesImportDirectory('sources.import_directory'),
  sourcesRefresh('sources.refresh'),
  sourcesImportFile('sources.import_file'),
  sourcesIndex('sources.index'),
  sourcesDelete('sources.delete'),
  sourcesPause('sources.pause'),
  sourcesResume('sources.resume'),
  sourcesSearch('sources.search'),
  answer('answer'),
  googleStatus('google.status'),
  googleConfigure('google.configure'),
  googleCompleteSignIn('google.complete_sign_in'),
  googleCancelSignIn('google.cancel_sign_in'),
  googleDisconnect('google.disconnect'),
  googleSwitchAccount('google.switch_account'),
  googleSignOutAccount('google.sign_out_account'),
  googleDriveFiles('google.drive_files'),
  googleImportFile('google.import_file'),
  googleImportFolder('google.import_folder'),
  googleImportYear('google.import_year'),
  googleRefresh('google.refresh'),
  googleCalendar('google.calendar'),
  googleAttachments('google.attachments'),
  notesList('notes.list'),
  notesSave('notes.save'),
  preferencesSet('preferences.set'),
  meetingsList('meetings.list'),
  meetingsCreate('meetings.create'),
  meetingsGet('meetings.get'),
  meetingsRetryQuestion('meetings.retry_question'),
  meetingsRetryDetection('meetings.retry_detection'),
  meetingsLinkAnswer('meetings.link_answer'),
  workspaceClear('workspace.clear'),
  meetingsNotes('meetings.notes'),
  meetingsTranscript('meetings.transcript'),
  meetingsIndex('meetings.index'),
  meetingsGenerate('meetings.generate'),
  meetingsEnhance('meetings.enhance'),
  meetingsCancelEnhance('meetings.cancel_enhance'),
  meetingsStart('meetings.start'),
  meetingsStop('meetings.stop'),
  meetingsPause('meetings.pause'),
  meetingsResume('meetings.resume'),
  artifactsEdit('artifacts.edit'),
  modelsCancelQueryAcquisition('models.cancel_query_acquisition'),
  modelsAcquireQuery('models.acquire_query'),
  modelsSpeech('models.speech'),
  modelsRegister('models.register'),
  modelsGeneration('models.generation'),
  modelsEmbedding('models.embedding'),
  applicationResume('application.resume'),
  graphEmbeddings('graph.embeddings'),
  labelsAutoAssign('labels.auto_assign'),
  labelsPut('labels.put'),
  labelsSet('labels.set'),
  labelsCluster('labels.cluster'),
  labelsDelete('labels.delete'),
  graphInvalidate('graph.invalidate'),
  graphAcknowledge('graph.acknowledge'),
  graphSave('graph.save'),
  answerStream('answer.stream'),
  googleSignIn('google.sign_in'),
  googleAddAccount('google.add_account'),
  securityAttachDesktop('security.attach_desktop'),
  securityDetachDesktop('security.detach_desktop'),
  securityDecide('security.decide'),
  securityAllowImportRoot('security.allow_import_root'),
  serviceStopIfIdle('service.stop_if_idle');

  const Operation(this.wire);
  final String wire;
  bool requiresApproval({bool webSearch = false}) {
    if ((this == Operation.answer || this == Operation.answerStream) &&
        webSearch) {
      return true;
    }
    return !{
      Operation.status,
      Operation.audioCapabilities,
      Operation.notificationsCapabilities,
      Operation.sourcesList,
      Operation.sourcesGet,
      Operation.sourcesSearch,
      Operation.sourcesIndex,
      Operation.notesList,
      Operation.notesSave,
      Operation.meetingsList,
      Operation.meetingsGet,
      Operation.meetingsCreate,
      Operation.meetingsNotes,
      Operation.meetingsPause,
      Operation.meetingsStop,
      Operation.answer,
      Operation.answerStream,
      Operation.applicationResume,
      Operation.googleStatus,
      Operation.artifactsEdit,
      Operation.meetingsGenerate,
      Operation.meetingsEnhance,
      Operation.meetingsCancelEnhance,
      Operation.meetingsRetryQuestion,
      Operation.meetingsRetryDetection,
      Operation.meetingsLinkAnswer,
    }.contains(this);
  }

  bool get notifiesChanges => !{
    Operation.status,
    Operation.audioCapabilities,
    Operation.notificationsCapabilities,
    Operation.sourcesList,
    Operation.sourcesGet,
    Operation.sourcesSearch,
    Operation.notesList,
    Operation.meetingsList,
    Operation.meetingsGet,
    Operation.googleStatus,
    Operation.googleDriveFiles,
    Operation.graphEmbeddings,
  }.contains(this);

  bool get requiresHelper => !{
    Operation.status,
    Operation.audioCapabilities,
    Operation.notificationsCapabilities,
    Operation.notificationsRequestPermission,
    Operation.audioRequestMicrophone,
    Operation.audioRequestSystem,
    Operation.sourcesList,
    Operation.sourcesGet,
    Operation.notesList,
    Operation.notesSave,
    Operation.meetingsList,
    Operation.meetingsGet,
    Operation.meetingsCreate,
    Operation.meetingsNotes,
    Operation.preferencesSet,
    Operation.artifactsEdit,
    Operation.googleStatus,
    Operation.googleConfigure,
    Operation.googleCompleteSignIn,
    Operation.googleSignIn,
    Operation.googleAddAccount,
    Operation.googleCancelSignIn,
    Operation.googleDisconnect,
    Operation.googleSwitchAccount,
    Operation.googleSignOutAccount,
  }.contains(this);

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

List<RpcTool> get rpcTools {
  final text = JsonSchema.string();
  final integer = JsonSchema.integer();
  final epoch = JsonSchema.string(
    description:
        'Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item.',
  );
  return [
    RpcTool(
      'audio_capabilities',
      Operation.audioCapabilities,
      'Inspect audio backend and permission state without requesting permission or starting capture.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'audio_request_microphone',
      Operation.audioRequestMicrophone,
      'Explicitly request microphone permission for the application service. May show macOS system consent UI; requires an interactive logged-in session.',
      {},
      [],
    ),
    RpcTool(
      'audio_request_system',
      Operation.audioRequestSystem,
      'Explicitly request system audio recording consent for the application service. May show macOS consent UI; requires an interactive logged-in session. CoreAudio cannot verify authorization: completed or unknown does not prove permission or audible input. Inspect the returned message and settings guidance.',
      {},
      [],
    ),
    RpcTool(
      'get_status',
      Operation.status,
      'Get local model readiness, indexing state, and active recording.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'list_sources',
      Operation.sourcesList,
      'List active source metadata and revisions.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'get_source',
      Operation.sourcesGet,
      'Read a complete active source by ID.',
      {'id': text, 'workspace_epoch': epoch},
      ['id'],
      readOnly: true,
    ),
    RpcTool(
      'search',
      Operation.sourcesSearch,
      'Search indexed local knowledge. Returns passages, source IDs, titles, revisions, and scores.',
      {'query': text, 'limit': JsonSchema.integer(minimum: 1, maximum: 100)},
      ['query'],
      readOnly: true,
    ),
    RpcTool(
      'import_text',
      Operation.sourcesImport,
      'Create or update a text source and index it. Supplying an existing ID replaces its content and increments its revision.',
      {'title': text, 'text': text, 'id': text, 'workspace_epoch': epoch},
      ['title', 'text'],
    ),
    RpcTool(
      'import_file',
      Operation.sourcesImportFile,
      'Request desktop approval to import a regular local UTF-8, PDF, or RTF file (up to 10 MiB) within a folder selected in the desktop. The application profile is excluded.',
      {'path': text},
      ['path'],
    ),
    RpcTool(
      'import_url',
      Operation.sourcesImportUrl,
      'Fetch and index an HTTP or HTTPS text/HTML page.',
      {
        'url': text,
        'allow_private_network': JsonSchema.boolean(
          description:
              'Explicitly permit local/private/special-use addresses for this import. Defaults to false.',
        ),
      },
      ['url'],
      openWorld: true,
    ),
    RpcTool(
      'import_directory',
      Operation.sourcesImportDirectory,
      'Import supported text, Markdown, PDF, and RTF files recursively from a local directory.',
      {'path': text},
      ['path'],
    ),
    RpcTool(
      'refresh_sources',
      Operation.sourcesRefresh,
      'Refresh imported sources and connected Google sources, then update the index.',
      {
        'allow_private_network': JsonSchema.boolean(
          description:
              'Explicitly permit private network URL refreshes for this request. Defaults to false.',
        ),
      },
      [],
      openWorld: true,
    ),
    RpcTool(
      'delete_source',
      Operation.sourcesDelete,
      'Delete a source from the application and search index.',
      {'id': text, 'workspace_epoch': epoch},
      ['id'],
      destructive: true,
    ),
    RpcTool(
      'list_notes',
      Operation.notesList,
      'Read saved personal notes.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'save_note',
      Operation.notesSave,
      'Create a personal note or update an existing note by ID.',
      {'id': integer, 'title': text, 'body': text, 'workspace_epoch': epoch},
      ['title', 'body'],
    ),
    RpcTool(
      'list_meetings',
      Operation.meetingsList,
      'List meetings and their states.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'create_meeting',
      Operation.meetingsCreate,
      'Create a meeting without starting audio capture.',
      {'title': text},
      ['title'],
    ),
    RpcTool(
      'get_meeting',
      Operation.meetingsGet,
      'Read meeting notes, transcript segments, and generated/edited artifacts.',
      {'id': integer, 'workspace_epoch': epoch},
      ['id'],
      readOnly: true,
    ),
    RpcTool(
      'save_meeting_notes',
      Operation.meetingsNotes,
      'Save original meeting notes. Live enhancement uses final transcript evidence when enabled.',
      {'id': integer, 'body': text, 'workspace_epoch': epoch},
      ['id', 'body'],
    ),
    RpcTool(
      'import_transcript',
      Operation.meetingsTranscript,
      'Append a final transcript segment and index the meeting.',
      {
        'id': integer,
        'text': text,
        'start': integer,
        'end': integer,
        'source': text,
        'workspace_epoch': epoch,
      },
      ['id', 'text'],
    ),
    RpcTool(
      'generate_meeting_artifact',
      Operation.meetingsGenerate,
      'Generate a summary or actions from final transcript evidence using the configured local model.',
      {
        'id': integer,
        'kind': JsonSchema.string(enumValues: ['summary', 'actions']),
        'workspace_epoch': epoch,
      },
      ['id', 'kind'],
    ),
    RpcTool(
      'enhance_meeting_notes',
      Operation.meetingsEnhance,
      'Generate an enhanced version of original meeting notes using final transcript evidence.',
      {'id': integer, 'workspace_epoch': epoch},
      ['id'],
    ),
    RpcTool(
      'edit_artifact',
      Operation.artifactsEdit,
      'Save an edited version of a meeting artifact while retaining its generated text.',
      {'id': integer, 'text': text, 'workspace_epoch': epoch},
      ['id', 'text'],
    ),
    RpcTool(
      'start_recording',
      Operation.meetingsStart,
      'Request visible desktop confirmation to start microphone and playback recording. Requires an open desktop with a recording indicator. Only one meeting can record per profile.',
      {'id': integer, 'workspace_epoch': epoch},
      ['id'],
    ),
    RpcTool(
      'pause_recording',
      Operation.meetingsPause,
      'Pause microphone and playback capture, retaining pre-pause transcription. An optional meeting ID guards ownership.',
      {'id': integer, 'workspace_epoch': epoch},
      [],
    ),
    RpcTool(
      'resume_recording',
      Operation.meetingsResume,
      'Request visible desktop confirmation to resume a paused recording with the same audio routes and transcript timeline.',
      {'id': integer, 'workspace_epoch': epoch},
      [],
    ),
    RpcTool(
      'stop_recording',
      Operation.meetingsStop,
      'Stop the current recording, finish transcription, and index final transcript evidence.',
      {},
      [],
    ),
    RpcTool(
      'ask',
      Operation.answerStream,
      'Generate a grounded, cited answer from indexed local sources. Uses the shared local generation worker.',
      {'question': text},
      ['question'],
    ),
  ];
}
