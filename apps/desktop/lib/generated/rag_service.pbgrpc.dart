// This is a generated file - do not edit.
//
// Generated from rag_service.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'rag_service.pb.dart' as $0;

export 'rag_service.pb.dart';

@$pb.GrpcServiceName(
    'research.xeno.labs.foresight.launch_agent.proto.RagService')
class RagServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  RagServiceClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.IndexResponse> indexDocument(
    $0.IndexRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$indexDocument, request, options: options);
  }

  $grpc.ResponseFuture<$0.RetrieveResponse> retrieveContext(
    $0.RetrieveRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$retrieveContext, request, options: options);
  }

  $grpc.ResponseFuture<$0.UpdateModelPathsResponse> updateModelPaths(
    $0.UpdateModelPathsRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$updateModelPaths, request, options: options);
  }

  $grpc.ResponseFuture<$0.DeleteResponse> deleteDocument(
    $0.DeleteRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$deleteDocument, request, options: options);
  }

  $grpc.ResponseFuture<$0.EncodeResponse> encode(
    $0.EncodeRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$encode, request, options: options);
  }

  $grpc.ResponseFuture<$0.ChunkTextResponse> chunkText(
    $0.ChunkTextRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$chunkText, request, options: options);
  }

  $grpc.ResponseFuture<$0.TruncateTextResponse> truncateText(
    $0.TruncateTextRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$truncateText, request, options: options);
  }

  $grpc.ResponseFuture<$0.ComputeEmbeddingResponse> computeEmbedding(
    $0.ComputeEmbeddingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$computeEmbedding, request, options: options);
  }

  $grpc.ResponseFuture<$0.ComputeEmbeddingResponse> computeImageEmbedding(
    $0.ComputeImageEmbeddingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$computeImageEmbedding, request, options: options);
  }

  $grpc.ResponseFuture<$0.ComputeEmbeddingResponse> computeAudioEmbedding(
    $0.ComputeAudioEmbeddingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$computeAudioEmbedding, request, options: options);
  }

  $grpc.ResponseFuture<$0.PingResponse> ping(
    $0.PingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$ping, request, options: options);
  }

  // method descriptors

  static final _$indexDocument = $grpc.ClientMethod<$0.IndexRequest,
          $0.IndexResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/IndexDocument',
      ($0.IndexRequest value) => value.writeToBuffer(),
      $0.IndexResponse.fromBuffer);
  static final _$retrieveContext = $grpc.ClientMethod<$0.RetrieveRequest,
          $0.RetrieveResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/RetrieveContext',
      ($0.RetrieveRequest value) => value.writeToBuffer(),
      $0.RetrieveResponse.fromBuffer);
  static final _$updateModelPaths = $grpc.ClientMethod<
          $0.UpdateModelPathsRequest, $0.UpdateModelPathsResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/UpdateModelPaths',
      ($0.UpdateModelPathsRequest value) => value.writeToBuffer(),
      $0.UpdateModelPathsResponse.fromBuffer);
  static final _$deleteDocument = $grpc.ClientMethod<$0.DeleteRequest,
          $0.DeleteResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/DeleteDocument',
      ($0.DeleteRequest value) => value.writeToBuffer(),
      $0.DeleteResponse.fromBuffer);
  static final _$encode =
      $grpc.ClientMethod<$0.EncodeRequest, $0.EncodeResponse>(
          '/research.xeno.labs.foresight.launch_agent.proto.RagService/Encode',
          ($0.EncodeRequest value) => value.writeToBuffer(),
          $0.EncodeResponse.fromBuffer);
  static final _$chunkText = $grpc.ClientMethod<$0.ChunkTextRequest,
          $0.ChunkTextResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/ChunkText',
      ($0.ChunkTextRequest value) => value.writeToBuffer(),
      $0.ChunkTextResponse.fromBuffer);
  static final _$truncateText = $grpc.ClientMethod<$0.TruncateTextRequest,
          $0.TruncateTextResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/TruncateText',
      ($0.TruncateTextRequest value) => value.writeToBuffer(),
      $0.TruncateTextResponse.fromBuffer);
  static final _$computeEmbedding = $grpc.ClientMethod<
          $0.ComputeEmbeddingRequest, $0.ComputeEmbeddingResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/ComputeEmbedding',
      ($0.ComputeEmbeddingRequest value) => value.writeToBuffer(),
      $0.ComputeEmbeddingResponse.fromBuffer);
  static final _$computeImageEmbedding = $grpc.ClientMethod<
          $0.ComputeImageEmbeddingRequest, $0.ComputeEmbeddingResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/ComputeImageEmbedding',
      ($0.ComputeImageEmbeddingRequest value) => value.writeToBuffer(),
      $0.ComputeEmbeddingResponse.fromBuffer);
  static final _$computeAudioEmbedding = $grpc.ClientMethod<
          $0.ComputeAudioEmbeddingRequest, $0.ComputeEmbeddingResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/ComputeAudioEmbedding',
      ($0.ComputeAudioEmbeddingRequest value) => value.writeToBuffer(),
      $0.ComputeEmbeddingResponse.fromBuffer);
  static final _$ping = $grpc.ClientMethod<$0.PingRequest, $0.PingResponse>(
      '/research.xeno.labs.foresight.launch_agent.proto.RagService/Ping',
      ($0.PingRequest value) => value.writeToBuffer(),
      $0.PingResponse.fromBuffer);
}

@$pb.GrpcServiceName(
    'research.xeno.labs.foresight.launch_agent.proto.RagService')
abstract class RagServiceBase extends $grpc.Service {
  $core.String get $name =>
      'research.xeno.labs.foresight.launch_agent.proto.RagService';

  RagServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.IndexRequest, $0.IndexResponse>(
        'IndexDocument',
        indexDocument_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.IndexRequest.fromBuffer(value),
        ($0.IndexResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.RetrieveRequest, $0.RetrieveResponse>(
        'RetrieveContext',
        retrieveContext_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.RetrieveRequest.fromBuffer(value),
        ($0.RetrieveResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.UpdateModelPathsRequest,
            $0.UpdateModelPathsResponse>(
        'UpdateModelPaths',
        updateModelPaths_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.UpdateModelPathsRequest.fromBuffer(value),
        ($0.UpdateModelPathsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DeleteRequest, $0.DeleteResponse>(
        'DeleteDocument',
        deleteDocument_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.DeleteRequest.fromBuffer(value),
        ($0.DeleteResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.EncodeRequest, $0.EncodeResponse>(
        'Encode',
        encode_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.EncodeRequest.fromBuffer(value),
        ($0.EncodeResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ChunkTextRequest, $0.ChunkTextResponse>(
        'ChunkText',
        chunkText_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ChunkTextRequest.fromBuffer(value),
        ($0.ChunkTextResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.TruncateTextRequest, $0.TruncateTextResponse>(
            'TruncateText',
            truncateText_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.TruncateTextRequest.fromBuffer(value),
            ($0.TruncateTextResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ComputeEmbeddingRequest,
            $0.ComputeEmbeddingResponse>(
        'ComputeEmbedding',
        computeEmbedding_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.ComputeEmbeddingRequest.fromBuffer(value),
        ($0.ComputeEmbeddingResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ComputeImageEmbeddingRequest,
            $0.ComputeEmbeddingResponse>(
        'ComputeImageEmbedding',
        computeImageEmbedding_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.ComputeImageEmbeddingRequest.fromBuffer(value),
        ($0.ComputeEmbeddingResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ComputeAudioEmbeddingRequest,
            $0.ComputeEmbeddingResponse>(
        'ComputeAudioEmbedding',
        computeAudioEmbedding_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.ComputeAudioEmbeddingRequest.fromBuffer(value),
        ($0.ComputeEmbeddingResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.PingRequest, $0.PingResponse>(
        'Ping',
        ping_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.PingRequest.fromBuffer(value),
        ($0.PingResponse value) => value.writeToBuffer()));
  }

  $async.Future<$0.IndexResponse> indexDocument_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.IndexRequest> $request) async {
    return indexDocument($call, await $request);
  }

  $async.Future<$0.IndexResponse> indexDocument(
      $grpc.ServiceCall call, $0.IndexRequest request);

  $async.Future<$0.RetrieveResponse> retrieveContext_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.RetrieveRequest> $request) async {
    return retrieveContext($call, await $request);
  }

  $async.Future<$0.RetrieveResponse> retrieveContext(
      $grpc.ServiceCall call, $0.RetrieveRequest request);

  $async.Future<$0.UpdateModelPathsResponse> updateModelPaths_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.UpdateModelPathsRequest> $request) async {
    return updateModelPaths($call, await $request);
  }

  $async.Future<$0.UpdateModelPathsResponse> updateModelPaths(
      $grpc.ServiceCall call, $0.UpdateModelPathsRequest request);

  $async.Future<$0.DeleteResponse> deleteDocument_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.DeleteRequest> $request) async {
    return deleteDocument($call, await $request);
  }

  $async.Future<$0.DeleteResponse> deleteDocument(
      $grpc.ServiceCall call, $0.DeleteRequest request);

  $async.Future<$0.EncodeResponse> encode_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.EncodeRequest> $request) async {
    return encode($call, await $request);
  }

  $async.Future<$0.EncodeResponse> encode(
      $grpc.ServiceCall call, $0.EncodeRequest request);

  $async.Future<$0.ChunkTextResponse> chunkText_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ChunkTextRequest> $request) async {
    return chunkText($call, await $request);
  }

  $async.Future<$0.ChunkTextResponse> chunkText(
      $grpc.ServiceCall call, $0.ChunkTextRequest request);

  $async.Future<$0.TruncateTextResponse> truncateText_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.TruncateTextRequest> $request) async {
    return truncateText($call, await $request);
  }

  $async.Future<$0.TruncateTextResponse> truncateText(
      $grpc.ServiceCall call, $0.TruncateTextRequest request);

  $async.Future<$0.ComputeEmbeddingResponse> computeEmbedding_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ComputeEmbeddingRequest> $request) async {
    return computeEmbedding($call, await $request);
  }

  $async.Future<$0.ComputeEmbeddingResponse> computeEmbedding(
      $grpc.ServiceCall call, $0.ComputeEmbeddingRequest request);

  $async.Future<$0.ComputeEmbeddingResponse> computeImageEmbedding_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ComputeImageEmbeddingRequest> $request) async {
    return computeImageEmbedding($call, await $request);
  }

  $async.Future<$0.ComputeEmbeddingResponse> computeImageEmbedding(
      $grpc.ServiceCall call, $0.ComputeImageEmbeddingRequest request);

  $async.Future<$0.ComputeEmbeddingResponse> computeAudioEmbedding_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ComputeAudioEmbeddingRequest> $request) async {
    return computeAudioEmbedding($call, await $request);
  }

  $async.Future<$0.ComputeEmbeddingResponse> computeAudioEmbedding(
      $grpc.ServiceCall call, $0.ComputeAudioEmbeddingRequest request);

  $async.Future<$0.PingResponse> ping_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.PingRequest> $request) async {
    return ping($call, await $request);
  }

  $async.Future<$0.PingResponse> ping(
      $grpc.ServiceCall call, $0.PingRequest request);
}
