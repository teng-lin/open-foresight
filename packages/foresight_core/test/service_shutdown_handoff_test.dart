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
Future<void> main() async {
  final data = Platform.environment['FORESIGHT_DATA']!;
  final runtime = Platform.environment['FORESIGHT_RUNTIME']!;
  final old = Platform.environment['OLD_OWNER'] == '1';
  if (!old) File('$data/launches').writeAsStringSync('launch\n', mode: FileMode.append);
  final lock = File('$data/.application.lock').openSync(mode: FileMode.append);
  lock.lockSync(FileLock.exclusive);
  final endpoint = File('$data/.application-endpoint.json');
  endpoint.writeAsStringSync(jsonEncode({'data': data, 'runtime': runtime}));
  final path = '$runtime/application.sock';
  final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
  final peers = <Socket>[];
  final stopped = Completer<void>();
  server.listen((socket) {
    peers.add(socket);
    unawaited(socket.done.catchError((Object _) {}));
    socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final request = jsonDecode(line) as Map;
      if (old && Platform.environment['ERROR_MESSAGE'] == 'stall') {
        stdout.writeln('closing-observed');
        return;
      }
      if (old || Platform.environment['REPLACEMENT_CLOSING'] == '1') {
        socket.writeln(jsonEncode({'id': request['id'], 'error': {'code': 'unavailable', 'message': Platform.environment['ERROR_MESSAGE'] ?? 'Application service is shutting down; retry after it exits.'}, 'done': true}));
        if (old) { stdout.writeln('closing-observed'); }
        else { unawaited(socket.flush().then((_) => stopped.complete())); }
      } else {
        File('$data/requests').writeAsStringSync('${request['method']}\n', mode: FileMode.append);
        socket.writeln(jsonEncode({'id': request['id'], 'result': {'pid': pid, 'application_api_version': 1, 'runtime_revision': 'fixture-revision', 'installation_root': Directory(data).resolveSymbolicLinksSync()}, 'done': true}));
        if (request['method'] == 'fixture.stop') unawaited(socket.flush().then((_) => stopped.complete()));
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
  if (Platform.environment['KEEP_ENDPOINT'] != '1') endpoint.deleteSync();
  lock.closeSync();
}
''';

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

  Future<void> close() async {
    try {
      await release();
      try {
        await pending;
      } catch (_) {
        /* Expected startup failures are asserted by the caller. */
      }
      if (client != null) await client!.call('fixture.stop');
      await client?.close();
      await messages.cancel();
    } finally {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
      root.deleteSync(recursive: true);
    }
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
        await expectLater(
          f.connect(startupTimeout: const Duration(seconds: 2)),
          throwsA(isA<TimeoutException>()),
        );
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
            throwsA(isA<TimeoutException>()),
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

  test(
    'unclean owner shutdown remains an actionable failure without a replacement',
    () async {
      final f = HandoffFixture();
      await f.start(keepEndpoint: true);
      try {
        final pending = f.connect();
        final failure = expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('without clean shutdown'),
            ),
          ),
        );
        await f.next('closing-observed');
        await f.release();
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

  test(
    'unrelated unavailable errors are never accepted as a shutdown handoff',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'Other unavailable service failure');
      try {
        await expectLater(
          f.connect(),
          throwsA(
            isA<RpcError>().having(
              (error) => error.message,
              'message',
              'Other unavailable service failure',
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
