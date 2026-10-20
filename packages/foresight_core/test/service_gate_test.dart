import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/gated_helper.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const closeGates = [
  'close.begin',
  'close.helper_closed',
  'close.listener_closed',
  'close.before_record_delete',
  'close.before_frontend_release',
  'close.before_lock_release',
];

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

void main() {
  group('serviceGate in this isolate', () {
    late Map<String, String> saved;
    late Directory gates;
    setUp(() {
      saved = Map.of(runtimeConfiguration.environment);
      gates = createTestTempDirectorySync('of-gate-');
    });
    tearDown(() {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(saved);
    });

    test('is a no-op without a gate directory', () async {
      runtimeConfiguration.environment.remove('FORESIGHT_SERVICE_GATES');
      expect(serviceGatesEnabled, isFalse);
      File('${gates.path}/close.begin.hold').writeAsStringSync('');
      await serviceGate('close.begin');
      expect(gates.listSync().map((entry) => entry.uri.pathSegments.last), [
        'close.begin.hold',
      ]);
    });

    test('records each point and holds only armed points', () async {
      runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] = gates.path;
      final control = ServiceGates(gates);
      expect(serviceGatesEnabled, isTrue);
      await serviceGate('close.begin');
      expect(await control.reached('close.begin'), pid);
      control.hold('close.helper_closed');
      var passed = false;
      final held = serviceGate(
        'close.helper_closed',
      ).whenComplete(() => passed = true);
      expect(await control.reached('close.helper_closed'), pid);
      // The gate is still polling for its release file.
      expect(passed, isFalse);
      control.release('close.helper_closed');
      await held;
      control.hold('close.listener_closed');
      final other = serviceGate('close.listener_closed');
      await control.reached('close.listener_closed');
      control.releaseAll();
      await other;
      expect(control.reachedPoints, [
        'close.begin',
        'close.helper_closed',
        'close.listener_closed',
      ]);
      expect(() => serviceGate('../escape'), throwsArgumentError);
    });
  });

  group('hook-enabled service child', () {
    late HookedServiceBuild build;
    setUpAll(() async => build = await HookedServiceBuild.compile());
    tearDownAll(() => build.dispose());

    test(
      'the isolated worker stops at every close gate in order',
      () async {
        final directory = createTestTempDirectorySync('of-gates-');
        final profile = ProfilePaths(
          '${directory.path}/data',
          '${directory.path}/run',
        );
        final helper = await GatedHelper.create(directory);
        final gates = await ServiceGates.create(directory);
        final owner = await HookedServiceProcess.start(
          build,
          profile,
          environment: {'FORESIGHT_HELPER': helper.executable},
          gates: gates,
          hold: closeGates,
        );
        try {
          await owner.ready();
          await helper.started();
          final record = File('${profile.data}/.application-endpoint.json');
          final socket = File('${profile.runtime}/application.sock');
          owner.signal(ProcessSignal.sigterm);
          for (final (index, point) in closeGates.indexed) {
            expect(await owner.reached(point), owner.pid, reason: point);
            // Every later point waits behind this held one.
            for (final later in closeGates.skip(index + 1)) {
              expect(gates.isReached(later), isFalse, reason: later);
            }
            switch (point) {
              case 'close.begin':
                // The helper is closed only after this point.
                expect(helper.isStopping, isFalse);
              case 'close.helper_closed':
                expect(helper.isStopping, isTrue);
              case 'close.before_record_delete':
                expect(record.existsSync(), isTrue);
                expect(socket.existsSync(), isTrue);
              case 'close.before_frontend_release':
                expect(record.existsSync(), isFalse);
                expect(socket.existsSync(), isTrue);
              case 'close.before_lock_release':
                expect(socket.existsSync(), isFalse);
                expect(lockHeld(profile), isTrue);
            }
            if (point == 'close.begin') {
              owner.release(point);
              await helper.stopping();
              helper.release();
            } else {
              owner.release(point);
            }
          }
          expect(await owner.exitCode, 0, reason: owner.output);
          expect(lockHeld(profile), isFalse);
        } finally {
          helper.release();
          await owner.stop();
          helper.kill();
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'a committed request waits at its gate before the reply is sent',
      () async {
        final directory = createTestTempDirectorySync('of-commit-');
        final profile = ProfilePaths(
          '${directory.path}/data',
          '${directory.path}/run',
        );
        final owner = await HookedServiceProcess.start(
          build,
          profile,
          hold: ['request.committed.notes.save'],
        );
        ServiceClient? writer, reader;
        try {
          await owner.ready();
          writer = await ServiceClient.connect(serviceEndpoint(profile));
          reader = await ServiceClient.connect(serviceEndpoint(profile));
          var replied = false;
          final save = writer.call('notes.save', {
            'title': 'Committed',
            'body': 'before its reply',
          });
          unawaited(
            save.then<void>((_) => replied = true, onError: (Object _) {}),
          );
          await owner.reached('request.committed.notes.save');
          // The row is visible to another connection; the reply is not sent.
          expect(
            (await reader.call('notes.list') as List).single['title'],
            'Committed',
          );
          expect(replied, isFalse);
          owner.release('request.committed.notes.save');
          expect(await save, isA<Map>());
        } finally {
          await writer?.close();
          await reader?.close();
          await owner.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  test(
    'a service compiled without test hooks ignores FORESIGHT_SERVICE_GATES',
    () async {
      final build = await HookedServiceBuild.compile(testHooks: false);
      final directory = createTestTempDirectorySync('of-release-');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final helper = await GatedHelper.create(directory);
      final gates = await ServiceGates.create(directory);
      final owner = await HookedServiceProcess.start(
        build,
        profile,
        environment: {'FORESIGHT_HELPER': helper.executable},
        gates: gates,
        hold: closeGates,
      );
      try {
        await owner.ready();
        await helper.started();
        owner.signal(ProcessSignal.sigterm);
        // With hooks, close.begin would hold before the helper is stopped.
        await helper.stopping();
        helper.release();
        expect(await owner.exitCode, 0, reason: owner.output);
        expect(gates.reachedPoints, isEmpty);
        expect(
          File('${profile.data}/.application-endpoint.json').existsSync(),
          isFalse,
        );
      } finally {
        helper.release();
        await owner.stop();
        helper.kill();
        await build.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
