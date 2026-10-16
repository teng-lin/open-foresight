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
    ..a<$core.int>(
        5, _omitFieldNames ? '' : 'maxSummarizationWords', $pb.PbFieldType.O3,
        defaultOrMaker: 100)
    ..aOS(6, _omitFieldNames ? '' : 'modelId')
    ..a<$core.int>(
        8, _omitFieldNames ? '' : 'summaryTimeoutMillis', $pb.PbFieldType.O3)
    ..a<$core.int>(
        9, _omitFieldNames ? '' : 'maxInputTokens', $pb.PbFieldType.O3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FetchExternalWebsiteRequest clone() =>
      FetchExternalWebsiteRequest()..mergeFromMessage(this);
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
  static $pb.PbList<FetchExternalWebsiteRequest> createRepeated() =>
      $pb.PbList<FetchExternalWebsiteRequest>();
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
    ..a<$core.double>(
        8, _omitFieldNames ? '' : 'summaryConfidenceScore', $pb.PbFieldType.OD)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FetchExternalWebsiteResponse clone() =>
      FetchExternalWebsiteResponse()..mergeFromMessage(this);
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
  static $pb.PbList<FetchExternalWebsiteResponse> createRepeated() =>
      $pb.PbList<FetchExternalWebsiteResponse>();
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

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
