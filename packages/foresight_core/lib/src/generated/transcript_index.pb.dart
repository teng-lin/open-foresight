// This is a generated file - do not edit.
//
// Generated from transcript_index.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'transcript_index.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'transcript_index.pbenum.dart';

class TranscriptKey extends $pb.GeneratedMessage {
  factory TranscriptKey({
    TranscriptKey_Channel? channel,
    $fixnum.Int64? segmentId,
  }) {
    final result = create();
    if (channel != null) result.channel = channel;
    if (segmentId != null) result.segmentId = segmentId;
    return result;
  }

  TranscriptKey._();

  factory TranscriptKey.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranscriptKey.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranscriptKey',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.transcript.v1'),
      createEmptyInstance: create)
    ..aE<TranscriptKey_Channel>(1, _omitFieldNames ? '' : 'channel',
        enumValues: TranscriptKey_Channel.values)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'segmentId', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptKey clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptKey copyWith(void Function(TranscriptKey) updates) =>
      super.copyWith((message) => updates(message as TranscriptKey))
          as TranscriptKey;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranscriptKey create() => TranscriptKey._();
  @$core.override
  TranscriptKey createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranscriptKey getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranscriptKey>(create);
  static TranscriptKey? _defaultInstance;

  @$pb.TagNumber(1)
  TranscriptKey_Channel get channel => $_getN(0);
  @$pb.TagNumber(1)
  set channel(TranscriptKey_Channel value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasChannel() => $_has(0);
  @$pb.TagNumber(1)
  void clearChannel() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get segmentId => $_getI64(1);
  @$pb.TagNumber(2)
  set segmentId($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSegmentId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSegmentId() => $_clearField(2);
}

class TranscriptSegment extends $pb.GeneratedMessage {
  factory TranscriptSegment({
    TranscriptKey? key,
    $core.String? text,
    $fixnum.Int64? startMs,
    $fixnum.Int64? endMs,
  }) {
    final result = create();
    if (key != null) result.key = key;
    if (text != null) result.text = text;
    if (startMs != null) result.startMs = startMs;
    if (endMs != null) result.endMs = endMs;
    return result;
  }

  TranscriptSegment._();

  factory TranscriptSegment.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranscriptSegment.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranscriptSegment',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.transcript.v1'),
      createEmptyInstance: create)
    ..aOM<TranscriptKey>(1, _omitFieldNames ? '' : 'key',
        subBuilder: TranscriptKey.create)
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..a<$fixnum.Int64>(3, _omitFieldNames ? '' : 'startMs', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(4, _omitFieldNames ? '' : 'endMs', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptSegment clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptSegment copyWith(void Function(TranscriptSegment) updates) =>
      super.copyWith((message) => updates(message as TranscriptSegment))
          as TranscriptSegment;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranscriptSegment create() => TranscriptSegment._();
  @$core.override
  TranscriptSegment createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranscriptSegment getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranscriptSegment>(create);
  static TranscriptSegment? _defaultInstance;

  @$pb.TagNumber(1)
  TranscriptKey get key => $_getN(0);
  @$pb.TagNumber(1)
  set key(TranscriptKey value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearKey() => $_clearField(1);
  @$pb.TagNumber(1)
  TranscriptKey ensureKey() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get startMs => $_getI64(2);
  @$pb.TagNumber(3)
  set startMs($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasStartMs() => $_has(2);
  @$pb.TagNumber(3)
  void clearStartMs() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get endMs => $_getI64(3);
  @$pb.TagNumber(4)
  set endMs($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasEndMs() => $_has(3);
  @$pb.TagNumber(4)
  void clearEndMs() => $_clearField(4);
}

class TranscriptCursorRequest extends $pb.GeneratedMessage {
  factory TranscriptCursorRequest({
    $core.String? documentId,
  }) {
    final result = create();
    if (documentId != null) result.documentId = documentId;
    return result;
  }

  TranscriptCursorRequest._();

  factory TranscriptCursorRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranscriptCursorRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranscriptCursorRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.transcript.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'documentId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptCursorRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptCursorRequest copyWith(
          void Function(TranscriptCursorRequest) updates) =>
      super.copyWith((message) => updates(message as TranscriptCursorRequest))
          as TranscriptCursorRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranscriptCursorRequest create() => TranscriptCursorRequest._();
  @$core.override
  TranscriptCursorRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranscriptCursorRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranscriptCursorRequest>(create);
  static TranscriptCursorRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get documentId => $_getSZ(0);
  @$pb.TagNumber(1)
  set documentId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDocumentId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDocumentId() => $_clearField(1);
}

class TranscriptCursor extends $pb.GeneratedMessage {
  factory TranscriptCursor({
    $core.bool? exists,
    $core.String? workspaceEpoch,
    $fixnum.Int64? revision,
    $fixnum.Int64? lastSegmentId,
    $fixnum.Int64? segmentCount,
  }) {
    final result = create();
    if (exists != null) result.exists = exists;
    if (workspaceEpoch != null) result.workspaceEpoch = workspaceEpoch;
    if (revision != null) result.revision = revision;
    if (lastSegmentId != null) result.lastSegmentId = lastSegmentId;
    if (segmentCount != null) result.segmentCount = segmentCount;
    return result;
  }

  TranscriptCursor._();

  factory TranscriptCursor.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranscriptCursor.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranscriptCursor',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.transcript.v1'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'exists')
    ..aOS(2, _omitFieldNames ? '' : 'workspaceEpoch')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'revision', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'lastSegmentId', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'segmentCount', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptCursor clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptCursor copyWith(void Function(TranscriptCursor) updates) =>
      super.copyWith((message) => updates(message as TranscriptCursor))
          as TranscriptCursor;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranscriptCursor create() => TranscriptCursor._();
  @$core.override
  TranscriptCursor createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranscriptCursor getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranscriptCursor>(create);
  static TranscriptCursor? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get exists => $_getBF(0);
  @$pb.TagNumber(1)
  set exists($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExists() => $_has(0);
  @$pb.TagNumber(1)
  void clearExists() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get workspaceEpoch => $_getSZ(1);
  @$pb.TagNumber(2)
  set workspaceEpoch($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasWorkspaceEpoch() => $_has(1);
  @$pb.TagNumber(2)
  void clearWorkspaceEpoch() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get revision => $_getI64(2);
  @$pb.TagNumber(3)
  set revision($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRevision() => $_has(2);
  @$pb.TagNumber(3)
  void clearRevision() => $_clearField(3);

  /// Monotonic committed application transcript row cursor (across channels).
  /// Retained across explicit deletes; reset starts a fresh cursor.
  @$pb.TagNumber(4)
  $fixnum.Int64 get lastSegmentId => $_getI64(3);
  @$pb.TagNumber(4)
  set lastSegmentId($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasLastSegmentId() => $_has(3);
  @$pb.TagNumber(4)
  void clearLastSegmentId() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get segmentCount => $_getI64(4);
  @$pb.TagNumber(5)
  set segmentCount($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasSegmentCount() => $_has(4);
  @$pb.TagNumber(5)
  void clearSegmentCount() => $_clearField(5);
}

class TranscriptDelta extends $pb.GeneratedMessage {
  factory TranscriptDelta({
    $core.String? documentId,
    $core.String? workspaceEpoch,
    $fixnum.Int64? expectedRevision,
    $fixnum.Int64? revision,
    $core.Iterable<TranscriptSegment>? upserts,
    $core.Iterable<TranscriptKey>? deletes,
    $core.bool? reset,
  }) {
    final result = create();
    if (documentId != null) result.documentId = documentId;
    if (workspaceEpoch != null) result.workspaceEpoch = workspaceEpoch;
    if (expectedRevision != null) result.expectedRevision = expectedRevision;
    if (revision != null) result.revision = revision;
    if (upserts != null) result.upserts.addAll(upserts);
    if (deletes != null) result.deletes.addAll(deletes);
    if (reset != null) result.reset = reset;
    return result;
  }

  TranscriptDelta._();

  factory TranscriptDelta.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranscriptDelta.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranscriptDelta',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.transcript.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'documentId')
    ..aOS(2, _omitFieldNames ? '' : 'workspaceEpoch')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'expectedRevision', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'revision', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..pPM<TranscriptSegment>(5, _omitFieldNames ? '' : 'upserts',
        subBuilder: TranscriptSegment.create)
    ..pPM<TranscriptKey>(6, _omitFieldNames ? '' : 'deletes',
        subBuilder: TranscriptKey.create)
    ..aOB(7, _omitFieldNames ? '' : 'reset')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptDelta clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptDelta copyWith(void Function(TranscriptDelta) updates) =>
      super.copyWith((message) => updates(message as TranscriptDelta))
          as TranscriptDelta;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranscriptDelta create() => TranscriptDelta._();
  @$core.override
  TranscriptDelta createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranscriptDelta getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranscriptDelta>(create);
  static TranscriptDelta? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get documentId => $_getSZ(0);
  @$pb.TagNumber(1)
  set documentId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDocumentId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDocumentId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get workspaceEpoch => $_getSZ(1);
  @$pb.TagNumber(2)
  set workspaceEpoch($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasWorkspaceEpoch() => $_has(1);
  @$pb.TagNumber(2)
  void clearWorkspaceEpoch() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get expectedRevision => $_getI64(2);
  @$pb.TagNumber(3)
  set expectedRevision($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasExpectedRevision() => $_has(2);
  @$pb.TagNumber(3)
  void clearExpectedRevision() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get revision => $_getI64(3);
  @$pb.TagNumber(4)
  set revision($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasRevision() => $_has(3);
  @$pb.TagNumber(4)
  void clearRevision() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbList<TranscriptSegment> get upserts => $_getList(4);

  @$pb.TagNumber(6)
  $pb.PbList<TranscriptKey> get deletes => $_getList(5);

  /// Explicit reconciliation starts a fresh index for this parent, atomically.
  @$pb.TagNumber(7)
  $core.bool get reset => $_getBF(6);
  @$pb.TagNumber(7)
  set reset($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasReset() => $_has(6);
  @$pb.TagNumber(7)
  void clearReset() => $_clearField(7);
}

class TranscriptDeltaResult extends $pb.GeneratedMessage {
  factory TranscriptDeltaResult({
    $fixnum.Int64? revision,
    $core.bool? applied,
    $fixnum.Int64? tokenizedBytes,
    $fixnum.Int64? tokenizedTokens,
    $fixnum.Int64? embeddedBytes,
    $fixnum.Int64? embeddedChunks,
    $fixnum.Int64? snapshotConstructedChunks,
  }) {
    final result = create();
    if (revision != null) result.revision = revision;
    if (applied != null) result.applied = applied;
    if (tokenizedBytes != null) result.tokenizedBytes = tokenizedBytes;
    if (tokenizedTokens != null) result.tokenizedTokens = tokenizedTokens;
    if (embeddedBytes != null) result.embeddedBytes = embeddedBytes;
    if (embeddedChunks != null) result.embeddedChunks = embeddedChunks;
    if (snapshotConstructedChunks != null)
      result.snapshotConstructedChunks = snapshotConstructedChunks;
    return result;
  }

  TranscriptDeltaResult._();

  factory TranscriptDeltaResult.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranscriptDeltaResult.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranscriptDeltaResult',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'foresight.transcript.v1'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'revision', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(2, _omitFieldNames ? '' : 'applied')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'tokenizedBytes', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'tokenizedTokens', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'embeddedBytes', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        6, _omitFieldNames ? '' : 'embeddedChunks', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(7, _omitFieldNames ? '' : 'snapshotConstructedChunks',
        $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptDeltaResult clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranscriptDeltaResult copyWith(
          void Function(TranscriptDeltaResult) updates) =>
      super.copyWith((message) => updates(message as TranscriptDeltaResult))
          as TranscriptDeltaResult;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranscriptDeltaResult create() => TranscriptDeltaResult._();
  @$core.override
  TranscriptDeltaResult createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranscriptDeltaResult getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranscriptDeltaResult>(create);
  static TranscriptDeltaResult? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get revision => $_getI64(0);
  @$pb.TagNumber(1)
  set revision($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRevision() => $_has(0);
  @$pb.TagNumber(1)
  void clearRevision() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get applied => $_getBF(1);
  @$pb.TagNumber(2)
  set applied($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasApplied() => $_has(1);
  @$pb.TagNumber(2)
  void clearApplied() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get tokenizedBytes => $_getI64(2);
  @$pb.TagNumber(3)
  set tokenizedBytes($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTokenizedBytes() => $_has(2);
  @$pb.TagNumber(3)
  void clearTokenizedBytes() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get tokenizedTokens => $_getI64(3);
  @$pb.TagNumber(4)
  set tokenizedTokens($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTokenizedTokens() => $_has(3);
  @$pb.TagNumber(4)
  void clearTokenizedTokens() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get embeddedBytes => $_getI64(4);
  @$pb.TagNumber(5)
  set embeddedBytes($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasEmbeddedBytes() => $_has(4);
  @$pb.TagNumber(5)
  void clearEmbeddedBytes() => $_clearField(5);

  @$pb.TagNumber(6)
  $fixnum.Int64 get embeddedChunks => $_getI64(5);
  @$pb.TagNumber(6)
  set embeddedChunks($fixnum.Int64 value) => $_setInt64(5, value);
  @$pb.TagNumber(6)
  $core.bool hasEmbeddedChunks() => $_has(5);
  @$pb.TagNumber(6)
  void clearEmbeddedChunks() => $_clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get snapshotConstructedChunks => $_getI64(6);
  @$pb.TagNumber(7)
  set snapshotConstructedChunks($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasSnapshotConstructedChunks() => $_has(6);
  @$pb.TagNumber(7)
  void clearSnapshotConstructedChunks() => $_clearField(7);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
