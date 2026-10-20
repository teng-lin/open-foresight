import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

// Characterization tests: the real bin/service.dart (IsolatedApplicationService)
// on one side and the real ensureService/ServiceClient on the other. They pin
// lifecycle behavior as it is today; tests marked PINNED change in PR 3.

const closingMessage =
    'Application service is shutting down; retry after it exits.';

/// A bound only: startup of a compiled service child under parallel load.
const startupBound = Duration(seconds: 90);

/// A bound only: a dropped connection reaching its client.
const connectionBound = Duration(seconds: 30);

String? recordedRuntime(ProfilePaths profile) {
  final record = File('${profile.data}/.application-endpoint.json');
  if (!record.existsSync()) return null;
  return (jsonDecode(record.readAsStringSync()) as Map)['runtime'] as String;
}

/// True when another process holds the profile's POSIX ownership lock.
bool lockHeld(ProfilePaths profile) {
  final lock = File(
    '${profile.data}/.application.lock',
  ).openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
    return false;
  } on FileSystemException {
    return true;
  } finally {
    lock.closeSync();
  }
}

/// A connection the service dropped: EOF, or a write into the closed socket.
final isTransportLoss = anyOf(
  isA<SocketException>(),
  isA<RpcError>().having(
    (error) => error.message,
    'message',
    'Application service disconnected',
  ),
);

void main() {
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
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    // Launched replacements inherit this configuration; run them helperless.
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(saved);
  });

  test(
    'a killed owner is replaced once and its recorded runtime is adopted',
    () async {
      final directory = createTestTempDirectorySync('of-kill-');
      final data = '${directory.path}/data';
      final ownerProfile = ProfilePaths(data, '${directory.path}/own');
      // The client's own runtime differs; only the record names the owner's.
      final clientProfile = ProfilePaths(data, '${directory.path}/run');
      final owner = await HookedServiceProcess.start(build, ownerProfile);
      final launcher = await build.launcher(directory);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          launcher.executable;
      ServiceClient? before, after;
      try {
        await owner.ready();
        before = await ServiceClient.connect(serviceEndpoint(clientProfile));
        await before.call('notes.save', {
          'title': 'Before the crash',
          'body': 'committed',
        });
        owner.signal(ProcessSignal.sigkill);
        await owner.exited();
        // A crash leaves the record and the stale public socket behind.
        expect(recordedRuntime(clientProfile), ownerProfile.runtime);
        expect(
          FileSystemEntity.typeSync('${ownerProfile.runtime}/application.sock'),
          FileSystemEntityType.unixDomainSock,
        );
        after = await ensureService(
          clientProfile,
          startupTimeout: startupBound,
        );
        final status = await after.call('status') as Map;
        expect(launcher.launched, [status['pid']]);
        // The replacement adopted the crashed owner's runtime.
        expect(recordedRuntime(clientProfile), ownerProfile.runtime);
        expect(
          serviceEndpoint(clientProfile),
          '${ownerProfile.runtime}/application.sock',
        );
        expect(
          FileSystemEntity.typeSync(
            '${clientProfile.runtime}/application.sock',
          ),
          FileSystemEntityType.notFound,
        );
        expect(
          (await after.call('notes.list') as List).single['title'],
          'Before the crash',
        );
      } finally {
        await before?.close();
        await after?.close();
        await launcher.stopAll();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'two launchers converge on one owner when none is running',
    () async {
      final directory = createTestTempDirectorySync('of-race-');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final launcher = await build.launcher(directory);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          launcher.executable;
      final clients = <ServiceClient>[];
      try {
        clients.addAll(
          await Future.wait([
            ensureService(profile, startupTimeout: startupBound),
            ensureService(profile, startupTimeout: startupBound),
          ]),
        );
        final pids = {
          for (final client in clients)
            (await client.call('status') as Map)['pid'] as int,
        };
        expect(pids, hasLength(1));
        final owner = pids.single;
        // Each launcher launches at most once; a losing launch exits.
        expect(launcher.launched, contains(owner));
        expect(launcher.launched.length, inInclusiveRange(1, 2));
        for (final pid in launcher.launched.where((pid) => pid != owner)) {
          await eventually(
            () async => !await isRunning(pid),
            timeout: startupBound,
          );
        }
        expect(await isRunning(owner), isTrue);
      } finally {
        for (final client in clients) {
          await client.close();
        }
        await launcher.stopAll();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'PINNED (SL-3, reordered by PR 3): at close.before_record_delete the '
    'record and public socket remain, new clients get EOF and no launch',
    () async {
      final directory = createTestTempDirectorySync('of-record-');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['close.before_record_delete'],
      );
      final launcher = await build.launcher(directory);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          launcher.executable;
      final proxy = ServiceFaultProxy();
      ServiceClient? attached, latecomer, replacement;
      try {
        await owner.ready();
        attached = await ServiceClient.connect(serviceEndpoint(profile));
        expect((await attached.call('status') as Map)['pid'], owner.pid);
        owner.signal(ProcessSignal.sigterm);
        await owner.reached('close.before_record_delete');
        // The worker has closed its own socket and still owns the profile.
        expect(recordedRuntime(profile), profile.runtime);
        expect(
          FileSystemEntity.typeSync('${profile.runtime}/application.sock'),
          FileSystemEntityType.unixDomainSock,
        );
        expect(
          FileSystemEntity.typeSync('${profile.runtime}/worker.sock'),
          FileSystemEntityType.notFound,
        );
        expect(lockHeld(profile), isTrue);
        // SIGTERM already dropped the attached client.
        await attached.events.stream.drain<void>().timeout(connectionBound);
        expect(attached.isClosed, isTrue);
        // The frontend still accepts, then closes without any reply.
        latecomer = await ServiceClient.connect(serviceEndpoint(profile));
        await expectLater(latecomer.call('status'), throwsA(isTransportLoss));
        // Startup retries while the lock is held. The frontend accepts each
        // connection and drops it, so its second connection follows a
        // complete lock probe: startup has decided not to launch.
        final secondProbe = proxy.attempt(refused: false, count: 2);
        final pending = proxy.run(
          () => ensureService(profile, startupTimeout: startupBound),
        );
        var settled = false;
        unawaited(
          pending.then<void>(
            (_) => settled = true,
            onError: (Object _) => settled = true,
          ),
        );
        await secondProbe;
        expect(settled, isFalse);
        expect(
          proxy.frames.where(
            (frame) =>
                frame.direction == ProxyDirection.toClient &&
                frame.method == 'status',
          ),
          isEmpty,
          reason: 'The closing owner answered no probe',
        );
        expect(launcher.launched, isEmpty);
        owner.release('close.before_record_delete');
        expect(await owner.exited(), 0, reason: owner.output);
        replacement = await pending;
        expect(launcher.launched, [
          (await replacement.call('status') as Map)['pid'],
        ]);
      } finally {
        await attached?.close();
        await latecomer?.close();
        await replacement?.close();
        await proxy.close();
        await launcher.stopAll();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('PINNED (D3, changed by PR 3): during a SIGTERM close a new client gets '
      'EOF or a broken pipe, never the closing reply', () async {
    final directory = createTestTempDirectorySync('of-sigterm-');
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.helper_closed'],
    );
    ServiceClient? attached, latecomer;
    try {
      await owner.ready();
      attached = await ServiceClient.connect(serviceEndpoint(profile));
      expect((await attached.call('status') as Map)['pid'], owner.pid);
      owner.signal(ProcessSignal.sigterm);
      await owner.reached('close.helper_closed');
      // The frontend destroys attached peers as soon as SIGTERM arrives.
      await attached.events.stream.drain<void>().timeout(connectionBound);
      expect(attached.isClosed, isTrue);
      await expectLater(attached.call('status'), throwsA(isTransportLoss));
      latecomer = await ServiceClient.connect(serviceEndpoint(profile));
      Object? failure;
      try {
        await latecomer.call('status');
      } catch (error) {
        failure = error;
      }
      // PR 3 (D3) replaces this with a structured closing refusal.
      expect(failure, isTransportLoss);
      expect(
        failure,
        isNot(
          isA<RpcError>().having(
            (error) => error.message,
            'message',
            closingMessage,
          ),
        ),
      );
      owner.release('close.helper_closed');
      expect(await owner.exited(), 0, reason: owner.output);
      expect(recordedRuntime(profile), isNull);
    } finally {
      await attached?.close();
      await latecomer?.close();
      await owner.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
