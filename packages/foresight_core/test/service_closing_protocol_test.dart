import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/gated_helper.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:test/test.dart';

// The closing protocol (fix plan, PR 3) with production code on both sides:
// the real bin/service.dart (IsolatedApplicationService) and the real wire
// client. Assertions read the wire where they can, so each test also runs
// against an owner or client built before the protocol existed.

const closingMessage =
    'Application service is shutting down; retry after it exits.';
const outcomeUnknownMessage =
    'Application service stopped before this request finished; it may or may '
    'not have completed.';

/// A bound only: startup of a compiled service child under parallel load.
const startupBound = Duration(seconds: 90);

/// The note titles committed to [profile]'s database, read directly.
List<String> committedNotes(ProfilePaths profile) {
  final store = Store.readOnly('${profile.data}/application.db');
  try {
    return [
      for (final row in store.rows('SELECT title FROM notes ORDER BY id'))
        row['title'] as String,
    ];
  } finally {
    store.close();
  }
}

/// The error [request] failed with; a bound only, so a missing terminal frame
/// fails the test instead of hanging it.
Future<Object> failureOf(Future<Object?> request) => request
    .then<Object>(
      (value) => fail('Expected a failure, got $value'),
      onError: (Object error) => error,
    )
    .timeout(const Duration(seconds: 120));

/// Whether [frame] is a closing refusal that carries its reason.
bool isClosingFrame(ServiceFrame frame) =>
    frame.error?['reason'] == 'closing' &&
    frame.error?['message'] == closingMessage;

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

/// An RpcError with [code], [message] and the wire reason [reason]. Reading
/// the reason through toJson keeps this file runnable against older clients.
Matcher rpcError(RpcErrorCode code, String message, String? reason) =>
    isA<RpcError>()
        .having((error) => error.code, 'code', code)
        .having((error) => error.message, 'message', message)
        .having((error) => error.toJson()['reason'], 'reason', reason);

/// One raw request and its terminal frame, as a client that predates the
/// `reason` field reads it: newline-delimited JSON, nothing else.
Future<Map<String, dynamic>> rawRequest(
  String endpoint,
  int id,
  String method,
) async {
  final socket = await Socket.connect(
    InternetAddress(endpoint, type: InternetAddressType.unix),
    0,
  );
  try {
    socket.add(
      utf8.encode('${jsonEncode({'id': id, 'method': method, 'args': {}})}\n'),
    );
    final line = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .firstWhere((line) => (jsonDecode(line) as Map)['id'] == id);
    return jsonDecode(line) as Map<String, dynamic>;
  } finally {
    socket.destroy();
  }
}

/// A running `--stop`, with its stderr lines as they arrive.
class StopRun {
  StopRun(this.process) {
    unawaited(process.stdout.drain<void>());
    utf8.decoder
        .bind(process.stderr)
        .transform(const LineSplitter())
        .listen(
          (line) {
            lines.add(line);
            for (final waiter in _waiters.toList()) {
              if (!line.contains(waiter.text)) continue;
              _waiters.remove(waiter);
              waiter.found.complete(line);
            }
          },
          onDone: () {
            for (final waiter in _waiters) {
              waiter.found.completeError(
                StateError(
                  'stderr ended without "${waiter.text}":\n${lines.join('\n')}',
                ),
              );
            }
            _waiters.clear();
          },
        );
  }

  final Process process;
  final lines = <String>[];
  final _waiters = <({String text, Completer<String> found})>[];

  /// The first stderr line containing [text]; fails if stderr ends first.
  Future<String> line(String text) {
    for (final line in lines) {
      if (line.contains(text)) return Future.value(line);
    }
    final found = Completer<String>();
    _waiters.add((text: text, found: found));
    return found.future.timeout(const Duration(seconds: 120));
  }

  /// The exit code; a bound only, since --stop's own waits are at most 30 s.
  Future<int> exited() =>
      process.exitCode.timeout(const Duration(seconds: 120));
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
    // Launched replacements inherit this configuration; run them helperless.
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(saved);
  });

  /// A profile by its canonical path: a hooked child records the canonical
  /// data path, and a record must name the reader's own profile.data.
  ProfilePaths newProfile(String prefix) {
    final directory = createServiceTestDirectorySync(prefix);
    return ProfilePaths('${directory.path}/data', '${directory.path}/run');
  }

  /// A launcher for replacements, beside [profile]'s data directory.
  Future<ServiceLauncher> launcherFor(ProfilePaths profile) async {
    final launcher = await build.launcher(Directory(profile.data).parent);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    return launcher;
  }

  test('a request in flight when the worker begins closing gets a terminal '
      'outcomeUnknown frame (SL-4)', () async {
    final profile = newProfile('of-drain-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['request.committed.notes.save', 'close.leases_terminated'],
    );
    ServiceClient? writer, desktop;
    try {
      await owner.ready();
      writer = await ServiceClient.connect(serviceEndpoint(profile));
      desktop = await ServiceClient.connect(serviceEndpoint(profile));
      await desktop.call('security.attach_desktop', {
        'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
      });
      final save = failureOf(
        writer.call('notes.save', {
          'title': 'Committed before close',
          'body': 'its reply is lost',
        }),
      );
      await owner.reached('request.committed.notes.save');
      // The desktop leaving starts a worker-initiated close after its
      // reattach grace; the frontend keeps relaying attached clients.
      await desktop.close();
      expect(
        await save,
        rpcError(
          RpcErrorCode.unavailable,
          outcomeUnknownMessage,
          'outcomeUnknown',
        ),
      );
      // The frame was sent before any later close step.
      await owner.reached('close.leases_terminated');
      expect(owner.gates.isReached('close.helper_closed'), isFalse);
      expect(committedNotes(profile), ['Committed before close']);
      owner.release('request.committed.notes.save');
      owner.release('close.leases_terminated');
      expect(await owner.exited(), 0, reason: owner.output);
    } finally {
      await writer?.close();
      await desktop?.close();
      await owner.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a status reply cut off by EOF is retried and attaches to the live owner '
    '(SL-6)',
    () async {
      final profile = newProfile('of-cut-');
      final owner = await HookedServiceProcess.start(build, profile);
      final launcher = await launcherFor(profile);
      final proxy = ServiceFaultProxy();
      ServiceClient? client;
      try {
        await owner.ready();
        final cut = proxy.truncate(
          ProxyDirection.toClient,
          method: 'status',
          keepBytes: 10,
        );
        final attached = await proxy.run(
          () => ensureService(profile, startupTimeout: startupBound),
        );
        client = attached;
        expect((await cut).method, 'status');
        expect((await attached.call('status') as Map)['pid'], owner.pid);
        // The cut probe, then one retry; the live owner kept its lock.
        expect(proxy.connections, hasLength(2));
        expect(launcher.launched, isEmpty);
      } finally {
        await client?.close();
        await proxy.close();
        await launcher.stopAll();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a malformed status frame is a protocol error without a replacement '
      '(SL-6)', () async {
    final profile = newProfile('of-garbage-');
    final owner = await HookedServiceProcess.start(build, profile);
    final launcher = await launcherFor(profile);
    final proxy = ServiceFaultProxy();
    ServiceClient? direct;
    try {
      await owner.ready();
      final reply = proxy.hold(ProxyDirection.toClient, method: 'status');
      final startup = proxy.run(
        () => ensureService(profile, startupTimeout: startupBound),
      );
      await reply.reached;
      proxy.inject(ProxyDirection.toClient, 'not-json');
      reply.release();
      await expectLater(
        startup,
        throwsA(
          rpcError(
            RpcErrorCode.internal,
            'Application service sent an invalid reply',
            'outcomeUnknown',
          ),
        ),
      );
      expect(proxy.connections, hasLength(1));
      expect(launcher.launched, isEmpty);
      // The owner itself is unaffected.
      direct = await ServiceClient.connect(serviceEndpoint(profile));
      expect((await direct.call('status') as Map)['pid'], owner.pid);
    } finally {
      await direct?.close();
      await proxy.close();
      await launcher.stopAll();
      await owner.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an old client recognizes a closing refusal by its unchanged text (wire '
      'compatibility)', () async {
    final profile = newProfile('of-wire-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.helper_closed'],
    );
    ServiceClient? stopper;
    try {
      await owner.ready();
      stopper = await ServiceClient.connect(serviceEndpoint(profile));
      final idle = stopper.call('service.stop_if_idle');
      await owner.reached('close.helper_closed');
      final frame = await rawRequest(serviceEndpoint(profile), 7, 'status');
      expect(frame['done'], isTrue);
      final error = frame['error'] as Map;
      // v0.1.0-v0.1.2 clients match exactly these two fields.
      expect(error['code'], 'unavailable');
      expect(error['message'], closingMessage);
      // The reason is one additive field that such clients ignore.
      expect(error['reason'], 'closing');
      expect(error.keys, unorderedEquals(['code', 'message', 'reason']));
      owner.release('close.helper_closed');
      expect(await idle.timeout(startupBound), {
        'stopped': true,
        'shutdown_verified': true,
      });
      expect(await owner.exited(), 0, reason: owner.output);
    } finally {
      await stopper?.close();
      await owner.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('startup joins a real closing owner and attaches to its one replacement '
      '(T3, SL-3)', () async {
    final profile = newProfile('of-join-');
    final helper = await GatedHelper.create(Directory(profile.data).parent);
    // The helper exits at once on SIGTERM; the gate holds the owner.
    helper.release();
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      environment: {'FORESIGHT_HELPER': helper.executable},
      hold: ['close.helper_closed'],
    );
    final launcher = await launcherFor(profile);
    final proxy = ServiceFaultProxy();
    ServiceClient? stopper, attached;
    try {
      await owner.ready();
      await helper.started();
      stopper = await ServiceClient.connect(serviceEndpoint(profile));
      final idle = stopper.call('service.stop_if_idle');
      await owner.reached('close.helper_closed');
      final refused = proxy
          .seen(ProxyDirection.toClient, where: isClosingFrame)
          .timeout(const Duration(seconds: 60));
      final startup = proxy.run(
        () => ensureService(profile, startupTimeout: startupBound),
      );
      final settled = settledFlag(startup);
      await refused;
      // The refused probe waits for its connection to end; the owner still
      // holds the profile, so nothing launches.
      expect(settled(), isFalse);
      expect(launcher.launched, isEmpty);
      final toOldOwner = proxy.connections.length;
      owner.release('close.helper_closed');
      expect(await idle.timeout(startupBound), {
        'stopped': true,
        'shutdown_verified': true,
      });
      expect(await owner.exited(), 0, reason: owner.output);
      attached = await startup;
      final status = await attached.call('status') as Map;
      expect(launcher.launched, [status['pid']]);
      // Every probe the closing owner received got a structured refusal;
      // none ended in a bare EOF (D3).
      for (final connection in proxy.connections.take(toOldOwner)) {
        final replies = proxy.frames.where(
          (frame) =>
              frame.connection == connection &&
              frame.direction == ProxyDirection.toClient &&
              frame.method == 'status',
        );
        expect(replies, isNotEmpty, reason: 'connection ${connection.index}');
        expect(replies.every(isClosingFrame), isTrue);
      }
    } finally {
      await stopper?.close();
      await attached?.close();
      await proxy.close();
      await launcher.stopAll();
      await owner.stop();
      helper.kill();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'after an unexpected worker exit new clients are refused and the handoff '
    'reaches one replacement (SL-3)',
    () async {
      final profile = newProfile('of-crash-');
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['frontend.draining'],
      );
      final launcher = await launcherFor(profile);
      final proxy = ServiceFaultProxy();
      ServiceClient? client, latecomer, replacement;
      try {
        await owner.ready();
        // The worker dies at this point without any cleanup.
        File(
          '${owner.gates.directory.path}/request.committed.notes.list.crash',
        ).writeAsStringSync('');
        client = await ServiceClient.connect(serviceEndpoint(profile));
        final lost = failureOf(client.call('notes.list'));
        // Only a crash ends a request with a bare EOF (D3).
        expect(
          await lost,
          rpcError(
            RpcErrorCode.unavailable,
            'Application service disconnected',
            'outcomeUnknown',
          ),
        );
        await owner.reached('frontend.draining');
        latecomer = await ServiceClient.connect(serviceEndpoint(profile));
        expect(
          await failureOf(latecomer.call('status')),
          rpcError(RpcErrorCode.unavailable, closingMessage, 'closing'),
        );
        final refused = proxy
            .seen(ProxyDirection.toClient, where: isClosingFrame)
            .timeout(const Duration(seconds: 60));
        final startup = proxy.run(
          () => ensureService(profile, startupTimeout: startupBound),
        );
        final settled = settledFlag(startup);
        await refused;
        expect(settled(), isFalse);
        expect(launcher.launched, isEmpty);
        owner.release('frontend.draining');
        // The process reports the worker's failure.
        expect(await owner.exited(), isNot(0), reason: owner.output);
        replacement = await startup;
        expect(launcher.launched, [
          (await replacement.call('status') as Map)['pid'],
        ]);
        // The replacement serves at the public socket path. The old process
        // could not have removed it: its own removal ran, under its leaked
        // lock, before the replacement could start. SI's "a frontend whose
        // worker died never unlinks a socket that replaced its own" covers
        // the identity check itself.
        expect(
          FileSystemEntity.typeSync(serviceEndpoint(profile)),
          FileSystemEntityType.unixDomainSock,
        );
        final direct = await ServiceClient.connect(serviceEndpoint(profile));
        try {
          expect(
            (await direct.call('status') as Map)['pid'],
            launcher.launched.single,
          );
        } finally {
          await direct.close();
        }
      } finally {
        await client?.close();
        await latecomer?.close();
        await replacement?.close();
        await proxy.close();
        await launcher.stopAll();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('two launcher processes join one closing owner and attach to the same '
      'replacement', () async {
    final probe = await HookedServiceBuild.compile(
      testHooks: false,
      entryPoint: 'test/fixtures/closing_owner_launcher.dart',
    );
    final profile = newProfile('of-two-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.helper_closed'],
    );
    final launcher = await launcherFor(profile);
    final launchers = <Process>[];
    try {
      await owner.ready();
      owner.signal(ProcessSignal.sigterm);
      await owner.reached('close.helper_closed');
      for (var i = 0; i < 2; i++) {
        launchers.add(
          await Process.start(
            Platform.resolvedExecutable,
            [probe.kernel],
            environment: {
              for (final entry in Platform.environment.entries)
                if (!entry.key.startsWith('FORESIGHT_')) entry.key: entry.value,
              'FORESIGHT_DATA': profile.data,
              'FORESIGHT_RUNTIME': profile.runtime,
              'FORESIGHT_SERVICE': launcher.executable,
              'FORESIGHT_HELPER': '',
            },
            includeParentEnvironment: false,
          ),
        );
      }
      final errors = [
        for (final process in launchers)
          utf8.decoder.bind(process.stderr).join(),
      ];
      final lines = [
        for (final process in launchers)
          StreamIterator(
            utf8.decoder.bind(process.stdout).transform(const LineSplitter()),
          ),
      ];
      Future<String> next(int index) async {
        final more = await lines[index].moveNext().timeout(
          const Duration(seconds: 120),
        );
        if (!more) fail('Launcher $index exited: ${await errors[index]}');
        return lines[index].current;
      }

      // Both launcher processes got the closing refusal; neither launched
      // while the owner held the profile.
      expect(await next(0), 'refused');
      expect(await next(1), 'refused');
      expect(launcher.launched, isEmpty);
      owner.release('close.helper_closed');
      expect(await owner.exited(), 0, reason: owner.output);
      final attached = {await next(0), await next(1)};
      expect(attached, hasLength(1));
      final pid = int.parse(attached.single.split(' ').last);
      expect(launcher.launched, contains(pid));
      // Each launches at most once; a losing replacement exits.
      expect(launcher.launched.length, inInclusiveRange(1, 2));
      for (final process in launchers) {
        expect(await process.exitCode.timeout(startupBound), 0);
      }
      for (final other in launcher.launched.where((other) => other != pid)) {
        await eventually(
          () async => !await isRunning(other),
          timeout: startupBound,
        );
      }
      expect(await isRunning(pid), isTrue);
    } finally {
      for (final process in launchers) {
        process.kill(ProcessSignal.sigkill);
      }
      await launcher.stopAll();
      await owner.stop();
      await probe.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
    'an attached ServiceConnection and RemoteDomain follow a closing owner and '
    'send each refused request to it only once (SL-9)',
    () async {
      final profile = newProfile('of-attached-');
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['close.helper_closed'],
      );
      final launcher = await launcherFor(profile);
      final proxy = ServiceFaultProxy();
      final connection = ServiceConnection(profile);
      RemoteDomain? remote;
      try {
        await owner.ready();
        await proxy.run(() => connection.connect());
        final domain = await proxy.run(() => RemoteDomain.connect(profile));
        remote = domain;
        owner.signal(ProcessSignal.sigterm);
        await owner.reached('close.helper_closed');
        // The owner refuses each request, then its frontend refuses each
        // client's startup probe for the next owner.
        final refused = proxy
            .seen(ProxyDirection.toClient, where: isClosingFrame, count: 4)
            .timeout(const Duration(seconds: 60));
        final listed = proxy.run(
          () => connection.stream('notes.list').toList(),
        );
        final commanded = proxy.run(() => domain.command(Operation.notesList));
        await refused;
        expect(launcher.launched, isEmpty);
        final oldConnections = proxy.connections.toSet();
        owner.release('close.helper_closed');
        expect(await owner.exited(), 0, reason: owner.output);
        expect(await listed, [isEmpty]);
        expect(await commanded, isEmpty);
        final pids = {
          (await connection.stream('status').single as Map)['pid'],
          (await domain.command(Operation.status) as Map)['pid'],
        };
        expect(pids, hasLength(1));
        expect(launcher.launched, contains(pids.single));
        List<ServiceFrame> lists({required bool toClosingOwner}) => [
          for (final frame in proxy.frames)
            if (frame.direction == ProxyDirection.toService &&
                frame.method == 'notes.list' &&
                oldConnections.contains(frame.connection) == toClosingOwner)
              frame,
        ];
        // Each client sent notes.list to the closing owner exactly once and
        // once more to the replacement.
        expect(lists(toClosingOwner: true), hasLength(2));
        expect(lists(toClosingOwner: false), hasLength(2));
      } finally {
        remote?.close();
        remote?.store.close();
        await connection.close();
        await proxy.close();
        await launcher.stopAll();
        await owner.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // A desktop's startup snapshot reserves the owner's lifetime, so the race
  // left is the grace ending before that reservation arrives.
  for (final held in ['status']) {
    test(
      'a desktop starting as the detach grace ends follows the owner to its '
      'replacement and attaches approvals once (held $held) (SL-9)',
      () async {
        // The launched replacement records its canonical data path.
        final directory = createServiceTestDirectorySync('of-grace-');
        final profile = ProfilePaths(
          '${directory.path}/data',
          '${directory.path}/run',
        );
        // This in-process owner reads the gate directory as it closes.
        final gates = await ServiceGates.create(directory);
        runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
            gates.directory.path;
        gates.hold('close.begin');
        final launcher = await launcherFor(profile);
        // In process, an unset helper disables it; replacements get ''.
        runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
        final service = await ApplicationService.start(
          profile,
          desktopDetachGrace: Duration.zero,
        );
        runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
        final proxy = ServiceFaultProxy();
        ServiceClient? previous;
        RemoteDomain? remote;
        try {
          previous = await ServiceClient.connect(serviceEndpoint(profile));
          await previous.call('security.attach_desktop', {
            'token': File(
              '${profile.data}/.desktop-capability',
            ).readAsStringSync(),
          });
          // The second status is the desktop's reserving snapshot.
          var statuses = 0;
          final request = proxy.hold(
            ProxyDirection.toService,
            where: (frame) =>
                frame.method == held && (held != 'status' || ++statuses == 2),
          );
          final connecting = proxy.run(() async {
            final domain = await RemoteDomain.connect(profile);
            await domain.enableDesktopApprovals((_) {});
            return domain;
          });
          await request.reached;
          // The previous desktop leaves while the new one is between its
          // calls; the grace ends and the owner begins closing.
          await previous.close();
          await gates.reached('close.begin');
          runtimeConfiguration.environment.remove('FORESIGHT_SERVICE_GATES');
          // The owner refuses the snapshot; startup then waits for this
          // owner inside the same handoff.
          final refused = proxy
              .seen(ProxyDirection.toClient, where: isClosingFrame)
              .timeout(const Duration(seconds: 60));
          request.release();
          await refused;
          expect(launcher.launched, isEmpty);
          final oldConnections = proxy.connections.toSet();
          gates.release('close.begin');
          await service.closed;
          remote = await connecting;
          final pid = (await remote.command(Operation.status) as Map)['pid'];
          expect(launcher.launched, [pid]);
          Iterable<ServiceFrame> sent(String method, bool toClosingOwner) =>
              proxy.frames.where(
                (frame) =>
                    frame.direction == ProxyDirection.toService &&
                    frame.method == method &&
                    oldConnections.contains(frame.connection) == toClosingOwner,
              );
          // Approvals are attached once on the replacement; nothing other
          // than status and that attach was ever sent.
          expect(sent('security.attach_desktop', false), hasLength(1));
          expect(
            sent('security.attach_desktop', true),
            hasLength(held == 'status' ? 0 : 1),
          );
          expect(
            proxy.frames
                .where((frame) => frame.direction == ProxyDirection.toService)
                .map((frame) => frame.method)
                .toSet(),
            {'status', 'security.attach_desktop'},
          );
        } finally {
          gates.releaseAll();
          await previous?.close();
          remote?.close();
          remote?.store.close();
          await proxy.close();
          await service.close();
          await launcher.stopAll();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'a replacement that fails to start reports its cause at once (L3)',
    () async {
      final profile = newProfile('of-dead-');
      final launcher = await launcherFor(profile);
      // The service refuses a capability link after it takes the lock.
      Directory(profile.data).createSync(recursive: true);
      Link(
        '${profile.data}/.desktop-capability',
      ).createSync('${profile.data}/elsewhere');
      final failure = await failureOf(
        ensureService(profile, startupTimeout: const Duration(minutes: 3)),
      );
      expect(
        failure,
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            startsWith('Application service failed to start: '),
            contains('Desktop capability must not be a symbolic link'),
            isNot(contains('\n')),
          ),
        ),
      );
      expect(launcher.launched, hasLength(1));
      await eventually(
        () async => !await isRunning(launcher.launched.single),
        timeout: startupBound,
      );
      // The launcher removed the status file the service wrote for it.
      expect(
        Directory(profile.runtime).listSync().map((entry) => entry.path),
        everyElement(isNot(contains('startup-'))),
      );
      expect(launcher.log.readAsStringSync(), contains('symbolic link'));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('a startup status is written only inside the profile runtime', () {
    final profile = newProfile('of-status-');
    Directory(profile.runtime).createSync(recursive: true);
    final outside = '${Directory(profile.runtime).parent.path}/startup-x.json';
    for (final path in [
      outside,
      '${profile.runtime}/application.sock',
      '${profile.runtime}/startup-../x.json',
    ]) {
      runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = path;
      recordServiceStartupFailure(profile, StateError('failed'));
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    final inside = '${profile.runtime}/startup-1-2-3.json';
    runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = inside;
    recordServiceStartupFailure(profile, StateError('Startup broke'));
    expect(jsonDecode(File(inside).readAsStringSync()), {
      'state': 'failed',
      'error': 'Startup broke',
    });
    expect(FileStat.statSync(inside).mode & 0x1ff, 0x180);
  });

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
          if (!entry.key.startsWith('FORESIGHT_')) entry.key: entry.value,
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

  test(
    '--stop returns only after the owner releases its profile lock (L6)',
    () async {
      final profile = newProfile('of-stop-');
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['close.before_lock_release'],
      );
      await owner.ready();
      final stop = await startStop(profile);
      var exited = false;
      unawaited(stop.process.exitCode.then((_) => exited = true));
      await owner.reached('close.before_lock_release');
      // Every connection has closed; --stop found the lock still held and
      // keeps waiting instead of reporting success at that EOF.
      await stop.line('still holds its profile');
      expect(exited, isFalse);
      owner.release('close.before_lock_release');
      expect(await stop.exited(), 0, reason: stop.lines.join('\n'));
      expect(
        stop.lines,
        contains(
          'Waiting for the application service (pid ${owner.pid}) to '
          'release its profile.',
        ),
      );
      expect(await owner.exited(), 0, reason: owner.output);
      // A clean shutdown gets no warning.
      expect(stop.lines.join('\n'), isNot(contains('clean shutdown')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('--stop fails when the owner keeps its profile past the release bound '
      '(L6)', () async {
    final profile = newProfile('of-stuck-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.before_lock_release'],
    );
    await owner.ready();
    final stop = await startStop(
      profile,
      environment: {'FORESIGHT_TEST_STOP_RELEASE_MS': '200'},
    );
    await owner.reached('close.before_lock_release');
    expect(await stop.exited(), isNot(0));
    expect(
      stop.lines.join('\n'),
      contains(
        'The application service (pid ${owner.pid}) closed its connections '
        'but did not release its profile within 200 ms.',
      ),
    );
    owner.release('close.before_lock_release');
    expect(await owner.exited(), 0, reason: owner.output);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('--stop succeeds but warns when the owner stops without a clean '
      'shutdown (L6)', () async {
    final profile = newProfile('of-unclean-');
    final owner = await HookedServiceProcess.start(build, profile);
    await owner.ready();
    // The worker dies just before deleting its record, leaving it behind.
    File(
      '${owner.gates.directory.path}/close.before_record_delete.crash',
    ).writeAsStringSync('');
    final stop = await startStop(profile);
    expect(await stop.exited(), 0, reason: stop.lines.join('\n'));
    expect(
      stop.lines,
      contains(
        'The application service stopped without a clean shutdown; its '
        'endpoint record remains, and the next start recovers its runtime.',
      ),
    );
    await owner.exited();
    expect(
      File('${profile.data}/.application-endpoint.json').existsSync(),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the release wait ends when the lock is free or the owner is gone, and '
      'gives up after its bound', () async {
    final profile = newProfile('of-release-');
    Directory(profile.data).createSync(recursive: true);
    final lock = '${profile.data}/.application.lock';
    File(lock).writeAsStringSync('');
    // Another process holds the profile lock until its stdin closes.
    final holder = await Process.start('python3', [
      '-c',
      'import fcntl,sys\nf=open(sys.argv[1],"a")\n'
          'fcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\n'
          'sys.stdin.read()',
      lock,
    ]);
    try {
      expect(
        await utf8.decoder
            .bind(holder.stdout)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      expect(
        await awaitProfileRelease(
          profile,
          holder.pid,
          timeout: const Duration(milliseconds: 200),
        ),
        isFalse,
      );
      // A process that is gone has released its profile, whoever holds
      // the lock now.
      // From PATH: macOS has no /bin/true.
      final gone = await Process.start('true', []);
      await gone.exitCode.timeout(startupBound);
      expect(await awaitProfileRelease(profile, gone.pid), isTrue);
      await holder.stdin.close();
      await holder.exitCode.timeout(startupBound);
      final waited = await awaitProfileRelease(
        profile,
        pid,
        timeout: const Duration(seconds: 30),
      );
      expect(waited, isTrue);
    } finally {
      holder.kill(ProcessSignal.sigkill);
    }
  });

  test('a startup probe that the closing owner ends with outcomeUnknown hands '
      'off to one replacement', () async {
    final profile = newProfile('of-probe-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.helper_closed'],
    );
    final launcher = await launcherFor(profile);
    final proxy = ServiceFaultProxy();
    ServiceClient? attached;
    try {
      await owner.ready();
      // Hold the next status at its commit, so the probe is in flight.
      owner.hold('request.committed.status');
      final ended = proxy
          .seen(
            ProxyDirection.toClient,
            where: (frame) => frame.error?['reason'] == 'outcomeUnknown',
          )
          .timeout(const Duration(seconds: 120));
      final startup = proxy.run(
        () => ensureService(profile, startupTimeout: startupBound),
      );
      final settled = settledFlag(startup);
      await owner.reached('request.committed.status');
      owner.signal(ProcessSignal.sigterm);
      await owner.reached('close.helper_closed');
      await ended;
      // Status is read-only: startup waits for this owner, not fails.
      expect(settled(), isFalse);
      expect(launcher.launched, isEmpty);
      owner.release('close.helper_closed');
      owner.release('request.committed.status');
      expect(await owner.exited(), 0, reason: owner.output);
      attached = await startup.timeout(startupBound);
      expect(launcher.launched, [
        (await attached.call('status') as Map)['pid'],
      ]);
    } finally {
      await attached?.close();
      await proxy.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'at SIGTERM a request waiting for approval is refused and resent once to '
    'the replacement, while a dispatched one is outcomeUnknown',
    () async {
      final profile = newProfile('of-waiting-');
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        hold: ['close.helper_closed', 'request.committed.notes.save'],
      );
      final launcher = await launcherFor(profile);
      final proxy = ServiceFaultProxy();
      final connection = ServiceConnection(profile);
      ServiceClient? desktop, writer, replacementDesktop;
      Future<ServiceClient> attachDesktop() async {
        final host = await ServiceClient.connect(serviceEndpoint(profile));
        await host.call('security.attach_desktop', {
          'token': File(
            '${profile.data}/.desktop-capability',
          ).readAsStringSync(),
        });
        return host;
      }

      Future<Map<String, dynamic>> approval(ServiceClient host) => host
          .events
          .stream
          .firstWhere((event) => event['event'] == 'approval')
          .timeout(const Duration(seconds: 120));
      try {
        await owner.ready();
        desktop = await attachDesktop();
        final shown = approval(desktop);
        writer = await ServiceClient.connect(serviceEndpoint(profile));
        final save = failureOf(
          writer.call('notes.save', {'title': 'Dispatched', 'body': 'b'}),
        );
        await owner.reached('request.committed.notes.save');
        // An agent's deletion waits for the desktop's decision.
        var deletions = 0;
        final resent = proxy.hold(
          ProxyDirection.toService,
          where: (frame) =>
              frame.method == 'sources.delete' && ++deletions == 2,
        );
        final refused = proxy
            .seen(
              ProxyDirection.toClient,
              method: 'sources.delete',
              where: isClosingFrame,
            )
            .timeout(const Duration(seconds: 120));
        final deletion = failureOf(
          proxy.run(
            () => connection.stream('sources.delete', {
              'id': 'fixture-source',
            }).toList(),
          ),
        );
        expect((await shown)['method'], 'sources.delete');
        owner.signal(ProcessSignal.sigterm);
        await owner.reached('close.helper_closed');
        expect(
          await save,
          rpcError(
            RpcErrorCode.unavailable,
            outcomeUnknownMessage,
            'outcomeUnknown',
          ),
        );
        await refused;
        owner.release('close.helper_closed');
        owner.release('request.committed.notes.save');
        expect(await owner.exited(), 0, reason: owner.output);
        // The connection handed off; its one resend waits at the proxy until
        // a desktop is attached to the replacement.
        await resent.reached.timeout(startupBound);
        replacementDesktop = await attachDesktop();
        final shownAgain = approval(replacementDesktop);
        resent.release();
        final request = await shownAgain;
        expect(request['method'], 'sources.delete');
        await replacementDesktop.call('security.decide', {
          'approval_id': request['approval_id'],
          'allow': false,
        });
        expect(
          await deletion,
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        );
        // Refused by the closing owner, then sent once to the replacement.
        expect(
          proxy.frames.where(
            (frame) =>
                frame.direction == ProxyDirection.toService &&
                frame.method == 'sources.delete',
          ),
          hasLength(2),
        );
        expect(launcher.launched, hasLength(1));
      } finally {
        await desktop?.close();
        await writer?.close();
        await replacementDesktop?.close();
        await connection.close();
        await proxy.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a replacement that loses the profile lock records no startup failure '
      '(L3)', () async {
    final profile = newProfile('of-contended-');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    final lock = '${profile.data}/.application.lock';
    File(lock).writeAsStringSync('');
    // Another process holds the lock, as a winning replacement, or a
    // momentary probe by another launcher or --stop, would.
    final holder = await Process.start('python3', [
      '-c',
      'import fcntl,sys\nf=open(sys.argv[1],"a")\n'
          'fcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\n'
          'sys.stdin.read()',
      lock,
    ]);
    try {
      expect(
        await utf8.decoder
            .bind(holder.stdout)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      final status = File('${profile.runtime}/startup-contended.json');
      final run = await Process.run(
        Platform.resolvedExecutable,
        [build.kernel],
        environment: {
          for (final entry in Platform.environment.entries)
            if (!entry.key.startsWith('FORESIGHT_')) entry.key: entry.value,
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
          'FORESIGHT_HELPER': '',
          'FORESIGHT_STARTUP_STATUS': status.path,
        },
        includeParentEnvironment: false,
      ).timeout(startupBound);
      expect(run.exitCode, isNot(0));
      expect(run.stderr, contains('Another application service owns'));
      // Its launcher keeps waiting for the owner that holds the lock. The
      // file is absent because the start chose not to record it, not because
      // the status path was rejected or could not be written.
      expect(status.existsSync(), isFalse);
      expect(run.stderr, isNot(contains('Ignoring a startup status')));
      expect(run.stderr, isNot(contains('Cannot record')));
    } finally {
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode.timeout(startupBound);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a launch sweeps startup status files no launcher still waits on',
    () async {
      final profile = newProfile('of-sweep-');
      privateDirectory(profile.data);
      privateDirectory(profile.runtime);
      final old = DateTime.now().subtract(const Duration(minutes: 10));
      File entry(String name) => File('${profile.runtime}/$name');
      for (final name in ['startup-old.json', 'startup-old.json.4242']) {
        entry(name)
          ..writeAsStringSync('{}')
          ..setLastModifiedSync(old);
      }
      entry('startup-fresh.json').writeAsStringSync('{}');
      final target = File('${Directory(profile.data).parent.path}/target')
        ..writeAsStringSync('kept');
      Link('${profile.runtime}/startup-link.json').createSync(target.path);
      Directory('${profile.runtime}/startup-dir.json').createSync();
      // A launch that never serves: startup then times out.
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = '/usr/bin/true';
      await expectLater(
        ensureService(profile, startupTimeout: const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        Directory(profile.runtime)
            .listSync()
            .map((item) => item.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
            .where((name) => name.startsWith('startup-'))
            .toSet(),
        {'startup-fresh.json', 'startup-dir.json'},
      );
      expect(target.readAsStringSync(), 'kept');
    },
  );

  test(
    'an owner waits out a momentary lock probe but not another owner (L3)',
    () async {
      final profile = newProfile('of-probed-');
      privateDirectory(profile.data);
      final path = '${profile.data}/.application.lock';
      File(path).writeAsStringSync('');
      Future<Process> holdLock() async {
        // Another process holds the lock until its stdin closes.
        final holder = await Process.start('python3', [
          '-c',
          'import fcntl,sys\nf=open(sys.argv[1],"a")\n'
              'fcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\n'
              'sys.stdin.read()',
          path,
        ]);
        addTearDown(() => holder.kill(ProcessSignal.sigkill));
        expect(
          await utf8.decoder
              .bind(holder.stdout)
              .transform(const LineSplitter())
              .first,
          'locked',
        );
        return holder;
      }

      final lock = File(path).openSync(mode: FileMode.append);
      try {
        // A probe (another launcher's, or --stop's) ends after the first
        // contended attempt: the owner takes the lock on a later one.
        final probe = await holdLock();
        var busy = 0;
        await acquireProfileOwnership(
          lock,
          attempts: 1000,
          onBusy: () {
            if (busy++ == 0) unawaited(probe.stdin.close());
          },
        );
        expect(busy, greaterThan(0));
        lock.unlockSync();
        await probe.exitCode.timeout(startupBound);
        // An owner holds it throughout: the start gives up after its bound.
        final owner = await holdLock();
        busy = 0;
        await expectLater(
          acquireProfileOwnership(lock, attempts: 3, onBusy: () => busy++),
          throwsA(isA<ServiceOwnershipContended>()),
        );
        expect(busy, 2);
        await owner.stdin.close();
      } finally {
        lock.closeSync();
      }
    },
  );
}
