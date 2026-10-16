// This is a generated file - do not edit.
//
// Generated from rag_service.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class IndexRequest extends $pb.GeneratedMessage {
  factory IndexRequest({
    $core.String? documentId,
    $core.String? content,
    $core.String? userId,
    $core.int? maxTokensPerChunk,
    $core.int? chunkOverlap,
    $core.List<$core.int>? imageBytes,
    $core.String? mimeType,
  }) {
    final result = create();
    if (documentId != null) result.documentId = documentId;
    if (content != null) result.content = content;
    if (userId != null) result.userId = userId;
    if (maxTokensPerChunk != null) result.maxTokensPerChunk = maxTokensPerChunk;
    if (chunkOverlap != null) result.chunkOverlap = chunkOverlap;
    if (imageBytes != null) result.imageBytes = imageBytes;
    if (mimeType != null) result.mimeType = mimeType;
    return result;
  }

  IndexRequest._();

  factory IndexRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory IndexRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'IndexRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'documentId')
    ..aOS(2, _omitFieldNames ? '' : 'content')
    ..aOS(3, _omitFieldNames ? '' : 'userId')
    ..aI(4, _omitFieldNames ? '' : 'maxTokensPerChunk')
    ..aI(5, _omitFieldNames ? '' : 'chunkOverlap')
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'imageBytes', $pb.PbFieldType.OY)
    ..aOS(7, _omitFieldNames ? '' : 'mimeType')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IndexRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IndexRequest copyWith(void Function(IndexRequest) updates) =>
      super.copyWith((message) => updates(message as IndexRequest))
          as IndexRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static IndexRequest create() => IndexRequest._();
  @$core.override
  IndexRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static IndexRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<IndexRequest>(create);
  static IndexRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get documentId => $_getSZ(0);
  @$pb.TagNumber(1)
  set documentId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDocumentId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDocumentId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get content => $_getSZ(1);
  @$pb.TagNumber(2)
  set content($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasContent() => $_has(1);
  @$pb.TagNumber(2)
  void clearContent() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get userId => $_getSZ(2);
  @$pb.TagNumber(3)
  set userId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearUserId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get maxTokensPerChunk => $_getIZ(3);
  @$pb.TagNumber(4)
  set maxTokensPerChunk($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMaxTokensPerChunk() => $_has(3);
  @$pb.TagNumber(4)
  void clearMaxTokensPerChunk() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get chunkOverlap => $_getIZ(4);
  @$pb.TagNumber(5)
  set chunkOverlap($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasChunkOverlap() => $_has(4);
  @$pb.TagNumber(5)
  void clearChunkOverlap() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get imageBytes => $_getN(5);
  @$pb.TagNumber(6)
  set imageBytes($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasImageBytes() => $_has(5);
  @$pb.TagNumber(6)
  void clearImageBytes() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get mimeType => $_getSZ(6);
  @$pb.TagNumber(7)
  set mimeType($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMimeType() => $_has(6);
  @$pb.TagNumber(7)
  void clearMimeType() => $_clearField(7);
}

class IndexResponse extends $pb.GeneratedMessage {
  factory IndexResponse({
    $core.bool? success,
    $core.String? errorMessage,
  }) {
    final result = create();
    if (success != null) result.success = success;
    if (errorMessage != null) result.errorMessage = errorMessage;
    return result;
  }

  IndexResponse._();

  factory IndexResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory IndexResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'IndexResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'success')
    ..aOS(2, _omitFieldNames ? '' : 'errorMessage')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IndexResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IndexResponse copyWith(void Function(IndexResponse) updates) =>
      super.copyWith((message) => updates(message as IndexResponse))
          as IndexResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static IndexResponse create() => IndexResponse._();
  @$core.override
  IndexResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static IndexResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<IndexResponse>(create);
  static IndexResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get success => $_getBF(0);
  @$pb.TagNumber(1)
  set success($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSuccess() => $_has(0);
  @$pb.TagNumber(1)
  void clearSuccess() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get errorMessage => $_getSZ(1);
  @$pb.TagNumber(2)
  set errorMessage($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasErrorMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearErrorMessage() => $_clearField(2);
}

enum Query_Query { textQuery, audioQuery, notSet }

class Query extends $pb.GeneratedMessage {
  factory Query({
    $core.String? textQuery,
    $core.List<$core.int>? audioQuery,
  }) {
    final result = create();
    if (textQuery != null) result.textQuery = textQuery;
    if (audioQuery != null) result.audioQuery = audioQuery;
    return result;
  }

  Query._();

  factory Query.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Query.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Query_Query> _Query_QueryByTag = {
    1: Query_Query.textQuery,
    2: Query_Query.audioQuery,
    0: Query_Query.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Query',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOS(1, _omitFieldNames ? '' : 'textQuery')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'audioQuery', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Query clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Query copyWith(void Function(Query) updates) =>
      super.copyWith((message) => updates(message as Query)) as Query;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Query create() => Query._();
  @$core.override
  Query createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Query getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Query>(create);
  static Query? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  Query_Query whichQuery() => _Query_QueryByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearQuery() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get textQuery => $_getSZ(0);
  @$pb.TagNumber(1)
  set textQuery($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTextQuery() => $_has(0);
  @$pb.TagNumber(1)
  void clearTextQuery() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get audioQuery => $_getN(1);
  @$pb.TagNumber(2)
  set audioQuery($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAudioQuery() => $_has(1);
  @$pb.TagNumber(2)
  void clearAudioQuery() => $_clearField(2);
}

class RetrieveRequest extends $pb.GeneratedMessage {
  factory RetrieveRequest({
    Query? query,
    $core.int? maxResults,
    $core.double? minSimilarityScore,
    $core.String? userId,
    $core.Iterable<$core.String>? allowedDocumentIds,
  }) {
    final result = create();
    if (query != null) result.query = query;
    if (maxResults != null) result.maxResults = maxResults;
    if (minSimilarityScore != null)
      result.minSimilarityScore = minSimilarityScore;
    if (userId != null) result.userId = userId;
    if (allowedDocumentIds != null)
      result.allowedDocumentIds.addAll(allowedDocumentIds);
    return result;
  }

  RetrieveRequest._();

  factory RetrieveRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RetrieveRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RetrieveRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOM<Query>(1, _omitFieldNames ? '' : 'query', subBuilder: Query.create)
    ..aI(2, _omitFieldNames ? '' : 'maxResults')
    ..aD(3, _omitFieldNames ? '' : 'minSimilarityScore')
    ..aOS(4, _omitFieldNames ? '' : 'userId')
    ..pPS(5, _omitFieldNames ? '' : 'allowedDocumentIds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RetrieveRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RetrieveRequest copyWith(void Function(RetrieveRequest) updates) =>
      super.copyWith((message) => updates(message as RetrieveRequest))
          as RetrieveRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RetrieveRequest create() => RetrieveRequest._();
  @$core.override
  RetrieveRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RetrieveRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RetrieveRequest>(create);
  static RetrieveRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Query get query => $_getN(0);
  @$pb.TagNumber(1)
  set query(Query value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasQuery() => $_has(0);
  @$pb.TagNumber(1)
  void clearQuery() => $_clearField(1);
  @$pb.TagNumber(1)
  Query ensureQuery() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.int get maxResults => $_getIZ(1);
  @$pb.TagNumber(2)
  set maxResults($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxResults() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxResults() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get minSimilarityScore => $_getN(2);
  @$pb.TagNumber(3)
  set minSimilarityScore($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMinSimilarityScore() => $_has(2);
  @$pb.TagNumber(3)
  void clearMinSimilarityScore() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get userId => $_getSZ(3);
  @$pb.TagNumber(4)
  set userId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasUserId() => $_has(3);
  @$pb.TagNumber(4)
  void clearUserId() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get allowedDocumentIds => $_getList(4);
}

class RetrieveResponse extends $pb.GeneratedMessage {
  factory RetrieveResponse({
    $core.Iterable<RetrievedChunk>? chunks,
  }) {
    final result = create();
    if (chunks != null) result.chunks.addAll(chunks);
    return result;
  }

  RetrieveResponse._();

  factory RetrieveResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RetrieveResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RetrieveResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..pPM<RetrievedChunk>(1, _omitFieldNames ? '' : 'chunks',
        subBuilder: RetrievedChunk.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RetrieveResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RetrieveResponse copyWith(void Function(RetrieveResponse) updates) =>
      super.copyWith((message) => updates(message as RetrieveResponse))
          as RetrieveResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RetrieveResponse create() => RetrieveResponse._();
  @$core.override
  RetrieveResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RetrieveResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RetrieveResponse>(create);
  static RetrieveResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<RetrievedChunk> get chunks => $_getList(0);
}

class RetrievedChunk extends $pb.GeneratedMessage {
  factory RetrievedChunk({
    $core.String? text,
    $core.double? relevanceScore,
    $core.String? documentId,
    $core.String? mimeType,
  }) {
    final result = create();
    if (text != null) result.text = text;
    if (relevanceScore != null) result.relevanceScore = relevanceScore;
    if (documentId != null) result.documentId = documentId;
    if (mimeType != null) result.mimeType = mimeType;
    return result;
  }

  RetrievedChunk._();

  factory RetrievedChunk.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RetrievedChunk.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RetrievedChunk',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..aD(2, _omitFieldNames ? '' : 'relevanceScore')
    ..aOS(3, _omitFieldNames ? '' : 'documentId')
    ..aOS(4, _omitFieldNames ? '' : 'mimeType')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RetrievedChunk clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RetrievedChunk copyWith(void Function(RetrievedChunk) updates) =>
      super.copyWith((message) => updates(message as RetrievedChunk))
          as RetrievedChunk;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RetrievedChunk create() => RetrievedChunk._();
  @$core.override
  RetrievedChunk createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RetrievedChunk getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RetrievedChunk>(create);
  static RetrievedChunk? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get relevanceScore => $_getN(1);
  @$pb.TagNumber(2)
  set relevanceScore($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRelevanceScore() => $_has(1);
  @$pb.TagNumber(2)
  void clearRelevanceScore() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get documentId => $_getSZ(2);
  @$pb.TagNumber(3)
  set documentId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDocumentId() => $_has(2);
  @$pb.TagNumber(3)
  void clearDocumentId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get mimeType => $_getSZ(3);
  @$pb.TagNumber(4)
  set mimeType($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMimeType() => $_has(3);
  @$pb.TagNumber(4)
  void clearMimeType() => $_clearField(4);
}

class UpdateModelPathsRequest extends $pb.GeneratedMessage {
  factory UpdateModelPathsRequest({
    $core.String? embeddingModelPath,
    $core.String? sentencePieceModelPath,
    $core.bool? useGpu,
    $core.String? cacheDir,
  }) {
    final result = create();
    if (embeddingModelPath != null)
      result.embeddingModelPath = embeddingModelPath;
    if (sentencePieceModelPath != null)
      result.sentencePieceModelPath = sentencePieceModelPath;
    if (useGpu != null) result.useGpu = useGpu;
    if (cacheDir != null) result.cacheDir = cacheDir;
    return result;
  }

  UpdateModelPathsRequest._();

  factory UpdateModelPathsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory UpdateModelPathsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateModelPathsRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'embeddingModelPath')
    ..aOS(2, _omitFieldNames ? '' : 'sentencePieceModelPath')
    ..aOB(3, _omitFieldNames ? '' : 'useGpu')
    ..aOS(4, _omitFieldNames ? '' : 'cacheDir')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateModelPathsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateModelPathsRequest copyWith(
          void Function(UpdateModelPathsRequest) updates) =>
      super.copyWith((message) => updates(message as UpdateModelPathsRequest))
          as UpdateModelPathsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static UpdateModelPathsRequest create() => UpdateModelPathsRequest._();
  @$core.override
  UpdateModelPathsRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static UpdateModelPathsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateModelPathsRequest>(create);
  static UpdateModelPathsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get embeddingModelPath => $_getSZ(0);
  @$pb.TagNumber(1)
  set embeddingModelPath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEmbeddingModelPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearEmbeddingModelPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sentencePieceModelPath => $_getSZ(1);
  @$pb.TagNumber(2)
  set sentencePieceModelPath($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSentencePieceModelPath() => $_has(1);
  @$pb.TagNumber(2)
  void clearSentencePieceModelPath() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get useGpu => $_getBF(2);
  @$pb.TagNumber(3)
  set useGpu($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUseGpu() => $_has(2);
  @$pb.TagNumber(3)
  void clearUseGpu() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get cacheDir => $_getSZ(3);
  @$pb.TagNumber(4)
  set cacheDir($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCacheDir() => $_has(3);
  @$pb.TagNumber(4)
  void clearCacheDir() => $_clearField(4);
}

class UpdateModelPathsResponse extends $pb.GeneratedMessage {
  factory UpdateModelPathsResponse({
    $core.bool? success,
    $core.String? errorMessage,
  }) {
    final result = create();
    if (success != null) result.success = success;
    if (errorMessage != null) result.errorMessage = errorMessage;
    return result;
  }

  UpdateModelPathsResponse._();

  factory UpdateModelPathsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory UpdateModelPathsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateModelPathsResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'success')
    ..aOS(2, _omitFieldNames ? '' : 'errorMessage')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateModelPathsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateModelPathsResponse copyWith(
          void Function(UpdateModelPathsResponse) updates) =>
      super.copyWith((message) => updates(message as UpdateModelPathsResponse))
          as UpdateModelPathsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static UpdateModelPathsResponse create() => UpdateModelPathsResponse._();
  @$core.override
  UpdateModelPathsResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static UpdateModelPathsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateModelPathsResponse>(create);
  static UpdateModelPathsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get success => $_getBF(0);
  @$pb.TagNumber(1)
  set success($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSuccess() => $_has(0);
  @$pb.TagNumber(1)
  void clearSuccess() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get errorMessage => $_getSZ(1);
  @$pb.TagNumber(2)
  set errorMessage($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasErrorMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearErrorMessage() => $_clearField(2);
}

class DeleteRequest extends $pb.GeneratedMessage {
  factory DeleteRequest({
    $core.String? documentId,
    $core.String? userId,
  }) {
    final result = create();
    if (documentId != null) result.documentId = documentId;
    if (userId != null) result.userId = userId;
    return result;
  }

  DeleteRequest._();

  factory DeleteRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DeleteRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'documentId')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteRequest copyWith(void Function(DeleteRequest) updates) =>
      super.copyWith((message) => updates(message as DeleteRequest))
          as DeleteRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DeleteRequest create() => DeleteRequest._();
  @$core.override
  DeleteRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DeleteRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteRequest>(create);
  static DeleteRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get documentId => $_getSZ(0);
  @$pb.TagNumber(1)
  set documentId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDocumentId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDocumentId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class DeleteResponse extends $pb.GeneratedMessage {
  factory DeleteResponse({
    $core.bool? success,
    $core.String? errorMessage,
  }) {
    final result = create();
    if (success != null) result.success = success;
    if (errorMessage != null) result.errorMessage = errorMessage;
    return result;
  }

  DeleteResponse._();

  factory DeleteResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DeleteResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'success')
    ..aOS(2, _omitFieldNames ? '' : 'errorMessage')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteResponse copyWith(void Function(DeleteResponse) updates) =>
      super.copyWith((message) => updates(message as DeleteResponse))
          as DeleteResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DeleteResponse create() => DeleteResponse._();
  @$core.override
  DeleteResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DeleteResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteResponse>(create);
  static DeleteResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get success => $_getBF(0);
  @$pb.TagNumber(1)
  set success($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSuccess() => $_has(0);
  @$pb.TagNumber(1)
  void clearSuccess() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get errorMessage => $_getSZ(1);
  @$pb.TagNumber(2)
  set errorMessage($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasErrorMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearErrorMessage() => $_clearField(2);
}

class EncodeRequest extends $pb.GeneratedMessage {
  factory EncodeRequest({
    $core.String? text,
  }) {
    final result = create();
    if (text != null) result.text = text;
    return result;
  }

  EncodeRequest._();

  factory EncodeRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory EncodeRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EncodeRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncodeRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncodeRequest copyWith(void Function(EncodeRequest) updates) =>
      super.copyWith((message) => updates(message as EncodeRequest))
          as EncodeRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EncodeRequest create() => EncodeRequest._();
  @$core.override
  EncodeRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static EncodeRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EncodeRequest>(create);
  static EncodeRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);
}

class EncodeResponse extends $pb.GeneratedMessage {
  factory EncodeResponse({
    $core.Iterable<$core.int>? tokens,
  }) {
    final result = create();
    if (tokens != null) result.tokens.addAll(tokens);
    return result;
  }

  EncodeResponse._();

  factory EncodeResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory EncodeResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EncodeResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..p<$core.int>(1, _omitFieldNames ? '' : 'tokens', $pb.PbFieldType.K3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncodeResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncodeResponse copyWith(void Function(EncodeResponse) updates) =>
      super.copyWith((message) => updates(message as EncodeResponse))
          as EncodeResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EncodeResponse create() => EncodeResponse._();
  @$core.override
  EncodeResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static EncodeResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EncodeResponse>(create);
  static EncodeResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.int> get tokens => $_getList(0);
}

class ChunkTextRequest extends $pb.GeneratedMessage {
  factory ChunkTextRequest({
    $core.String? text,
    $core.int? maxTokensPerChunk,
  }) {
    final result = create();
    if (text != null) result.text = text;
    if (maxTokensPerChunk != null) result.maxTokensPerChunk = maxTokensPerChunk;
    return result;
  }

  ChunkTextRequest._();

  factory ChunkTextRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ChunkTextRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ChunkTextRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..aI(2, _omitFieldNames ? '' : 'maxTokensPerChunk')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChunkTextRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChunkTextRequest copyWith(void Function(ChunkTextRequest) updates) =>
      super.copyWith((message) => updates(message as ChunkTextRequest))
          as ChunkTextRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ChunkTextRequest create() => ChunkTextRequest._();
  @$core.override
  ChunkTextRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ChunkTextRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ChunkTextRequest>(create);
  static ChunkTextRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get maxTokensPerChunk => $_getIZ(1);
  @$pb.TagNumber(2)
  set maxTokensPerChunk($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxTokensPerChunk() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxTokensPerChunk() => $_clearField(2);
}

class ChunkTextResponse extends $pb.GeneratedMessage {
  factory ChunkTextResponse({
    $core.Iterable<$core.String>? chunks,
  }) {
    final result = create();
    if (chunks != null) result.chunks.addAll(chunks);
    return result;
  }

  ChunkTextResponse._();

  factory ChunkTextResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ChunkTextResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ChunkTextResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'chunks')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChunkTextResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChunkTextResponse copyWith(void Function(ChunkTextResponse) updates) =>
      super.copyWith((message) => updates(message as ChunkTextResponse))
          as ChunkTextResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ChunkTextResponse create() => ChunkTextResponse._();
  @$core.override
  ChunkTextResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ChunkTextResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ChunkTextResponse>(create);
  static ChunkTextResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get chunks => $_getList(0);
}

class TruncateTextRequest extends $pb.GeneratedMessage {
  factory TruncateTextRequest({
    $core.String? text,
    $core.int? maxTokens,
  }) {
    final result = create();
    if (text != null) result.text = text;
    if (maxTokens != null) result.maxTokens = maxTokens;
    return result;
  }

  TruncateTextRequest._();

  factory TruncateTextRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TruncateTextRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TruncateTextRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..aI(2, _omitFieldNames ? '' : 'maxTokens')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TruncateTextRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TruncateTextRequest copyWith(void Function(TruncateTextRequest) updates) =>
      super.copyWith((message) => updates(message as TruncateTextRequest))
          as TruncateTextRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TruncateTextRequest create() => TruncateTextRequest._();
  @$core.override
  TruncateTextRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TruncateTextRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TruncateTextRequest>(create);
  static TruncateTextRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get maxTokens => $_getIZ(1);
  @$pb.TagNumber(2)
  set maxTokens($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxTokens() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxTokens() => $_clearField(2);
}

class TruncateTextResponse extends $pb.GeneratedMessage {
  factory TruncateTextResponse({
    $core.String? truncatedText,
  }) {
    final result = create();
    if (truncatedText != null) result.truncatedText = truncatedText;
    return result;
  }

  TruncateTextResponse._();

  factory TruncateTextResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TruncateTextResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TruncateTextResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'truncatedText')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TruncateTextResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TruncateTextResponse copyWith(void Function(TruncateTextResponse) updates) =>
      super.copyWith((message) => updates(message as TruncateTextResponse))
          as TruncateTextResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TruncateTextResponse create() => TruncateTextResponse._();
  @$core.override
  TruncateTextResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TruncateTextResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TruncateTextResponse>(create);
  static TruncateTextResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get truncatedText => $_getSZ(0);
  @$pb.TagNumber(1)
  set truncatedText($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTruncatedText() => $_has(0);
  @$pb.TagNumber(1)
  void clearTruncatedText() => $_clearField(1);
}

class ComputeEmbeddingRequest extends $pb.GeneratedMessage {
  factory ComputeEmbeddingRequest({
    $core.String? text,
  }) {
    final result = create();
    if (text != null) result.text = text;
    return result;
  }

  ComputeEmbeddingRequest._();

  factory ComputeEmbeddingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ComputeEmbeddingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ComputeEmbeddingRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeEmbeddingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeEmbeddingRequest copyWith(
          void Function(ComputeEmbeddingRequest) updates) =>
      super.copyWith((message) => updates(message as ComputeEmbeddingRequest))
          as ComputeEmbeddingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ComputeEmbeddingRequest create() => ComputeEmbeddingRequest._();
  @$core.override
  ComputeEmbeddingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ComputeEmbeddingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ComputeEmbeddingRequest>(create);
  static ComputeEmbeddingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);
}

class ComputeEmbeddingResponse extends $pb.GeneratedMessage {
  factory ComputeEmbeddingResponse({
    $core.Iterable<$core.double>? embedding,
  }) {
    final result = create();
    if (embedding != null) result.embedding.addAll(embedding);
    return result;
  }

  ComputeEmbeddingResponse._();

  factory ComputeEmbeddingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ComputeEmbeddingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ComputeEmbeddingResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..p<$core.double>(1, _omitFieldNames ? '' : 'embedding', $pb.PbFieldType.KD)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeEmbeddingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeEmbeddingResponse copyWith(
          void Function(ComputeEmbeddingResponse) updates) =>
      super.copyWith((message) => updates(message as ComputeEmbeddingResponse))
          as ComputeEmbeddingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ComputeEmbeddingResponse create() => ComputeEmbeddingResponse._();
  @$core.override
  ComputeEmbeddingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ComputeEmbeddingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ComputeEmbeddingResponse>(create);
  static ComputeEmbeddingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.double> get embedding => $_getList(0);
}

class ComputeImageEmbeddingRequest extends $pb.GeneratedMessage {
  factory ComputeImageEmbeddingRequest({
    $core.List<$core.int>? imageBytes,
  }) {
    final result = create();
    if (imageBytes != null) result.imageBytes = imageBytes;
    return result;
  }

  ComputeImageEmbeddingRequest._();

  factory ComputeImageEmbeddingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ComputeImageEmbeddingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ComputeImageEmbeddingRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'imageBytes', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeImageEmbeddingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeImageEmbeddingRequest copyWith(
          void Function(ComputeImageEmbeddingRequest) updates) =>
      super.copyWith(
              (message) => updates(message as ComputeImageEmbeddingRequest))
          as ComputeImageEmbeddingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ComputeImageEmbeddingRequest create() =>
      ComputeImageEmbeddingRequest._();
  @$core.override
  ComputeImageEmbeddingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ComputeImageEmbeddingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ComputeImageEmbeddingRequest>(create);
  static ComputeImageEmbeddingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get imageBytes => $_getN(0);
  @$pb.TagNumber(1)
  set imageBytes($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasImageBytes() => $_has(0);
  @$pb.TagNumber(1)
  void clearImageBytes() => $_clearField(1);
}

class ComputeAudioEmbeddingRequest extends $pb.GeneratedMessage {
  factory ComputeAudioEmbeddingRequest({
    $core.List<$core.int>? audioBytes,
  }) {
    final result = create();
    if (audioBytes != null) result.audioBytes = audioBytes;
    return result;
  }

  ComputeAudioEmbeddingRequest._();

  factory ComputeAudioEmbeddingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ComputeAudioEmbeddingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ComputeAudioEmbeddingRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'audioBytes', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeAudioEmbeddingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ComputeAudioEmbeddingRequest copyWith(
          void Function(ComputeAudioEmbeddingRequest) updates) =>
      super.copyWith(
              (message) => updates(message as ComputeAudioEmbeddingRequest))
          as ComputeAudioEmbeddingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ComputeAudioEmbeddingRequest create() =>
      ComputeAudioEmbeddingRequest._();
  @$core.override
  ComputeAudioEmbeddingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ComputeAudioEmbeddingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ComputeAudioEmbeddingRequest>(create);
  static ComputeAudioEmbeddingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get audioBytes => $_getN(0);
  @$pb.TagNumber(1)
  set audioBytes($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAudioBytes() => $_has(0);
  @$pb.TagNumber(1)
  void clearAudioBytes() => $_clearField(1);
}

class PingRequest extends $pb.GeneratedMessage {
  factory PingRequest() => create();

  PingRequest._();

  factory PingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PingRequest',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingRequest copyWith(void Function(PingRequest) updates) =>
      super.copyWith((message) => updates(message as PingRequest))
          as PingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PingRequest create() => PingRequest._();
  @$core.override
  PingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PingRequest>(create);
  static PingRequest? _defaultInstance;
}

class PingResponse extends $pb.GeneratedMessage {
  factory PingResponse({
    $core.bool? success,
    $core.String? version,
  }) {
    final result = create();
    if (success != null) result.success = success;
    if (version != null) result.version = version;
    return result;
  }

  PingResponse._();

  factory PingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PingResponse',
      package: const $pb.PackageName(_omitMessageNames
          ? ''
          : 'research.xeno.labs.foresight.launch_agent.proto'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'success')
    ..aOS(2, _omitFieldNames ? '' : 'version')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingResponse copyWith(void Function(PingResponse) updates) =>
      super.copyWith((message) => updates(message as PingResponse))
          as PingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PingResponse create() => PingResponse._();
  @$core.override
  PingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PingResponse>(create);
  static PingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get success => $_getBF(0);
  @$pb.TagNumber(1)
  set success($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSuccess() => $_has(0);
  @$pb.TagNumber(1)
  void clearSuccess() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get version => $_getSZ(1);
  @$pb.TagNumber(2)
  set version($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearVersion() => $_clearField(2);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
