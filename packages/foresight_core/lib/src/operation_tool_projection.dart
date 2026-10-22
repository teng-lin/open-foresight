import 'package:mcp_dart/mcp_dart.dart';
import 'operation_argument_schema.dart';
import 'operations.dart';

/// An explicit, closed MCP subset of the service argument contract.
class OperationToolProjection {
  const OperationToolProjection(
    this.name,
    this.operation,
    this.fields,
    this.required, {
    this.overrides = const {},
  });
  final String name;
  final Operation operation;
  final List<String> fields, required;
  final Map<String, Map<String, Object?>> overrides;
  Map<String, JsonSchema> get properties => {
    for (final name in fields)
      name: JsonSchema.fromJson({
        ..._field(name).schemaJson,
        ...?overrides[name],
      }),
  };
  JsonSchema get schema => JsonSchema.object(
    properties: properties,
    required: required,
    additionalProperties: false,
  );
  ArgumentField _field(String name) => switch (name) {
    'workspace_epoch' => const ArgumentField(
      'workspace_epoch',
      ArgumentKind.string,
      nullable: true,
    ),
    'idempotency_key' => const ArgumentField(
      'idempotency_key',
      ArgumentKind.string,
      nullable: true,
      minimumLength: 1,
      maximumLength: 256,
    ),
    _ => operation.descriptor.arguments.field(name),
  };
}

const operationToolProjections = <OperationToolProjection>[
  OperationToolProjection(
    "audio_capabilities",
    Operation.audioCapabilities,
    [],
    [],
  ),
  OperationToolProjection(
    "audio_request_system",
    Operation.audioRequestSystem,
    [],
    [],
  ),
  OperationToolProjection(
    "audio_request_microphone",
    Operation.audioRequestMicrophone,
    [],
    [],
  ),
  OperationToolProjection("get_status", Operation.status, [], []),
  OperationToolProjection("list_sources", Operation.sourcesList, [], []),
  OperationToolProjection(
    "get_source",
    Operation.sourcesGet,
    ["id", "workspace_epoch"],
    ["id"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "import_text",
    Operation.sourcesImport,
    ["title", "text", "id", "workspace_epoch", "idempotency_key"],
    ["title", "text"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
      "idempotency_key": {
        "description":
            "Optional unique key for this change. If a call fails with reason outcomeUnknown, retry with the same idempotency_key: the change is applied at most once in the same workspace (pass workspace_epoch) and the retry returns its result. Use a new key for a different change.",
      },
    },
  ),
  OperationToolProjection(
    "import_url",
    Operation.sourcesImportUrl,
    ["url", "allow_private_network"],
    ["url"],
    overrides: {
      "allow_private_network": {
        "description":
            "Explicitly permit local/private/special-use addresses for this import. Defaults to false.",
      },
    },
  ),
  OperationToolProjection(
    "import_directory",
    Operation.sourcesImportDirectory,
    ["path"],
    ["path"],
  ),
  OperationToolProjection(
    "refresh_sources",
    Operation.sourcesRefresh,
    ["allow_private_network"],
    [],
    overrides: {
      "allow_private_network": {
        "description":
            "Explicitly permit private network URL refreshes for this request. Defaults to false.",
      },
    },
  ),
  OperationToolProjection(
    "import_file",
    Operation.sourcesImportFile,
    ["path"],
    ["path"],
  ),
  OperationToolProjection(
    "delete_source",
    Operation.sourcesDelete,
    ["id", "workspace_epoch"],
    ["id"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "search",
    Operation.sourcesSearch,
    ["query", "limit"],
    ["query"],
  ),
  OperationToolProjection("list_notes", Operation.notesList, [], []),
  OperationToolProjection(
    "save_note",
    Operation.notesSave,
    ["id", "title", "body", "workspace_epoch", "idempotency_key"],
    ["title", "body"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
      "idempotency_key": {
        "description":
            "Optional unique key for this change. If a call fails with reason outcomeUnknown, retry with the same idempotency_key: the change is applied at most once in the same workspace (pass workspace_epoch) and the retry returns its result. Use a new key for a different change.",
      },
    },
  ),
  OperationToolProjection("list_meetings", Operation.meetingsList, [], []),
  OperationToolProjection(
    "create_meeting",
    Operation.meetingsCreate,
    ["title", "workspace_epoch", "idempotency_key"],
    ["title"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
      "idempotency_key": {
        "description":
            "Optional unique key for this change. If a call fails with reason outcomeUnknown, retry with the same idempotency_key: the change is applied at most once in the same workspace (pass workspace_epoch) and the retry returns its result. Use a new key for a different change.",
      },
    },
  ),
  OperationToolProjection(
    "get_meeting",
    Operation.meetingsGet,
    ["id", "workspace_epoch"],
    ["id"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "save_meeting_notes",
    Operation.meetingsNotes,
    ["id", "body", "workspace_epoch"],
    ["id", "body"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "import_transcript",
    Operation.meetingsTranscript,
    [
      "id",
      "text",
      "start",
      "end",
      "source",
      "workspace_epoch",
      "idempotency_key",
    ],
    ["id", "text"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
      "idempotency_key": {
        "description":
            "Optional unique key for this change. If a call fails with reason outcomeUnknown, retry with the same idempotency_key: the change is applied at most once in the same workspace (pass workspace_epoch) and the retry returns its result. Use a new key for a different change.",
      },
    },
  ),
  OperationToolProjection(
    "generate_meeting_artifact",
    Operation.meetingsGenerate,
    ["id", "kind", "workspace_epoch"],
    ["id", "kind"],
    overrides: {
      "kind": {
        "enum": ["summary", "actions"],
      },
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "get_meeting_tasks",
    Operation.meetingsTasks,
    ["id", "workspace_epoch"],
    ["id"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "edit_meeting_task",
    Operation.meetingsEditTask,
    ["id", "task", "owner", "due", "status", "workspace_epoch"],
    ["id"],
    overrides: {
      "status": {
        "enum": ["open", "completed", "cancelled"],
      },
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "prepare_meeting",
    Operation.meetingsPrepare,
    ["id", "source_ids", "workspace_epoch"],
    ["id", "source_ids"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "cancel_meeting_generation",
    Operation.meetingsCancelGeneration,
    ["id", "kind", "workspace_epoch"],
    ["id", "kind"],
    overrides: {
      "kind": {
        "enum": ["actions", "preparation"],
      },
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "enhance_meeting_notes",
    Operation.meetingsEnhance,
    ["id", "workspace_epoch"],
    ["id"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "start_recording",
    Operation.meetingsStart,
    ["id", "workspace_epoch"],
    ["id"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection("stop_recording", Operation.meetingsStop, [], []),
  OperationToolProjection(
    "pause_recording",
    Operation.meetingsPause,
    ["id", "workspace_epoch"],
    [],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "resume_recording",
    Operation.meetingsResume,
    ["id", "workspace_epoch"],
    [],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "edit_artifact",
    Operation.artifactsEdit,
    ["id", "text", "workspace_epoch"],
    ["id", "text"],
    overrides: {
      "workspace_epoch": {
        "description":
            "Optional workspace_epoch from get_status. If the workspace was cleared since, the call fails with notFound instead of acting on an ID that may now name a different item, or replaying a keyed change into the new workspace.",
      },
    },
  ),
  OperationToolProjection(
    "ask",
    Operation.answerStream,
    ["question"],
    ["question"],
  ),
];
