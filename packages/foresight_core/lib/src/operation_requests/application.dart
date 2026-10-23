import '../operations.dart';
import 'request_context.dart';

class NotificationsCapabilitiesRequest extends OperationRequest {
  NotificationsCapabilitiesRequest._(super.context);
  @override
  Operation get operation => Operation.notificationsCapabilities;
  factory NotificationsCapabilitiesRequest.decode(
    OperationRequestContext context,
  ) {
    return NotificationsCapabilitiesRequest._(context);
  }
}

class NotificationsRequestPermissionRequest extends OperationRequest {
  NotificationsRequestPermissionRequest._(super.context);
  @override
  Operation get operation => Operation.notificationsRequestPermission;
  factory NotificationsRequestPermissionRequest.decode(
    OperationRequestContext context,
  ) {
    return NotificationsRequestPermissionRequest._(context);
  }
}

class AudioCapabilitiesRequest extends OperationRequest {
  AudioCapabilitiesRequest._(super.context);
  @override
  Operation get operation => Operation.audioCapabilities;
  factory AudioCapabilitiesRequest.decode(OperationRequestContext context) {
    return AudioCapabilitiesRequest._(context);
  }
}

class AudioRequestSystemRequest extends OperationRequest {
  AudioRequestSystemRequest._(super.context);
  @override
  Operation get operation => Operation.audioRequestSystem;
  factory AudioRequestSystemRequest.decode(OperationRequestContext context) {
    return AudioRequestSystemRequest._(context);
  }
}

class AudioRequestMicrophoneRequest extends OperationRequest {
  AudioRequestMicrophoneRequest._(super.context);
  @override
  Operation get operation => Operation.audioRequestMicrophone;
  factory AudioRequestMicrophoneRequest.decode(
    OperationRequestContext context,
  ) {
    return AudioRequestMicrophoneRequest._(context);
  }
}

class StatusRequest extends OperationRequest {
  StatusRequest._(
    super.context,
    this.desktop,
    this.token,
    this.clientApiVersion,
  );
  final bool desktop;
  final String? token;
  final int? clientApiVersion;
  @override
  Operation get operation => Operation.status;
  factory StatusRequest.decode(OperationRequestContext context) {
    final values = Operation.status.descriptor.arguments.decode(
      context.rawArguments,
    );
    return StatusRequest._(
      context,
      values.value<bool>("desktop"),
      values.value<String?>("token"),
      values.value<int?>("client_api_version"),
    );
  }
}

class AnswerRequest extends OperationRequest {
  AnswerRequest._(super.context, this.question, this.meetingId, this.webSearch);
  final String question;
  final int? meetingId;
  final bool webSearch;
  @override
  Operation get operation => Operation.answer;
  factory AnswerRequest.decode(OperationRequestContext context) {
    final values = Operation.answer.descriptor.arguments.decode(
      context.rawArguments,
    );
    return AnswerRequest._(
      context,
      values.value<String>("question"),
      values.value<int?>("meeting_id"),
      values.value<bool>("web_search"),
    );
  }
}

class NotesListRequest extends OperationRequest {
  NotesListRequest._(super.context);
  @override
  Operation get operation => Operation.notesList;
  factory NotesListRequest.decode(OperationRequestContext context) {
    return NotesListRequest._(context);
  }
}

class NotesSaveRequest extends OperationRequest {
  NotesSaveRequest._(super.context, this.id, this.title, this.body);
  final int? id;
  final String title;
  final String body;
  @override
  Operation get operation => Operation.notesSave;
  factory NotesSaveRequest.decode(OperationRequestContext context) {
    final values = Operation.notesSave.descriptor.arguments.decode(
      context.rawArguments,
    );
    return NotesSaveRequest._(
      context,
      values.value<int?>("id"),
      values.value<String>("title"),
      values.value<String>("body"),
    );
  }
}

class PreferencesSetRequest extends OperationRequest {
  PreferencesSetRequest._(super.context, this.key, this.value);
  final String key;
  final String value;
  @override
  Operation get operation => Operation.preferencesSet;
  factory PreferencesSetRequest.decode(OperationRequestContext context) {
    final values = Operation.preferencesSet.descriptor.arguments.decode(
      context.rawArguments,
    );
    return PreferencesSetRequest._(
      context,
      values.value<String>("key"),
      values.value<String>("value"),
    );
  }
}

class WorkspaceClearRequest extends OperationRequest {
  WorkspaceClearRequest._(super.context);
  @override
  Operation get operation => Operation.workspaceClear;
  factory WorkspaceClearRequest.decode(OperationRequestContext context) {
    return WorkspaceClearRequest._(context);
  }
}

class ArtifactsEditRequest extends OperationRequest {
  ArtifactsEditRequest._(
    super.context,
    this.id,
    this.text,
    this.lastManualEdit,
  );
  final int id;
  final String text;
  final int? lastManualEdit;
  @override
  Operation get operation => Operation.artifactsEdit;
  factory ArtifactsEditRequest.decode(OperationRequestContext context) {
    final values = Operation.artifactsEdit.descriptor.arguments.decode(
      context.rawArguments,
    );
    return ArtifactsEditRequest._(
      context,
      values.value<int>("id"),
      values.value<String>("text"),
      values.value<int?>("last_manual_edit"),
    );
  }
}

class ApplicationResumeRequest extends OperationRequest {
  ApplicationResumeRequest._(super.context);
  @override
  Operation get operation => Operation.applicationResume;
  factory ApplicationResumeRequest.decode(OperationRequestContext context) {
    return ApplicationResumeRequest._(context);
  }
}

class AnswerStreamRequest extends OperationRequest {
  AnswerStreamRequest._(
    super.context,
    this.question,
    this.meetingId,
    this.webSearch,
  );
  final String question;
  final int? meetingId;
  final bool webSearch;
  @override
  Operation get operation => Operation.answerStream;
  factory AnswerStreamRequest.decode(OperationRequestContext context) {
    final values = Operation.answerStream.descriptor.arguments.decode(
      context.rawArguments,
    );
    return AnswerStreamRequest._(
      context,
      values.value<String>("question"),
      values.value<int?>("meeting_id"),
      values.value<bool>("web_search"),
    );
  }
}

class ServiceStopIfIdleRequest extends OperationRequest {
  ServiceStopIfIdleRequest._(
    super.context,
    this.expectedPid,
    this.installationRoot,
    this.runtimeRevision,
    this.token,
  );
  final int? expectedPid;
  final String? installationRoot;
  final String? runtimeRevision;
  final String? token;
  @override
  Operation get operation => Operation.serviceStopIfIdle;
  factory ServiceStopIfIdleRequest.decode(OperationRequestContext context) {
    final values = Operation.serviceStopIfIdle.descriptor.arguments.decode(
      context.rawArguments,
    );
    return ServiceStopIfIdleRequest._(
      context,
      values.value<int?>("expected_pid"),
      values.value<String?>("installation_root"),
      values.value<String?>("runtime_revision"),
      values.value<String?>("token"),
    );
  }
}
