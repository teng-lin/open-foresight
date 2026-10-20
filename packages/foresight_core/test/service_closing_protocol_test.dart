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
import 'package:foresight_test_support/test_paths.dart';
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

  ProfilePaths newProfile(String prefix) {
    final directory = createTestTempDirectorySync(prefix);
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
      expect(await owner.exitCode, 0, reason: owner.output);
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
            null,
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
      expect(await idle, {'stopped': true, 'shutdown_verified': true});
      expect(await owner.exitCode, 0, reason: owner.output);
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
      expect(await idle, {'stopped': true, 'shutdown_verified': true});
      expect(await owner.exitCode, 0, reason: owner.output);
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
        expect(await owner.exitCode, isNot(0), reason: owner.output);
        replacement = await startup;
        expect(launcher.launched, [
          (await replacement.call('status') as Map)['pid'],
        ]);
        // The old frontend left the replacement's public socket alone.
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
      expect(await owner.exitCode, 0, reason: owner.output);
      final attached = {await next(0), await next(1)};
      expect(attached, hasLength(1));
      final pid = int.parse(attached.single.split(' ').last);
      expect(launcher.launched, contains(pid));
      // Each launches at most once; a losing replacement exits.
      expect(launcher.launched.length, inInclusiveRange(1, 2));
      for (final process in launchers) {
        expect(await process.exitCode, 0);
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
        expect(await owner.exitCode, 0, reason: owner.output);
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
        final directory = createTestTempDirectorySync('of-grace-');
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
}
