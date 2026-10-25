import '../client_contract.dart';

final class GoogleStatusInput extends ClientArguments {
  const GoogleStatusInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleConfigureInput extends ClientArguments {
  const GoogleConfigureInput({
    super.envelope,
    this.provider = const WireField.absent(),
    this.path = const WireField.absent(),
    this.checkOnly = const WireField.absent(),
  });
  final WireField<String?> provider;
  final WireField<String?> path;
  final WireField<bool?> checkOnly;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (provider.present) 'provider': provider.value,
    if (path.present) 'path': path.value,
    if (checkOnly.present) 'checkOnly': checkOnly.value,
  });
}

final class GoogleCompleteSignInInput extends ClientArguments {
  const GoogleCompleteSignInInput({
    super.envelope,
    required this.url,
    this.manual = const WireField.absent(),
  });
  final String url;
  final WireField<bool?> manual;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'url': url, if (manual.present) 'manual': manual.value});
}

final class GoogleCancelSignInInput extends ClientArguments {
  const GoogleCancelSignInInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleDisconnectInput extends ClientArguments {
  const GoogleDisconnectInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleSwitchAccountInput extends ClientArguments {
  const GoogleSwitchAccountInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class GoogleSignOutAccountInput extends ClientArguments {
  const GoogleSignOutAccountInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class GoogleDriveFilesInput extends ClientArguments {
  const GoogleDriveFilesInput({
    super.envelope,
    this.parent = const WireField.absent(),
    this.query = const WireField.absent(),
    this.modifiedAfter = const WireField.absent(),
  });
  final WireField<String?> parent;
  final WireField<String?> query;
  final WireField<String?> modifiedAfter;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (parent.present) 'parent': parent.value,
    if (query.present) 'query': query.value,
    if (modifiedAfter.present) 'modifiedAfter': modifiedAfter.value,
  });
}

final class GoogleImportFileInput extends ClientArguments {
  const GoogleImportFileInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class GoogleImportFolderInput extends ClientArguments {
  const GoogleImportFolderInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class GoogleImportYearInput extends ClientArguments {
  const GoogleImportYearInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleRefreshInput extends ClientArguments {
  const GoogleRefreshInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleCalendarInput extends ClientArguments {
  const GoogleCalendarInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleAttachmentsInput extends ClientArguments {
  const GoogleAttachmentsInput({super.envelope, required this.id});
  final int id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class GoogleSignInInput extends ClientArguments {
  const GoogleSignInInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GoogleAddAccountInput extends ClientArguments {
  const GoogleAddAccountInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}
