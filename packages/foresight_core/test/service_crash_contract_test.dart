import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:test/test.dart';

// Desktop <-> service, crash contract. The production RemoteDomain is attached
// to the real bin/service.dart (compiled with its test hooks) and the service
// is killed with SIGKILL, a crash that runs no shutdown code at all. Nothing
// replaces either side: the service is the same entrypoint, and the only
// addition is the hook that holds the service after a commit, so the kill
// lands at an exact instant rather than at a guessed one.

void main() {
  bootstrapSqlSupportFixture();
  late HookedServiceBuild build;
  late Map<String, String> saved;
  setUpAll(() async => build = await HookedServiceBuild.compile());
  tearDownAll(() => build.dispose());
  setUp(() {
    saved = Map.of(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_NATIVE',
      'FORESIGHT_INSTALL_ROOT',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_MODEL_MANIFEST',
      'FORESIGHT_SERVICE_GATES',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(saved);
  });

  Future<RemoteDomain> attach(ProfilePaths profile) async {
    final domain = await RemoteDomain.connect(profile);
    addTearDown(() async {
      domain.close();
      await domain.closed;
    });
    return domain;
  }

  Future<List<Object?>> titles(RemoteDomain domain) async => [
    for (final note in (await domain.command(Operation.notesList)) as List)
      (note as Map)['title'],
  ];

  test('a service killed after committing a mutation and before its reply: the '
      'desktop is told the outcome is unknown, never resends, and the replacement '
      'holds the mutation exactly once', () async {
    final directory = createServiceTestDirectorySync('of-crash-commit-');
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['request.committed.notes.save'],
    );
    await owner.ready();
    final launcher = await build.launcher(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    final domain = await attach(profile);

    final save = domain.command(Operation.notesSave, {
      'title': 'Committed once',
      'body': 'the reply is lost',
    });
    final outcome = save.then<Object?>((value) => value, onError: (e) => e);
    // The row is durable and the reply is not sent: kill at that instant.
    await owner.reached('request.committed.notes.save');
    owner.signal(ProcessSignal.sigkill);
    await owner.exited();

    final error = await outcome;
    expect(error, isA<RpcError>(), reason: 'outcome: $error');
    expect((error as RpcError).reason, RpcErrorReason.outcomeUnknown);
    // Nothing started a replacement for the lost request: only the next
    // command's reconnect does, and it must not resend notes.save.
    expect(launcher.launched, isEmpty);

    expect(await titles(domain), ['Committed once']);
    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single, isNot(owner.pid));
    // A further round trip on the same replacement does not duplicate it.
    expect(await titles(domain), ['Committed once']);
    expect(launcher.launched, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a service killed while idle: the next command reconnects once to a '
      'replacement and the committed data survived', () async {
    final directory = createServiceTestDirectorySync('of-crash-idle-');
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final owner = await HookedServiceProcess.start(build, profile);
    await owner.ready();
    final launcher = await build.launcher(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    final domain = await attach(profile);
    await domain.command(Operation.notesSave, {
      'title': 'Before the crash',
      'body': 'committed and replied',
    });

    owner.signal(ProcessSignal.sigkill);
    await owner.exited();
    // A killed service leaves its socket and record behind, and no shutdown
    // code ran; the replacement must replace that stale owner.
    expect(
      File('${profile.data}/.application-endpoint.json').existsSync(),
      isTrue,
    );
    expect(launcher.launched, isEmpty);

    expect(await titles(domain), ['Before the crash']);
    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single, isNot(owner.pid));
    final status = await domain.command(Operation.status) as Map;
    expect(status['pid'], launcher.launched.single);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
