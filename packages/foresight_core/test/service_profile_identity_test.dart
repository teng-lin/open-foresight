import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:test/test.dart';

// Profile identity (fix plan, PR 4; SL-7): an owner says which profile it
// serves, and no client, administration command or owner of another profile
// attaches to it, stops it or deletes its socket. The real bin/service.dart
// runs on the owner side.

/// A bound only: a command of a compiled service child under parallel load.
const commandBound = Duration(minutes: 2);

/// A profile's identity as its owner reports it, computed here from the data
/// path rather than through ProfilePaths.
String identityOf(String data) => sha256
    .convert(utf8.encode(canonicalProfilePath(data)))
    .toString()
    .substring(0, 24);

/// What a client of another profile reports for [endpoint].
String foreignOwner(String endpoint) =>
    'Another Open Foresight profile is serving $endpoint. Set '
    'FORESIGHT_RUNTIME for this profile.';

/// The runtime that [profile]'s endpoint record names, if it has one.
String? recordedRuntime(ProfilePaths profile) {
  final record = File('${profile.data}/.application-endpoint.json');
  if (!record.existsSync()) return null;
  return (jsonDecode(record.readAsStringSync()) as Map)['runtime'] as String;
}

/// The pid that answers status at [endpoint].
Future<int> statusPid(String endpoint) async {
  final client = await ServiceClient.connect(endpoint);
  try {
    return (await client.call('status') as Map)['pid'] as int;
  } finally {
    await client.close();
  }
}

/// An owner released before profile identity: its status has no profile_id.
Future<ServerSocket> legacyOwner(String endpoint, int ownerPid) async {
  final server = await ServerSocket.bind(
    InternetAddress(endpoint, type: InternetAddressType.unix),
    0,
  );
  server.listen((socket) {
    unawaited(socket.done.catchError((Object _) {}));
    utf8.decoder.bind(socket).transform(const LineSplitter()).listen((line) {
      final request = jsonDecode(line) as Map;
      if (request['id'] is! int) return;
      socket.writeln(
        jsonEncode({
          'id': request['id'],
          'result': {'pid': ownerPid, 'application_api_version': 1},
          'done': true,
        }),
      );
    }, onError: (Object _) {});
  });
  return server;
}

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

  /// Two profiles whose runtimes are one directory, as only an explicit
  /// FORESIGHT_RUNTIME (or the shared Linux default before D5) arranges.
  ({ProfilePaths owner, ProfilePaths other}) sharedRuntime(String prefix) {
    final directory = createServiceTestDirectorySync(prefix);
    final runtime = '${directory.path}/run';
    return (
      owner: ProfilePaths('${directory.path}/a', runtime),
      other: ProfilePaths('${directory.path}/b', runtime),
    );
  }

  /// bin/service.dart run as an administrator of [profile] would run it.
  Future<ProcessResult> serviceCommand(ProfilePaths profile, String argument) =>
      Process.run(
        Platform.resolvedExecutable,
        [build.kernel, argument],
        environment: {
          for (final entry in Platform.environment.entries)
            if (!entry.key.startsWith('FORESIGHT_')) entry.key: entry.value,
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
        },
        includeParentEnvironment: false,
      ).timeout(commandBound);

  test('status names the profile, and an owner from before profile identity '
      'is still attached (wire compatibility)', () async {
    final directory = createServiceTestDirectorySync('of-legacy-');
    final current = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final owner = await HookedServiceProcess.start(build, current);
    await owner.ready();
    final client = await ServiceClient.connect(serviceEndpoint(current));
    try {
      final status = await client.call('status') as Map;
      expect(status['pid'], owner.pid);
      expect(status['profile_id'], identityOf(current.data));
    } finally {
      await client.close();
    }
    expect(await owner.stop(), 0, reason: owner.output);

    // An owner released before this change reports no identity. A client
    // and the administration commands accept it.
    final legacy = ProfilePaths(
      '${directory.path}/legacy',
      '${directory.path}/old',
    );
    privateDirectory(legacy.runtime);
    final server = await legacyOwner('${legacy.runtime}/application.sock', 42);
    addTearDown(server.close);
    final attached = await ensureService(
      legacy,
      startupTimeout: const Duration(seconds: 30),
    );
    try {
      expect((await attached.call('status') as Map)['pid'], 42);
    } finally {
      await attached.close();
    }
    final status = await serviceCommand(legacy, '--status');
    expect(status.exitCode, 0, reason: '${status.stderr}');
    expect(jsonDecode(status.stdout as String), {
      'pid': 42,
      'application_api_version': 1,
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a data path reached through a symbolic link is the same profile: its '
      'client attaches to the owner of the canonical path', () async {
    final directory = createServiceTestDirectorySync('of-alias-');
    final canonical = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final links = createServiceTestDirectorySync('of-alias-link-');
    Link('${links.path}/profile').createSync(directory.path);
    final alias = ProfilePaths(
      '${links.path}/profile/data',
      '${links.path}/profile/run',
    );
    final owner = await HookedServiceProcess.start(build, alias);
    await owner.ready();
    // The owner canonicalizes the alias; the identity it reports is the
    // canonical path's, and a client of the alias computes the same one.
    final client = await ensureService(
      alias,
      startupTimeout: const Duration(seconds: 30),
    );
    try {
      final status = await client.call('status') as Map;
      expect(status['pid'], owner.pid);
      expect(status['profile_id'], identityOf(canonical.data));
    } finally {
      await client.close();
    }
    final reached = await ensureService(
      canonical,
      startupTimeout: const Duration(seconds: 30),
    );
    try {
      expect((await reached.call('status') as Map)['pid'], owner.pid);
    } finally {
      await reached.close();
    }
    expect(await owner.stop(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('startup never attaches to or launches over another profile\'s owner '
      '(SL-7)', () async {
    final profiles = sharedRuntime('of-foreign-');
    final owner = await HookedServiceProcess.start(build, profiles.owner);
    final launcher = await build.launcher(
      Directory(profiles.other.runtime).parent,
    );
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    await owner.ready();
    final endpoint = '${profiles.owner.runtime}/application.sock';
    // The budget only bounds the wait for the owner to go away.
    await expectLater(
      ensureService(
        profiles.other,
        startupTimeout: const Duration(seconds: 10),
      ),
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          foreignOwner(endpoint),
        ),
      ),
    );
    expect(launcher.launched, isEmpty);
    expect(await statusPid(endpoint), owner.pid);
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final cut in ['connect', 'status probe']) {
    test('startup still names another profile\'s owner when its deadline '
        'cuts a later $cut short (SL-7)', () async {
      final profiles = sharedRuntime('of-foreign-late-');
      final owner = await HookedServiceProcess.start(build, profiles.owner);
      final launcher = await build.launcher(
        Directory(profiles.other.runtime).parent,
      );
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          launcher.executable;
      await owner.ready();
      final endpoint = '${profiles.owner.runtime}/application.sock';
      Future<ServiceClient> startup() => ensureService(
        profiles.other,
        startupTimeout: const Duration(seconds: 10),
      );
      // The first attempt reaches the other profile's owner. The next one
      // runs into the deadline.
      final Future<ServiceClient> starting;
      final Future<Object?> cutShort;
      if (cut == 'connect') {
        // Every later connect times out, as one the deadline cuts short does.
        var connects = 0;
        final later = Completer<void>();
        final outer = Zone.current;
        starting = IOOverrides.runZoned(
          startup,
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) {
                if (host is InternetAddress &&
                    host.address == endpoint &&
                    ++connects > 1) {
                  if (!later.isCompleted) later.complete();
                  return Future<Socket>.error(
                    SocketException(
                      'Connection timed out',
                      osError: const OSError('Connection timed out', 110),
                      address: host,
                    ),
                  );
                }
                return outer.run(
                  () => Socket.connect(
                    host,
                    port,
                    sourceAddress: sourceAddress,
                    sourcePort: sourcePort,
                    timeout: timeout,
                  ),
                );
              },
        );
        cutShort = later.future;
      } else {
        // The second status result is never released; the deadline ends
        // that probe. An owner ends each reply with a separate done frame.
        final proxy = ServiceFaultProxy();
        addTearDown(proxy.close);
        var results = 0;
        cutShort = proxy
            .hold(
              ProxyDirection.toClient,
              where: (frame) =>
                  frame.method == 'status' &&
                  frame.json?.containsKey('result') == true &&
                  ++results == 2,
            )
            .reached;
        starting = proxy.run(startup);
      }
      await expectLater(
        starting,
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            foreignOwner(endpoint),
          ),
        ),
      );
      await cutShort;
      expect(launcher.launched, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('--status, --stop-if-idle and --stop never act on another profile\'s '
      'owner (SL-7)', () async {
    final profiles = sharedRuntime('of-foreign-cli-');
    final owner = await HookedServiceProcess.start(build, profiles.owner);
    await owner.ready();
    final endpoint = '${profiles.owner.runtime}/application.sock';
    for (final argument in ['--status', '--stop-if-idle', '--stop']) {
      final result = await serviceCommand(profiles.other, argument);
      expect(result.exitCode, 1, reason: argument);
      expect(result.stdout, isEmpty, reason: argument);
      expect(result.stderr, contains(foreignOwner(endpoint)), reason: argument);
      // The owner of the other profile is still serving.
      expect(await statusPid(endpoint), owner.pid, reason: argument);
    }
    expect(await owner.stop(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an owner starting where another profile serves never deletes its live '
      'sockets (SL-7)', () async {
    final profiles = sharedRuntime('of-live-');
    final owner = await HookedServiceProcess.start(build, profiles.owner);
    await owner.ready();
    runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
    final endpoint = '${profiles.owner.runtime}/application.sock';
    // A service without the isolate relay binds the public socket itself.
    await expectLater(
      ApplicationService.start(profiles.other),
      throwsA(
        isStateError.having(
          (error) => error.message,
          'message',
          foreignOwner(endpoint),
        ),
      ),
    );
    // An isolated service's worker binds the worker socket first.
    await expectLater(
      IsolatedApplicationService.start(profiles.other),
      throwsA(
        isStateError.having(
          (error) => error.message,
          'message',
          contains(foreignOwner('${profiles.owner.runtime}/worker.sock')),
        ),
      ),
    );
    // A new connection reaches the owner through both of its sockets.
    expect(await statusPid(endpoint), owner.pid);
    expect(
      File('${profiles.other.data}/.application-endpoint.json').existsSync(),
      isFalse,
    );
    expect(await owner.stop(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an isolated frontend never deletes another profile\'s live public '
      'socket (SL-7)', () async {
    final profiles = sharedRuntime('of-live-public-');
    runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
    // An owner without the isolate relay serves only the public socket, so
    // the other profile's worker binds its own worker socket and only its
    // frontend meets the live one.
    final owner = await ApplicationService.start(profiles.owner);
    try {
      final endpoint = '${profiles.owner.runtime}/application.sock';
      await expectLater(
        IsolatedApplicationService.start(profiles.other),
        throwsA(
          isStateError.having(
            (error) => error.message,
            'message',
            foreignOwner(endpoint),
          ),
        ),
      );
      final client = await ServiceClient.connect(endpoint);
      try {
        expect(
          (await client.call('status') as Map)['profile_id'],
          identityOf(profiles.owner.data),
        );
      } finally {
        await client.close();
      }
      // The failed worker removed its own socket and record.
      expect(
        File('${profiles.owner.runtime}/worker.sock').existsSync(),
        isFalse,
      );
      expect(
        File('${profiles.other.data}/.application-endpoint.json').existsSync(),
        isFalse,
      );
    } finally {
      await owner.close();
    }
  });

  test('an owner started with the shared Linux runtime of earlier versions is '
      'still attached, and its replacement uses the profile\'s own runtime '
      '(D5)', () async {
    final directory = createServiceTestDirectorySync('of-up-');
    final xdg = '${directory.path}/xdg';
    privateDirectory(xdg);
    final profile = ProfilePaths.resolve({
      'HOME': directory.path,
      'XDG_RUNTIME_DIR': xdg,
      'FORESIGHT_DATA': '${directory.path}/data',
    }, macOS: false);
    final shared = '$xdg/open-foresight';
    expect(
      profile.runtime,
      '$shared/${identityOf(profile.data).substring(0, 12)}',
    );
    // An earlier version served every profile from the shared default and
    // recorded that runtime.
    final earlier = await HookedServiceProcess.start(
      build,
      ProfilePaths(profile.data, shared),
    );
    await earlier.ready();
    expect(recordedRuntime(profile), shared);
    final launcher = await build.launcher(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    final attached = await ensureService(
      profile,
      startupTimeout: const Duration(seconds: 30),
    );
    try {
      expect((await attached.call('status') as Map)['pid'], earlier.pid);
    } finally {
      await attached.close();
    }
    expect(launcher.launched, isEmpty);
    // A clean exit removes the record; the next owner uses the new default.
    expect(await earlier.stop(), 0, reason: earlier.output);
    final replaced = await ensureService(profile);
    try {
      expect(
        (await replaced.call('status') as Map)['pid'],
        launcher.launched.single,
      );
    } finally {
      await replaced.close();
    }
    expect(recordedRuntime(profile), profile.runtime);
    expect(File('${profile.runtime}/application.sock').existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('--stop with an invalid endpoint record never signals another '
      'profile\'s owner at the fallback endpoint (SL-7)', () async {
    final profiles = sharedRuntime('of-foreign-record-');
    final owner = await HookedServiceProcess.start(build, profiles.owner);
    await owner.ready();
    // An invalid record falls back to the profile's own runtime, which the
    // other profile's owner serves.
    privateDirectory(profiles.other.data);
    final record = File('${profiles.other.data}/.application-endpoint.json')
      ..writeAsStringSync('{"data":');
    protectPrivateFile(record.path);
    final endpoint = '${profiles.owner.runtime}/application.sock';
    final result = await serviceCommand(profiles.other, '--stop');
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      allOf(
        contains('${record.path} was ignored because it is not valid JSON'),
        contains(foreignOwner(endpoint)),
      ),
    );
    expect(await statusPid(endpoint), owner.pid);
    expect(await owner.stop(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  /// A desktop facade for [profile], closed with everything it opened at the
  /// end of the test.
  Future<RemoteDomain> desktop(Future<RemoteDomain> connecting) async {
    final domain = await connecting;
    addTearDown(() async {
      domain.close();
      domain.store.close();
      await domain.helper.close();
    });
    return domain;
  }

  test('the desktop names the helper beside the endpoint it connected to, '
      'not one the record names afterwards (L9)', () async {
    final directory = createServiceTestDirectorySync('of-helper-');
    final data = '${directory.path}/data';
    final owner = await HookedServiceProcess.start(
      build,
      ProfilePaths(data, '${directory.path}/own'),
    );
    await owner.ready();
    // The desktop's own runtime differs; only the record names the owner's.
    final profile = ProfilePaths(data, '${directory.path}/run');
    final record = File('$data/.application-endpoint.json');
    final proxy = ServiceFaultProxy();
    addTearDown(proxy.close);
    final probed = proxy.hold(ProxyDirection.toClient, method: 'status');
    final connecting = proxy.run(() => RemoteDomain.connect(profile));
    // The startup probe has reached the owner through the record. Before the
    // desktop goes on, the record stops naming that runtime, as when an
    // owner hands over.
    await probed.reached;
    record.renameSync('${record.path}.held');
    probed.release();
    final domain = await desktop(connecting);
    expect(domain.helper.socket, '${directory.path}/own/helper.sock');
    File('${record.path}.held').renameSync(record.path);
    expect(await owner.stop(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a desktop reconnecting to an owner in another runtime names that '
      'owner\'s helper (L9)', () async {
    final directory = createServiceTestDirectorySync('of-moved-');
    final data = '${directory.path}/data';
    final first = await HookedServiceProcess.start(
      build,
      ProfilePaths(data, '${directory.path}/own'),
    );
    await first.ready();
    final launcher = await build.launcher(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    // The replacement starts in the desktop's own runtime.
    final profile = ProfilePaths(data, '${directory.path}/run');
    final domain = await desktop(RemoteDomain.connect(profile));
    expect(domain.helper.socket, '${directory.path}/own/helper.sock');
    expect(await first.stop(), 0, reason: first.output);
    // The request waits for the reconnect, which launches the replacement.
    final status = await domain.command(Operation.status) as Map;
    expect(status['pid'], launcher.launched.single);
    expect(domain.helper.socket, '${profile.runtime}/helper.sock');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
