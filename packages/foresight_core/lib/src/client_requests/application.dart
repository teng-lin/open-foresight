import '../client_contract.dart';

final class NotificationsCapabilitiesInput extends ClientArguments {
  const NotificationsCapabilitiesInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class NotificationsRequestPermissionInput extends ClientArguments {
  const NotificationsRequestPermissionInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class AudioCapabilitiesInput extends ClientArguments {
  const AudioCapabilitiesInput({
    super.envelope,
    this.enumerateDevices = const WireField.absent(),
  });
  final WireField<bool?> enumerateDevices;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (enumerateDevices.present) 'enumerate_devices': enumerateDevices.value,
  });
}

final class AudioRequestSystemInput extends ClientArguments {
  const AudioRequestSystemInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class AudioRequestMicrophoneInput extends ClientArguments {
  const AudioRequestMicrophoneInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class StatusInput extends ClientArguments {
  const StatusInput({
    super.envelope,
    this.desktop = const WireField.absent(),
    this.token = const WireField.absent(),
    this.clientApiVersion = const WireField.absent(),
  });
  final WireField<bool?> desktop;
  final WireField<String?> token;
  final WireField<int?> clientApiVersion;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (desktop.present) 'desktop': desktop.value,
    if (token.present) 'token': token.value,
    if (clientApiVersion.present) 'client_api_version': clientApiVersion.value,
  });
}

final class AnswerInput extends ClientArguments {
  const AnswerInput({
    super.envelope,
    required this.question,
    this.meetingId = const WireField.absent(),
    this.webSearch = const WireField.absent(),
  });
  final String question;
  final WireField<int?> meetingId;
  final WireField<bool?> webSearch;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'question': question,
    if (meetingId.present) 'meeting_id': meetingId.value,
    if (webSearch.present) 'web_search': webSearch.value,
  });
}

final class NotesListInput extends ClientArguments {
  const NotesListInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class NotesSaveInput extends ClientArguments {
  const NotesSaveInput({
    super.envelope,
    this.id = const WireField.absent(),
    required this.title,
    required this.body,
  });
  final WireField<int?> id;
  final String title;
  final String body;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (id.present) 'id': id.value,
    'title': title,
    'body': body,
  });
}

final class PreferencesSetInput extends ClientArguments {
  const PreferencesSetInput({
    super.envelope,
    required this.key,
    required this.value,
  });
  final String key;
  final String value;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'key': key, 'value': value});
}

final class WorkspaceClearInput extends ClientArguments {
  const WorkspaceClearInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class ArtifactsEditInput extends ClientArguments {
  const ArtifactsEditInput({
    super.envelope,
    required this.id,
    required this.text,
    this.lastManualEdit = const WireField.absent(),
  });
  final int id;
  final String text;
  final WireField<int?> lastManualEdit;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    'text': text,
    if (lastManualEdit.present) 'last_manual_edit': lastManualEdit.value,
  });
}

final class ApplicationResumeInput extends ClientArguments {
  const ApplicationResumeInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class AnswerStreamInput extends ClientArguments {
  const AnswerStreamInput({
    super.envelope,
    required this.question,
    this.meetingId = const WireField.absent(),
    this.webSearch = const WireField.absent(),
  });
  final String question;
  final WireField<int?> meetingId;
  final WireField<bool?> webSearch;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'question': question,
    if (meetingId.present) 'meeting_id': meetingId.value,
    if (webSearch.present) 'web_search': webSearch.value,
  });
}

final class ServiceStopIfIdleInput extends ClientArguments {
  const ServiceStopIfIdleInput({
    super.envelope,
    this.expectedPid = const WireField.absent(),
    this.installationRoot = const WireField.absent(),
    this.runtimeRevision = const WireField.absent(),
    this.token = const WireField.absent(),
  });
  final WireField<int?> expectedPid;
  final WireField<String?> installationRoot;
  final WireField<String?> runtimeRevision;
  final WireField<String?> token;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (expectedPid.present) 'expected_pid': expectedPid.value,
    if (installationRoot.present) 'installation_root': installationRoot.value,
    if (runtimeRevision.present) 'runtime_revision': runtimeRevision.value,
    if (token.present) 'token': token.value,
  });
}
