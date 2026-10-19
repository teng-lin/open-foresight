import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';

import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/version.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/generated/helper_control.pbgrpc.dart'
    as control;
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class AdoptionRag extends RagServiceBase {
  String version = '1.0.3';
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

void main() {
  late Directory root;
  late Helper helper;
  late Server server;
  late AdoptionRag rag;
  late AdoptionControl status;
  late Map<String, String> environment;
  const revision = '0123456789abcdef0123456789abcdef01234567';
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment['FORESIGHT_RUNTIME_REVISION'] = revision;
    runtimeConfiguration.environment['FORESIGHT_HELPER'] =
        '/must-not-launch-a-second-helper';
    root = createTestTempDirectorySync('helper-adoption-');
    rag = AdoptionRag();
    status = AdoptionControl(
      control.State(
        referenceVersion: '1.0.3',
        buildId:
            'open-foresight-$openForesightVersion-${revision.substring(0, 12)}',
        pipeline: 'ready',
      ),
    );
    server = Server.create(services: [rag, status]);
    final socket = '${root.path}/helper.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    helper = Helper(socket, root.path);
    addTearDown(() async {
      await helper.close();
      await server.shutdown();
      root.deleteSync(recursive: true);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
    // serve() binds the socket without establishing an RPC-ready channel.
    // Establish fixture readiness outside the production 400 ms adoption probe
    // so a busy test host cannot turn first-call setup into a second spawn.
    await helper.client.ping(
      PingRequest(),
      options: CallOptions(timeout: const Duration(seconds: 5)),
    );
  });
  test('a matching helper is adopted before application readiness', () async {
    var ready = 0;
    helper.onReady = () async {
      ready++;
    };
    await helper.start();
    expect(ready, 1);
    expect(helper.process, isNull);
    expect(helper.snapshot?.buildId, status.state.buildId);
  });
  test(
    'transient adoption state lookup does not disable a healthy transport',
    () async {
      status.unavailableOnce = true;
      await expectLater(helper.start(), throwsA(isA<GrpcError>()));
      expect(helper.incompatible, isFalse);
      expect((await helper.client.ping(PingRequest())).success, isTrue);
      var ready = 0;
      helper.onReady = () async {
        ready++;
      };
      await helper.start();
      expect(ready, 1);
      expect(helper.snapshot?.buildId, status.state.buildId);
    },
  );
  for (final mismatch in [
    'protocol',
    'build',
    'version',
    'missing',
    'dev-version',
  ]) {
    test(
      'an incompatible $mismatch helper cannot restore application models',
      () async {
        var ready = 0;
        helper.onReady = () async {
          ready++;
        };
        switch (mismatch) {
          case 'protocol':
            rag.version = '1.0.2';
          case 'build':
            status.state.buildId =
                'open-foresight-$openForesightVersion-deadbeef1234';
          case 'version':
            status.state.buildId =
                'open-foresight-9.9.9-${revision.substring(0, 12)}';
          case 'missing':
            status.state.buildId = '';
          case 'dev-version':
            runtimeConfiguration.environment.remove(
              'FORESIGHT_RUNTIME_REVISION',
            );
            status.state.buildId =
                'open-foresight-9.9.9-${revision.substring(0, 12)}';
        }
        await expectLater(helper.start(), throwsStateError);
        expect(ready, 0);
        expect(helper.process, isNull);
        expect(helper.state, contains('incompatible helper'));
        expect(helper.incompatible, isTrue);
        await expectLater(
          helper.client.ping(PingRequest()),
          throwsA(isA<GrpcError>()),
        );
      },
    );
  }
}
