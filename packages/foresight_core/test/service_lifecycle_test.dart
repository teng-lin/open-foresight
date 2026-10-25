import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:test/test.dart';

// Lifecycle tests with the real bin/service.dart (IsolatedApplicationService)
// on one side and the real ensureService/ServiceClient on the other.

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

/// A closing owner's refusal of a request it never dispatched (D3).
final closingRefusal = isA<RpcError>()
    .having((error) => error.code, 'code', RpcErrorCode.unavailable)
    .having((error) => error.message, 'message', closingMessage)
    .having((error) => error.toJson()['reason'], 'reason', 'closing');

/// The owner's terminal frame for a request it dispatched but did not finish.
final outcomeUnknown = isA<RpcError>()
    .having((error) => error.code, 'code', RpcErrorCode.unavailable)
    .having(
      (error) => error.message,
      'message',
      'Application service stopped before this request finished; it may or '
          'may not have completed.',
    )
    .having((error) => error.toJson()['reason'], 'reason', 'outcomeUnknown');

/// The error [request] failed with; a bound only, so a request that gets no
/// terminal frame fails the test instead of hanging it.
Future<Object> failureOf(Future<Object?> request) => request
    .then<Object>(
      (value) => fail('Expected a failure, got $value'),
      onError: (Object error) => error,
    )
    .timeout(const Duration(seconds: 120));

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
      final directory = createServiceTestDirectorySync('of-kill-');
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
      final directory = createServiceTestDirectorySync('of-race-');
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
    'at close.before_record_delete the public socket is gone, the record '
    'remains, and startup waits for the lock without a launch (SL-3)',
    () async {
      final directory = createServiceTestDirectorySync('of-record-');
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
      ServiceClient? attached, replacement;
      try {
        await owner.ready();
        attached = await ServiceClient.connect(serviceEndpoint(profile));
        expect((await attached.call('status') as Map)['pid'], owner.pid);
        owner.signal(ProcessSignal.sigterm);
        await owner.reached('close.before_record_delete');
        // Worker socket, then public socket, are gone; the record and lock
        // remain, so a record never outlives its owner's lock (SL-3).
        expect(recordedRuntime(profile), profile.runtime);
        for (final name in ['application.sock', 'worker.sock']) {
          expect(
            FileSystemEntity.typeSync('${profile.runtime}/$name'),
            FileSystemEntityType.notFound,
            reason: name,
          );
        }
        expect(lockHeld(profile), isTrue);
        // The worker closed the attached client after its terminal frames.
        await attached.events.stream.drain<void>().timeout(connectionBound);
        expect(attached.isClosed, isTrue);
        // Startup finds no socket while the lock is held. Its second refused
        // connect follows a complete lock probe, so it has decided not to
        // launch.
        final secondProbe = proxy.attempt(refused: true, count: 2);
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
        expect(launcher.launched, isEmpty);
        owner.release('close.before_record_delete');
        expect(await owner.exited(), 0, reason: owner.output);
        replacement = await pending;
        expect(launcher.launched, [
          (await replacement.call('status') as Map)['pid'],
        ]);
      } finally {
        await attached?.close();
        await replacement?.close();
        await proxy.close();
        await launcher.stopAll();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'during a SIGTERM close a new client gets the closing refusal and an '
    'in-flight request outcomeUnknown, never a bare EOF (SL-3, SL-4)',
    () async {
      final directory = createServiceTestDirectorySync('of-sigterm-');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['request.committed.notes.save', 'close.helper_closed'],
      );
      ServiceClient? attached, writer, latecomer;
      try {
        await owner.ready();
        attached = await ServiceClient.connect(serviceEndpoint(profile));
        writer = await ServiceClient.connect(serviceEndpoint(profile));
        expect((await attached.call('status') as Map)['pid'], owner.pid);
        final save = failureOf(
          writer.call('notes.save', {
            'title': 'In flight at SIGTERM',
            'body': 'committed',
          }),
        );
        await owner.reached('request.committed.notes.save');
        owner.signal(ProcessSignal.sigterm);
        await owner.reached('close.helper_closed');
        expect(await save, outcomeUnknown);
        // An attached client keeps its connection and gets the refusal.
        expect(await failureOf(attached.call('status')), closingRefusal);
        expect(attached.isClosed, isFalse);
        latecomer = await ServiceClient.connect(serviceEndpoint(profile));
        expect(await failureOf(latecomer.call('status')), closingRefusal);
        expect(latecomer.isClosed, isFalse);
        owner.release('close.helper_closed');
        owner.release('request.committed.notes.save');
        expect(await owner.exited(), 0, reason: owner.output);
        expect(recordedRuntime(profile), isNull);
        // The write whose reply was lost had committed.
        final store = Store.readOnly('${profile.data}/application.db');
        try {
          expect(
            store.rows('SELECT title FROM notes').single['title'],
            'In flight at SIGTERM',
          );
        } finally {
          store.close();
        }
        for (final client in [attached, latecomer]) {
          await client.events.stream.drain<void>().timeout(connectionBound);
          expect(client.isClosed, isTrue);
        }
      } finally {
        await attached?.close();
        await writer?.close();
        await latecomer?.close();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
