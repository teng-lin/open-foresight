// This is a generated file - do not edit.
//
// Generated from web_content.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class FetchExternalWebsiteRequest extends $pb.GeneratedMessage {
  factory FetchExternalWebsiteRequest({
    $core.String? url,
    $core.bool? useTrawler,
    $core.bool? summarizeContent,
    $core.int? maxSummarizationWords,
    $core.String? modelId,
    $core.int? summaryTimeoutMillis,
    $core.int? maxInputTokens,
  }) {
    final result = create();
    if (url != null) result.url = url;
    if (useTrawler != null) result.useTrawler = useTrawler;
    if (summarizeContent != null) result.summarizeContent = summarizeContent;
    if (maxSummarizationWords != null)
      result.maxSummarizationWords = maxSummarizationWords;
    if (modelId != null) result.modelId = modelId;
    if (summaryTimeoutMillis != null)
      result.summaryTimeoutMillis = summaryTimeoutMillis;
    if (maxInputTokens != null) result.maxInputTokens = maxInputTokens;
    return result;
  }

  FetchExternalWebsiteRequest._();

  factory FetchExternalWebsiteRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FetchExternalWebsiteRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FetchExternalWebsiteRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'ai_edge.foresight.service'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'url')
    ..aOB(2, _omitFieldNames ? '' : 'useTrawler')
    ..aOB(4, _omitFieldNames ? '' : 'summarizeContent')
    ..aI(5, _omitFieldNames ? '' : 'maxSummarizationWords', defaultOrMaker: 100)
    ..aOS(6, _omitFieldNames ? '' : 'modelId')
    ..aI(8, _omitFieldNames ? '' : 'summaryTimeoutMillis')
    ..aI(9, _omitFieldNames ? '' : 'maxInputTokens')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FetchExternalWebsiteRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FetchExternalWebsiteRequest copyWith(
          void Function(FetchExternalWebsiteRequest) updates) =>
      super.copyWith(
              (message) => updates(message as FetchExternalWebsiteRequest))
          as FetchExternalWebsiteRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FetchExternalWebsiteRequest create() =>
      FetchExternalWebsiteRequest._();
  @$core.override
  FetchExternalWebsiteRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FetchExternalWebsiteRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FetchExternalWebsiteRequest>(create);
  static FetchExternalWebsiteRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get useTrawler => $_getBF(1);
  @$pb.TagNumber(2)
  set useTrawler($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUseTrawler() => $_has(1);
  @$pb.TagNumber(2)
  void clearUseTrawler() => $_clearField(2);

  @$pb.TagNumber(4)
  $core.bool get summarizeContent => $_getBF(2);
  @$pb.TagNumber(4)
  set summarizeContent($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(4)
  $core.bool hasSummarizeContent() => $_has(2);
  @$pb.TagNumber(4)
  void clearSummarizeContent() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get maxSummarizationWords => $_getI(3, 100);
  @$pb.TagNumber(5)
  set maxSummarizationWords($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(5)
  $core.bool hasMaxSummarizationWords() => $_has(3);
  @$pb.TagNumber(5)
  void clearMaxSummarizationWords() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get modelId => $_getSZ(4);
  @$pb.TagNumber(6)
  set modelId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(6)
  $core.bool hasModelId() => $_has(4);
  @$pb.TagNumber(6)
  void clearModelId() => $_clearField(6);

  @$pb.TagNumber(8)
  $core.int get summaryTimeoutMillis => $_getIZ(5);
  @$pb.TagNumber(8)
  set summaryTimeoutMillis($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(8)
  $core.bool hasSummaryTimeoutMillis() => $_has(5);
  @$pb.TagNumber(8)
  void clearSummaryTimeoutMillis() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.int get maxInputTokens => $_getIZ(6);
  @$pb.TagNumber(9)
  set maxInputTokens($core.int value) => $_setSignedInt32(6, value);
  @$pb.TagNumber(9)
  $core.bool hasMaxInputTokens() => $_has(6);
  @$pb.TagNumber(9)
  void clearMaxInputTokens() => $_clearField(9);
}

class FetchExternalWebsiteResponse extends $pb.GeneratedMessage {
  factory FetchExternalWebsiteResponse({
    $core.String? title,
    $core.String? content,
    $core.String? mimeType,
    $core.String? summary,
    $core.double? summaryConfidenceScore,
  }) {
    final result = create();
    if (title != null) result.title = title;
    if (content != null) result.content = content;
    if (mimeType != null) result.mimeType = mimeType;
    if (summary != null) result.summary = summary;
    if (summaryConfidenceScore != null)
      result.summaryConfidenceScore = summaryConfidenceScore;
    return result;
  }

  FetchExternalWebsiteResponse._();

  factory FetchExternalWebsiteResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FetchExternalWebsiteResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FetchExternalWebsiteResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'ai_edge.foresight.service'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'title')
    ..aOS(3, _omitFieldNames ? '' : 'content')
    ..aOS(5, _omitFieldNames ? '' : 'mimeType')
    ..aOS(7, _omitFieldNames ? '' : 'summary')
    ..aD(8, _omitFieldNames ? '' : 'summaryConfidenceScore')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FetchExternalWebsiteResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FetchExternalWebsiteResponse copyWith(
          void Function(FetchExternalWebsiteResponse) updates) =>
      super.copyWith(
              (message) => updates(message as FetchExternalWebsiteResponse))
          as FetchExternalWebsiteResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FetchExternalWebsiteResponse create() =>
      FetchExternalWebsiteResponse._();
  @$core.override
  FetchExternalWebsiteResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FetchExternalWebsiteResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FetchExternalWebsiteResponse>(create);
  static FetchExternalWebsiteResponse? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get title => $_getSZ(0);
  @$pb.TagNumber(2)
  set title($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasTitle() => $_has(0);
  @$pb.TagNumber(2)
  void clearTitle() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get content => $_getSZ(1);
  @$pb.TagNumber(3)
  set content($core.String value) => $_setString(1, value);
  @$pb.TagNumber(3)
  $core.bool hasContent() => $_has(1);
  @$pb.TagNumber(3)
  void clearContent() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.String get mimeType => $_getSZ(2);
  @$pb.TagNumber(5)
  set mimeType($core.String value) => $_setString(2, value);
  @$pb.TagNumber(5)
  $core.bool hasMimeType() => $_has(2);
  @$pb.TagNumber(5)
  void clearMimeType() => $_clearField(5);

  @$pb.TagNumber(7)
  $core.String get summary => $_getSZ(3);
  @$pb.TagNumber(7)
  set summary($core.String value) => $_setString(3, value);
  @$pb.TagNumber(7)
  $core.bool hasSummary() => $_has(3);
  @$pb.TagNumber(7)
  void clearSummary() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.double get summaryConfidenceScore => $_getN(4);
  @$pb.TagNumber(8)
  set summaryConfidenceScore($core.double value) => $_setDouble(4, value);
  @$pb.TagNumber(8)
  $core.bool hasSummaryConfidenceScore() => $_has(4);
  @$pb.TagNumber(8)
  void clearSummaryConfidenceScore() => $_clearField(8);
}

class GetSharedConfigRequest extends $pb.GeneratedMessage {
  factory GetSharedConfigRequest({
    $core.String? appVersion,
    $core.String? platform,
    $core.int? fallbackMode,
  }) {
    final result = create();
    if (appVersion != null) result.appVersion = appVersion;
    if (platform != null) result.platform = platform;
    if (fallbackMode != null) result.fallbackMode = fallbackMode;
    return result;
  }

  GetSharedConfigRequest._();

  factory GetSharedConfigRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetSharedConfigRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetSharedConfigRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'ai_edge.foresight.service'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'appVersion')
    ..aOS(2, _omitFieldNames ? '' : 'platform')
    ..aI(3, _omitFieldNames ? '' : 'fallbackMode')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetSharedConfigRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetSharedConfigRequest copyWith(
          void Function(GetSharedConfigRequest) updates) =>
      super.copyWith((message) => updates(message as GetSharedConfigRequest))
          as GetSharedConfigRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetSharedConfigRequest create() => GetSharedConfigRequest._();
  @$core.override
  GetSharedConfigRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetSharedConfigRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetSharedConfigRequest>(create);
  static GetSharedConfigRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get appVersion => $_getSZ(0);
  @$pb.TagNumber(1)
  set appVersion($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAppVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearAppVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get platform => $_getSZ(1);
  @$pb.TagNumber(2)
  set platform($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPlatform() => $_has(1);
  @$pb.TagNumber(2)
  void clearPlatform() => $_clearField(2);

  /// Enum wire value 1 is FALLBACK_CLOSEST_LOWER. Other names are not recovered.
  @$pb.TagNumber(3)
  $core.int get fallbackMode => $_getIZ(2);
  @$pb.TagNumber(3)
  set fallbackMode($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasFallbackMode() => $_has(2);
  @$pb.TagNumber(3)
  void clearFallbackMode() => $_clearField(3);
}

class OnDeviceModelMetadata extends $pb.GeneratedMessage {
  factory OnDeviceModelMetadata({
    $core.int? modelType,
    $core.String? name,
    $core.String? version,
    $core.String? blobId,
    $fixnum.Int64? size,
  }) {
    final result = create();
    if (modelType != null) result.modelType = modelType;
    if (name != null) result.name = name;
    if (version != null) result.version = version;
    if (blobId != null) result.blobId = blobId;
    if (size != null) result.size = size;
    return result;
  }

  OnDeviceModelMetadata._();

  factory OnDeviceModelMetadata.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory OnDeviceModelMetadata.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OnDeviceModelMetadata',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'ai_edge.foresight.service'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'modelType')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'version')
    ..aOS(6, _omitFieldNames ? '' : 'blobId')
    ..aInt64(8, _omitFieldNames ? '' : 'size')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OnDeviceModelMetadata clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OnDeviceModelMetadata copyWith(
          void Function(OnDeviceModelMetadata) updates) =>
      super.copyWith((message) => updates(message as OnDeviceModelMetadata))
          as OnDeviceModelMetadata;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static OnDeviceModelMetadata create() => OnDeviceModelMetadata._();
  @$core.override
  OnDeviceModelMetadata createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static OnDeviceModelMetadata getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OnDeviceModelMetadata>(create);
  static OnDeviceModelMetadata? _defaultInstance;

  /// Enum wire value 4 is MODEL_TYPE_QUERY_DETECTOR. Preserve unknown variants.
  @$pb.TagNumber(1)
  $core.int get modelType => $_getIZ(0);
  @$pb.TagNumber(1)
  set modelType($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasModelType() => $_has(0);
  @$pb.TagNumber(1)
  void clearModelType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get version => $_getSZ(2);
  @$pb.TagNumber(3)
  set version($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearVersion() => $_clearField(3);

  @$pb.TagNumber(6)
  $core.String get blobId => $_getSZ(3);
  @$pb.TagNumber(6)
  set blobId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(6)
  $core.bool hasBlobId() => $_has(3);
  @$pb.TagNumber(6)
  void clearBlobId() => $_clearField(6);

  @$pb.TagNumber(8)
  $fixnum.Int64 get size => $_getI64(4);
  @$pb.TagNumber(8)
  set size($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(8)
  $core.bool hasSize() => $_has(4);
  @$pb.TagNumber(8)
  void clearSize() => $_clearField(8);
}

class ForesightSharedConfig extends $pb.GeneratedMessage {
  factory ForesightSharedConfig({
    $core.Iterable<OnDeviceModelMetadata>? onDeviceModelMetadatas,
  }) {
    final result = create();
    if (onDeviceModelMetadatas != null)
      result.onDeviceModelMetadatas.addAll(onDeviceModelMetadatas);
    return result;
  }

  ForesightSharedConfig._();

  factory ForesightSharedConfig.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ForesightSharedConfig.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ForesightSharedConfig',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'ai_edge.foresight.service'),
      createEmptyInstance: create)
    ..pPM<OnDeviceModelMetadata>(
        1, _omitFieldNames ? '' : 'onDeviceModelMetadatas',
        subBuilder: OnDeviceModelMetadata.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ForesightSharedConfig clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ForesightSharedConfig copyWith(
          void Function(ForesightSharedConfig) updates) =>
      super.copyWith((message) => updates(message as ForesightSharedConfig))
          as ForesightSharedConfig;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ForesightSharedConfig create() => ForesightSharedConfig._();
  @$core.override
  ForesightSharedConfig createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ForesightSharedConfig getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ForesightSharedConfig>(create);
  static ForesightSharedConfig? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<OnDeviceModelMetadata> get onDeviceModelMetadatas => $_getList(0);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
