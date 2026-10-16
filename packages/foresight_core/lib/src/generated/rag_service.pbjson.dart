// This is a generated file - do not edit.
//
// Generated from rag_service.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use indexRequestDescriptor instead')
const IndexRequest$json = {
  '1': 'IndexRequest',
  '2': [
    {'1': 'document_id', '3': 1, '4': 1, '5': 9, '10': 'documentId'},
    {'1': 'content', '3': 2, '4': 1, '5': 9, '10': 'content'},
    {'1': 'user_id', '3': 3, '4': 1, '5': 9, '10': 'userId'},
    {
      '1': 'max_tokens_per_chunk',
      '3': 4,
      '4': 1,
      '5': 5,
      '10': 'maxTokensPerChunk'
    },
    {'1': 'chunk_overlap', '3': 5, '4': 1, '5': 5, '10': 'chunkOverlap'},
    {'1': 'image_bytes', '3': 6, '4': 1, '5': 12, '10': 'imageBytes'},
    {'1': 'mime_type', '3': 7, '4': 1, '5': 9, '10': 'mimeType'},
  ],
};

/// Descriptor for `IndexRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List indexRequestDescriptor = $convert.base64Decode(
    'CgxJbmRleFJlcXVlc3QSHwoLZG9jdW1lbnRfaWQYASABKAlSCmRvY3VtZW50SWQSGAoHY29udG'
    'VudBgCIAEoCVIHY29udGVudBIXCgd1c2VyX2lkGAMgASgJUgZ1c2VySWQSLwoUbWF4X3Rva2Vu'
    'c19wZXJfY2h1bmsYBCABKAVSEW1heFRva2Vuc1BlckNodW5rEiMKDWNodW5rX292ZXJsYXAYBS'
    'ABKAVSDGNodW5rT3ZlcmxhcBIfCgtpbWFnZV9ieXRlcxgGIAEoDFIKaW1hZ2VCeXRlcxIbCglt'
    'aW1lX3R5cGUYByABKAlSCG1pbWVUeXBl');

@$core.Deprecated('Use indexResponseDescriptor instead')
const IndexResponse$json = {
  '1': 'IndexResponse',
  '2': [
    {'1': 'success', '3': 1, '4': 1, '5': 8, '10': 'success'},
    {'1': 'error_message', '3': 2, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
};

/// Descriptor for `IndexResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List indexResponseDescriptor = $convert.base64Decode(
    'Cg1JbmRleFJlc3BvbnNlEhgKB3N1Y2Nlc3MYASABKAhSB3N1Y2Nlc3MSIwoNZXJyb3JfbWVzc2'
    'FnZRgCIAEoCVIMZXJyb3JNZXNzYWdl');

@$core.Deprecated('Use queryDescriptor instead')
const Query$json = {
  '1': 'Query',
  '2': [
    {'1': 'text_query', '3': 1, '4': 1, '5': 9, '9': 0, '10': 'textQuery'},
    {'1': 'audio_query', '3': 2, '4': 1, '5': 12, '9': 0, '10': 'audioQuery'},
  ],
  '8': [
    {'1': 'query'},
  ],
};

/// Descriptor for `Query`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List queryDescriptor = $convert.base64Decode(
    'CgVRdWVyeRIfCgp0ZXh0X3F1ZXJ5GAEgASgJSABSCXRleHRRdWVyeRIhCgthdWRpb19xdWVyeR'
    'gCIAEoDEgAUgphdWRpb1F1ZXJ5QgcKBXF1ZXJ5');

@$core.Deprecated('Use retrieveRequestDescriptor instead')
const RetrieveRequest$json = {
  '1': 'RetrieveRequest',
  '2': [
    {
      '1': 'query',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.research.xeno.labs.foresight.launch_agent.proto.Query',
      '10': 'query'
    },
    {'1': 'max_results', '3': 2, '4': 1, '5': 5, '10': 'maxResults'},
    {
      '1': 'min_similarity_score',
      '3': 3,
      '4': 1,
      '5': 1,
      '10': 'minSimilarityScore'
    },
    {'1': 'user_id', '3': 4, '4': 1, '5': 9, '10': 'userId'},
    {
      '1': 'allowed_document_ids',
      '3': 5,
      '4': 3,
      '5': 9,
      '10': 'allowedDocumentIds'
    },
  ],
};

/// Descriptor for `RetrieveRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List retrieveRequestDescriptor = $convert.base64Decode(
    'Cg9SZXRyaWV2ZVJlcXVlc3QSTAoFcXVlcnkYASABKAsyNi5yZXNlYXJjaC54ZW5vLmxhYnMuZm'
    '9yZXNpZ2h0LmxhdW5jaF9hZ2VudC5wcm90by5RdWVyeVIFcXVlcnkSHwoLbWF4X3Jlc3VsdHMY'
    'AiABKAVSCm1heFJlc3VsdHMSMAoUbWluX3NpbWlsYXJpdHlfc2NvcmUYAyABKAFSEm1pblNpbW'
    'lsYXJpdHlTY29yZRIXCgd1c2VyX2lkGAQgASgJUgZ1c2VySWQSMAoUYWxsb3dlZF9kb2N1bWVu'
    'dF9pZHMYBSADKAlSEmFsbG93ZWREb2N1bWVudElkcw==');

@$core.Deprecated('Use retrieveResponseDescriptor instead')
const RetrieveResponse$json = {
  '1': 'RetrieveResponse',
  '2': [
    {
      '1': 'chunks',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.research.xeno.labs.foresight.launch_agent.proto.RetrievedChunk',
      '10': 'chunks'
    },
  ],
};

/// Descriptor for `RetrieveResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List retrieveResponseDescriptor = $convert.base64Decode(
    'ChBSZXRyaWV2ZVJlc3BvbnNlElcKBmNodW5rcxgBIAMoCzI/LnJlc2VhcmNoLnhlbm8ubGFicy'
    '5mb3Jlc2lnaHQubGF1bmNoX2FnZW50LnByb3RvLlJldHJpZXZlZENodW5rUgZjaHVua3M=');

@$core.Deprecated('Use retrievedChunkDescriptor instead')
const RetrievedChunk$json = {
  '1': 'RetrievedChunk',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
    {'1': 'relevance_score', '3': 2, '4': 1, '5': 1, '10': 'relevanceScore'},
    {'1': 'document_id', '3': 3, '4': 1, '5': 9, '10': 'documentId'},
    {'1': 'mime_type', '3': 4, '4': 1, '5': 9, '10': 'mimeType'},
  ],
};

/// Descriptor for `RetrievedChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List retrievedChunkDescriptor = $convert.base64Decode(
    'Cg5SZXRyaWV2ZWRDaHVuaxISCgR0ZXh0GAEgASgJUgR0ZXh0EicKD3JlbGV2YW5jZV9zY29yZR'
    'gCIAEoAVIOcmVsZXZhbmNlU2NvcmUSHwoLZG9jdW1lbnRfaWQYAyABKAlSCmRvY3VtZW50SWQS'
    'GwoJbWltZV90eXBlGAQgASgJUghtaW1lVHlwZQ==');

@$core.Deprecated('Use updateModelPathsRequestDescriptor instead')
const UpdateModelPathsRequest$json = {
  '1': 'UpdateModelPathsRequest',
  '2': [
    {
      '1': 'embedding_model_path',
      '3': 1,
      '4': 1,
      '5': 9,
      '10': 'embeddingModelPath'
    },
    {
      '1': 'sentence_piece_model_path',
      '3': 2,
      '4': 1,
      '5': 9,
      '10': 'sentencePieceModelPath'
    },
    {'1': 'use_gpu', '3': 3, '4': 1, '5': 8, '10': 'useGpu'},
    {'1': 'cache_dir', '3': 4, '4': 1, '5': 9, '10': 'cacheDir'},
  ],
};

/// Descriptor for `UpdateModelPathsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateModelPathsRequestDescriptor = $convert.base64Decode(
    'ChdVcGRhdGVNb2RlbFBhdGhzUmVxdWVzdBIwChRlbWJlZGRpbmdfbW9kZWxfcGF0aBgBIAEoCV'
    'ISZW1iZWRkaW5nTW9kZWxQYXRoEjkKGXNlbnRlbmNlX3BpZWNlX21vZGVsX3BhdGgYAiABKAlS'
    'FnNlbnRlbmNlUGllY2VNb2RlbFBhdGgSFwoHdXNlX2dwdRgDIAEoCFIGdXNlR3B1EhsKCWNhY2'
    'hlX2RpchgEIAEoCVIIY2FjaGVEaXI=');

@$core.Deprecated('Use updateModelPathsResponseDescriptor instead')
const UpdateModelPathsResponse$json = {
  '1': 'UpdateModelPathsResponse',
  '2': [
    {'1': 'success', '3': 1, '4': 1, '5': 8, '10': 'success'},
    {'1': 'error_message', '3': 2, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
};

/// Descriptor for `UpdateModelPathsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateModelPathsResponseDescriptor =
    $convert.base64Decode(
        'ChhVcGRhdGVNb2RlbFBhdGhzUmVzcG9uc2USGAoHc3VjY2VzcxgBIAEoCFIHc3VjY2VzcxIjCg'
        '1lcnJvcl9tZXNzYWdlGAIgASgJUgxlcnJvck1lc3NhZ2U=');

@$core.Deprecated('Use deleteRequestDescriptor instead')
const DeleteRequest$json = {
  '1': 'DeleteRequest',
  '2': [
    {'1': 'document_id', '3': 1, '4': 1, '5': 9, '10': 'documentId'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `DeleteRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteRequestDescriptor = $convert.base64Decode(
    'Cg1EZWxldGVSZXF1ZXN0Eh8KC2RvY3VtZW50X2lkGAEgASgJUgpkb2N1bWVudElkEhcKB3VzZX'
    'JfaWQYAiABKAlSBnVzZXJJZA==');

@$core.Deprecated('Use deleteResponseDescriptor instead')
const DeleteResponse$json = {
  '1': 'DeleteResponse',
  '2': [
    {'1': 'success', '3': 1, '4': 1, '5': 8, '10': 'success'},
    {'1': 'error_message', '3': 2, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
};

/// Descriptor for `DeleteResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteResponseDescriptor = $convert.base64Decode(
    'Cg5EZWxldGVSZXNwb25zZRIYCgdzdWNjZXNzGAEgASgIUgdzdWNjZXNzEiMKDWVycm9yX21lc3'
    'NhZ2UYAiABKAlSDGVycm9yTWVzc2FnZQ==');

@$core.Deprecated('Use encodeRequestDescriptor instead')
const EncodeRequest$json = {
  '1': 'EncodeRequest',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
  ],
};

/// Descriptor for `EncodeRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List encodeRequestDescriptor =
    $convert.base64Decode('Cg1FbmNvZGVSZXF1ZXN0EhIKBHRleHQYASABKAlSBHRleHQ=');

@$core.Deprecated('Use encodeResponseDescriptor instead')
const EncodeResponse$json = {
  '1': 'EncodeResponse',
  '2': [
    {'1': 'tokens', '3': 1, '4': 3, '5': 5, '10': 'tokens'},
  ],
};

/// Descriptor for `EncodeResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List encodeResponseDescriptor = $convert
    .base64Decode('Cg5FbmNvZGVSZXNwb25zZRIWCgZ0b2tlbnMYASADKAVSBnRva2Vucw==');

@$core.Deprecated('Use chunkTextRequestDescriptor instead')
const ChunkTextRequest$json = {
  '1': 'ChunkTextRequest',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
    {
      '1': 'max_tokens_per_chunk',
      '3': 2,
      '4': 1,
      '5': 5,
      '10': 'maxTokensPerChunk'
    },
  ],
};

/// Descriptor for `ChunkTextRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List chunkTextRequestDescriptor = $convert.base64Decode(
    'ChBDaHVua1RleHRSZXF1ZXN0EhIKBHRleHQYASABKAlSBHRleHQSLwoUbWF4X3Rva2Vuc19wZX'
    'JfY2h1bmsYAiABKAVSEW1heFRva2Vuc1BlckNodW5r');

@$core.Deprecated('Use chunkTextResponseDescriptor instead')
const ChunkTextResponse$json = {
  '1': 'ChunkTextResponse',
  '2': [
    {'1': 'chunks', '3': 1, '4': 3, '5': 9, '10': 'chunks'},
  ],
};

/// Descriptor for `ChunkTextResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List chunkTextResponseDescriptor = $convert.base64Decode(
    'ChFDaHVua1RleHRSZXNwb25zZRIWCgZjaHVua3MYASADKAlSBmNodW5rcw==');

@$core.Deprecated('Use truncateTextRequestDescriptor instead')
const TruncateTextRequest$json = {
  '1': 'TruncateTextRequest',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
    {'1': 'max_tokens', '3': 2, '4': 1, '5': 5, '10': 'maxTokens'},
  ],
};

/// Descriptor for `TruncateTextRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List truncateTextRequestDescriptor = $convert.base64Decode(
    'ChNUcnVuY2F0ZVRleHRSZXF1ZXN0EhIKBHRleHQYASABKAlSBHRleHQSHQoKbWF4X3Rva2Vucx'
    'gCIAEoBVIJbWF4VG9rZW5z');

@$core.Deprecated('Use truncateTextResponseDescriptor instead')
const TruncateTextResponse$json = {
  '1': 'TruncateTextResponse',
  '2': [
    {'1': 'truncated_text', '3': 1, '4': 1, '5': 9, '10': 'truncatedText'},
  ],
};

/// Descriptor for `TruncateTextResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List truncateTextResponseDescriptor = $convert.base64Decode(
    'ChRUcnVuY2F0ZVRleHRSZXNwb25zZRIlCg50cnVuY2F0ZWRfdGV4dBgBIAEoCVINdHJ1bmNhdG'
    'VkVGV4dA==');

@$core.Deprecated('Use computeEmbeddingRequestDescriptor instead')
const ComputeEmbeddingRequest$json = {
  '1': 'ComputeEmbeddingRequest',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
  ],
};

/// Descriptor for `ComputeEmbeddingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List computeEmbeddingRequestDescriptor =
    $convert.base64Decode(
        'ChdDb21wdXRlRW1iZWRkaW5nUmVxdWVzdBISCgR0ZXh0GAEgASgJUgR0ZXh0');

@$core.Deprecated('Use computeEmbeddingResponseDescriptor instead')
const ComputeEmbeddingResponse$json = {
  '1': 'ComputeEmbeddingResponse',
  '2': [
    {'1': 'embedding', '3': 1, '4': 3, '5': 1, '10': 'embedding'},
  ],
};

/// Descriptor for `ComputeEmbeddingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List computeEmbeddingResponseDescriptor =
    $convert.base64Decode(
        'ChhDb21wdXRlRW1iZWRkaW5nUmVzcG9uc2USHAoJZW1iZWRkaW5nGAEgAygBUgllbWJlZGRpbm'
        'c=');

@$core.Deprecated('Use computeImageEmbeddingRequestDescriptor instead')
const ComputeImageEmbeddingRequest$json = {
  '1': 'ComputeImageEmbeddingRequest',
  '2': [
    {'1': 'image_bytes', '3': 1, '4': 1, '5': 12, '10': 'imageBytes'},
  ],
};

/// Descriptor for `ComputeImageEmbeddingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List computeImageEmbeddingRequestDescriptor =
    $convert.base64Decode(
        'ChxDb21wdXRlSW1hZ2VFbWJlZGRpbmdSZXF1ZXN0Eh8KC2ltYWdlX2J5dGVzGAEgASgMUgppbW'
        'FnZUJ5dGVz');

@$core.Deprecated('Use computeAudioEmbeddingRequestDescriptor instead')
const ComputeAudioEmbeddingRequest$json = {
  '1': 'ComputeAudioEmbeddingRequest',
  '2': [
    {'1': 'audio_bytes', '3': 1, '4': 1, '5': 12, '10': 'audioBytes'},
  ],
};

/// Descriptor for `ComputeAudioEmbeddingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List computeAudioEmbeddingRequestDescriptor =
    $convert.base64Decode(
        'ChxDb21wdXRlQXVkaW9FbWJlZGRpbmdSZXF1ZXN0Eh8KC2F1ZGlvX2J5dGVzGAEgASgMUgphdW'
        'Rpb0J5dGVz');

@$core.Deprecated('Use pingRequestDescriptor instead')
const PingRequest$json = {
  '1': 'PingRequest',
};

/// Descriptor for `PingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pingRequestDescriptor =
    $convert.base64Decode('CgtQaW5nUmVxdWVzdA==');

@$core.Deprecated('Use pingResponseDescriptor instead')
const PingResponse$json = {
  '1': 'PingResponse',
  '2': [
    {'1': 'success', '3': 1, '4': 1, '5': 8, '10': 'success'},
    {'1': 'version', '3': 2, '4': 1, '5': 9, '10': 'version'},
  ],
};

/// Descriptor for `PingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pingResponseDescriptor = $convert.base64Decode(
    'CgxQaW5nUmVzcG9uc2USGAoHc3VjY2VzcxgBIAEoCFIHc3VjY2VzcxIYCgd2ZXJzaW9uGAIgAS'
    'gJUgd2ZXJzaW9u');
