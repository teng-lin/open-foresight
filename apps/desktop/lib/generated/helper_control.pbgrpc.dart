// This is a generated file - do not edit.
//
// Generated from helper_control.proto.

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

import 'helper_control.pb.dart' as $0;

export 'helper_control.pb.dart';

@$pb.GrpcServiceName('foresight.linux.control.v1.HelperControl')
class HelperControlClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  HelperControlClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.State> getState(
    $0.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getState, request, options: options);
  }

  $grpc.ResponseStream<$0.State> watchState(
    $0.WatchRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$watchState, $async.Stream.fromIterable([request]),
        options: options);
  }

  // method descriptors

  static final _$getState = $grpc.ClientMethod<$0.Empty, $0.State>(
      '/foresight.linux.control.v1.HelperControl/GetState',
      ($0.Empty value) => value.writeToBuffer(),
      $0.State.fromBuffer);
  static final _$watchState = $grpc.ClientMethod<$0.WatchRequest, $0.State>(
      '/foresight.linux.control.v1.HelperControl/WatchState',
      ($0.WatchRequest value) => value.writeToBuffer(),
      $0.State.fromBuffer);
}

@$pb.GrpcServiceName('foresight.linux.control.v1.HelperControl')
abstract class HelperControlServiceBase extends $grpc.Service {
  $core.String get $name => 'foresight.linux.control.v1.HelperControl';

  HelperControlServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.State>(
        'GetState',
        getState_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.State value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.WatchRequest, $0.State>(
        'WatchState',
        watchState_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.WatchRequest.fromBuffer(value),
        ($0.State value) => value.writeToBuffer()));
  }

  $async.Future<$0.State> getState_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.Empty> $request) async {
    return getState($call, await $request);
  }

  $async.Future<$0.State> getState($grpc.ServiceCall call, $0.Empty request);

  $async.Stream<$0.State> watchState_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.WatchRequest> $request) async* {
    yield* watchState($call, await $request);
  }

  $async.Stream<$0.State> watchState(
      $grpc.ServiceCall call, $0.WatchRequest request);
}
