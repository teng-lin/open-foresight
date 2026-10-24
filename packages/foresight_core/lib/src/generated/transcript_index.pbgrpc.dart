// This is a generated file - do not edit.
//
// Generated from transcript_index.proto.

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

import 'transcript_index.pb.dart' as $0;

export 'transcript_index.pb.dart';

@$pb.GrpcServiceName('foresight.transcript.v1.TranscriptIndex')
class TranscriptIndexClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  TranscriptIndexClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.TranscriptCursor> getCursor(
    $0.TranscriptCursorRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getCursor, request, options: options);
  }

  $grpc.ResponseFuture<$0.TranscriptDeltaResult> applyDelta(
    $0.TranscriptDelta request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$applyDelta, request, options: options);
  }

  // method descriptors

  static final _$getCursor =
      $grpc.ClientMethod<$0.TranscriptCursorRequest, $0.TranscriptCursor>(
          '/foresight.transcript.v1.TranscriptIndex/GetCursor',
          ($0.TranscriptCursorRequest value) => value.writeToBuffer(),
          $0.TranscriptCursor.fromBuffer);
  static final _$applyDelta =
      $grpc.ClientMethod<$0.TranscriptDelta, $0.TranscriptDeltaResult>(
          '/foresight.transcript.v1.TranscriptIndex/ApplyDelta',
          ($0.TranscriptDelta value) => value.writeToBuffer(),
          $0.TranscriptDeltaResult.fromBuffer);
}

@$pb.GrpcServiceName('foresight.transcript.v1.TranscriptIndex')
abstract class TranscriptIndexServiceBase extends $grpc.Service {
  $core.String get $name => 'foresight.transcript.v1.TranscriptIndex';

  TranscriptIndexServiceBase() {
    $addMethod(
        $grpc.ServiceMethod<$0.TranscriptCursorRequest, $0.TranscriptCursor>(
            'GetCursor',
            getCursor_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.TranscriptCursorRequest.fromBuffer(value),
            ($0.TranscriptCursor value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.TranscriptDelta, $0.TranscriptDeltaResult>(
            'ApplyDelta',
            applyDelta_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.TranscriptDelta.fromBuffer(value),
            ($0.TranscriptDeltaResult value) => value.writeToBuffer()));
  }

  $async.Future<$0.TranscriptCursor> getCursor_Pre($grpc.ServiceCall $call,
      $async.Future<$0.TranscriptCursorRequest> $request) async {
    return getCursor($call, await $request);
  }

  $async.Future<$0.TranscriptCursor> getCursor(
      $grpc.ServiceCall call, $0.TranscriptCursorRequest request);

  $async.Future<$0.TranscriptDeltaResult> applyDelta_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.TranscriptDelta> $request) async {
    return applyDelta($call, await $request);
  }

  $async.Future<$0.TranscriptDeltaResult> applyDelta(
      $grpc.ServiceCall call, $0.TranscriptDelta request);
}
