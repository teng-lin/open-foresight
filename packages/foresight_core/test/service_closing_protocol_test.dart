import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/hooked_service.dart';
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
    .timeout(const Duration(seconds: 60));

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
      final save = writer.call('notes.save', {
        'title': 'Committed before close',
        'body': 'its reply is lost',
      });
      await owner.reached('request.committed.notes.save');
      // The desktop leaving starts a worker-initiated close after its
      // reattach grace; the frontend keeps relaying attached clients.
      await desktop.close();
      expect(
        await failureOf(save),
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
}
