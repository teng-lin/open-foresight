import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/hooked_service.dart' show ServiceGates;
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const closingMessage =
    'Application service is shutting down; retry after it exits.';
// v0.1.x owners refused requests that reached _execute with this text.
const legacyClosingMessage = 'Application service is shutting down';
const probeTimeoutMessage =
    'Application service did not answer its startup status probe';

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
  var runtime = Platform.environment['FORESIGHT_RUNTIME']!;
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
  // As in production, a replacement adopts the runtime that an unclean
  // predecessor recorded; only the record links that runtime to the profile.
  if (!old && endpoint.existsSync()) {
    final record = jsonDecode(endpoint.readAsStringSync());
    if (record is Map && record['data'] == data && record['runtime'] is String) {
      runtime = record['runtime'] as String;
    }
  }
  // Publish the record atomically and privately, as production does.
  final temporary = File('${endpoint.path}.$pid')
    ..writeAsStringSync(jsonEncode({'data': data, 'runtime': runtime}));
  if (Process.runSync('/bin/chmod', ['600', temporary.path]).exitCode != 0) {
    throw StateError('Cannot protect the endpoint record');
  }
  temporary.renameSync(endpoint.path);
  final path = '$runtime/application.sock';
  // Bind under a private name, then rename, as ServiceSocketBinding does.
  // Closing the listener then never unlinks the public path; teardown must.
  final bound = '$runtime/.s$pid';
  final server = await ServerSocket.bind(InternetAddress(bound, type: InternetAddressType.unix), 0);
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
        socket.writeln(jsonEncode({'id': request['id'], 'error': Platform.environment['ERROR_MESSAGE'] == 'healthy-then-unknown' ? {'code': 'unavailable', 'message': 'Application service stopped before this request finished; it may or may not have completed.', 'reason': 'outcomeUnknown'} : {'code': 'unavailable', 'message': Platform.environment['ERROR_MESSAGE'] == 'healthy-then-closing' ? 'Application service is shutting down; retry after it exits.' : Platform.environment['ERROR_MESSAGE'] ?? 'Application service is shutting down; retry after it exits.'}, 'done': true}));
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
  // Publish only after the handler is attached.
  File(bound).renameSync(path);
  if (!old) File('$data/replacement.ready').writeAsStringSync('$pid');
  // Teardown matches the non-isolated service and PR 3's target order: public
  // socket, then record, then lock. Today's isolated binary deletes the
  // record before its frontend removes the public socket (SL-3).
  Future<void> removeSocket() async {
    for (final socket in peers) { socket.destroy(); }
    await server.close();
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) File(path).deleteSync();
  }
  if (old) {
    stdout.writeln('ready');
    await for (final command in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (command == 'close-socket' || command == 'release') {
        await removeSocket();
        if (command == 'close-socket') stdout.writeln('socket-closed');
      }
      if (command == 'release') break;
    }
  } else {
    await stopped.future;
    await removeSocket();
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

  /// The old owner's runtime. With a separate one, only the endpoint record
  /// links it to the profile; clients use [ProfilePaths.runtime] otherwise.
  late String ownerRuntime;
  late Process old;
  late StreamIterator<String> messages;
  late Future<String> errors;
  Future<ServiceClient>? pending;
  ServiceClient? client;
  bool released = false;

  /// Relays [connect]'s socket connects, so tests anchor on observed frames
  /// and connect attempts instead of elapsed time.
  final proxy = ServiceFaultProxy();

  Future<void> start({
    String errorMessage = closingMessage,
    bool keepEndpoint = false,
    bool separateOwnerRuntime = false,
    int firstProbeDelayMs = 0,
  }) async {
    root = await createPrivateTempDirectory(shortTestTempRoot, 'of-handoff-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    ownerRuntime = separateOwnerRuntime ? '${root.path}/own' : profile.runtime;
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    privateDirectory(ownerRuntime);
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
        'FORESIGHT_RUNTIME': ownerRuntime,
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
  }) => pending = proxy
      .run(() => ensureService(profile, startupTimeout: startupTimeout))
      .then((value) => client = value);

  /// Whether a launched replacement lost the profile lock to a live owner,
  /// which would mean a launch happened while the old owner held the lock.
  bool get lostLaunch => File('${profile.data}/lost-launches').existsSync();

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
        for (final runtime in {profile.runtime, ownerRuntime}) {
          expect(File('$runtime/application.sock').existsSync(), isFalse);
        }
        expect(
          File('${profile.data}/.application-endpoint.json').existsSync(),
          isFalse,
        );
      }
      await messages.cancel();
    } finally {
      await proxy.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    }
    // Never remove a running child's executable or owned resources.
    root.deleteSync(recursive: true);
  }
}

/// The protocol error for a complete frame that is not a JSON object, with
/// [reason] outcomeUnknown for a request already written.
Matcher isInvalidReply(String? reason) => isA<RpcError>()
    .having((error) => error.code, 'code', RpcErrorCode.internal)
    .having(
      (error) => error.message,
      'message',
      'Application service sent an invalid reply',
    )
    .having((error) => error.toJson()['reason'], 'reason', reason);

/// The error a startup failed with. A successful startup fails the test.
Future<Object> startupFailure(Future<Object?> startup) async {
  try {
    await startup;
  } catch (error) {
    return error;
  }
  fail('Startup unexpectedly succeeded');
}

/// Whether [startup] has completed, observed without waiting for it.
bool Function() settledFlag(Future<Object?> startup) {
  var settled = false;
  unawaited(
    startup.then<void>(
      (_) => settled = true,
      onError: (Object _) => settled = true,
    ),
  );
  return () => settled;
}

/// Startup deadline ladders for [expireDeadlineDuring].
const handoffDeadlines = [
  Duration(milliseconds: 500),
  Duration(seconds: 2),
  Duration(seconds: 8),
];

/// The deadline also covers launching the replacement.
const launchDeadlines = [
  Duration(seconds: 1),
  Duration(seconds: 4),
  Duration(seconds: 16),
];

const localOwnerDeadlines = [
  Duration(milliseconds: 300),
  Duration(seconds: 1),
  Duration(seconds: 4),
];

/// A test timeout that covers every attempt of a ladder, with fixture setup
/// and teardown, even on a loaded host (about two minutes).
Timeout ladderTimeout(List<Duration> deadlines) => Timeout(
  deadlines.fold(Duration.zero, (sum, deadline) => sum + deadline) * 3 +
      const Duration(seconds: 60),
);

/// ensureService's startup deadline runs from its call, so on a loaded host
/// it can expire before the phase a test is about, and that run would test
/// nothing. [attempt] runs one startup with the given deadline and returns
/// whether the deadline expired during [phase], judged from observed frames
/// and connect attempts, never from elapsed time. Only then does it assert.
/// A longer deadline is tried only when the phase was not reached.
Future<void> expireDeadlineDuring(
  String phase,
  Future<bool> Function(Duration startupTimeout) attempt, {
  List<Duration> deadlines = handoffDeadlines,
}) async {
  for (final deadline in deadlines) {
    if (await attempt(deadline)) return;
    print('Startup deadline $deadline expired before $phase; retrying.');
  }
  fail('Every startup deadline expired before $phase');
}

/// Closing-owner tests run twice: with the owner in the client's runtime, and
/// in a separate runtime that only the endpoint record links to the profile.
void ownerRuntimeVariants(
  String name,
  Future<void> Function(bool separateOwnerRuntime) body, {
  Timeout? timeout,
}) {
  for (final separate in [false, true]) {
    test(
      separate ? '$name (separate owner runtime)' : name,
      () => body(separate),
      timeout: timeout,
    );
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
      // The probe limit caps a status call only while more than it remains
      // of the startup deadline. The owner holds its first reply long enough
      // that less than the limit remains, so the stalled final snapshot ends
      // uncapped, at the original deadline. A fresh budget for it would
      // exceed the limit and end capped, with a message naming the limit.
      await expireDeadlineDuring('the final snapshot', (deadline) async {
        final f = HandoffFixture();
        await f.start(
          errorMessage: 'healthy-then-stall',
          firstProbeDelayMs: (deadline * 0.25).inMilliseconds,
        );
        try {
          ServiceFrame? last;
          unawaited(
            f.proxy
                .seen(
                  ProxyDirection.toService,
                  method: 'status',
                  where: (frame) =>
                      (frame.json?['args'] as Map?)?['desktop'] == true,
                )
                .then((frame) => last = frame),
          );
          final failure = await startupFailure(
            f.proxy.run(
              () => ensureServiceSnapshot(
                f.profile,
                startupTimeout: deadline,
                statusProbeLimit: deadline * 0.9,
              ),
            ),
          );
          expect(failure, isA<TimeoutException>());
          // Only a final snapshot that reached the stalled owner tests it.
          if (last == null) return false;
          expect((failure as TimeoutException).message, probeTimeoutMessage);
          await eventually(
            () => File('${f.profile.data}/old-peer-closed').existsSync(),
          );
          expect(f.launched, isFalse);
          expect(
            File('${f.profile.data}/old-connections').readAsStringSync(),
            '1',
          );
          return true;
        } finally {
          await f.close();
        }
      });
    },
    timeout: ladderTimeout(handoffDeadlines),
  );

  test('desktop final snapshot follows an owner that closes uncleanly to one '
      'adopting replacement (D2)', () async {
    final f = HandoffFixture();
    await f.start(errorMessage: 'healthy-then-closing', keepEndpoint: true);
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
      // The old owner exits without deleting its record.
      await f.release();
      final connected = await pending.timeout(const Duration(seconds: 15));
      await success;
      expect(
        (await connected.client.call('status') as Map)['pid'],
        int.parse(File('${f.profile.data}/replacement.pid').readAsStringSync()),
      );
      expect(File('${f.profile.data}/launches').readAsLinesSync(), ['launch']);
      expect(File('${f.profile.data}/old-connections').readAsStringSync(), '1');
    } finally {
      domain?.close();
      domain?.store.close();
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
    'desktop final status that the owner ends as outcomeUnknown hands off to '
    'one replacement',
    () async {
      // A status the owner answered as it began closing: read-only, so the
      // snapshot waits for that owner and follows the handoff.
      final f = HandoffFixture();
      await f.start(errorMessage: 'healthy-then-unknown');
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
      } finally {
        domain?.close();
        domain?.store.close();
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
              mode == 'malformed'
                  ? isInvalidReply('outcomeUnknown')
                  : isA<RpcError>(),
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

  ownerRuntimeVariants(
    'desktop startup joins the closing owner before one replacement launch',
    (separate) async {
      final f = HandoffFixture();
      await f.start(separateOwnerRuntime: separate);
      try {
        final pending = f.connect();
        final settled = settledFlag(pending);
        final success = expectLater(pending, completes);
        await f.next('closing-observed');
        expect(f.launched, isFalse);
        // Once the closing socket is gone, startup probes the endpoint again.
        // The second refusal follows a complete lock probe, which found the
        // controlled old process still owning the real profile lock.
        final retried = f.proxy.attempt(refused: true, count: 2);
        await f.closeSocket();
        await retried;
        expect(settled(), isFalse);
        expect(f.launched, isFalse);
        await f.release();
        final client = await pending.timeout(const Duration(seconds: 5));
        await success;
        expect((await client.call('status') as Map)['pid'], isNot(f.old.pid));
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
        expect(f.lostLaunch, isFalse);
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
    'a legacy owner refusing with its shorter closing text is handed off (L2)',
    () async {
      // A legacy owner sends no reason, only one of its two closing texts.
      final f = HandoffFixture();
      await f.start(errorMessage: legacyClosingMessage);
      try {
        final pending = f.connect();
        final success = expectLater(pending, completes);
        await f.next('closing-observed');
        expect(f.launched, isFalse);
        await f.release();
        final client = await pending.timeout(const Duration(seconds: 15));
        await success;
        expect((await client.call('status') as Map)['pid'], isNot(f.old.pid));
        expect(File('${f.profile.data}/launches').readAsLinesSync(), [
          'launch',
        ]);
        expect(f.lostLaunch, isFalse);
      } finally {
        await f.close();
      }
    },
  );

  ownerRuntimeVariants(
    'EOF before status waits for the real owner lock before one launch',
    (separate) async {
      final f = HandoffFixture();
      await f.start(errorMessage: 'eof', separateOwnerRuntime: separate);
      try {
        // Each probe of the old owner meets EOF. The second probe follows a
        // complete lock probe, which found the old owner still holding it.
        final secondProbe = f.proxy.seen(
          ProxyDirection.toService,
          method: 'status',
          count: 2,
        );
        final pending = f.connect();
        final settled = settledFlag(pending);
        final success = expectLater(pending, completes);
        await f.next('eof-observed');
        await secondProbe;
        expect(settled(), isFalse);
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
        expect(f.lostLaunch, isFalse);
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
        await expireDeadlineDuring('the stalled status probe', (
          deadline,
        ) async {
          final earlier = f.proxy.connections.length;
          ServiceFrame? probe;
          unawaited(
            f.proxy
                .seen(
                  ProxyDirection.toService,
                  method: 'status',
                  where: (frame) => frame.connection.index >= earlier,
                )
                .then((frame) => probe = frame),
          );
          final failure = await startupFailure(
            f.connect(startupTimeout: deadline),
          );
          expect(failure, isA<TimeoutException>());
          // Only a probe that reached the stalled owner tests the timeout.
          if (probe == null) return false;
          expect((failure as TimeoutException).message, probeTimeoutMessage);
          // The timed-out probe closed its own connection.
          await probe!.connection.ended(ProxyDirection.toService);
          return true;
        });
        expect(f.launched, isFalse);
      } finally {
        await f.close();
      }
    },
    timeout: ladderTimeout(handoffDeadlines),
  );

  test('a stalled owner fails startup at the probe limit, not after the whole '
      'budget (L1)', () async {
    final f = HandoffFixture();
    await f.start(errorMessage: 'stall');
    try {
      // The full three-minute budget; only the probe limit is shortened.
      final failure = await startupFailure(
        f.proxy.run(
          () => ensureService(
            f.profile,
            statusProbeLimit: const Duration(milliseconds: 200),
          ),
        ),
      );
      expect(
        failure,
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          'Application service at ${f.ownerRuntime}/application.sock '
              'accepted the connection but did not answer status within '
              '200 ms; it may be busy or hung.',
        ),
      );
      // One probe; a stalled live owner is never replaced.
      expect(f.proxy.connections, hasLength(1));
      await f.proxy.connections.single.ended(ProxyDirection.toService);
      expect(f.launched, isFalse);
    } finally {
      await f.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'a closing post-launch owner remains bounded without another launch',
    () async {
      // The deadline also covers launching the replacement, so start with
      // a longer one than the owner-handoff tests.
      await expireDeadlineDuring("the replacement's closing reply", (
        deadline,
      ) async {
        final f = HandoffFixture();
        await f.start();
        try {
          await f.release();
          runtimeConfiguration.environment['REPLACEMENT_CLOSING'] = '1';
          ServiceFrame? closing;
          unawaited(
            f.proxy
                .seen(
                  ProxyDirection.toClient,
                  method: 'status',
                  where: (frame) => frame.error?['message'] == closingMessage,
                )
                .then((frame) => closing = frame),
          );
          final failure = await startupFailure(
            f.connect(startupTimeout: deadline),
          );
          expect(failure, isA<TimeoutException>());
          final message = (failure as TimeoutException).message;
          // The deadline must expire after startup took the closing reply,
          // not while the replacement launched or the reply was in flight.
          if (closing == null || message == probeTimeoutMessage) return false;
          expect(
            message,
            allOf(contains('${f.root.path}/launch'), contains('startup error')),
          );
          final replied = File('${f.profile.data}/closing-replied');
          await eventually(replied.existsSync);
          final reply = jsonDecode(replied.readAsStringSync()) as Map;
          expect(reply['method'], 'status');
          expect(reply['message'], closingMessage);
          expect(
            reply['pid'],
            int.parse(
              File('${f.profile.data}/replacement.pid').readAsStringSync(),
            ),
          );
          expect(File('${f.profile.data}/launches').readAsLinesSync(), [
            'launch',
          ]);
          return true;
        } finally {
          await f.close();
        }
      }, deadlines: launchDeadlines);
    },
    timeout: ladderTimeout(launchDeadlines),
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
        final marker = File('${directory.path}/launched');
        final launcher = File(
          '${directory.path}/launch',
        )..writeAsStringSync('#!/bin/sh\nprintf launched > "${marker.path}"\n');
        await Process.run('/bin/chmod', ['700', launcher.path]);
        final gates = await ServiceGates.create(directory);
        for (final key in [
          'FORESIGHT_NATIVE',
          'FORESIGHT_INSTALL_ROOT',
          'FORESIGHT_RUNTIME_REVISION',
          'FORESIGHT_MODEL_MANIFEST',
        ]) {
          runtimeConfiguration.environment.remove(key);
        }
        runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
        runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.path;
        // Hold the real close just before it releases the profile lock. This
        // isolate's configuration keeps the key, and the worker inherits it.
        runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
            gates.directory.path;
        gates.hold('close.before_lock_release');
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
          final shutdown = close();
          await gates.reached('close.before_lock_release', pid: pid);
          // The real close has removed the public socket; the lock remains.
          expect(
            FileSystemEntity.typeSync('${profile.runtime}/application.sock'),
            FileSystemEntityType.notFound,
          );
          final proxy = ServiceFaultProxy();
          try {
            await expireDeadlineDuring('a lock probe', (deadline) async {
              // A second refused connect follows a complete lock probe.
              var probed = false;
              unawaited(
                proxy
                    .attempt(refused: true, count: 2)
                    .then((_) => probed = true),
              );
              final failure = await startupFailure(
                proxy.run(
                  () => ensureService(profile, startupTimeout: deadline),
                ),
              );
              expect(
                failure,
                isA<TimeoutException>().having(
                  (error) => error.message,
                  'message',
                  allOf(
                    contains('profile lock'),
                    contains('owner'),
                    isNot(contains('null')),
                  ),
                ),
              );
              return probed;
            }, deadlines: localOwnerDeadlines);
          } finally {
            await proxy.close();
          }
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
          gates.release('close.before_lock_release');
          await shutdown.timeout(const Duration(seconds: 10));
        } finally {
          gates.releaseAll();
          await close?.call();
          runtimeConfiguration.environment
            ..clear()
            ..addAll(saved);
          directory.deleteSync(recursive: true);
        }
      },
      timeout: ladderTimeout(localOwnerDeadlines),
    );
  }

  for (final socketClosed in [false, true]) {
    ownerRuntimeVariants(
      'owner handoff deadline preserves a live owner (socket closed: $socketClosed)',
      (separate) async {
        await expireDeadlineDuring(
          socketClosed
              ? 'lock probes after the closing socket closed'
              : 'the wait for the closing socket',
          (deadline) async {
            final f = HandoffFixture();
            await f.start(separateOwnerRuntime: separate);
            try {
              ServiceFrame? closing;
              final replied = f.proxy
                  .seen(ProxyDirection.toClient, method: 'status')
                  .then((frame) => closing = frame);
              // A second refusal follows a complete lock probe.
              var probed = false;
              unawaited(
                f.proxy
                    .attempt(refused: true, count: 2)
                    .then((_) => probed = true),
              );
              final failure = startupFailure(
                f.connect(startupTimeout: deadline),
              );
              await Future.any([replied, failure]);
              if (closing != null && socketClosed) {
                await f.next('closing-observed');
                await f.closeSocket();
              }
              final error = await failure;
              expect(error, isA<TimeoutException>());
              final message = (error as TimeoutException).message;
              // Startup must have taken the closing reply before the deadline,
              // and, once the socket closed, probed the lock while it was held.
              if (closing == null ||
                  message == probeTimeoutMessage ||
                  (socketClosed && !probed)) {
                return false;
              }
              expect(
                message,
                'Application service owner handoff did not finish',
              );
              expect(f.launched, isFalse);
              expect(
                File(
                  '${f.profile.data}/.application-endpoint.json',
                ).existsSync(),
                isTrue,
              );
              return true;
            } finally {
              await f.close();
            }
          },
        );
      },
      timeout: ladderTimeout(handoffDeadlines),
    );
  }

  for (final mode in [closingMessage, 'eof']) {
    final observed = mode == 'eof' ? 'eof-observed' : 'closing-observed';
    ownerRuntimeVariants(
      'unclean owner shutdown hands off to one adopting replacement ($observed)',
      (separate) async {
        final f = HandoffFixture();
        await f.start(
          errorMessage: mode,
          keepEndpoint: true,
          separateOwnerRuntime: separate,
        );
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
          // The replacement adopted the runtime the old owner recorded.
          expect(
            (jsonDecode(
                  File(
                    '${f.profile.data}/.application-endpoint.json',
                  ).readAsStringSync(),
                )
                as Map)['runtime'],
            f.ownerRuntime,
          );
        } finally {
          await f.close();
        }
      },
    );
  }

  ownerRuntimeVariants(
    'concurrent launchers after an unclean shutdown converge on one owner',
    (separate) async {
      final f = HandoffFixture();
      await f.start(keepEndpoint: true, separateOwnerRuntime: separate);
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
      // A complete frame that is not JSON is a protocol error, not a caller
      // error and not a lost connection to retry (SL-6).
      await expectLater(f.connect(), throwsA(isInvalidReply('outcomeUnknown')));
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
        await expectLater(client.call('status'), throwsA(isInvalidReply(null)));
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
