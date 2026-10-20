import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const closingMessage =
    'Application service is shutting down; retry after it exits.';

// A real separate owner holds the same OS lock as the application service.
// Its socket can close before that owner releases the lock, as in production.
const ownerSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
// Concurrent replacements append to shared logs. FileMode.append seeks to the
// end at open rather than using O_APPEND, so serialize each append.
void appendLine(String path, String line) {
  final log = File(path).openSync(mode: FileMode.append);
  try {
    log.lockSync(FileLock.blockingExclusive);
    log.setPositionSync(log.lengthSync());
    log.writeStringSync('$line\n');
  } finally {
    log.closeSync();
  }
}
Future<void> main() async {
  final data = Platform.environment['FORESIGHT_DATA']!;
  final runtime = Platform.environment['FORESIGHT_RUNTIME']!;
  final old = Platform.environment['OLD_OWNER'] == '1';
  if (!old) {
    appendLine('$data/launches', 'launch');
    appendLine('$data/launched-pids', '$pid');
    // A test may hold replacements before they contend for the lock.
    if (Platform.environment['REPLACEMENT_GATE'] == '1') {
      while (!File('$data/replacement.go').existsSync()) {
        sleep(const Duration(milliseconds: 5));
      }
    }
  }
  final lock = File('$data/.application.lock').openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
  } on FileSystemException catch (error) {
    // Concurrent launchers may start two replacements; only the one that
    // loses lock contention (EAGAIN on Linux or macOS, or EACCES) exits.
    final code = error.osError?.errorCode;
    if (old || (code != 11 && code != 13 && code != 35)) rethrow;
    appendLine('$data/lost-launches', '$pid');
    exit(3);
  }
  if (!old) File('$data/replacement.pid').writeAsStringSync('$pid');
  final endpoint = File('$data/.application-endpoint.json');
  // Publish the record atomically, as production does.
  File('${endpoint.path}.$pid')
    ..writeAsStringSync(jsonEncode({'data': data, 'runtime': runtime}))
    ..renameSync(endpoint.path);
  final path = '$runtime/application.sock';
  final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
  if (!old) File('$data/replacement.ready').writeAsStringSync('$pid');
  final peers = <Socket>[];
  final stopped = Completer<void>();
  void stop() { if (!stopped.isCompleted) stopped.complete(); }
  final control = old ? null : Timer.periodic(const Duration(milliseconds: 10), (_) {
    if (File('$data/replacement.stop').existsSync()) stop();
  });
  var observedEof = false;
  server.listen((socket) {
    peers.add(socket);
    if (old && Platform.environment['ERROR_MESSAGE'] == 'malformed-push') {
      socket.writeln('not-json');
      unawaited(socket.flush().then((_) => stdout.writeln('malformed-sent')));
    }
    unawaited(socket.done.catchError((Object _) {}));
    socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final request = jsonDecode(line) as Map;
      if (old && Platform.environment['ERROR_MESSAGE'] == 'malformed') {
        socket.writeln('not-json');
        return;
      }
      if (old && Platform.environment['ERROR_MESSAGE'] == 'eof') {
        socket.destroy();
        if (!observedEof) { stdout.writeln('eof-observed'); observedEof = true; }
        return;
      }
      if (old && Platform.environment['ERROR_MESSAGE'] == 'stall') {
        stdout.writeln('closing-observed');
        return;
      }
      if (old || Platform.environment['REPLACEMENT_CLOSING'] == '1') {
        socket.writeln(jsonEncode({'id': request['id'], 'error': {'code': 'unavailable', 'message': Platform.environment['ERROR_MESSAGE'] ?? 'Application service is shutting down; retry after it exits.'}, 'done': true}));
        if (old) { stdout.writeln('closing-observed'); }
        else { unawaited(socket.flush().then((_) {
          File('$data/closing-replied').writeAsStringSync(jsonEncode({'pid': pid, 'method': request['method'], 'message': 'Application service is shutting down; retry after it exits.'}));
        })); }
      } else {
        File('$data/requests').writeAsStringSync('${request['method']}\n', mode: FileMode.append);
        socket.writeln(jsonEncode({'id': request['id'], 'result': {'pid': pid, 'application_api_version': 1, 'runtime_revision': 'fixture-revision', 'installation_root': Directory(data).resolveSymbolicLinksSync()}, 'done': true}));
        if (request['method'] == 'fixture.stop') unawaited(socket.flush().then((_) => stop()));
      }
    }, onError: (Object _) {}, onDone: () {
      if (old && Platform.environment['ERROR_MESSAGE'] == 'stall') stdout.writeln('peer-closed');
    });
  });
  if (old) {
    stdout.writeln('ready');
    await for (final command in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (command == 'close-socket' || command == 'release') {
        for (final socket in peers) { socket.destroy(); }
        await server.close();
        if (File(path).existsSync()) File(path).deleteSync();
        if (command == 'close-socket') stdout.writeln('socket-closed');
      }
      if (command == 'release') break;
    }
  } else {
    await stopped.future;
    for (final socket in peers) { socket.destroy(); }
    await server.close();
    if (File(path).existsSync()) File(path).deleteSync();
  }
  control?.cancel();
  if (Platform.environment['KEEP_ENDPOINT'] != '1') endpoint.deleteSync();
  lock.closeSync();
  if (!old) File('$data/replacement.closed').writeAsStringSync('$pid');
}
''';

// Delete the real record exactly at read time, after the production type check.
// Other files still use dart:io's real implementation through the base override.
class EndpointDeletionOverrides extends IOOverrides {
  final File record;
  bool deleted = false;
  EndpointDeletionOverrides(this.record);

  @override
  File createFile(String path) => path == record.path
      ? EndpointDeletingFile(record, () => deleted = true)
      : super.createFile(path);
}

class EndpointDeletingFile implements File {
  final File delegate;
  final void Function() onDelete;
  EndpointDeletingFile(this.delegate, this.onDelete);
  @override
  String get path => delegate.path;
  @override
  bool existsSync() => delegate.existsSync();
  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    delegate.deleteSync();
    onDelete();
    return delegate.readAsStringSync(encoding: encoding);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class HandoffFixture {
  final environment = Map.of(runtimeConfiguration.environment);
  late Directory root;
  late ProfilePaths profile;
  late Process old;
  late StreamIterator<String> messages;
  late Future<String> errors;
  Future<ServiceClient>? pending;
  ServiceClient? client;
  bool released = false;

  Future<void> start({
    String errorMessage = closingMessage,
    bool keepEndpoint = false,
  }) async {
    root = await createPrivateTempDirectory(shortTestTempRoot, 'of-handoff-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    final owner = File('${root.path}/owner.dart')
      ..writeAsStringSync(ownerSource);
    final launcher = File('${root.path}/launch')
      ..writeAsStringSync('#!${Platform.resolvedExecutable}\n$ownerSource');
    expect(
      (await Process.run('/bin/chmod', ['700', launcher.path])).exitCode,
      0,
    );
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.path;
    runtimeConfiguration.environment['FORESIGHT_RUNTIME_REVISION'] =
        'fixture-revision';
    runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = profile.data;
    old = await Process.start(
      Platform.resolvedExecutable,
      [owner.path],
      environment: {
        'FORESIGHT_DATA': profile.data,
        'FORESIGHT_RUNTIME': profile.runtime,
        'OLD_OWNER': '1',
        'ERROR_MESSAGE': errorMessage,
        'KEEP_ENDPOINT': keepEndpoint ? '1' : '0',
      },
    );
    messages = StreamIterator(
      old.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    errors = old.stderr.transform(utf8.decoder).join();
    await next('ready');
  }

  Future<void> next(String message) async {
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    expect(messages.current, message);
  }

  Future<ServiceClient> connect({
    Duration startupTimeout = const Duration(minutes: 3),
  }) => pending = ensureService(
    profile,
    startupTimeout: startupTimeout,
  ).then((value) => client = value);

  Future<void> closeSocket() async {
    old.stdin.writeln('close-socket');
    await next('socket-closed');
  }

  bool get launched => File('${profile.data}/launches').existsSync();

  Future<void> release() async {
    if (released) return;
    released = true;
    old.stdin.writeln('release');
    await old.stdin.close();
    expect(
      await old.exitCode.timeout(const Duration(seconds: 5)),
      0,
      reason: await errors,
    );
  }

  Future<bool> replacementRunning(int pid) async {
    final result = await Process.run('/bin/ps', ['-p', '$pid', '-o', 'stat=']);
    return result.exitCode == 0 &&
        result.stdout.toString().trim().isNotEmpty &&
        !result.stdout.toString().trim().startsWith('Z');
  }

  Future<void> close() async {
    try {
      await release();
      try {
        await pending;
      } catch (_) {
        /* Expected startup failures are asserted by the caller. */
      }
      // This control path also stops a replacement whose startup status failed,
      // for which ensureService never returned a client to the test.
      File('${profile.data}/replacement.stop').writeAsStringSync('stop');
      File('${profile.data}/replacement.go').writeAsStringSync('go');
      await client?.close();
      if (launched) {
        final marker = File('${profile.data}/replacement.pid');
        await eventually(
          marker.existsSync,
          timeout: const Duration(seconds: 15),
        );
        final replacementPid = int.parse(marker.readAsStringSync());
        await eventually(
          () async => !await replacementRunning(replacementPid),
          timeout: const Duration(seconds: 15),
        );
        expect(
          File('${profile.data}/replacement.closed').readAsStringSync(),
          '$replacementPid',
        );
        // Concurrent launchers may also have started a losing replacement.
        for (final line in File(
          '${profile.data}/launched-pids',
        ).readAsLinesSync()) {
          final launchedPid = int.parse(line);
          await eventually(
            () async => !await replacementRunning(launchedPid),
            timeout: const Duration(seconds: 15),
          );
        }
        expect(
          File('${profile.runtime}/application.sock').existsSync(),
          isFalse,
        );
        expect(
          File('${profile.data}/.application-endpoint.json').existsSync(),
          isFalse,
        );
      }
      await messages.cancel();
    } finally {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    }
    // Never remove a running child's executable or owned resources.
    root.deleteSync(recursive: true);
  }
}

void main() {
  test(
    'desktop startup joins the closing owner before one replacement launch',
    () async {
      final f = HandoffFixture();
      await f.start();
      try {
        final pending = f.connect();
        final success = expectLater(pending, completes);
        await f.next('closing-observed');
        expect(f.launched, isFalse);
        await f.closeSocket();
        // Observe that startup remains pending while the socket has closed but
        // the controlled old process still owns the real profile lock.
        await expectLater(
          pending.timeout(const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()),
        );
        expect(f.launched, isFalse);
        await f.release();
        final client = await pending.timeout(const Duration(seconds: 5));
        await success;
        expect((await client.call('status') as Map)['pid'], isNot(f.old.pid));
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
        expect(
          File('${f.profile.data}/requests').readAsLinesSync(),
          everyElement('status'),
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'EOF before status waits for the real owner lock before one launch',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'eof');
      try {
        final pending = f.connect();
        final success = expectLater(pending, completes);
        await f.next('eof-observed');
        await expectLater(
          pending.timeout(const Duration(milliseconds: 150)),
          throwsA(isA<TimeoutException>()),
        );
        expect(f.launched, isFalse);
        expect(
          File('${f.profile.data}/.application-endpoint.json').existsSync(),
          isTrue,
        );
        await f.release();
        final client = await pending.timeout(const Duration(seconds: 15));
        await success;
        expect((await client.call('status') as Map)['pid'], isNot(f.old.pid));
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
        expect(
          File('${f.profile.data}/requests').readAsLinesSync(),
          everyElement('status'),
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'a stalled startup status probe times out and closes its client',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'stall');
      try {
        final failure = expectLater(
          f.connect(startupTimeout: const Duration(milliseconds: 500)),
          throwsA(isA<TimeoutException>()),
        );
        await f.next('closing-observed');
        await failure;
        await f.next('peer-closed');
        expect(f.launched, isFalse);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'a closing post-launch owner remains bounded without another launch',
    () async {
      final f = HandoffFixture();
      await f.start();
      try {
        await f.release();
        runtimeConfiguration.environment['REPLACEMENT_CLOSING'] = '1';
        final failure = expectLater(
          f.connect(startupTimeout: const Duration(seconds: 15)),
          throwsA(
            isA<TimeoutException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('${f.root.path}/launch'),
                contains('startup error'),
              ),
            ),
          ),
        );
        final ready = File('${f.profile.data}/replacement.ready');
        await eventually(
          ready.existsSync,
          timeout: const Duration(seconds: 12),
        );
        final replied = File('${f.profile.data}/closing-replied');
        await eventually(
          replied.existsSync,
          timeout: const Duration(seconds: 12),
        );
        final reply = jsonDecode(replied.readAsStringSync()) as Map;
        expect(reply['method'], 'status');
        expect(reply['message'], closingMessage);
        expect(
          reply['pid'],
          int.parse(
            File('${f.profile.data}/replacement.pid').readAsStringSync(),
          ),
        );
        await failure;
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
      } finally {
        await f.close();
      }
    },
  );

  for (final isolated in [false, true]) {
    test(
      'a local closing owner retains its process lock (isolated: $isolated)',
      () async {
        final saved = Map.of(runtimeConfiguration.environment);
        final directory = await createPrivateTempDirectory(
          shortTestTempRoot,
          'of-local-owner-',
        );
        final started = File('${directory.path}/started');
        final stopping = File('${directory.path}/stopping');
        final release = File('${directory.path}/release');
        final marker = File('${directory.path}/launched');
        final helper = File('${directory.path}/helper');
        helper.writeAsStringSync('''#!/usr/bin/env python3
import os,pathlib,signal,time
started=pathlib.Path(${jsonEncode(started.path)})
stopping=pathlib.Path(${jsonEncode(stopping.path)})
release=pathlib.Path(${jsonEncode(release.path)})
def shutdown(signum, frame):
 stopping.touch()
 while not release.exists(): time.sleep(.005)
 raise SystemExit(0)
signal.signal(signal.SIGTERM,shutdown)
started.write_text(str(os.getpid()))
while True: signal.pause()
''');
        final launcher = File(
          '${directory.path}/launch',
        )..writeAsStringSync('#!/bin/sh\nprintf launched > "${marker.path}"\n');
        await Process.run('/bin/chmod', ['700', helper.path, launcher.path]);
        for (final key in [
          'FORESIGHT_NATIVE',
          'FORESIGHT_INSTALL_ROOT',
          'FORESIGHT_RUNTIME_REVISION',
          'FORESIGHT_MODEL_MANIFEST',
        ]) {
          runtimeConfiguration.environment.remove(key);
        }
        runtimeConfiguration.environment['FORESIGHT_HELPER'] = helper.path;
        runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.path;
        final profile = ProfilePaths(
          '${directory.path}/data',
          '${directory.path}/run',
        );
        Future<void> Function()? close;
        try {
          if (isolated) {
            final host = await IsolatedApplicationService.start(profile);
            close = host.close;
          } else {
            final service = await ApplicationService.start(profile);
            close = service.close;
          }
          await eventually(started.existsSync);
          final shutdown = close();
          await eventually(stopping.existsSync);
          // Simulate the normal socket-before-lock cleanup interval. The worker
          // is deterministically held in its owned helper shutdown, not a sleep.
          File(serviceEndpoint(profile)).deleteSync();
          await expectLater(
            ensureService(
              profile,
              startupTimeout: const Duration(milliseconds: 300),
            ),
            throwsA(
              isA<TimeoutException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('profile lock'),
                  contains('owner'),
                  isNot(contains('null')),
                ),
              ),
            ),
          );
          expect(marker.existsSync(), isFalse);
          final probe = await Process.run('python3', [
            '-c',
            'import fcntl,sys\nf=open(sys.argv[1],"a")\ntry: fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(0)\nsys.exit(1)',
            '${profile.data}/.application.lock',
          ]);
          expect(
            probe.exitCode,
            0,
            reason:
                'Startup must not release another isolate or local owner lock: ${probe.stderr}',
          );
          release.writeAsStringSync('release');
          await shutdown.timeout(const Duration(seconds: 10));
        } finally {
          release.writeAsStringSync('release');
          await close?.call();
          runtimeConfiguration.environment
            ..clear()
            ..addAll(saved);
          directory.deleteSync(recursive: true);
        }
      },
    );
  }

  for (final socketClosed in [false, true]) {
    test(
      'owner handoff deadline preserves a live owner (socket closed: $socketClosed)',
      () async {
        final f = HandoffFixture();
        await f.start();
        try {
          final pending = f.connect(
            startupTimeout: const Duration(milliseconds: 500),
          );
          final failure = expectLater(
            pending,
            throwsA(isA<TimeoutException>()),
          );
          await f.next('closing-observed');
          if (socketClosed) await f.closeSocket();
          await failure;
          expect(f.launched, isFalse);
          expect(
            File('${f.profile.data}/.application-endpoint.json').existsSync(),
            isTrue,
          );
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final mode in [closingMessage, 'eof']) {
    final observed = mode == 'eof' ? 'eof-observed' : 'closing-observed';
    test(
      'unclean owner shutdown hands off to one adopting replacement ($observed)',
      () async {
        final f = HandoffFixture();
        await f.start(errorMessage: mode, keepEndpoint: true);
        try {
          final pending = f.connect();
          final success = expectLater(pending, completes);
          await f.next(observed);
          expect(f.launched, isFalse);
          // The old owner exits without deleting its record, as an owner does
          // after an unverified helper shutdown or a crash.
          await f.release();
          final client = await pending.timeout(const Duration(seconds: 15));
          await success;
          expect(
            (await client.call('status') as Map)['pid'],
            int.parse(
              File('${f.profile.data}/replacement.pid').readAsStringSync(),
            ),
          );
          expect(File('${f.profile.data}/launches').readAsLinesSync(), [
            'launch',
          ]);
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'concurrent launchers after an unclean shutdown converge on one owner',
    () async {
      final f = HandoffFixture();
      await f.start(keepEndpoint: true);
      // Hold replacements before the lock, so both launchers find it free and
      // each launches exactly once.
      runtimeConfiguration.environment['REPLACEMENT_GATE'] = '1';
      ServiceClient? second;
      try {
        final first = f.connect();
        final other = ensureService(f.profile);
        // Each launcher's status probe receives the closing reply.
        await f.next('closing-observed');
        await f.next('closing-observed');
        expect(f.launched, isFalse);
        await f.release();
        final launches = File('${f.profile.data}/launches');
        await eventually(
          () => launches.existsSync() && launches.readAsLinesSync().length == 2,
          timeout: const Duration(seconds: 15),
        );
        File('${f.profile.data}/replacement.go').writeAsStringSync('go');
        final a = await first.timeout(const Duration(seconds: 15));
        second = await other.timeout(const Duration(seconds: 15));
        final lost = File('${f.profile.data}/lost-launches');
        await eventually(
          () => lost.existsSync() && lost.readAsLinesSync().length == 1,
          timeout: const Duration(seconds: 15),
        );
        final owner = int.parse(
          File('${f.profile.data}/replacement.pid').readAsStringSync(),
        );
        expect((await a.call('status') as Map)['pid'], owner);
        expect((await second.call('status') as Map)['pid'], owner);
        expect(launches.readAsLinesSync(), ['launch', 'launch']);
      } finally {
        await second?.close();
        await f.close();
      }
    },
  );

  for (final message in [
    'Other unavailable service failure',
    'Application service disconnected',
  ]) {
    test(
      'server unavailable remains fatal even for transport-like text: $message',
      () async {
        final f = HandoffFixture();
        await f.start(errorMessage: message);
        try {
          await expectLater(
            f.connect(),
            throwsA(
              isA<RpcError>().having(
                (error) => error.message,
                'message',
                message,
              ),
            ),
          );
          expect(f.launched, isFalse);
          expect(
            File('${f.profile.data}/.application-endpoint.json').existsSync(),
            isTrue,
          );
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'a deleted endpoint record falls back only after the real lookup race',
    () async {
      final root = await createPrivateTempDirectory(
        shortTestTempRoot,
        'of-endpoint-',
      );
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      privateDirectory(profile.data);
      final record = File('${profile.data}/.application-endpoint.json')
        ..writeAsStringSync(
          jsonEncode({'data': profile.data, 'runtime': '${root.path}/other'}),
        );
      final overrides = EndpointDeletionOverrides(record);
      try {
        final endpoint = IOOverrides.runWithIOOverrides(
          () => serviceEndpoint(profile),
          overrides,
        );
        expect(overrides.deleted, isTrue);
        expect(record.existsSync(), isFalse);
        expect(endpoint, '${profile.runtime}/application.sock');
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );

  test('malformed startup status is fatal without a replacement', () async {
    final f = HandoffFixture();
    await f.start(errorMessage: 'malformed');
    try {
      await expectLater(f.connect(), throwsFormatException);
      expect(f.launched, isFalse);
    } finally {
      await f.close();
    }
  });

  test(
    'an already closed client preserves the first malformed-frame failure',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'malformed-push');
      ServiceClient? client;
      try {
        client = await ServiceClient.connect(serviceEndpoint(f.profile));
        await f.next('malformed-sent');
        await eventually(() => client!.isClosed);
        await expectLater(
          client.call('status'),
          throwsA(
            isA<RpcError>()
                .having(
                  (error) => error.code,
                  'code',
                  RpcErrorCode.invalidArgument,
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('not-json'),
                ),
          ),
        );
        expect(f.launched, isFalse);
      } finally {
        await client?.close();
        await f.close();
      }
    },
  );

  test('owner handoff cannot remove the startup deadline', () async {
    for (final timeout in [
      Duration.zero,
      const Duration(milliseconds: -1),
      const Duration(minutes: 4),
    ]) {
      await expectLater(
        ensureService(
          ProfilePaths('/unused', '/unused'),
          startupTimeout: timeout,
        ),
        throwsArgumentError,
      );
    }
  });
}
