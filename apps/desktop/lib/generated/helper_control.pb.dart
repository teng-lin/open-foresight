// This is a generated file - do not edit.
//
// Generated from helper_control.proto.

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

class Empty extends $pb.GeneratedMessage {
  factory Empty() => create();

  Empty._();

  factory Empty.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Empty.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Empty',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.linux.control.v1'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Empty clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Empty copyWith(void Function(Empty) updates) =>
      super.copyWith((message) => updates(message as Empty)) as Empty;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Empty create() => Empty._();
  @$core.override
  Empty createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Empty getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Empty>(create);
  static Empty? _defaultInstance;
}

class WatchRequest extends $pb.GeneratedMessage {
  factory WatchRequest({
    $fixnum.Int64? lastRevision,
  }) {
    final result = create();
    if (lastRevision != null) result.lastRevision = lastRevision;
    return result;
  }

  WatchRequest._();

  factory WatchRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory WatchRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'WatchRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.linux.control.v1'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'lastRevision', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WatchRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WatchRequest copyWith(void Function(WatchRequest) updates) =>
      super.copyWith((message) => updates(message as WatchRequest))
          as WatchRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static WatchRequest create() => WatchRequest._();
  @$core.override
  WatchRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static WatchRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<WatchRequest>(create);
  static WatchRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get lastRevision => $_getI64(0);
  @$pb.TagNumber(1)
  set lastRevision($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLastRevision() => $_has(0);
  @$pb.TagNumber(1)
  void clearLastRevision() => $_clearField(1);
}

class ModelIdentity extends $pb.GeneratedMessage {
  factory ModelIdentity({
    $core.String? modelDigest,
    $core.String? tokenizerDigest,
    $core.String? preprocessing,
    $core.String? backend,
    $core.int? dimensions,
    $core.Iterable<$core.String>? modalities,
    $core.String? path,
  }) {
    final result = create();
    if (modelDigest != null) result.modelDigest = modelDigest;
    if (tokenizerDigest != null) result.tokenizerDigest = tokenizerDigest;
    if (preprocessing != null) result.preprocessing = preprocessing;
    if (backend != null) result.backend = backend;
    if (dimensions != null) result.dimensions = dimensions;
    if (modalities != null) result.modalities.addAll(modalities);
    if (path != null) result.path = path;
    return result;
  }

  ModelIdentity._();

  factory ModelIdentity.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ModelIdentity.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ModelIdentity',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.linux.control.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'modelDigest')
    ..aOS(2, _omitFieldNames ? '' : 'tokenizerDigest')
    ..aOS(3, _omitFieldNames ? '' : 'preprocessing')
    ..aOS(4, _omitFieldNames ? '' : 'backend')
    ..aI(5, _omitFieldNames ? '' : 'dimensions', fieldType: $pb.PbFieldType.OU3)
    ..pPS(6, _omitFieldNames ? '' : 'modalities')
    ..aOS(7, _omitFieldNames ? '' : 'path')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModelIdentity clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModelIdentity copyWith(void Function(ModelIdentity) updates) =>
      super.copyWith((message) => updates(message as ModelIdentity))
          as ModelIdentity;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ModelIdentity create() => ModelIdentity._();
  @$core.override
  ModelIdentity createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ModelIdentity getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ModelIdentity>(create);
  static ModelIdentity? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get modelDigest => $_getSZ(0);
  @$pb.TagNumber(1)
  set modelDigest($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasModelDigest() => $_has(0);
  @$pb.TagNumber(1)
  void clearModelDigest() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get tokenizerDigest => $_getSZ(1);
  @$pb.TagNumber(2)
  set tokenizerDigest($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTokenizerDigest() => $_has(1);
  @$pb.TagNumber(2)
  void clearTokenizerDigest() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get preprocessing => $_getSZ(2);
  @$pb.TagNumber(3)
  set preprocessing($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPreprocessing() => $_has(2);
  @$pb.TagNumber(3)
  void clearPreprocessing() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get backend => $_getSZ(3);
  @$pb.TagNumber(4)
  set backend($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasBackend() => $_has(3);
  @$pb.TagNumber(4)
  void clearBackend() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get dimensions => $_getIZ(4);
  @$pb.TagNumber(5)
  set dimensions($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasDimensions() => $_has(4);
  @$pb.TagNumber(5)
  void clearDimensions() => $_clearField(5);

  @$pb.TagNumber(6)
  $pb.PbList<$core.String> get modalities => $_getList(5);

  @$pb.TagNumber(7)
  $core.String get path => $_getSZ(6);
  @$pb.TagNumber(7)
  set path($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasPath() => $_has(6);
  @$pb.TagNumber(7)
  void clearPath() => $_clearField(7);
}

class State extends $pb.GeneratedMessage {
  factory State({
    $core.String? buildId,
    $core.String? referenceVersion,
    $core.String? instanceId,
    $fixnum.Int64? revision,
    $core.String? pipeline,
    $core.bool? tokenizerReady,
    ModelIdentity? model,
    $fixnum.Int64? activeGeneration,
    $fixnum.Int64? pendingGeneration,
    $core.String? index,
    $fixnum.Int64? attempted,
    $fixnum.Int64? completed,
    $fixnum.Int64? failed,
    $core.bool? totalsKnown,
    $core.String? lastError,
  }) {
    final result = create();
    if (buildId != null) result.buildId = buildId;
    if (referenceVersion != null) result.referenceVersion = referenceVersion;
    if (instanceId != null) result.instanceId = instanceId;
    if (revision != null) result.revision = revision;
    if (pipeline != null) result.pipeline = pipeline;
    if (tokenizerReady != null) result.tokenizerReady = tokenizerReady;
    if (model != null) result.model = model;
    if (activeGeneration != null) result.activeGeneration = activeGeneration;
    if (pendingGeneration != null) result.pendingGeneration = pendingGeneration;
    if (index != null) result.index = index;
    if (attempted != null) result.attempted = attempted;
    if (completed != null) result.completed = completed;
    if (failed != null) result.failed = failed;
    if (totalsKnown != null) result.totalsKnown = totalsKnown;
    if (lastError != null) result.lastError = lastError;
    return result;
  }

  State._();

  factory State.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory State.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'State',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.linux.control.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'buildId')
    ..aOS(2, _omitFieldNames ? '' : 'referenceVersion')
    ..aOS(3, _omitFieldNames ? '' : 'instanceId')
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'revision', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(5, _omitFieldNames ? '' : 'pipeline')
    ..aOB(6, _omitFieldNames ? '' : 'tokenizerReady')
    ..aOM<ModelIdentity>(7, _omitFieldNames ? '' : 'model',
        subBuilder: ModelIdentity.create)
    ..a<$fixnum.Int64>(
        8, _omitFieldNames ? '' : 'activeGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        9, _omitFieldNames ? '' : 'pendingGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(10, _omitFieldNames ? '' : 'index')
    ..a<$fixnum.Int64>(
        11, _omitFieldNames ? '' : 'attempted', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        12, _omitFieldNames ? '' : 'completed', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(13, _omitFieldNames ? '' : 'failed', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(14, _omitFieldNames ? '' : 'totalsKnown')
    ..aOS(15, _omitFieldNames ? '' : 'lastError')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  State clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  State copyWith(void Function(State) updates) =>
      super.copyWith((message) => updates(message as State)) as State;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static State create() => State._();
  @$core.override
  State createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static State getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<State>(create);
  static State? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get buildId => $_getSZ(0);
  @$pb.TagNumber(1)
  set buildId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBuildId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBuildId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get referenceVersion => $_getSZ(1);
  @$pb.TagNumber(2)
  set referenceVersion($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasReferenceVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearReferenceVersion() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get instanceId => $_getSZ(2);
  @$pb.TagNumber(3)
  set instanceId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasInstanceId() => $_has(2);
  @$pb.TagNumber(3)
  void clearInstanceId() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get revision => $_getI64(3);
  @$pb.TagNumber(4)
  set revision($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasRevision() => $_has(3);
  @$pb.TagNumber(4)
  void clearRevision() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get pipeline => $_getSZ(4);
  @$pb.TagNumber(5)
  set pipeline($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPipeline() => $_has(4);
  @$pb.TagNumber(5)
  void clearPipeline() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get tokenizerReady => $_getBF(5);
  @$pb.TagNumber(6)
  set tokenizerReady($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasTokenizerReady() => $_has(5);
  @$pb.TagNumber(6)
  void clearTokenizerReady() => $_clearField(6);

  @$pb.TagNumber(7)
  ModelIdentity get model => $_getN(6);
  @$pb.TagNumber(7)
  set model(ModelIdentity value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasModel() => $_has(6);
  @$pb.TagNumber(7)
  void clearModel() => $_clearField(7);
  @$pb.TagNumber(7)
  ModelIdentity ensureModel() => $_ensure(6);

  @$pb.TagNumber(8)
  $fixnum.Int64 get activeGeneration => $_getI64(7);
  @$pb.TagNumber(8)
  set activeGeneration($fixnum.Int64 value) => $_setInt64(7, value);
  @$pb.TagNumber(8)
  $core.bool hasActiveGeneration() => $_has(7);
  @$pb.TagNumber(8)
  void clearActiveGeneration() => $_clearField(8);

  @$pb.TagNumber(9)
  $fixnum.Int64 get pendingGeneration => $_getI64(8);
  @$pb.TagNumber(9)
  set pendingGeneration($fixnum.Int64 value) => $_setInt64(8, value);
  @$pb.TagNumber(9)
  $core.bool hasPendingGeneration() => $_has(8);
  @$pb.TagNumber(9)
  void clearPendingGeneration() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.String get index => $_getSZ(9);
  @$pb.TagNumber(10)
  set index($core.String value) => $_setString(9, value);
  @$pb.TagNumber(10)
  $core.bool hasIndex() => $_has(9);
  @$pb.TagNumber(10)
  void clearIndex() => $_clearField(10);

  @$pb.TagNumber(11)
  $fixnum.Int64 get attempted => $_getI64(10);
  @$pb.TagNumber(11)
  set attempted($fixnum.Int64 value) => $_setInt64(10, value);
  @$pb.TagNumber(11)
  $core.bool hasAttempted() => $_has(10);
  @$pb.TagNumber(11)
  void clearAttempted() => $_clearField(11);

  @$pb.TagNumber(12)
  $fixnum.Int64 get completed => $_getI64(11);
  @$pb.TagNumber(12)
  set completed($fixnum.Int64 value) => $_setInt64(11, value);
  @$pb.TagNumber(12)
  $core.bool hasCompleted() => $_has(11);
  @$pb.TagNumber(12)
  void clearCompleted() => $_clearField(12);

  @$pb.TagNumber(13)
  $fixnum.Int64 get failed => $_getI64(12);
  @$pb.TagNumber(13)
  set failed($fixnum.Int64 value) => $_setInt64(12, value);
  @$pb.TagNumber(13)
  $core.bool hasFailed() => $_has(12);
  @$pb.TagNumber(13)
  void clearFailed() => $_clearField(13);

  @$pb.TagNumber(14)
  $core.bool get totalsKnown => $_getBF(13);
  @$pb.TagNumber(14)
  set totalsKnown($core.bool value) => $_setBool(13, value);
  @$pb.TagNumber(14)
  $core.bool hasTotalsKnown() => $_has(13);
  @$pb.TagNumber(14)
  void clearTotalsKnown() => $_clearField(14);

  @$pb.TagNumber(15)
  $core.String get lastError => $_getSZ(14);
  @$pb.TagNumber(15)
  set lastError($core.String value) => $_setString(14, value);
  @$pb.TagNumber(15)
  $core.bool hasLastError() => $_has(14);
  @$pb.TagNumber(15)
  void clearLastError() => $_clearField(15);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
