import '../operation_descriptor.dart';
import 'package:mcp_dart/mcp_dart.dart';
import '../operations.dart';
import 'operation_tool_projection.dart';

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
    destructive:
        destructive ||
        operation.descriptor.approval == ApprovalPolicy.overwrite,
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
