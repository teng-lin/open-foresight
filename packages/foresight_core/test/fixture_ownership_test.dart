import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/fixture_ownership.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// A real child that ignores SIGTERM (Dart watches it) and reports readiness
/// only after the handler is installed.
Future<OwnedProcess> startTermIgnoringChild(OwnedProcesses owned) async {
  final script =
      File(
        '${createTestTempDirectorySync('owned-child-').path}/ignore_term.dart',
      )..writeAsStringSync('''
import 'dart:io';
void main() {
  ProcessSignal.sigterm.watch().listen((_) {});
  stdout.writeln('ready');
}
''');
  final child = await owned.start(Platform.resolvedExecutable, [
    script.path,
  ], name: 'term-ignoring child');
  await child.stdout
      .transform(utf8.decoder)
      .firstWhere((text) => text.contains('ready'))
      .timeout(const Duration(seconds: 60));
  return child;
}

void main() {
  group('eventually failure evidence', () {
    test('keeps the original first line and adds label and observation', () {
      final message = eventuallyFailureMessage(
        const Duration(seconds: 3),
        label: 'owner records',
        describe: () => 'owner=null',
      );
      expect(
        message.split('\n').first,
        'Condition was not observed before the 0:00:03.000000 deadline',
      );
      expect(message, contains('awaiting: owner records'));
      expect(message, contains('observed at deadline: owner=null'));
    });

    test('a bare call still fails with the original message only', () async {
      await expectLater(
        eventually(() => false, timeout: const Duration(milliseconds: 30)),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            'Condition was not observed before the '
                '0:00:00.030000 deadline',
          ),
        ),
      );
    });

    test('a failing describe reports its type, never its message', () {
      final message = eventuallyFailureMessage(
        const Duration(seconds: 1),
        describe: () => throw StateError('secret canary'),
      );
      expect(message, contains('unavailable (StateError)'));
      expect(message, isNot(contains('secret canary')));
    });

    test('describe is sampled only at the deadline', () async {
      var samples = 0;
      var polls = 0;
      await eventually(
        () => ++polls == 3,
        label: 'third poll',
        describe: () {
          samples++;
          return 'unused';
        },
      );
      expect(samples, 0);
      await expectLater(
        eventually(
          () => false,
          timeout: const Duration(milliseconds: 30),
          describe: () {
            samples++;
            return 'sampled';
          },
        ),
        throwsA(isA<TestFailure>()),
      );
      expect(samples, 1);
    });
  });

  group('PhaseTrace', () {
    test('separates the last observed phase from inferred pending work', () {
      final trace = PhaseTrace()
        ..enter('launching')
        ..enter('launched');
      final text = trace.describe(pending: 'child closing stdin');
      expect(trace.last, 'launched');
      expect(text, contains('last observed phase: launched'));
      expect(text, contains('path: launching > launched'));
      expect(text, contains('inferred pending (not observed): child closing'));
      expect(PhaseTrace().describe(), 'last observed phase: none');
      expect(PhaseTrace().describe(), isNot(contains('inferred')));
    });

    test('retains only the newest phases', () {
      final trace = PhaseTrace(limit: 3);
      for (final phase in ['a', 'b', 'c', 'd', 'e']) {
        trace.enter(phase);
      }
      expect(trace.phases, ['c', 'd', 'e']);
    });
  });

  group('OwnedCleanups', () {
    test('runs newest first and only once', () async {
      final cleanups = OwnedCleanups();
      final order = <String>[];
      cleanups
        ..add('directory', () => order.add('directory'))
        ..add('database', () async => order.add('database'))
        ..add('process', () => order.add('process'));
      await cleanups.run();
      await cleanups.run();
      expect(order, ['process', 'database', 'directory']);
      expect(cleanups.pending, isEmpty);
    });

    test(
      'preserves every failure and still runs the remaining steps',
      () async {
        final cleanups = OwnedCleanups();
        final ran = <String>[];
        cleanups
          ..add('first', () => ran.add('first'))
          ..add('second', () => throw StateError('second failed'))
          ..add('third', () => throw ArgumentError('third failed'))
          ..add('fourth', () => ran.add('fourth'));
        Object? failure;
        try {
          await cleanups.run();
        } catch (error) {
          failure = error;
        }
        expect(ran, ['fourth', 'first']);
        expect(failure, isA<FixtureCleanupFailure>());
        final steps = (failure as FixtureCleanupFailure).failures;
        expect(steps.map((f) => f.step), ['third', 'second']);
        expect(steps.map((f) => f.error.runtimeType), [
          ArgumentError,
          StateError,
        ]);
        expect('$failure', contains('second failed'));
      },
    );

    test('a hung step is abandoned at its bound and reported', () async {
      final cleanups = OwnedCleanups(
        stepTimeout: const Duration(milliseconds: 50),
      );
      final ran = <String>[];
      cleanups
        ..add('early', () => ran.add('early'))
        ..add('hung', () => Completer<void>().future);
      final elapsed = Stopwatch()..start();
      await expectLater(cleanups.run(), throwsA(isA<FixtureCleanupFailure>()));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ran, ['early']);
    });
  });

  group('owned child processes', () {
    test('terminates a child that ignores SIGTERM', () async {
      final owned = OwnedProcesses.forTest();
      final child = await startTermIgnoringChild(owned);
      expect(owned.running, [child]);
      final status = await child.terminate(
        grace: const Duration(milliseconds: 200),
      );
      // -9: SIGTERM was ignored, so only the SIGKILL escalation ended it.
      expect(status, -9);
      expect(child.hasExited, isTrue);
      owned.expectNoneRunning();
    });

    test('settles with a paused peer', () async {
      final owned = OwnedProcesses.forTest();
      final child = await startTermIgnoringChild(owned);
      // A stopped child cannot act on SIGTERM; only SIGKILL ends it.
      expect(child.kill(ProcessSignal.sigstop), isTrue);
      final elapsed = Stopwatch()..start();
      await owned.close();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 10)));
      expect(child.exitStatus, -9);
      owned.expectNoneRunning();
    });

    test('is registered at allocation and reports a leak by name', () async {
      final owned = OwnedProcesses.forTest();
      final child = await owned.start('/bin/sh', [
        '-c',
        'exec sleep 30',
      ], name: 'sleeper');
      expect(
        owned.expectNoneRunning,
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            allOf(contains('sleeper'), contains('${child.pid}')),
          ),
        ),
      );
      await owned.close();
      owned.expectNoneRunning();
    });

    test('an already exited child is reaped without a signal', () async {
      final owned = OwnedProcesses.forTest();
      final child = await owned.start('/bin/sh', ['-c', 'exit 7']);
      expect(await child.exitCode, 7);
      expect(child.hasExited, isTrue);
      expect(child.kill(), isFalse);
      expect(await child.terminate(), 7);
    });

    test('never signals a process it does not own', () async {
      final bystander = await Process.start('/bin/sh', ['-c', 'exec sleep 30']);
      var bystanderExited = false;
      bystander.exitCode.then((_) => bystanderExited = true).ignore();
      addTearDown(() async {
        bystander.kill(ProcessSignal.sigkill);
        await bystander.exitCode;
      });
      final owned = OwnedProcesses(OwnedCleanups());
      await owned.start('/bin/sh', ['-c', 'exec sleep 30']);
      await owned.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(bystanderExited, isFalse);
    });

    test(
      'an unreaped child fails cleanup instead of passing quietly',
      () async {
        final cleanups = OwnedCleanups();
        final owned = OwnedProcesses(cleanups);
        // The real process is already reaped; adopting a handle whose exit never
        // completes models a kernel exit that cannot be observed.
        final unobservable = _NeverExits();
        owned.adopt(unobservable, name: 'unobservable');
        await expectLater(
          cleanups.run(),
          throwsA(
            isA<FixtureCleanupFailure>().having(
              (e) => '$e',
              'text',
              contains('was not reaped'),
            ),
          ),
        );
        expect(unobservable.signals, [
          ProcessSignal.sigterm,
          ProcessSignal.sigkill,
        ]);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('awaitMarker', () {
    test('succeeds when the marker appears before the deadline', () async {
      final directory = createTestTempDirectorySync('marker-');
      final marker = File('${directory.path}/ready');
      Timer(
        const Duration(milliseconds: 40),
        () => marker.writeAsStringSync(''),
      );
      await awaitMarker(marker);
    });

    test('names the phase, the inference and the owner on timeout', () async {
      final directory = createTestTempDirectorySync('marker-');
      final marker = File('${directory.path}/ready');
      final owned = OwnedProcesses.forTest();
      final child = await owned.start('/bin/sh', ['-c', 'exit 3']);
      await child.exitCode;
      final trace = PhaseTrace()
        ..enter('launching')
        ..enter('launched');
      Object? failure;
      try {
        await awaitMarker(
          marker,
          timeout: const Duration(milliseconds: 50),
          trace: trace,
          pending: 'child publishing stdin-closed',
          owner: child,
        );
      } on TestFailure catch (error) {
        failure = error;
      }
      expect(failure, isA<TestFailure>());
      final message = (failure as TestFailure).message!;
      expect(message, contains('marker ${marker.path}'));
      expect(message, contains('last observed phase: launched'));
      expect(message, contains('inferred pending (not observed): child pub'));
      expect(message, contains('exited with 3'));
    });
  });
}

/// A process whose exit is never observed and which records signals sent.
final class _NeverExits implements Process {
  final signals = <ProcessSignal>[];
  @override
  final Future<int> exitCode = Completer<int>().future;
  @override
  int get pid => 0;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    return true;
  }
}
