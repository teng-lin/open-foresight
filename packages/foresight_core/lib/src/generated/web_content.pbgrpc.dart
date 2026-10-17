// This is a generated file - do not edit.
//
// Generated from web_content.proto.

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

import 'web_content.pb.dart' as $0;

export 'web_content.pb.dart';

@$pb.GrpcServiceName('ai_edge.foresight.service.ForesightService')
class ForesightServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  ForesightServiceClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.FetchExternalWebsiteResponse> fetchExternalWebsite(
    $0.FetchExternalWebsiteRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$fetchExternalWebsite, request, options: options);
  }

  $grpc.ResponseFuture<$0.ForesightSharedConfig> getSharedConfig(
    $0.GetSharedConfigRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getSharedConfig, request, options: options);
  }

  // method descriptors

  static final _$fetchExternalWebsite = $grpc.ClientMethod<
          $0.FetchExternalWebsiteRequest, $0.FetchExternalWebsiteResponse>(
      '/ai_edge.foresight.service.ForesightService/FetchExternalWebsite',
      ($0.FetchExternalWebsiteRequest value) => value.writeToBuffer(),
      $0.FetchExternalWebsiteResponse.fromBuffer);
  static final _$getSharedConfig =
      $grpc.ClientMethod<$0.GetSharedConfigRequest, $0.ForesightSharedConfig>(
          '/ai_edge.foresight.service.ForesightService/GetSharedConfig',
          ($0.GetSharedConfigRequest value) => value.writeToBuffer(),
          $0.ForesightSharedConfig.fromBuffer);
}

@$pb.GrpcServiceName('ai_edge.foresight.service.ForesightService')
abstract class ForesightServiceBase extends $grpc.Service {
  $core.String get $name => 'ai_edge.foresight.service.ForesightService';

  ForesightServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.FetchExternalWebsiteRequest,
            $0.FetchExternalWebsiteResponse>(
        'FetchExternalWebsite',
        fetchExternalWebsite_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.FetchExternalWebsiteRequest.fromBuffer(value),
        ($0.FetchExternalWebsiteResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GetSharedConfigRequest,
            $0.ForesightSharedConfig>(
        'GetSharedConfig',
        getSharedConfig_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.GetSharedConfigRequest.fromBuffer(value),
        ($0.ForesightSharedConfig value) => value.writeToBuffer()));
  }

  $async.Future<$0.FetchExternalWebsiteResponse> fetchExternalWebsite_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.FetchExternalWebsiteRequest> $request) async {
    return fetchExternalWebsite($call, await $request);
  }

  $async.Future<$0.FetchExternalWebsiteResponse> fetchExternalWebsite(
      $grpc.ServiceCall call, $0.FetchExternalWebsiteRequest request);

  $async.Future<$0.ForesightSharedConfig> getSharedConfig_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.GetSharedConfigRequest> $request) async {
    return getSharedConfig($call, await $request);
  }

  $async.Future<$0.ForesightSharedConfig> getSharedConfig(
      $grpc.ServiceCall call, $0.GetSharedConfigRequest request);
}
