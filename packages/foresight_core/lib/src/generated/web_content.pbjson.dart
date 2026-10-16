// This is a generated file - do not edit.
//
// Generated from web_content.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use fetchExternalWebsiteRequestDescriptor instead')
const FetchExternalWebsiteRequest$json = {
  '1': 'FetchExternalWebsiteRequest',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {'1': 'use_trawler', '3': 2, '4': 1, '5': 8, '10': 'useTrawler'},
    {
      '1': 'summarize_content',
      '3': 4,
      '4': 1,
      '5': 8,
      '10': 'summarizeContent'
    },
    {
      '1': 'max_summarization_words',
      '3': 5,
      '4': 1,
      '5': 5,
      '7': '100',
      '10': 'maxSummarizationWords'
    },
    {'1': 'model_id', '3': 6, '4': 1, '5': 9, '10': 'modelId'},
    {
      '1': 'summary_timeout_millis',
      '3': 8,
      '4': 1,
      '5': 5,
      '10': 'summaryTimeoutMillis'
    },
    {'1': 'max_input_tokens', '3': 9, '4': 1, '5': 5, '10': 'maxInputTokens'},
  ],
  '9': [
    {'1': 3, '2': 4},
    {'1': 7, '2': 8},
  ],
};

/// Descriptor for `FetchExternalWebsiteRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fetchExternalWebsiteRequestDescriptor = $convert.base64Decode(
    'ChtGZXRjaEV4dGVybmFsV2Vic2l0ZVJlcXVlc3QSEAoDdXJsGAEgASgJUgN1cmwSHwoLdXNlX3'
    'RyYXdsZXIYAiABKAhSCnVzZVRyYXdsZXISKwoRc3VtbWFyaXplX2NvbnRlbnQYBCABKAhSEHN1'
    'bW1hcml6ZUNvbnRlbnQSOwoXbWF4X3N1bW1hcml6YXRpb25fd29yZHMYBSABKAU6AzEwMFIVbW'
    'F4U3VtbWFyaXphdGlvbldvcmRzEhkKCG1vZGVsX2lkGAYgASgJUgdtb2RlbElkEjQKFnN1bW1h'
    'cnlfdGltZW91dF9taWxsaXMYCCABKAVSFHN1bW1hcnlUaW1lb3V0TWlsbGlzEigKEG1heF9pbn'
    'B1dF90b2tlbnMYCSABKAVSDm1heElucHV0VG9rZW5zSgQIAxAESgQIBxAI');

@$core.Deprecated('Use fetchExternalWebsiteResponseDescriptor instead')
const FetchExternalWebsiteResponse$json = {
  '1': 'FetchExternalWebsiteResponse',
  '2': [
    {'1': 'title', '3': 2, '4': 1, '5': 9, '10': 'title'},
    {'1': 'content', '3': 3, '4': 1, '5': 9, '10': 'content'},
    {'1': 'mime_type', '3': 5, '4': 1, '5': 9, '10': 'mimeType'},
    {'1': 'summary', '3': 7, '4': 1, '5': 9, '10': 'summary'},
    {
      '1': 'summary_confidence_score',
      '3': 8,
      '4': 1,
      '5': 1,
      '10': 'summaryConfidenceScore'
    },
  ],
  '9': [
    {'1': 1, '2': 2},
    {'1': 4, '2': 5},
    {'1': 6, '2': 7},
  ],
};

/// Descriptor for `FetchExternalWebsiteResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fetchExternalWebsiteResponseDescriptor = $convert.base64Decode(
    'ChxGZXRjaEV4dGVybmFsV2Vic2l0ZVJlc3BvbnNlEhQKBXRpdGxlGAIgASgJUgV0aXRsZRIYCg'
    'djb250ZW50GAMgASgJUgdjb250ZW50EhsKCW1pbWVfdHlwZRgFIAEoCVIIbWltZVR5cGUSGAoH'
    'c3VtbWFyeRgHIAEoCVIHc3VtbWFyeRI4ChhzdW1tYXJ5X2NvbmZpZGVuY2Vfc2NvcmUYCCABKA'
    'FSFnN1bW1hcnlDb25maWRlbmNlU2NvcmVKBAgBEAJKBAgEEAVKBAgGEAc=');
