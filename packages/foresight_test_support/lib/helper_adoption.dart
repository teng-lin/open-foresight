import 'dart:async';
import 'package:grpc/grpc.dart';
// ignore: implementation_imports
import 'package:foresight_core/src/helper_protocol_version.dart';
// ignore: implementation_imports
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
// ignore: implementation_imports
import 'package:foresight_core/src/generated/helper_control.pbgrpc.dart'
    as control;

class AdoptionRag extends RagServiceBase {
  String version = helperProtocolVersion;
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(success: true, version: version);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class AdoptionControl extends control.HelperControlServiceBase {
  final control.State state;
  bool unavailableOnce = false;
  AdoptionControl(this.state);
  @override
  Future<control.State> getState(
    ServiceCall call,
    control.Empty request,
  ) async {
    if (unavailableOnce) {
      unavailableOnce = false;
      throw GrpcError.unavailable('Temporary adoption lookup failure');
    }
    return state;
  }

  @override
  Stream<control.State> watchState(
    ServiceCall call,
    control.WatchRequest request,
  ) async* {
    yield state;
  }
}

class HeldPing extends AdoptionRag {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.ping(call, request);
  }
}
