// This is a generated file - do not edit.
//
// Generated from transcript_index.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use transcriptKeyDescriptor instead')
const TranscriptKey$json = {
  '1': 'TranscriptKey',
  '2': [
    {
      '1': 'channel',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.foresight.transcript.v1.TranscriptKey.Channel',
      '10': 'channel'
    },
    {'1': 'segment_id', '3': 2, '4': 1, '5': 4, '10': 'segmentId'},
  ],
  '4': [TranscriptKey_Channel$json],
};

@$core.Deprecated('Use transcriptKeyDescriptor instead')
const TranscriptKey_Channel$json = {
  '1': 'Channel',
  '2': [
    {'1': 'MICROPHONE', '2': 0},
    {'1': 'PLAYBACK', '2': 1},
    {'1': 'IMPORTED', '2': 2},
  ],
};

/// Descriptor for `TranscriptKey`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List transcriptKeyDescriptor = $convert.base64Decode(
    'Cg1UcmFuc2NyaXB0S2V5EkgKB2NoYW5uZWwYASABKA4yLi5mb3Jlc2lnaHQudHJhbnNjcmlwdC'
    '52MS5UcmFuc2NyaXB0S2V5LkNoYW5uZWxSB2NoYW5uZWwSHQoKc2VnbWVudF9pZBgCIAEoBFIJ'
    'c2VnbWVudElkIjUKB0NoYW5uZWwSDgoKTUlDUk9QSE9ORRAAEgwKCFBMQVlCQUNLEAESDAoISU'
    '1QT1JURUQQAg==');

@$core.Deprecated('Use transcriptSegmentDescriptor instead')
const TranscriptSegment$json = {
  '1': 'TranscriptSegment',
  '2': [
    {
      '1': 'key',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.foresight.transcript.v1.TranscriptKey',
      '10': 'key'
    },
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
    {'1': 'start_ms', '3': 3, '4': 1, '5': 4, '10': 'startMs'},
    {'1': 'end_ms', '3': 4, '4': 1, '5': 4, '10': 'endMs'},
  ],
};

/// Descriptor for `TranscriptSegment`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List transcriptSegmentDescriptor = $convert.base64Decode(
    'ChFUcmFuc2NyaXB0U2VnbWVudBI4CgNrZXkYASABKAsyJi5mb3Jlc2lnaHQudHJhbnNjcmlwdC'
    '52MS5UcmFuc2NyaXB0S2V5UgNrZXkSEgoEdGV4dBgCIAEoCVIEdGV4dBIZCghzdGFydF9tcxgD'
    'IAEoBFIHc3RhcnRNcxIVCgZlbmRfbXMYBCABKARSBWVuZE1z');

@$core.Deprecated('Use transcriptCursorRequestDescriptor instead')
const TranscriptCursorRequest$json = {
  '1': 'TranscriptCursorRequest',
  '2': [
    {'1': 'document_id', '3': 1, '4': 1, '5': 9, '10': 'documentId'},
  ],
};

/// Descriptor for `TranscriptCursorRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List transcriptCursorRequestDescriptor =
    $convert.base64Decode(
        'ChdUcmFuc2NyaXB0Q3Vyc29yUmVxdWVzdBIfCgtkb2N1bWVudF9pZBgBIAEoCVIKZG9jdW1lbn'
        'RJZA==');

@$core.Deprecated('Use transcriptCursorDescriptor instead')
const TranscriptCursor$json = {
  '1': 'TranscriptCursor',
  '2': [
    {'1': 'exists', '3': 1, '4': 1, '5': 8, '10': 'exists'},
    {'1': 'workspace_epoch', '3': 2, '4': 1, '5': 9, '10': 'workspaceEpoch'},
    {'1': 'revision', '3': 3, '4': 1, '5': 4, '10': 'revision'},
    {'1': 'last_segment_id', '3': 4, '4': 1, '5': 4, '10': 'lastSegmentId'},
    {'1': 'segment_count', '3': 5, '4': 1, '5': 4, '10': 'segmentCount'},
  ],
};

/// Descriptor for `TranscriptCursor`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List transcriptCursorDescriptor = $convert.base64Decode(
    'ChBUcmFuc2NyaXB0Q3Vyc29yEhYKBmV4aXN0cxgBIAEoCFIGZXhpc3RzEicKD3dvcmtzcGFjZV'
    '9lcG9jaBgCIAEoCVIOd29ya3NwYWNlRXBvY2gSGgoIcmV2aXNpb24YAyABKARSCHJldmlzaW9u'
    'EiYKD2xhc3Rfc2VnbWVudF9pZBgEIAEoBFINbGFzdFNlZ21lbnRJZBIjCg1zZWdtZW50X2NvdW'
    '50GAUgASgEUgxzZWdtZW50Q291bnQ=');

@$core.Deprecated('Use transcriptDeltaDescriptor instead')
const TranscriptDelta$json = {
  '1': 'TranscriptDelta',
  '2': [
    {'1': 'document_id', '3': 1, '4': 1, '5': 9, '10': 'documentId'},
    {'1': 'workspace_epoch', '3': 2, '4': 1, '5': 9, '10': 'workspaceEpoch'},
    {
      '1': 'expected_revision',
      '3': 3,
      '4': 1,
      '5': 4,
      '10': 'expectedRevision'
    },
    {'1': 'revision', '3': 4, '4': 1, '5': 4, '10': 'revision'},
    {
      '1': 'upserts',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.foresight.transcript.v1.TranscriptSegment',
      '10': 'upserts'
    },
    {
      '1': 'deletes',
      '3': 6,
      '4': 3,
      '5': 11,
      '6': '.foresight.transcript.v1.TranscriptKey',
      '10': 'deletes'
    },
    {'1': 'reset', '3': 7, '4': 1, '5': 8, '10': 'reset'},
  ],
};

/// Descriptor for `TranscriptDelta`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List transcriptDeltaDescriptor = $convert.base64Decode(
    'Cg9UcmFuc2NyaXB0RGVsdGESHwoLZG9jdW1lbnRfaWQYASABKAlSCmRvY3VtZW50SWQSJwoPd2'
    '9ya3NwYWNlX2Vwb2NoGAIgASgJUg53b3Jrc3BhY2VFcG9jaBIrChFleHBlY3RlZF9yZXZpc2lv'
    'bhgDIAEoBFIQZXhwZWN0ZWRSZXZpc2lvbhIaCghyZXZpc2lvbhgEIAEoBFIIcmV2aXNpb24SRA'
    'oHdXBzZXJ0cxgFIAMoCzIqLmZvcmVzaWdodC50cmFuc2NyaXB0LnYxLlRyYW5zY3JpcHRTZWdt'
    'ZW50Ugd1cHNlcnRzEkAKB2RlbGV0ZXMYBiADKAsyJi5mb3Jlc2lnaHQudHJhbnNjcmlwdC52MS'
    '5UcmFuc2NyaXB0S2V5UgdkZWxldGVzEhQKBXJlc2V0GAcgASgIUgVyZXNldA==');

@$core.Deprecated('Use transcriptDeltaResultDescriptor instead')
const TranscriptDeltaResult$json = {
  '1': 'TranscriptDeltaResult',
  '2': [
    {'1': 'revision', '3': 1, '4': 1, '5': 4, '10': 'revision'},
    {'1': 'applied', '3': 2, '4': 1, '5': 8, '10': 'applied'},
    {'1': 'tokenized_bytes', '3': 3, '4': 1, '5': 4, '10': 'tokenizedBytes'},
    {'1': 'tokenized_tokens', '3': 4, '4': 1, '5': 4, '10': 'tokenizedTokens'},
    {'1': 'embedded_bytes', '3': 5, '4': 1, '5': 4, '10': 'embeddedBytes'},
    {'1': 'embedded_chunks', '3': 6, '4': 1, '5': 4, '10': 'embeddedChunks'},
    {
      '1': 'snapshot_constructed_chunks',
      '3': 7,
      '4': 1,
      '5': 4,
      '10': 'snapshotConstructedChunks'
    },
  ],
};

/// Descriptor for `TranscriptDeltaResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List transcriptDeltaResultDescriptor = $convert.base64Decode(
    'ChVUcmFuc2NyaXB0RGVsdGFSZXN1bHQSGgoIcmV2aXNpb24YASABKARSCHJldmlzaW9uEhgKB2'
    'FwcGxpZWQYAiABKAhSB2FwcGxpZWQSJwoPdG9rZW5pemVkX2J5dGVzGAMgASgEUg50b2tlbml6'
    'ZWRCeXRlcxIpChB0b2tlbml6ZWRfdG9rZW5zGAQgASgEUg90b2tlbml6ZWRUb2tlbnMSJQoOZW'
    '1iZWRkZWRfYnl0ZXMYBSABKARSDWVtYmVkZGVkQnl0ZXMSJwoPZW1iZWRkZWRfY2h1bmtzGAYg'
    'ASgEUg5lbWJlZGRlZENodW5rcxI+ChtzbmFwc2hvdF9jb25zdHJ1Y3RlZF9jaHVua3MYByABKA'
    'RSGXNuYXBzaG90Q29uc3RydWN0ZWRDaHVua3M=');
