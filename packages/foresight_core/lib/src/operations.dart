import 'package:mcp_dart/mcp_dart.dart';
import 'rpc_error.dart';

/// The single wire operation registry. Dispatch is exhaustive over this enum.
enum Operation {
  notifications_capabilities('notifications.capabilities'),
  notifications_request_permission('notifications.request_permission'),
  audio_capabilities('audio.capabilities'),
  audio_request_system('audio.request_system'),
  audio_request_microphone('audio.request_microphone'),
  status('status'),
  sources_list('sources.list'),
  sources_get('sources.get'),
  sources_import('sources.import'),
  sources_import_url('sources.import_url'),
  sources_import_directory('sources.import_directory'),
  sources_refresh('sources.refresh'),
  sources_import_file('sources.import_file'),
  sources_index('sources.index'),
  sources_delete('sources.delete'),
  sources_pause('sources.pause'),
  sources_resume('sources.resume'),
  sources_search('sources.search'),
  answer('answer'),
  google_status('google.status'),
  google_configure('google.configure'),
  google_cancel_sign_in('google.cancel_sign_in'),
  google_disconnect('google.disconnect'),
  google_drive_files('google.drive_files'),
  google_import_file('google.import_file'),
  google_import_folder('google.import_folder'),
  google_import_year('google.import_year'),
  google_refresh('google.refresh'),
  google_calendar('google.calendar'),
  google_attachments('google.attachments'),
  notes_list('notes.list'),
  notes_save('notes.save'),
  preferences_set('preferences.set'),
  meetings_list('meetings.list'),
  meetings_create('meetings.create'),
  meetings_get('meetings.get'),
  meetings_retry_question('meetings.retry_question'),
  meetings_retry_detection('meetings.retry_detection'),
  meetings_link_answer('meetings.link_answer'),
  workspace_clear('workspace.clear'),
  meetings_notes('meetings.notes'),
  meetings_transcript('meetings.transcript'),
  meetings_index('meetings.index'),
  meetings_generate('meetings.generate'),
  meetings_enhance('meetings.enhance'),
  meetings_cancel_enhance('meetings.cancel_enhance'),
  meetings_start('meetings.start'),
  meetings_stop('meetings.stop'),
  meetings_pause('meetings.pause'),
  meetings_resume('meetings.resume'),
  artifacts_edit('artifacts.edit'),
  models_cancel_query_acquisition('models.cancel_query_acquisition'),
  models_acquire_query('models.acquire_query'),
  models_speech('models.speech'),
  models_register('models.register'),
  models_generation('models.generation'),
  models_embedding('models.embedding'),
  application_resume('application.resume'),
  graph_embeddings('graph.embeddings'),
  labels_put('labels.put'),
  labels_set('labels.set'),
  labels_cluster('labels.cluster'),
  labels_delete('labels.delete'),
  graph_invalidate('graph.invalidate'),
  graph_acknowledge('graph.acknowledge'),
  graph_save('graph.save'),
  answer_stream('answer.stream'),
  google_sign_in('google.sign_in'),
  security_attach_desktop('security.attach_desktop'),
  security_detach_desktop('security.detach_desktop'),
  security_decide('security.decide'),
  security_allow_import_root('security.allow_import_root'),
  service_stop_if_idle('service.stop_if_idle');

  const Operation(this.wire);
  final String wire;
  bool get requiresHelper => !{
    Operation.status,
    Operation.audio_capabilities,
    Operation.notifications_capabilities,
    Operation.notifications_request_permission,
    Operation.audio_request_microphone,
    Operation.audio_request_system,
    Operation.sources_list,
    Operation.sources_get,
    Operation.notes_list,
    Operation.notes_save,
    Operation.meetings_list,
    Operation.meetings_get,
    Operation.meetings_create,
    Operation.meetings_notes,
    Operation.preferences_set,
    Operation.artifacts_edit,
    Operation.google_status,
    Operation.google_configure,
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
  return [
    RpcTool(
      'audio_capabilities',
      Operation.audio_capabilities,
      'Inspect audio backend and permission state without requesting permission or starting capture.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'audio_request_microphone',
      Operation.audio_request_microphone,
      'Explicitly request microphone permission for the application service. May show macOS system consent UI; requires an interactive logged-in session.',
      {},
      [],
    ),
    RpcTool(
      'audio_request_system',
      Operation.audio_request_system,
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
      Operation.sources_list,
      'List active source metadata and revisions.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'get_source',
      Operation.sources_get,
      'Read a complete active source by ID.',
      {'id': text},
      ['id'],
      readOnly: true,
    ),
    RpcTool(
      'search',
      Operation.sources_search,
      'Search indexed local knowledge. Returns passages, source IDs, titles, revisions, and scores.',
      {'query': text, 'limit': JsonSchema.integer(minimum: 1, maximum: 100)},
      ['query'],
      readOnly: true,
    ),
    RpcTool(
      'import_text',
      Operation.sources_import,
      'Create or update a text source and index it. Supplying an existing ID replaces its content and increments its revision.',
      {'title': text, 'text': text, 'id': text},
      ['title', 'text'],
    ),
    RpcTool(
      'import_file',
      Operation.sources_import_file,
      'Request desktop approval to import a regular local UTF-8, PDF, or RTF file (up to 10 MiB) within a folder selected in the desktop. The application profile is excluded.',
      {'path': text},
      ['path'],
    ),
    RpcTool(
      'import_url',
      Operation.sources_import_url,
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
      Operation.sources_import_directory,
      'Import supported text, Markdown, PDF, and RTF files recursively from a local directory.',
      {'path': text},
      ['path'],
    ),
    RpcTool(
      'refresh_sources',
      Operation.sources_refresh,
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
      Operation.sources_delete,
      'Delete a source from the application and search index.',
      {'id': text},
      ['id'],
      destructive: true,
    ),
    RpcTool(
      'list_notes',
      Operation.notes_list,
      'Read saved personal notes.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'save_note',
      Operation.notes_save,
      'Create a personal note or update an existing note by ID.',
      {'id': integer, 'title': text, 'body': text},
      ['title', 'body'],
    ),
    RpcTool(
      'list_meetings',
      Operation.meetings_list,
      'List meetings and their states.',
      {},
      [],
      readOnly: true,
    ),
    RpcTool(
      'create_meeting',
      Operation.meetings_create,
      'Create a meeting without starting audio capture.',
      {'title': text},
      ['title'],
    ),
    RpcTool(
      'get_meeting',
      Operation.meetings_get,
      'Read meeting notes, transcript segments, and generated/edited artifacts.',
      {'id': integer},
      ['id'],
      readOnly: true,
    ),
    RpcTool(
      'save_meeting_notes',
      Operation.meetings_notes,
      'Save original meeting notes. Live enhancement uses final transcript evidence when enabled.',
      {'id': integer, 'body': text},
      ['id', 'body'],
    ),
    RpcTool(
      'import_transcript',
      Operation.meetings_transcript,
      'Append a final transcript segment and index the meeting.',
      {
        'id': integer,
        'text': text,
        'start': integer,
        'end': integer,
        'source': text,
      },
      ['id', 'text'],
    ),
    RpcTool(
      'generate_meeting_artifact',
      Operation.meetings_generate,
      'Generate a summary or actions from final transcript evidence using the configured local model.',
      {
        'id': integer,
        'kind': JsonSchema.string(enumValues: ['summary', 'actions']),
      },
      ['id', 'kind'],
    ),
    RpcTool(
      'enhance_meeting_notes',
      Operation.meetings_enhance,
      'Generate an enhanced version of original meeting notes using final transcript evidence.',
      {'id': integer},
      ['id'],
    ),
    RpcTool(
      'edit_artifact',
      Operation.artifacts_edit,
      'Save an edited version of a meeting artifact while retaining its generated text.',
      {'id': integer, 'text': text},
      ['id', 'text'],
    ),
    RpcTool(
      'start_recording',
      Operation.meetings_start,
      'Request visible desktop confirmation to start microphone and playback recording. Requires an open desktop with a recording indicator. Only one meeting can record per profile.',
      {'id': integer},
      ['id'],
    ),
    RpcTool(
      'pause_recording',
      Operation.meetings_pause,
      'Pause microphone and playback capture, retaining pre-pause transcription. An optional meeting ID guards ownership.',
      {'id': integer},
      [],
    ),
    RpcTool(
      'resume_recording',
      Operation.meetings_resume,
      'Request visible desktop confirmation to resume a paused recording with the same audio routes and transcript timeline.',
      {'id': integer},
      [],
    ),
    RpcTool(
      'stop_recording',
      Operation.meetings_stop,
      'Stop the current recording, finish transcription, and index final transcript evidence.',
      {},
      [],
    ),
    RpcTool(
      'ask',
      Operation.answer_stream,
      'Generate a grounded, cited answer from indexed local sources. Uses the shared local generation worker.',
      {'question': text},
      ['question'],
    ),
  ];
}
