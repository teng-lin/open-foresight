import '../client_contract.dart';

final class MeetingsListInput extends ClientArguments {
  const MeetingsListInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class MeetingsCreateInput extends ClientArguments {
  const MeetingsCreateInput({super.envelope, required this.title});
  final String title;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'title': title});
}

final class MeetingsRenameInput extends ClientArguments {
  const MeetingsRenameInput({
    super.envelope,
    required this.id,
    required this.title,
  });
  final int id;
  final String title;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id, 'title': title});
}

final class MeetingsGetInput extends ClientArguments {
  const MeetingsGetInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsRetryQuestionInput extends ClientArguments {
  const MeetingsRetryQuestionInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsRetryDetectionInput extends ClientArguments {
  const MeetingsRetryDetectionInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsLinkAnswerInput extends ClientArguments {
  const MeetingsLinkAnswerInput({
    super.envelope,
    required this.id,
    required this.answer,
  });
  final int id;
  final int answer;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'id': id, 'answer': answer});
}

final class MeetingsNotesInput extends ClientArguments {
  const MeetingsNotesInput({
    super.envelope,
    required this.id,
    required this.body,
    this.lastManualEdit = const WireField.absent(),
  });
  final int id;
  final String body;
  final WireField<int?> lastManualEdit;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    'body': body,
    if (lastManualEdit.present) 'last_manual_edit': lastManualEdit.value,
  });
}

final class MeetingsTranscriptInput extends ClientArguments {
  const MeetingsTranscriptInput({
    super.envelope,
    required this.id,
    required this.text,
    this.start = const WireField.absent(),
    this.end = const WireField.absent(),
    this.source = const WireField.absent(),
  });
  final int id;
  final String text;
  final WireField<int?> start;
  final WireField<int?> end;
  final WireField<String?> source;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    'text': text,
    if (start.present) 'start': start.value,
    if (end.present) 'end': end.value,
    if (source.present) 'source': source.value,
  });
}

final class MeetingsIndexInput extends ClientArguments {
  const MeetingsIndexInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsGenerateInput extends ClientArguments {
  const MeetingsGenerateInput({
    super.envelope,
    required this.id,
    required this.kind,
  });
  final int id;
  final String kind;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id, 'kind': kind});
}

final class MeetingsTasksInput extends ClientArguments {
  const MeetingsTasksInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsEditTaskInput extends ClientArguments {
  const MeetingsEditTaskInput({
    super.envelope,
    required this.id,
    this.task = const WireField.absent(),
    this.owner = const WireField.absent(),
    this.due = const WireField.absent(),
    this.status = const WireField.absent(),
  });
  final int id;
  final WireField<String?> task;
  final WireField<String?> owner;
  final WireField<String?> due;
  final WireField<String?> status;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    if (task.present) 'task': task.value,
    if (owner.present) 'owner': owner.value,
    if (due.present) 'due': due.value,
    if (status.present) 'status': status.value,
  });
}

final class MeetingsPrepareInput extends ClientArguments {
  MeetingsPrepareInput({
    super.envelope,
    required this.id,
    required List<String> sourceIds,
  }) : sourceIds = List.unmodifiable(sourceIds);
  final int id;
  final List<String> sourceIds;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'id': id, 'source_ids': sourceIds});
}

final class MeetingsCancelGenerationInput extends ClientArguments {
  const MeetingsCancelGenerationInput({
    super.envelope,
    required this.id,
    this.kind = const WireField.absent(),
  });
  final int id;
  final WireField<String?> kind;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'id': id, if (kind.present) 'kind': kind.value});
}

final class MeetingsEnhanceInput extends ClientArguments {
  const MeetingsEnhanceInput({
    super.envelope,
    required this.id,
    this.forceRegenerate = const WireField.absent(),
  });
  final int id;
  final WireField<bool?> forceRegenerate;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    if (forceRegenerate.present) 'force_regenerate': forceRegenerate.value,
  });
}

final class MeetingsCancelEnhanceInput extends ClientArguments {
  const MeetingsCancelEnhanceInput({
    super.envelope,
    required this.id,
    this.requestId = const WireField.absent(),
  });
  final int id;
  final WireField<String?> requestId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    if (requestId.present) 'request_id': requestId.value,
  });
}

final class MeetingsCancelSummaryInput extends ClientArguments {
  const MeetingsCancelSummaryInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsStartInput extends ClientArguments {
  const MeetingsStartInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class MeetingsStopInput extends ClientArguments {
  const MeetingsStopInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class MeetingsPauseInput extends ClientArguments {
  const MeetingsPauseInput({
    super.envelope,
    this.id = const WireField.absent(),
  });
  final WireField<int?> id;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({if (id.present) 'id': id.value});
}

final class MeetingsResumeInput extends ClientArguments {
  const MeetingsResumeInput({
    super.envelope,
    this.id = const WireField.absent(),
  });
  final WireField<int?> id;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({if (id.present) 'id': id.value});
}
