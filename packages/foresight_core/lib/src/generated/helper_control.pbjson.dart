// This is a generated file - do not edit.
//
// Generated from helper_control.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use emptyDescriptor instead')
const Empty$json = {
  '1': 'Empty',
};

/// Descriptor for `Empty`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List emptyDescriptor =
    $convert.base64Decode('CgVFbXB0eQ==');

@$core.Deprecated('Use watchRequestDescriptor instead')
const WatchRequest$json = {
  '1': 'WatchRequest',
  '2': [
    {'1': 'last_revision', '3': 1, '4': 1, '5': 4, '10': 'lastRevision'},
  ],
};

/// Descriptor for `WatchRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List watchRequestDescriptor = $convert.base64Decode(
    'CgxXYXRjaFJlcXVlc3QSIwoNbGFzdF9yZXZpc2lvbhgBIAEoBFIMbGFzdFJldmlzaW9u');

@$core.Deprecated('Use modelIdentityDescriptor instead')
const ModelIdentity$json = {
  '1': 'ModelIdentity',
  '2': [
    {'1': 'model_digest', '3': 1, '4': 1, '5': 9, '10': 'modelDigest'},
    {'1': 'tokenizer_digest', '3': 2, '4': 1, '5': 9, '10': 'tokenizerDigest'},
    {'1': 'preprocessing', '3': 3, '4': 1, '5': 9, '10': 'preprocessing'},
    {'1': 'backend', '3': 4, '4': 1, '5': 9, '10': 'backend'},
    {'1': 'dimensions', '3': 5, '4': 1, '5': 13, '10': 'dimensions'},
    {'1': 'modalities', '3': 6, '4': 3, '5': 9, '10': 'modalities'},
    {'1': 'path', '3': 7, '4': 1, '5': 9, '10': 'path'},
  ],
};

/// Descriptor for `ModelIdentity`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List modelIdentityDescriptor = $convert.base64Decode(
    'Cg1Nb2RlbElkZW50aXR5EiEKDG1vZGVsX2RpZ2VzdBgBIAEoCVILbW9kZWxEaWdlc3QSKQoQdG'
    '9rZW5pemVyX2RpZ2VzdBgCIAEoCVIPdG9rZW5pemVyRGlnZXN0EiQKDXByZXByb2Nlc3NpbmcY'
    'AyABKAlSDXByZXByb2Nlc3NpbmcSGAoHYmFja2VuZBgEIAEoCVIHYmFja2VuZBIeCgpkaW1lbn'
    'Npb25zGAUgASgNUgpkaW1lbnNpb25zEh4KCm1vZGFsaXRpZXMYBiADKAlSCm1vZGFsaXRpZXMS'
    'EgoEcGF0aBgHIAEoCVIEcGF0aA==');

@$core.Deprecated('Use stateDescriptor instead')
const State$json = {
  '1': 'State',
  '2': [
    {'1': 'build_id', '3': 1, '4': 1, '5': 9, '10': 'buildId'},
    {
      '1': 'reference_version',
      '3': 2,
      '4': 1,
      '5': 9,
      '10': 'referenceVersion'
    },
    {'1': 'instance_id', '3': 3, '4': 1, '5': 9, '10': 'instanceId'},
    {'1': 'revision', '3': 4, '4': 1, '5': 4, '10': 'revision'},
    {'1': 'pipeline', '3': 5, '4': 1, '5': 9, '10': 'pipeline'},
    {'1': 'tokenizer_ready', '3': 6, '4': 1, '5': 8, '10': 'tokenizerReady'},
    {
      '1': 'model',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.foresight.linux.control.v1.ModelIdentity',
      '10': 'model'
    },
    {
      '1': 'active_generation',
      '3': 8,
      '4': 1,
      '5': 4,
      '10': 'activeGeneration'
    },
    {
      '1': 'pending_generation',
      '3': 9,
      '4': 1,
      '5': 4,
      '10': 'pendingGeneration'
    },
    {'1': 'index', '3': 10, '4': 1, '5': 9, '10': 'index'},
    {'1': 'attempted', '3': 11, '4': 1, '5': 4, '10': 'attempted'},
    {'1': 'completed', '3': 12, '4': 1, '5': 4, '10': 'completed'},
    {'1': 'failed', '3': 13, '4': 1, '5': 4, '10': 'failed'},
    {'1': 'totals_known', '3': 14, '4': 1, '5': 8, '10': 'totalsKnown'},
    {'1': 'last_error', '3': 15, '4': 1, '5': 9, '10': 'lastError'},
  ],
};

/// Descriptor for `State`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List stateDescriptor = $convert.base64Decode(
    'CgVTdGF0ZRIZCghidWlsZF9pZBgBIAEoCVIHYnVpbGRJZBIrChFyZWZlcmVuY2VfdmVyc2lvbh'
    'gCIAEoCVIQcmVmZXJlbmNlVmVyc2lvbhIfCgtpbnN0YW5jZV9pZBgDIAEoCVIKaW5zdGFuY2VJ'
    'ZBIaCghyZXZpc2lvbhgEIAEoBFIIcmV2aXNpb24SGgoIcGlwZWxpbmUYBSABKAlSCHBpcGVsaW'
    '5lEicKD3Rva2VuaXplcl9yZWFkeRgGIAEoCFIOdG9rZW5pemVyUmVhZHkSPwoFbW9kZWwYByAB'
    'KAsyKS5mb3Jlc2lnaHQubGludXguY29udHJvbC52MS5Nb2RlbElkZW50aXR5UgVtb2RlbBIrCh'
    'FhY3RpdmVfZ2VuZXJhdGlvbhgIIAEoBFIQYWN0aXZlR2VuZXJhdGlvbhItChJwZW5kaW5nX2dl'
    'bmVyYXRpb24YCSABKARSEXBlbmRpbmdHZW5lcmF0aW9uEhQKBWluZGV4GAogASgJUgVpbmRleB'
    'IcCglhdHRlbXB0ZWQYCyABKARSCWF0dGVtcHRlZBIcCgljb21wbGV0ZWQYDCABKARSCWNvbXBs'
    'ZXRlZBIWCgZmYWlsZWQYDSABKARSBmZhaWxlZBIhCgx0b3RhbHNfa25vd24YDiABKAhSC3RvdG'
    'Fsc0tub3duEh0KCmxhc3RfZXJyb3IYDyABKAlSCWxhc3RFcnJvcg==');
