import '../client_contract.dart';

final class SourcesListInput extends ClientArguments {
  const SourcesListInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class SourcesGetInput extends ClientArguments {
  const SourcesGetInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class SourcesImportInput extends ClientArguments {
  const SourcesImportInput({
    super.envelope,
    this.id = const WireField.absent(),
    required this.title,
    required this.text,
    this.mime = const WireField.absent(),
    this.provenance = const WireField.absent(),
    this.modifiedAtMs = const WireField.absent(),
    this.sourceUri = const WireField.absent(),
    this.locallyEdited = const WireField.absent(),
    this.index = const WireField.absent(),
  });
  final WireField<String?> id;
  final String title;
  final String text;
  final WireField<String?> mime;
  final WireField<String?> provenance;
  final WireField<int?> modifiedAtMs;
  final WireField<String?> sourceUri;
  final WireField<bool?> locallyEdited;
  final WireField<bool?> index;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (id.present) 'id': id.value,
    'title': title,
    'text': text,
    if (mime.present) 'mime': mime.value,
    if (provenance.present) 'provenance': provenance.value,
    if (modifiedAtMs.present) 'modifiedAtMs': modifiedAtMs.value,
    if (sourceUri.present) 'sourceUri': sourceUri.value,
    if (locallyEdited.present) 'locallyEdited': locallyEdited.value,
    if (index.present) 'index': index.value,
  });
}

final class SourcesImportUrlInput extends ClientArguments {
  const SourcesImportUrlInput({
    super.envelope,
    required this.url,
    this.allowPrivateNetwork = const WireField.absent(),
  });
  final String url;
  final WireField<bool?> allowPrivateNetwork;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'url': url,
    if (allowPrivateNetwork.present)
      'allow_private_network': allowPrivateNetwork.value,
  });
}

final class SourcesImportDirectoryInput extends ClientArguments {
  const SourcesImportDirectoryInput({super.envelope, required this.path});
  final String path;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'path': path});
}

final class SourcesRefreshInput extends ClientArguments {
  const SourcesRefreshInput({
    super.envelope,
    this.allowPrivateNetwork = const WireField.absent(),
  });
  final WireField<bool?> allowPrivateNetwork;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    if (allowPrivateNetwork.present)
      'allow_private_network': allowPrivateNetwork.value,
  });
}

final class SourcesImportFileInput extends ClientArguments {
  const SourcesImportFileInput({super.envelope, required this.path});
  final String path;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'path': path});
}

final class SourcesIndexInput extends ClientArguments {
  const SourcesIndexInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class SourcesDeleteInput extends ClientArguments {
  const SourcesDeleteInput({super.envelope, required this.id});
  final String id;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'id': id});
}

final class SourcesPauseInput extends ClientArguments {
  const SourcesPauseInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class SourcesResumeInput extends ClientArguments {
  const SourcesResumeInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class SourcesSearchInput extends ClientArguments {
  const SourcesSearchInput({
    super.envelope,
    required this.query,
    this.limit = const WireField.absent(),
  });
  final String query;
  final WireField<int?> limit;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'query': query,
    if (limit.present) 'limit': limit.value,
  });
}
