import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

// Lost replies with production code on both sides: the in-process service,
// the real client, and the fault proxy cutting the reply after the commit.
void main() {
  late ProfilePaths profile;
  late Map<String, String> original;
  setUp(() {
    original = Map.of(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_HELPER',
      'FORESIGHT_NATIVE',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_INSTALL_ROOT',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    final temp = createTestTempDirectorySync('of-lost-');
    profile = ProfilePaths('${temp.path}/profile', '${temp.path}/run');
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(original);
  });

  test('a keyed save whose reply is lost after it committed is saved once on '
      'retry (LR-M1)', () async {
    final service = await ApplicationService.start(
      profile,
      desktopPeerVerifier: trustInProcessDesktop,
    );
    final proxy = ServiceFaultProxy();
    final connection = ServiceConnection(profile);
    Future<Object?> save(Map<String, dynamic> args) =>
        proxy.run(() => connection.stream('notes.save', args).last);
    Future<Object> failure(Map<String, dynamic> args) => save(args).then(
      (value) => fail('Expected a lost reply, got $value'),
      onError: (Object error) => error,
    );
    final lostReply = isA<RpcError>().having(
      (error) => error.reason,
      'reason',
      RpcErrorReason.outcomeUnknown,
    );
    List<Object?> titles() => service.domain.store
        .rows('SELECT title FROM notes ORDER BY id')
        .map((row) => row['title'])
        .toList();
    try {
      final keyed = {'title': 'Keyed', 'body': '', 'idempotency_key': 'lr-m1'};
      var dropped = proxy.drop(ProxyDirection.toClient, method: 'notes.save');
      expect(await failure(keyed), lostReply);
      await dropped;
      expect(titles(), ['Keyed'], reason: 'it committed');
      expect(await save(keyed), {'id': 1});
      expect(titles(), ['Keyed']);
      // Without a key the caller learns the same, and a retry writes again.
      dropped = proxy.drop(ProxyDirection.toClient, method: 'notes.save');
      final unkeyed = {'title': 'Unkeyed', 'body': ''};
      expect(await failure(unkeyed), lostReply);
      await dropped;
      expect(await save(unkeyed), {'id': 3});
      expect(titles(), ['Keyed', 'Unkeyed', 'Unkeyed']);
    } finally {
      await connection.close();
      await proxy.close();
      await service.close();
    }
  });
}
