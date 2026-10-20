import 'dart:async';
import 'dart:io';
import 'package:clock/clock.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProfilePaths profile;
  late ApplicationService service;
  late ServiceClient agent;
  late Map<String,String> environment;
  var now = DateTime.utc(2026,10,20);
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere((key, _) => key.startsWith('FORESIGHT_'));
    root = createTestTempDirectorySync('lifetime-');
    profile = ProfilePaths('${root.path}/d', '${root.path}/r');
    now = DateTime.utc(2026,10,20);
    service = await ApplicationService.start(profile, clock: Clock(() => now));
    service.domain.store.setPreference('serviceIdleMinutes', '30');
    agent = await ServiceClient.connect('${profile.runtime}/application.sock');
    addTearDown(() async {
    await agent.close();
    await service.close();
    await eventually(() => service.dispatchedCount == 0);
    expect(service.application.activeEnhancements, 0);
    expect(service.application.proactiveWork, 0);
    expect(service.application.transcriptComputing, 0);
    expect(service.domain.mutating, 0);
    runtimeConfiguration.environment..clear()..addAll(environment);
    });
  });
  Future<Map> lifetime() async => (await agent.call('status') as Map)['lifetime'] as Map;
  test('status lifetime numbers preserve fractional preferences without stamping', () async {
    service.domain.store.setPreference('serviceIdleMinutes', '0.05');
    final state = await lifetime();
    expect(state['idle_minutes'], 0.05);
    expect(state['last_agent_activity'], null);
    expect(state['pinned_by_desktop'], false);
    expect(state['busy'], false);
  });
  test('cancelled committed future remains busy until its work settles', () async {
    final gates = await ServiceGates.create(root);
    runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] = gates.directory.path;
    gates.hold('request.committed.notes.save');
    addTearDown(gates.releaseAll);
    final subscription = agent.stream('notes.save', {'title': 'held', 'body': 'committed'}).listen((_) {});
    await gates.reached('request.committed.notes.save');
    expect((await lifetime())['busy'], true);
    await subscription.cancel();
    expect((await lifetime())['busy'], true);
    await expectLater(agent.call('service.stop_if_idle'), throwsA(isA<RpcError>().having((e) => e.message, 'message', contains('operations are in progress'))));
    gates.release('request.committed.notes.save');
    await eventually(() => service.dispatchedCount == 0);
    expect((await lifetime())['busy'], false);
  });


}
