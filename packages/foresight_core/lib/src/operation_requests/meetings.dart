import '../operations.dart';
import 'request_context.dart';

class MeetingsListRequest extends OperationRequest {
  MeetingsListRequest._(super.context);
  @override
  Operation get operation => Operation.meetingsList;
  factory MeetingsListRequest.decode(OperationRequestContext context) {
    return MeetingsListRequest._(context);
  }
}

class MeetingsCreateRequest extends OperationRequest {
  MeetingsCreateRequest._(super.context, this.title);
  final String title;
  @override
  Operation get operation => Operation.meetingsCreate;
  factory MeetingsCreateRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsCreate.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsCreateRequest._(context, values.value<String>("title"));
  }
}

class MeetingsRenameRequest extends OperationRequest {
  MeetingsRenameRequest._(super.context, this.id, this.title);
  final int id;
  final String title;
  @override
  Operation get operation => Operation.meetingsRename;
  factory MeetingsRenameRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsRename.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsRenameRequest._(
      context,
      values.value<int>('id'),
      values.value<String>('title'),
    );
  }
}

class MeetingsGetRequest extends OperationRequest {
  MeetingsGetRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsGet;
  factory MeetingsGetRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsGet.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsGetRequest._(context, values.value<int>("id"));
  }
}

class MeetingsRetryQuestionRequest extends OperationRequest {
  MeetingsRetryQuestionRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsRetryQuestion;
  factory MeetingsRetryQuestionRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsRetryQuestion.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsRetryQuestionRequest._(context, values.value<int>("id"));
  }
}

class MeetingsRetryDetectionRequest extends OperationRequest {
  MeetingsRetryDetectionRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsRetryDetection;
  factory MeetingsRetryDetectionRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.meetingsRetryDetection.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsRetryDetectionRequest._(context, values.value<int>("id"));
  }
}

class MeetingsLinkAnswerRequest extends OperationRequest {
  MeetingsLinkAnswerRequest._(super.context, this.id, this.answer);
  final int id;
  final int answer;
  @override
  Operation get operation => Operation.meetingsLinkAnswer;
  factory MeetingsLinkAnswerRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsLinkAnswer.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsLinkAnswerRequest._(
      context,
      values.value<int>("id"),
      values.value<int>("answer"),
    );
  }
}

class MeetingsNotesRequest extends OperationRequest {
  MeetingsNotesRequest._(
    super.context,
    this.id,
    this.body,
    this.lastManualEdit,
  );
  final int id;
  final String body;
  final int? lastManualEdit;
  @override
  Operation get operation => Operation.meetingsNotes;
  factory MeetingsNotesRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsNotes.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsNotesRequest._(
      context,
      values.value<int>("id"),
      values.value<String>("body"),
      values.value<int?>("last_manual_edit"),
    );
  }
}

class MeetingsTranscriptRequest extends OperationRequest {
  MeetingsTranscriptRequest._(
    super.context,
    this.id,
    this.text,
    this.start,
    this.end,
    this.source,
  );
  final int id;
  final String text;
  final int start;
  final int end;
  final String source;
  @override
  Operation get operation => Operation.meetingsTranscript;
  factory MeetingsTranscriptRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsTranscript.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsTranscriptRequest._(
      context,
      values.value<int>("id"),
      values.value<String>("text"),
      values.value<int>("start"),
      values.value<int>("end"),
      values.value<String>("source"),
    );
  }
}

class MeetingsIndexRequest extends OperationRequest {
  MeetingsIndexRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsIndex;
  factory MeetingsIndexRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsIndex.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsIndexRequest._(context, values.value<int>("id"));
  }
}

class MeetingsGenerateRequest extends OperationRequest {
  MeetingsGenerateRequest._(super.context, this.id, this.kind);
  final int id;
  final String kind;
  @override
  Operation get operation => Operation.meetingsGenerate;
  factory MeetingsGenerateRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsGenerate.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsGenerateRequest._(
      context,
      values.value<int>("id"),
      values.value<String>("kind"),
    );
  }
}

class MeetingsTasksRequest extends OperationRequest {
  MeetingsTasksRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsTasks;
  factory MeetingsTasksRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsTasks.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsTasksRequest._(context, values.value<int>("id"));
  }
}

class MeetingsEditTaskRequest extends OperationRequest {
  MeetingsEditTaskRequest._(
    super.context,
    this.id,
    this.task,
    this.owner,
    this.due,
    this.status,
  );
  final int id;
  final String? task;
  final String? owner;
  final String? due;
  final String? status;
  bool get hasTask => rawArguments.containsKey('task');
  bool get hasOwner => rawArguments.containsKey('owner');
  bool get hasDue => rawArguments.containsKey('due');
  bool get editsDetails => hasTask || hasOwner || hasDue;
  @override
  Operation get operation => Operation.meetingsEditTask;
  factory MeetingsEditTaskRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsEditTask.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsEditTaskRequest._(
      context,
      values.value<int>("id"),
      values.value<String?>("task"),
      values.value<String?>("owner"),
      values.value<String?>("due"),
      values.value<String?>("status"),
    );
  }
}

class MeetingsPrepareRequest extends OperationRequest {
  MeetingsPrepareRequest._(super.context, this.id, this.sourceIds);
  final int id;
  final List<String> sourceIds;
  @override
  Operation get operation => Operation.meetingsPrepare;
  factory MeetingsPrepareRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsPrepare.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsPrepareRequest._(
      context,
      values.value<int>("id"),
      values.value<List<String>>("source_ids"),
    );
  }
}

class MeetingsCancelGenerationRequest extends OperationRequest {
  MeetingsCancelGenerationRequest._(super.context, this.id, this.kind);
  final int id;
  final String? kind;
  @override
  Operation get operation => Operation.meetingsCancelGeneration;
  factory MeetingsCancelGenerationRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.meetingsCancelGeneration.descriptor.arguments
        .decode(context.rawArguments);
    return MeetingsCancelGenerationRequest._(
      context,
      values.value<int>("id"),
      values.value<String?>("kind"),
    );
  }
}

class MeetingsEnhanceRequest extends OperationRequest {
  MeetingsEnhanceRequest._(super.context, this.id, this.forceRegenerate);
  final int id;
  final bool forceRegenerate;
  @override
  Operation get operation => Operation.meetingsEnhance;
  factory MeetingsEnhanceRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsEnhance.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsEnhanceRequest._(
      context,
      values.value<int>("id"),
      values.value<bool>("force_regenerate"),
    );
  }
}

class MeetingsCancelEnhanceRequest extends OperationRequest {
  MeetingsCancelEnhanceRequest._(super.context, this.id, this.targetRequestId);
  final int id;
  final String? targetRequestId;
  @override
  Operation get operation => Operation.meetingsCancelEnhance;
  factory MeetingsCancelEnhanceRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsCancelEnhance.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsCancelEnhanceRequest._(
      context,
      values.value<int>("id"),
      values.value<String?>("request_id"),
    );
  }
}

class MeetingsCancelSummaryRequest extends OperationRequest {
  MeetingsCancelSummaryRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsCancelSummary;
  factory MeetingsCancelSummaryRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsCancelSummary.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsCancelSummaryRequest._(context, values.value<int>("id"));
  }
}

class MeetingsStartRequest extends OperationRequest {
  MeetingsStartRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.meetingsStart;
  factory MeetingsStartRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsStart.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsStartRequest._(context, values.value<int>("id"));
  }
}

class MeetingsStopRequest extends OperationRequest {
  MeetingsStopRequest._(super.context);
  @override
  Operation get operation => Operation.meetingsStop;
  factory MeetingsStopRequest.decode(OperationRequestContext context) {
    return MeetingsStopRequest._(context);
  }
}

class MeetingsPauseRequest extends OperationRequest {
  MeetingsPauseRequest._(super.context, this.id);
  final int? id;
  @override
  Operation get operation => Operation.meetingsPause;
  factory MeetingsPauseRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsPause.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsPauseRequest._(context, values.value<int?>("id"));
  }
}

class MeetingsResumeRequest extends OperationRequest {
  MeetingsResumeRequest._(super.context, this.id);
  final int? id;
  @override
  Operation get operation => Operation.meetingsResume;
  factory MeetingsResumeRequest.decode(OperationRequestContext context) {
    final values = Operation.meetingsResume.descriptor.arguments.decode(
      context.rawArguments,
    );
    return MeetingsResumeRequest._(context, values.value<int?>("id"));
  }
}
