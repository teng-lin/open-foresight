// A separate gRPC process: lifecycle tests exercise actual EOF, signals and
// reconnects while keeping inference and downloaded models out of the fixture.
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/generated/helper_control.pbgrpc.dart'
    as control;
import 'package:grpc/grpc.dart';

class _Rag extends RagServiceBase {
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(success: true, version: '1.0.3');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Control extends control.HelperControlServiceBase {
  @override
  Future<control.State> getState(
    ServiceCall call,
    control.Empty request,
  ) async => control.State(pipeline: 'ready', instanceId: '$pid-1');
  @override
  Stream<control.State> watchState(
    ServiceCall call,
    control.WatchRequest request,
  ) async* {
    yield await getState(call, control.Empty());
    await Completer<void>().future;
  }
}

Future<void> main(List<String> args) async {
  final launches = File('${args[1]}/launches');
  launches.parent.createSync(recursive: true);
  launches.writeAsStringSync('$pid\n', mode: FileMode.append, flush: true);
  if (File('${args[1]}/ignore-term').existsSync()) {
    ProcessSignal.sigterm.watch().listen((_) {
      File('${args[1]}/term-received').writeAsStringSync('received');
    });
  }
  final stale = File(args[0]);
  if (stale.existsSync()) stale.deleteSync();
  final server = Server.create(services: [_Rag(), _Control()]);
  await server.serve(
    address: InternetAddress(args[0], type: InternetAddressType.unix),
    port: 0,
  );
}
