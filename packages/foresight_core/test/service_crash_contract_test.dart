import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart'
    show ServiceClient, serviceEndpoint;
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:test/test.dart';

// Desktop <-> service, crash contract. The production RemoteDomain, with its
// desktop approval window attached, talks to the real bin/service.dart
// (compiled with its test hooks), which is killed with SIGKILL: a crash that
// runs no shutdown code. The only addition to the service is the hook that
// holds it after a commit, so the kill lands at an exact instant. The helper
// is disabled, the replacement is started by a /bin/sh launcher through
// ensureService, and the tests cover one request at a time; the inventory
// lists what that leaves unproven.

const bound = Duration(seconds: 30);

void main() {
  bootstrapSqlSupportFixture();
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

  /// Wait for [future], and say what the service and its launcher printed if
  /// it does not finish.
  Future<T> within<T>(
    Future<T> future,
    String what,
    HookedServiceProcess owner,
    ServiceLauncher launcher,
  ) => future.timeout(
    bound,
    onTimeout: () => throw TimeoutException(
      '$what did not finish within $bound.\n'
      'owner ${owner.pid} output:\n${owner.output}\n'
      'launched ${launcher.launched}, launcher log:\n'
      '${launcher.log.existsSync() ? launcher.log.readAsStringSync() : '(none)'}',
    ),
  );

  Future<RemoteDomain> attach(ProfilePaths profile) async {
    final domain = await RemoteDomain.connect(profile);
    addTearDown(() async {
      domain.close();
      await domain.closed;
    });
    return domain;
  }

  Future<List<Object?>> titles(RemoteDomain domain) async => [
    for (final note in (await domain.command(Operation.notesList)) as List)
      (note as Map)['title'],
  ];

  /// The approval window works against whichever service the desktop now
  /// talks to: an agent overwrites an existing note, the desktop's callback
  /// receives the approval, the desktop decides, and only then does the
  /// overwrite land. A desktop that had not re-attached would leave the agent
  /// refused with needsDesktop instead.
  Future<void> approvedOverwriteRoundTrip(
    RemoteDomain domain,
    List<Map<String, dynamic>> approvals,
    ProfilePaths profile,
    String expectedTitle,
  ) async {
    final note =
        ((await domain.command(Operation.notesList)) as List).single as Map;
    approvals.clear();
    final agent = await ServiceClient.connect(serviceEndpoint(profile));
    addTearDown(agent.close);
    final work = agent.call('notes.save', {
      'id': note['id'],
      'title': 'Rewritten by an agent',
      'body': 'after the desktop approved',
    });
    await eventually(
      () => approvals.any((event) => event['method'] == 'notes.save'),
      timeout: bound,
    );
    final approval = approvals.firstWhere((e) => e['event'] == 'approval');
    expect(approval['args'], containsPair('id', note['id']));
    expect(note['title'], expectedTitle);
    expect(
      await domain.client.call('security.decide', {
        'approval_id': approval['approval_id'],
        'allow': true,
      }),
      isTrue,
    );
    expect(await work, isA<Map>());
    expect(await titles(domain), ['Rewritten by an agent']);
  }

  /// The desktop reconnects on its own when it sees the loss (RemoteDomain
  /// listens for its connection ending); no command is needed to start the
  /// replacement. Wait for that launch, with the service output on failure.
  Future<void> reconnectedByItself(_Session s) => within(
    eventually(() => s.launcher.launched.length == 1, timeout: bound),
    'the desktop starting a replacement on its own',
    s.owner,
    s.launcher,
  );

  /// SIGKILL [owner] and check that it died of that signal, not of a clean
  /// exit that would have run shutdown code.
  Future<void> crash(
    HookedServiceProcess owner,
    ServiceLauncher launcher,
  ) async {
    expect(owner.signal(ProcessSignal.sigkill), isTrue);
    expect(
      await within(
        owner.exited(),
        'the killed service exiting',
        owner,
        launcher,
      ),
      -ProcessSignal.sigkill.signalNumber,
      reason: owner.output,
    );
  }

  Future<_Session> start(
    String prefix, {
    Iterable<String> hold = const [],
  }) async {
    final directory = createServiceTestDirectorySync(prefix);
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    final owner = await HookedServiceProcess.start(build, profile, hold: hold);
    await owner.ready();
    final launcher = await build.launcher(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.executable;
    final domain = await attach(profile);
    // The desktop approval window: the reconnect must attach it again.
    final approvals = <Map<String, dynamic>>[];
    await domain.enableDesktopApprovals(approvals.add);
    // A hidden window cannot show approvals; the reconnect must keep it visible.
    await domain.setDesktopVisible(true);
    return _Session(owner, launcher, domain, approvals, profile);
  }

  test(
    'a service killed after committing a mutation and before its reply: the '
    'desktop is told the outcome is unknown, never resends, re-attaches its '
    'approval window, and the replacement holds the mutation exactly once',
    () async {
      final s = await start(
        'of-crash-commit-',
        hold: ['request.committed.notes.save'],
      );
      final save = s.domain.command(Operation.notesSave, {
        'title': 'Committed once',
        'body': 'the reply is lost',
      });
      final outcome = save.then<Object?>((value) => value, onError: (e) => e);
      // The row is durable and the reply is not sent: kill at that instant.
      await within(
        s.owner.reached('request.committed.notes.save'),
        'the service reaching its commit gate',
        s.owner,
        s.launcher,
      );
      await crash(s.owner, s.launcher);

      final error = await within(
        outcome,
        'the lost request settling',
        s.owner,
        s.launcher,
      );
      expect(error, isA<RpcError>(), reason: 'outcome: $error');
      expect((error as RpcError).reason, RpcErrorReason.outcomeUnknown);

      // The desktop reconnects by itself once it sees the loss; that reconnect
      // must not resend notes.save.
      await reconnectedByItself(s);
      expect(
        await within(titles(s.domain), 'listing notes', s.owner, s.launcher),
        ['Committed once'],
      );
      expect(s.launcher.launched, hasLength(1));
      expect(s.launcher.launched.single, isNot(s.owner.pid));
      // The replacement has the desktop approval window attached again.
      await approvedOverwriteRoundTrip(
        s.domain,
        s.approvals,
        s.profile,
        'Committed once',
      );
      expect(s.launcher.launched, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a service killed while idle: the desktop reconnects on its own to one '
      'replacement, re-attaches its approval window, and the committed data '
      'survived', () async {
    final s = await start('of-crash-idle-');
    await s.domain.command(Operation.notesSave, {
      'title': 'Before the crash',
      'body': 'committed and replied',
    });
    await crash(s.owner, s.launcher);
    // No command is issued: the desktop starts the replacement itself.
    await reconnectedByItself(s);

    expect(
      await within(titles(s.domain), 'listing notes', s.owner, s.launcher),
      ['Before the crash'],
    );
    expect(s.launcher.launched, hasLength(1));
    expect(s.launcher.launched.single, isNot(s.owner.pid));
    final status = await s.domain.command(Operation.status) as Map;
    expect(status['pid'], s.launcher.launched.single);
    await approvedOverwriteRoundTrip(
      s.domain,
      s.approvals,
      s.profile,
      'Before the crash',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'control: a request issued after the loss was seen was never sent, so the '
    'reconnect sends it once and it succeeds (not every loss is outcomeUnknown)',
    () async {
      final s = await start('of-crash-unsent-');
      final lost = s.domain.client;
      final seen = lost.events.stream.drain<void>();
      await crash(s.owner, s.launcher);
      await within(
        seen,
        'the desktop seeing the lost connection',
        s.owner,
        s.launcher,
      );

      final result = await within(
        s.domain.command(Operation.notesSave, {
          'title': 'Sent after the loss',
          'body': 'once',
        }),
        'the unsent request',
        s.owner,
        s.launcher,
      );
      expect(result, isA<Map>());
      expect(await titles(s.domain), ['Sent after the loss']);
      expect(s.launcher.launched, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _Session {
  _Session(
    this.owner,
    this.launcher,
    this.domain,
    this.approvals,
    this.profile,
  );
  final HookedServiceProcess owner;
  final ServiceLauncher launcher;
  final RemoteDomain domain;
  final List<Map<String, dynamic>> approvals;
  final ProfilePaths profile;
}
