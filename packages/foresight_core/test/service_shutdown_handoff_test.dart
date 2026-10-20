import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/store.dart';
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
  if (!old) {
    File('$data/launches').writeAsStringSync('launch\n', mode: FileMode.append);
    File('$data/replacement.pid').writeAsStringSync('$pid');
  }
  final lock = File('$data/.application.lock').openSync(mode: FileMode.append);
  lock.lockSync(FileLock.exclusive);
  final endpoint = File('$data/.application-endpoint.json');
  endpoint.writeAsStringSync(jsonEncode({'data': data, 'runtime': runtime}));
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
  var healthyProbe = false;
  var connectionCount = 0;
  server.listen((socket) {
    peers.add(socket);
    if (old) File('$data/old-connections').writeAsStringSync('${++connectionCount}');
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
      if (old && (Platform.environment['ERROR_MESSAGE'] ?? '').startsWith('healthy-then-') && !healthyProbe) {
        healthyProbe = true;
        Timer(Duration(milliseconds: int.parse(Platform.environment['FIRST_PROBE_DELAY_MS'] ?? '0')), () {
          socket.writeln(jsonEncode({'id': request['id'], 'result': {'pid': pid, 'application_api_version': 1, 'runtime_revision': 'fixture-revision', 'installation_root': Directory(data).resolveSymbolicLinksSync()}, 'done': true}));
          stdout.writeln('healthy-observed');
        });
        return;
      }
      if (old && Platform.environment['ERROR_MESSAGE'] == 'healthy-then-invalid-state') { socket.writeln(jsonEncode({'id': request['id'], 'result': {'generation': 1, 'pid': pid, 'application_api_version': 1, 'runtime_revision': 'fixture-revision', 'installation_root': Directory(data).resolveSymbolicLinksSync()}, 'done': true})); stdout.writeln('final-observed'); return; }
      if (old && Platform.environment['ERROR_MESSAGE'] == 'healthy-then-stall') { stdout.writeln('final-observed'); return; }
      if (old && Platform.environment['ERROR_MESSAGE'] == 'healthy-then-malformed') { socket.writeln('not-json'); stdout.writeln('final-observed'); return; }
      if (old || Platform.environment['REPLACEMENT_CLOSING'] == '1') {
        socket.writeln(jsonEncode({'id': request['id'], 'error': {'code': 'unavailable', 'message': Platform.environment['ERROR_MESSAGE'] == 'healthy-then-closing' ? 'Application service is shutting down; retry after it exits.' : Platform.environment['ERROR_MESSAGE'] ?? 'Application service is shutting down; retry after it exits.'}, 'done': true}));
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
      if (old) File('$data/old-peer-closed').writeAsStringSync('closed');
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
    int firstProbeDelayMs = 0,
  }) async {
    root = await createPrivateTempDirectory(shortTestTempRoot, 'of-handoff-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    File(
      '${profile.data}/.desktop-capability',
    ).writeAsStringSync('fixture-desktop-token');
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
        'FIRST_PROBE_DELAY_MS': '$firstProbeDelayMs',
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
    'ordinary ensureService retains one status probe and no desktop reservation',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'healthy-then-closing');
      try {
        final pending = f.connect();
        await f.next('healthy-observed');
        final client = await pending.timeout(const Duration(seconds: 5));
        expect(client.isClosed, isFalse);
        expect(f.launched, isFalse);
        await expectLater(
          client.call('status'),
          throwsA(
            isA<RpcError>().having((e) => e.message, 'message', closingMessage),
          ),
        );
        await f.next('closing-observed');
      } finally {
        await f.close();
      }
    },
  );

  test(
    'desktop final status joins closing owner after a healthy first probe',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'healthy-then-closing');
      Store('${f.profile.data}/application.db').close();
      RemoteDomain? domain;
      try {
        final pending = RemoteDomain.connect(
          f.profile,
        ).then((value) => domain = value);
        final success = expectLater(pending, completes);
        await f.next('healthy-observed');
        await f.next('closing-observed');
        expect(f.launched, isFalse);
        await f.closeSocket();
        await expectLater(
          pending.timeout(const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()),
        );
        expect(f.launched, isFalse);
        await f.release();
        final connected = await pending.timeout(const Duration(seconds: 15));
        await success;
        expect(
          (await connected.client.call('status') as Map)['pid'],
          isNot(f.old.pid),
        );
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
        expect(
          File('${f.profile.data}/requests').readAsLinesSync(),
          everyElement('status'),
        );
      } finally {
        domain?.close();
        domain?.store.close();
        await f.close();
      }
    },
  );
  test(
    'desktop final snapshot shares the original overall startup deadline',
    () async {
      final f = HandoffFixture();
      await f.start(
        errorMessage: 'healthy-then-stall',
        firstProbeDelayMs: 1500,
      );
      Store('${f.profile.data}/application.db').close();
      try {
        final failure = expectLater(
          RemoteDomain.connect(
            f.profile,
            startupTimeout: const Duration(seconds: 2),
          ),
          throwsA(isA<TimeoutException>()),
        );
        await f.next('healthy-observed');
        await f.next('final-observed');
        await failure.timeout(const Duration(milliseconds: 1200));
        await eventually(
          () => File('${f.profile.data}/old-peer-closed').existsSync(),
        );
        expect(f.launched, isFalse);
        expect(
          File('${f.profile.data}/old-connections').readAsStringSync(),
          '1',
        );
      } finally {
        await f.close();
      }
    },
  );

  test('desktop final closing owner keeps clean endpoint proof', () async {
    final f = HandoffFixture();
    await f.start(errorMessage: 'healthy-then-closing', keepEndpoint: true);
    Store('${f.profile.data}/application.db').close();
    try {
      final failure = expectLater(
        RemoteDomain.connect(f.profile),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('without clean shutdown'),
          ),
        ),
      );
      await f.next('healthy-observed');
      await f.next('closing-observed');
      await f.release();
      await failure.timeout(const Duration(seconds: 5));
      expect(f.launched, isFalse);
      expect(File('${f.profile.data}/old-connections').readAsStringSync(), '1');
    } finally {
      await f.close();
    }
  });

  test(
    'desktop final handoff launches at most one replacement within its deadline',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'healthy-then-closing');
      Store('${f.profile.data}/application.db').close();
      runtimeConfiguration.environment['REPLACEMENT_CLOSING'] = '1';
      try {
        final failure = expectLater(
          RemoteDomain.connect(
            f.profile,
            startupTimeout: const Duration(seconds: 3),
          ),
          throwsA(isA<TimeoutException>()),
        );
        await f.next('healthy-observed');
        await f.next('closing-observed');
        await f.release();
        await eventually(
          () => File('${f.profile.data}/closing-replied').existsSync(),
          timeout: const Duration(seconds: 2),
        );
        await failure.timeout(const Duration(seconds: 4));
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'desktop snapshot construction failure closes partial domain without reconnect',
    () async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'healthy-then-invalid-state');
      Store('${f.profile.data}/application.db').close();
      try {
        final failure = expectLater(
          RemoteDomain.connect(f.profile),
          throwsA(isA<TypeError>()),
        );
        await f.next('healthy-observed');
        await f.next('final-observed');
        await failure;
        await eventually(
          () => File('${f.profile.data}/old-peer-closed').existsSync(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(f.launched, isFalse);
        expect(
          File('${f.profile.data}/old-connections').readAsStringSync(),
          '1',
        );
      } finally {
        await f.close();
      }
    },
  );

  for (final mode in ['unavailable', 'malformed']) {
    test(
      'desktop final $mode failure closes client before resources or reconnect',
      () async {
        final f = HandoffFixture();
        await f.start(errorMessage: 'healthy-then-$mode');
        Store('${f.profile.data}/application.db').close();
        try {
          final failure = expectLater(
            RemoteDomain.connect(f.profile),
            throwsA(
              mode == 'malformed' ? isA<FormatException>() : isA<RpcError>(),
            ),
          );
          await f.next('healthy-observed');
          await f.next(
            mode == 'malformed' ? 'final-observed' : 'closing-observed',
          );
          await failure;
          await eventually(
            () => File('${f.profile.data}/old-peer-closed').existsSync(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(f.launched, isFalse);
          expect(
            File('${f.profile.data}/old-connections').readAsStringSync(),
            '1',
          );
        } finally {
          await f.close();
        }
      },
    );
  }

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
