import '../operations.dart';
import 'request_context.dart';

class SourcesListRequest extends OperationRequest {
  SourcesListRequest._(super.context);
  @override
  Operation get operation => Operation.sourcesList;
  factory SourcesListRequest.decode(OperationRequestContext context) {
    return SourcesListRequest._(context);
  }
}

class SourcesGetRequest extends OperationRequest {
  SourcesGetRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.sourcesGet;
  factory SourcesGetRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesGet.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesGetRequest._(context, values.value<String>("id"));
  }
}

class SourcesImportRequest extends OperationRequest {
  SourcesImportRequest._(
    super.context,
    this.id,
    this.title,
    this.text,
    this.mime,
    this.provenance,
    this.modifiedAtMs,
    this.sourceUri,
    this.locallyEdited,
    this.index,
  );
  final String? id;
  final String title;
  final String text;
  final String mime;
  final String provenance;
  final int? modifiedAtMs;
  final String? sourceUri;
  final bool locallyEdited;
  final bool index;
  @override
  Operation get operation => Operation.sourcesImport;
  factory SourcesImportRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesImport.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesImportRequest._(
      context,
      values.value<String?>("id"),
      values.value<String>("title"),
      values.value<String>("text"),
      values.value<String>("mime"),
      values.value<String>("provenance"),
      values.value<int?>("modifiedAtMs"),
      values.value<String?>("sourceUri"),
      values.value<bool>("locallyEdited"),
      values.value<bool>("index"),
    );
  }
}

class SourcesImportUrlRequest extends OperationRequest {
  SourcesImportUrlRequest._(super.context, this.url, this.allowPrivateNetwork);
  final String url;
  final bool allowPrivateNetwork;
  @override
  Operation get operation => Operation.sourcesImportUrl;
  factory SourcesImportUrlRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesImportUrl.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesImportUrlRequest._(
      context,
      values.value<String>("url"),
      values.value<bool>("allow_private_network"),
    );
  }
}

class SourcesImportDirectoryRequest extends OperationRequest {
  SourcesImportDirectoryRequest._(super.context, this.path);
  final String path;
  @override
  Operation get operation => Operation.sourcesImportDirectory;
  factory SourcesImportDirectoryRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.sourcesImportDirectory.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesImportDirectoryRequest._(
      context,
      values.value<String>("path"),
    );
  }
}

class SourcesRefreshRequest extends OperationRequest {
  SourcesRefreshRequest._(super.context, this.allowPrivateNetwork);
  final bool allowPrivateNetwork;
  @override
  Operation get operation => Operation.sourcesRefresh;
  factory SourcesRefreshRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesRefresh.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesRefreshRequest._(
      context,
      values.value<bool>("allow_private_network"),
    );
  }
}

class SourcesImportFileRequest extends OperationRequest {
  SourcesImportFileRequest._(super.context, this.path);
  final String path;
  @override
  Operation get operation => Operation.sourcesImportFile;
  factory SourcesImportFileRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesImportFile.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesImportFileRequest._(context, values.value<String>("path"));
  }
}

class SourcesIndexRequest extends OperationRequest {
  SourcesIndexRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.sourcesIndex;
  factory SourcesIndexRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesIndex.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesIndexRequest._(context, values.value<String>("id"));
  }
}

class SourcesDeleteRequest extends OperationRequest {
  SourcesDeleteRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.sourcesDelete;
  factory SourcesDeleteRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesDelete.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesDeleteRequest._(context, values.value<String>("id"));
  }
}

class SourcesPauseRequest extends OperationRequest {
  SourcesPauseRequest._(super.context);
  @override
  Operation get operation => Operation.sourcesPause;
  factory SourcesPauseRequest.decode(OperationRequestContext context) {
    return SourcesPauseRequest._(context);
  }
}

class SourcesResumeRequest extends OperationRequest {
  SourcesResumeRequest._(super.context);
  @override
  Operation get operation => Operation.sourcesResume;
  factory SourcesResumeRequest.decode(OperationRequestContext context) {
    return SourcesResumeRequest._(context);
  }
}

class SourcesSearchRequest extends OperationRequest {
  SourcesSearchRequest._(super.context, this.query, this.limit);
  final String query;
  final int limit;
  @override
  Operation get operation => Operation.sourcesSearch;
  factory SourcesSearchRequest.decode(OperationRequestContext context) {
    final values = Operation.sourcesSearch.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SourcesSearchRequest._(
      context,
      values.value<String>("query"),
      values.value<int>("limit"),
    );
  }
}
