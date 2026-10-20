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

/// What a profile reports when another profile's service (pid [pid])
/// serves [endpoint] in the runtime both profiles use.
String sharedRuntimeRefusal(String endpoint, {int? pid}) =>
    "Another Open Foresight profile's service"
    "${pid == null ? '' : ' (pid $pid)'} serves $endpoint: both profiles use "
    'runtime ${File(endpoint).parent.path}. Give this profile its own '
    'FORESIGHT_RUNTIME, or unset it.';

/// What [profile] reports when its endpoint record names the runtime of
/// [endpoint], where another profile's service (pid [pid]) serves.
String staleRecordRefusal(ProfilePaths profile, String endpoint, int pid) =>
    'The endpoint record ${profile.data}/.application-endpoint.json names '
    'runtime ${File(endpoint).parent.path}, where another Open Foresight '
    "profile's service (pid $pid) serves. Starting this profile's service "
    'replaces the record.';

/// The dedicated refusal of another profile's service, matched by name so
/// this file also runs against code that predates it.
final refusedForAnotherProfile = isStateError.having(
  (error) => error.runtimeType.toString(),
  'type',
  'AnotherProfileServing',
);

/// Hold [profile]'s ownership lock from another process, as every released
/// owner does, until the test ends.
Future<void> holdProfileLock(ProfilePaths profile) async {
  privateDirectory(profile.data);
  final holder = await Process.start('python3', [
    '-c',
    'import fcntl,sys\nf=open(sys.argv[1],"a")\n'
        'fcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\n'
        'sys.stdin.read()',
    '${profile.data}/.application.lock',
  ]);
  addTearDown(() async {
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode;
  });
  expect(
    await utf8.decoder
        .bind(holder.stdout)
        .transform(const LineSplitter())
        .first,
    'locked',
  );
}

/// Write the endpoint record a crashed owner of [profile] leaves, naming
/// [runtime].
void writeCrashRecord(ProfilePaths profile, String runtime) {
  privateDirectory(profile.data);
  final record = File('${profile.data}/.application-endpoint.json')
    ..writeAsStringSync(jsonEncode({'data': profile.data, 'runtime': runtime}));
  protectPrivateFile(record.path);
}

/// The endpoint records an owner of [profile] set aside.
List<String> quarantinedRecords(ProfilePaths profile) => [
  for (final entry in Directory(profile.data).listSync())
    if (entry.path.contains('.application-endpoint.json.invalid-')) entry.path,
];

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

/// What the listener at [path] answers.
Future<String> answerAt(String path) async {
  final client = await Socket.connect(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  try {
    return await client.cast<List<int>>().transform(utf8.decoder).join();
  } finally {
    client.destroy();
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

    // An owner released before this change reports no identity. While it
    // holds this profile's lock, as every released owner does, a client and
    // the administration commands accept it.
    final legacy = ProfilePaths(
      '${directory.path}/legacy',
      '${directory.path}/old',
    );
    await holdProfileLock(legacy);
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
    // It fails at once, within the whole startup budget: a service that
    // answers status is not closing and does not go away by waiting (Q3).
    await expectLater(
      ensureService(profiles.other).timeout(const Duration(seconds: 60)),
      throwsA(
        refusedForAnotherProfile.having(
          (error) => error.message,
          'message',
          sharedRuntimeRefusal(endpoint, pid: owner.pid),
        ),
      ),
    );
    expect(launcher.launched, isEmpty);
    expect(await statusPid(endpoint), owner.pid);
  }, timeout: const Timeout(Duration(minutes: 3)));

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
      expect(
        result.stderr,
        contains(sharedRuntimeRefusal(endpoint, pid: owner.pid)),
        reason: argument,
      );
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
        refusedForAnotherProfile.having(
          (error) => error.message,
          'message',
          sharedRuntimeRefusal(endpoint),
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
          contains(
            sharedRuntimeRefusal('${profiles.owner.runtime}/worker.sock'),
          ),
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

  test('an owner never deletes a socket whose state a connect cannot tell '
      '(N1)', () async {
    final root = Process.runSync('/usr/bin/id', ['-u']).stdout.toString();
    if (root.trim() == '0') {
      markTestSkipped('root may connect to any socket');
      return;
    }
    final directory = createServiceTestDirectorySync('of-unknown-');
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    privateDirectory(profile.runtime);
    final path = '${profile.runtime}/application.sock';
    // Connecting fails with EACCES, which says nothing about whether a
    // service listens there.
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    addTearDown(server.close);
    expect(Process.runSync('/bin/chmod', ['000', path]).exitCode, 0);
    runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
    await expectLater(
      ApplicationService.start(profile),
      throwsA(
        isStateError.having(
          (error) => error.message,
          'message',
          contains('it was not removed'),
        ),
      ),
    );
    expect(
      FileSystemEntity.typeSync(path, followLinks: false),
      FileSystemEntityType.unixDomainSock,
    );
  });

  test('a closing owner never removes a socket published at its path after '
      'its listener closed (S3)', () async {
    final directory = createServiceTestDirectorySync('of-teardown-');
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final gates = await ServiceGates.create(directory);
    runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
    runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
        gates.directory.path;
    gates.hold('close.listener_closed');
    final owner = await ApplicationService.start(profile);
    final path = '${profile.runtime}/application.sock';
    final closing = owner.close();
    await gates.reached('close.listener_closed');
    // Another profile's owner sharing the runtime publishes where the closed
    // listener's socket was.
    final bound = '${profile.runtime}/.other';
    final other = await ServerSocket.bind(
      InternetAddress(bound, type: InternetAddressType.unix),
      0,
    );
    addTearDown(other.close);
    other.listen((socket) async {
      socket.write('other');
      await socket.flush();
      socket.destroy();
    });
    File(bound).renameSync(path);
    gates.release('close.listener_closed');
    await closing.timeout(const Duration(seconds: 60));
    expect(await answerAt(path), 'other');
  });

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
          refusedForAnotherProfile.having(
            (error) => error.message,
            'message',
            sharedRuntimeRefusal(endpoint),
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
        contains(sharedRuntimeRefusal(endpoint, pid: owner.pid)),
      ),
    );
    expect(await statusPid(endpoint), owner.pid);
    expect(await owner.stop(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a profile is refused at once while another profile\'s service shares '
      'its runtime, and starts its own once that service stops listening '
      '(SL-7)', () async {
    final profiles = sharedRuntime('of-gone-');
    final owner = await HookedServiceProcess.start(
      build,
      profiles.owner,
      hold: ['frontend.listener_closed'],
    );
    final launcher = await build.launcher(
      Directory(profiles.other.runtime).parent,
    );
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    await owner.ready();
    final endpoint = '${profiles.owner.runtime}/application.sock';
    await expectLater(
      ensureService(profiles.other).timeout(const Duration(seconds: 60)),
      throwsA(refusedForAnotherProfile),
    );
    owner.signal(ProcessSignal.sigterm);
    // Its listener is closed and its socket still there, so a connect is
    // refused (ECONNREFUSED).
    await owner.reached('frontend.listener_closed');
    final client = await ensureService(profiles.other);
    try {
      final status = await client.call('status') as Map;
      expect(status['pid'], launcher.launched.single);
      expect(status['profile_id'], identityOf(profiles.other.data));
    } finally {
      await client.close();
    }
    owner.release('frontend.listener_closed');
    expect(await owner.exited(), 0, reason: owner.output);
    // The closing service left the new one's socket alone.
    expect(await statusPid(endpoint), launcher.launched.single);
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final lockFile in [true, false]) {
    test('a profile that meets another profile\'s closing service in its '
        'runtime ${lockFile ? 'starts its own once it is gone' : 'and has '
                  'no lock file is refused with the reason'} (SL-7)', () async {
      final profiles = sharedRuntime('of-closing-');
      final owner = await HookedServiceProcess.start(
        build,
        profiles.owner,
        hold: ['close.helper_closed'],
      );
      final launcher = await build.launcher(
        Directory(profiles.other.runtime).parent,
      );
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          launcher.executable;
      await owner.ready();
      final endpoint = '${profiles.owner.runtime}/application.sock';
      if (lockFile) {
        // An earlier owner of this profile left its lock file.
        privateDirectory(profiles.other.data);
        final lock = File('${profiles.other.data}/.application.lock')
          ..writeAsStringSync('');
        protectPrivateFile(lock.path);
      }
      owner.signal(ProcessSignal.sigterm);
      await owner.reached('close.helper_closed');
      final proxy = ServiceFaultProxy();
      addTearDown(proxy.close);
      // A closing refusal says nothing about whose service it is.
      final refused = proxy.seen(
        ProxyDirection.toClient,
        where: (frame) => frame.error?['reason'] == 'closing',
      );
      final startup = proxy.run(() => ensureService(profiles.other));
      await refused;
      owner.release('close.helper_closed');
      if (lockFile) {
        final client = await startup.timeout(const Duration(seconds: 120));
        try {
          final status = await client.call('status') as Map;
          expect(status['pid'], launcher.launched.single);
          expect(status['profile_id'], identityOf(profiles.other.data));
        } finally {
          await client.close();
        }
        expect(await owner.exited(), 0, reason: owner.output);
        expect(await statusPid(endpoint), launcher.launched.single);
      } else {
        await expectLater(
          startup,
          throwsA(
            refusedForAnotherProfile.having(
              (error) => error.message,
              'message',
              allOf(
                contains('does not own this profile'),
                contains('Give this profile its own FORESIGHT_RUNTIME'),
              ),
            ),
          ),
        );
        expect(launcher.launched, isEmpty);
        expect(await owner.exited(), 0, reason: owner.output);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('a crash record naming a runtime another profile\'s service now uses '
      'is replaced by this profile\'s own service (S1)', () async {
    final directory = createServiceTestDirectorySync('of-stale-');
    final shared = '${directory.path}/run';
    final other = ProfilePaths('${directory.path}/a', shared);
    final profile = ProfilePaths(
      '${directory.path}/b',
      '${directory.path}/own',
    );
    final owner = await HookedServiceProcess.start(build, other);
    await owner.ready();
    final endpoint = '$shared/application.sock';
    writeCrashRecord(profile, shared);
    // The administration commands name the record, not a shared runtime.
    final status = await serviceCommand(profile, '--status');
    expect(status.exitCode, 1);
    expect(
      status.stderr,
      contains(staleRecordRefusal(profile, endpoint, owner.pid)),
    );
    // A client never attaches there. This profile's lock is free, so it
    // starts this profile's service, which sets the record aside and serves
    // from its own runtime.
    final launcher = await build.launcher(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    final client = await ensureService(
      profile,
      startupTimeout: const Duration(seconds: 60),
    );
    try {
      final reply = await client.call('status') as Map;
      expect(reply['pid'], launcher.launched.single);
      expect(reply['profile_id'], identityOf(profile.data));
    } finally {
      await client.close();
    }
    expect(recordedRuntime(profile), profile.runtime);
    expect(quarantinedRecords(profile), hasLength(1));
    expect(await statusPid(endpoint), owner.pid);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an owner never adopts a recorded runtime another profile\'s service '
      'uses, and starts in its own (S1)', () async {
    final directory = createServiceTestDirectorySync('of-adopt-');
    final shared = '${directory.path}/run';
    final other = ProfilePaths('${directory.path}/a', shared);
    final profile = ProfilePaths(
      '${directory.path}/b',
      '${directory.path}/own',
    );
    final owner = await HookedServiceProcess.start(build, other);
    await owner.ready();
    writeCrashRecord(profile, shared);
    runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
    final service = await ApplicationService.start(profile);
    try {
      expect(service.path, '${profile.runtime}/application.sock');
      expect(recordedRuntime(profile), profile.runtime);
      expect(quarantinedRecords(profile), hasLength(1));
      expect(await statusPid('$shared/application.sock'), owner.pid);
    } finally {
      await service.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a service without profile_id is another profile\'s unless this '
      'profile\'s lock is held (S4)', () async {
    final directory = createServiceTestDirectorySync('of-older-');
    // An owner released before profile identity serves the shared runtime
    // of earlier versions and holds its own profile's lock.
    final shared = '${directory.path}/old';
    final older = ProfilePaths('${directory.path}/a', shared);
    await holdProfileLock(older);
    final process = await Process.start('sleep', ['600']);
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    privateDirectory(shared);
    final server = await legacyOwner('$shared/application.sock', process.pid);
    addTearDown(server.close);
    final endpoint = '$shared/application.sock';
    // This profile's crash record still names that runtime.
    final profile = ProfilePaths(
      '${directory.path}/b',
      '${directory.path}/own',
    );
    writeCrashRecord(profile, shared);
    final stop = await serviceCommand(profile, '--stop');
    expect(stop.exitCode, 1);
    expect(
      stop.stderr,
      contains(staleRecordRefusal(profile, endpoint, process.pid)),
    );
    expect(await isRunning(process.pid), isTrue);
    // This profile's new owner holds its lock before it sets the record
    // aside. Meanwhile the older service must stay refused.
    final gates = await ServiceGates.create(directory);
    gates.hold('start.locked');
    final launcher = await build.launcher(directory, gates: gates);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    final proxy = ServiceFaultProxy();
    addTearDown(proxy.close);
    final starting = proxy.run(
      () => ensureService(profile, startupTimeout: const Duration(seconds: 90)),
    );
    await gates.reached('start.locked');
    // Two more probes of the older service while this profile's lock is
    // held, and no attach to it.
    final observed = await Future.any([
      proxy
          .seen(
            ProxyDirection.toClient,
            where: (frame) => frame.json?.containsKey('result') == true,
            count: 2,
          )
          .then((_) => 'probed twice'),
      starting.then((client) async {
        final attached = (await client.call('status') as Map)['pid'];
        await client.close();
        return 'attached to $attached';
      }),
    ]);
    expect(observed, 'probed twice');
    gates.release('start.locked');
    final client = await starting;
    try {
      final reply = await client.call('status') as Map;
      expect(reply['pid'], launcher.launched.single);
      expect(reply['profile_id'], identityOf(profile.data));
    } finally {
      await client.close();
    }
    expect(recordedRuntime(profile), profile.runtime);
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
