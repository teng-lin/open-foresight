import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:test/test.dart';

// `bin/service.dart --stop` against owners that are already stopping, and
// against an owner released before profile identity, which ends its
// connections at SIGTERM and only then finalizes.

/// A running `--stop`, with its stderr lines as they arrive.
class StopRun {
  StopRun(this.process) {
    unawaited(process.stdout.drain<void>());
    final ended = Completer<void>();
    utf8.decoder
        .bind(process.stderr)
        .transform(const LineSplitter())
        .listen(lines.add, onDone: ended.complete);
    _ended = ended.future;
  }

  final Process process;
  final lines = <String>[];
  late final Future<void> _ended;

  /// The first stderr line containing [text]; fails if stderr ends first.
  Future<String> line(String text) async {
    final waited = Stopwatch()..start();
    var ended = false;
    unawaited(_ended.then((_) => ended = true));
    while (waited.elapsed < const Duration(seconds: 120)) {
      for (final line in lines) {
        if (line.contains(text)) return line;
      }
      if (ended) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('stderr has no "$text":\n${lines.join('\n')}');
  }

  /// The exit code, with all of stderr read; a bound only.
  Future<int> exited() async {
    final code = await process.exitCode.timeout(const Duration(seconds: 120));
    await _ended;
    return code;
  }
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

/// An owner released before profile identity (v0.1.x): it holds the
/// profile lock, answers status without profile_id, and at SIGTERM ends its
/// connections at once, then keeps the lock for [finalizing] while it
/// finalizes a recording.
Future<Process> releasedOwner(
  ProfilePaths profile, {
  required Duration finalizing,
}) async {
  privateDirectory(profile.data);
  privateDirectory(profile.runtime);
  final owner = await Process.start('python3', [
    '-c',
    r'''
import fcntl, json, os, signal, socket, sys, threading, time
lock_path, endpoint, finalizing = sys.argv[1], sys.argv[2], float(sys.argv[3])
lock = open(lock_path, "a")
fcntl.lockf(lock, fcntl.LOCK_EX)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(endpoint)
server.listen()
peers = []
def serve(peer):
    pending = b""
    try:
        while True:
            chunk = peer.recv(65536)
            if not chunk:
                return
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                request = json.loads(line)
                if isinstance(request.get("id"), int):
                    reply = {"id": request["id"], "done": True, "result": {
                        "pid": os.getpid(), "application_api_version": 1}}
                    peer.sendall((json.dumps(reply) + "\n").encode())
    except OSError:
        return
def stop(*_):
    for peer in peers:
        try:
            peer.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        peer.close()
    server.close()
    os.unlink(endpoint)
    print("finalizing", flush=True)
    time.sleep(finalizing)
    os._exit(0)
signal.signal(signal.SIGTERM, stop)
print("ready", flush=True)
while True:
    peer, _ = server.accept()
    peers.append(peer)
    threading.Thread(target=serve, args=(peer,), daemon=True).start()
''',
    '${profile.data}/.application.lock',
    '${profile.runtime}/application.sock',
    '${finalizing.inMilliseconds / 1000}',
  ]);
  addTearDown(() => owner.kill(ProcessSignal.sigkill));
  final output = StreamIterator(
    utf8.decoder.bind(owner.stdout).transform(const LineSplitter()),
  );
  expect(await output.moveNext(), isTrue);
  expect(output.current, 'ready');
  unawaited(() async {
    while (await output.moveNext()) {}
  }());
  return owner;
}

void main() {
  late HookedServiceBuild build;
  setUpAll(() async => build = await HookedServiceBuild.compile());
  tearDownAll(() => build.dispose());

  ProfilePaths newProfile(String prefix) {
    final directory = createServiceTestDirectorySync(prefix);
    return ProfilePaths('${directory.path}/data', '${directory.path}/run');
  }

  /// `bin/service.dart --stop` for [profile], with service traces on.
  Future<StopRun> startStop(
    ProfilePaths profile, {
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [build.kernel, '--stop'],
      environment: {
        for (final entry in Platform.environment.entries)
          if (!entry.key.startsWith('FORESIGHT_') ||
              entry.key == 'FORESIGHT_SQLITE_LIBRARY')
            entry.key: entry.value,
        'FORESIGHT_DATA': profile.data,
        'FORESIGHT_RUNTIME': profile.runtime,
        'FORESIGHT_SERVICE_TRACE': '1',
        ...environment,
      },
      includeParentEnvironment: false,
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    return StopRun(process);
  }

  test('--status run in another pid namespace than this profile\'s older '
      'owner says it cannot verify that owner', () async {
    if (!Platform.isLinux) {
      markTestSkipped('unshare and /proc/locks are Linux only');
      return;
    }
    // A user and pid namespace with its own /proc, as in a sandbox. The
    // kernel leaves the owner, outside it, out of that /proc/locks.
    final ProcessResult probe;
    try {
      probe = await Process.run('unshare', ['-Urpf', '--mount-proc', 'true']);
    } on ProcessException catch (error) {
      markTestSkipped('unshare is not installed here: $error');
      return;
    }
    if (probe.exitCode != 0) {
      markTestSkipped('unshare is not permitted here: ${probe.stderr}');
      return;
    }
    final profile = newProfile('of-namespace-');
    final owner = await releasedOwner(
      profile,
      finalizing: const Duration(seconds: 1),
    );
    final status = await Process.run(
      'unshare',
      [
        '-Urpf',
        '--mount-proc',
        Platform.resolvedExecutable,
        build.kernel,
        '--status',
      ],
      environment: {
        for (final entry in Platform.environment.entries)
          if (!entry.key.startsWith('FORESIGHT_') ||
              entry.key == 'FORESIGHT_SQLITE_LIBRARY')
            entry.key: entry.value,
        'FORESIGHT_DATA': profile.data,
        'FORESIGHT_RUNTIME': profile.runtime,
      },
      includeParentEnvironment: false,
    ).timeout(const Duration(seconds: 120));
    expect(status.exitCode, 1, reason: '${status.stdout}${status.stderr}');
    expect(
      status.stderr,
      contains(
        'Cannot verify the running older Open Foresight service (pid '
        '${owner.pid}) for this profile; stop it with its own --stop, then '
        'retry.',
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    '--stop waits past the release bound of a current owner for a '
    'released owner, which finalizes after it ends its connections',
    () async {
      final profile = newProfile('of-released-');
      final owner = await releasedOwner(
        profile,
        finalizing: const Duration(seconds: 2),
      );
      // The bound for a current owner is 200 ms here: ten times shorter than
      // the released owner's finalization.
      final stop = await startStop(
        profile,
        environment: {'FORESIGHT_TEST_STOP_RELEASE_MS': '200'},
      );
      expect(await stop.exited(), 0, reason: stop.lines.join('\n'));
      expect(
        stop.lines,
        contains(
          'Waiting for the application service (pid ${owner.pid}) to release '
          'its profile.',
        ),
      );
      // It returned only once the owner had released the profile.
      expect(lockHeld(profile), isFalse);
      expect(stop.lines.join('\n'), isNot(contains('did not release')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '--stop against an owner that removed its socket but still holds its '
    'profile waits for it to release the profile instead of failing',
    () async {
      final profile = newProfile('of-unlisted-');
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['close.before_record_delete'],
      );
      await owner.ready();
      owner.signal(ProcessSignal.sigterm);
      // Its sockets are gone; its endpoint record and lock remain.
      await owner.reached('close.before_record_delete');
      expect(File('${profile.runtime}/application.sock').existsSync(), isFalse);
      expect(lockHeld(profile), isTrue);
      final stop = await startStop(profile);
      var exited = false;
      unawaited(stop.process.exitCode.then((_) => exited = true));
      await stop.line('The application service is already stopping.');
      await stop.line(
        'Waiting for the application service to release its profile.',
      );
      expect(exited, isFalse);
      owner.release('close.before_record_delete');
      expect(await stop.exited(), 0, reason: stop.lines.join('\n'));
      expect(await owner.exited(), 0, reason: owner.output);
      expect(lockHeld(profile), isFalse);
      expect(stop.lines.join('\n'), isNot(contains('clean shutdown')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('--stop against an owner that is already stopping waits for it to '
      'release its profile instead of failing', () async {
    final profile = newProfile('of-draining-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.begin', 'close.before_lock_release'],
    );
    await owner.ready();
    owner.signal(ProcessSignal.sigterm);
    // The owner is draining: it refuses every new connection's requests.
    await owner.reached('close.begin');
    final stop = await startStop(profile);
    var exited = false;
    unawaited(stop.process.exitCode.then((_) => exited = true));
    await stop.line('The application service is already stopping.');
    owner.release('close.begin');
    await owner.reached('close.before_lock_release');
    // Its connection ended; the owner still holds its profile.
    await stop.line('still holds its profile');
    expect(exited, isFalse);
    owner.release('close.before_lock_release');
    expect(await stop.exited(), 0, reason: stop.lines.join('\n'));
    expect(
      stop.lines,
      contains('Waiting for the application service to release its profile.'),
    );
    expect(await owner.exited(), 0, reason: owner.output);
    expect(lockHeld(profile), isFalse);
    // A clean shutdown gets no warning.
    expect(stop.lines.join('\n'), isNot(contains('clean shutdown')));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
