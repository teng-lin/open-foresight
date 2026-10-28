import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/src/meeting_speaker_observer.dart';
import 'package:foresight_core/src/process_speaker_observer.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Supervision against a real child process speaking the protocol over pipes.
/// Paths come from the package, not the working directory, and liveness uses
/// signal 0-equivalent delivery rather than a shell command, so the suite is
/// the same on macOS and Linux.
void main() {
  late String script;
  late Directory root;
  late File pidFile;
  late List<SpeakerObserverEvent> events;
  late List<SpeakerObserverDiagnostic> diagnostics;
  final observers = <ProcessMeetingSpeakerObserver>[];

  List<String> pids() =>
      pidFile.existsSync() ? pidFile.readAsLinesSync().toList() : [];

  /// Whether a process with this id still exists. Signal 18 (SIGCONT) is
  /// harmless to a live child and, unlike a shell, portable.
  bool alive(String pid) =>
      Process.killPid(int.parse(pid), ProcessSignal.sigcont);

  setUpAll(() async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:foresight_core/foresight_core.dart'),
    );
    script = File.fromUri(
      library!.resolve('../test/support/fake_speaker_helper_main.dart'),
    ).path;
    expect(File(script).existsSync(), true, reason: script);
  });

  setUp(() {
    root = createTestTempDirectorySync('observer-');
    pidFile = File('${root.path}/pids');
    events = [];
    diagnostics = [];
    observers.clear();
  });

  tearDown(() async {
    // Disposal failures are real failures: do not swallow them.
    for (final observer in observers) {
      await observer.dispose().timeout(const Duration(seconds: 20));
      expect(observer.debugActiveTimers, 0);
    }
    for (final pid in pids()) {
      expect(alive(pid), false, reason: 'helper $pid outlived its observer');
    }
  });

  ProcessMeetingSpeakerObserver observer(
    String scenario, {
    String? executable,
    List<String>? arguments,
    int maxRestarts = 5,
  }) {
    final value = ProcessMeetingSpeakerObserver(
      SpeakerObserverConfig(
        executable: executable ?? Platform.resolvedExecutable,
        arguments:
            arguments ??
            [
              script,
              '--scenario=$scenario',
              '--pidfile=${pidFile.path}',
              '--statefile=${root.path}/state',
            ],
        pollMs: 100,
        readDeadlineMs: 500,
        spawnTimeout: const Duration(seconds: 20),
        handshakeTimeout: const Duration(seconds: 20),
        requestTimeout: const Duration(seconds: 10),
        stallSlack: const Duration(seconds: 10),
        exitGrace: const Duration(milliseconds: 700),
        termGrace: const Duration(milliseconds: 400),
        killGrace: const Duration(seconds: 5),
        maxRestarts: maxRestarts,
        backoffInitial: const Duration(milliseconds: 20),
        backoffMax: const Duration(milliseconds: 100),
        maxStderrBytes: 1024,
      ),
      clockUs: () => DateTime.now().microsecondsSinceEpoch,
      onDiagnostic: diagnostics.add,
    );
    value.events.listen(events.add);
    observers.add(value);
    return value;
  }

  List<ObservationEvent> observations() =>
      events.whereType<ObservationEvent>().toList();

  List<SpeakerObserverDiagnosticCode> codes() => [
    for (final d in diagnostics) d.code,
  ];

  test(
    'orderly lifecycle: capabilities, observations, stop, child reaped',
    () async {
      final value = observer('ok');
      expect((await value.inspect()).available, true);
      final oneShot = pids().single;
      expect(alive(oneShot), false, reason: 'one-shot helper reaped');

      await value.start('s1');
      await eventually(
        () => observations().length >= 3,
        timeout: const Duration(seconds: 10),
      );
      final first = observations().first.observation;
      expect(first.session, 's1');
      expect(first.participants.single.ref, '1:p1');
      // The clock probe lands helper reads within a second of now.
      expect(
        (first.readStartUs - DateTime.now().microsecondsSinceEpoch).abs(),
        lessThan(2000000),
      );
      final live = pids().last;
      expect(alive(live), true);
      await value.stop();
      expect(alive(live), false);
      expect(
        codes(),
        isNot(contains(SpeakerObserverDiagnosticCode.reapFailed)),
      );
      expect(codes(), isNot(contains(SpeakerObserverDiagnosticCode.termSent)));
    },
  );

  test(
    'a TERM-resistant helper gets TERM, then KILL, and is reaped on stop',
    () async {
      final value = observer('hang');
      await value.start('s1');
      final pid = pids().last;
      expect(alive(pid), true);
      final elapsed = Stopwatch()..start();
      await value.stop();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 10)));
      expect(
        alive(pid),
        false,
        reason: 'stop must SIGKILL and reap the owned child',
      );
      final escalation = codes().where(
        (c) =>
            c == SpeakerObserverDiagnosticCode.termSent ||
            c == SpeakerObserverDiagnosticCode.killSent,
      );
      expect(escalation, [
        SpeakerObserverDiagnosticCode.termSent,
        SpeakerObserverDiagnosticCode.killSent,
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<ObserverStateEvent>().last.failure,
        SpeakerObserverFailure.shutdownTimeout,
      );
    },
  );

  test(
    'stop cancels a start of a stubborn helper without waiting out timeouts',
    () async {
      final value = observer('hang');
      final start = value
          .start('s1')
          .then<Object>((_) => 'started', onError: (Object e) => e);
      // Stop as soon as the child exists, whatever stage the start has reached.
      await eventually(
        () => pids().isNotEmpty,
        timeout: const Duration(seconds: 20),
      );
      final elapsed = Stopwatch()..start();
      await value.stop();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 12)));
      final result = await start;
      // The hang scenario answers start normally, so the start may have won the
      // race; either way nothing may be left running.
      if (result is SpeakerObserverException) {
        expect(result.failure, SpeakerObserverFailure.cancelled);
      }
      for (final pid in pids()) {
        expect(alive(pid), false);
      }
    },
  );

  test('a crashed helper is replaced and its predecessor reaped', () async {
    final value = observer('crash_once');
    await value.start('s1');
    final first = pids().last;
    await eventually(
      () => observations().any((o) => o.epoch == 1),
      timeout: const Duration(seconds: 30),
    );
    final restarted = observations().firstWhere((o) => o.epoch == 1);
    expect(restarted.observation.participants.single.ref, '1:p1');
    expect(pids(), hasLength(2));
    expect(alive(first), false);
    final second = pids().last;
    expect(alive(second), true);
    await value.stop();
    await Future<void>.delayed(Duration.zero);
    expect(alive(second), false);
    expect(value.stats.restarts, 1);
    final statuses = events.whereType<ObserverStateEvent>().map(
      (e) => e.status,
    );
    expect(
      statuses,
      containsAllInOrder([
        ObserverStatus.running,
        ObserverStatus.restarting,
        ObserverStatus.running,
        ObserverStatus.stopped,
      ]),
    );
  });

  test(
    'a helper writing a non-protocol line is replaced, not trusted',
    () async {
      final value = observer('garbage');
      await value.start('s1');
      await eventually(
        () => pids().length >= 2,
        timeout: const Duration(seconds: 30),
      );
      expect(alive(pids().first), false);
      expect(codes(), contains(SpeakerObserverDiagnosticCode.protocolError));
      await value.stop();
    },
  );

  test(
    'more than a megabyte of stderr neither blocks the helper nor the observer',
    () async {
      final value = observer('stderr_flood');
      await value.start('s1');
      await eventually(
        () => observations().length >= 3,
        timeout: const Duration(seconds: 20),
      );
      expect(
        pids(),
        hasLength(1),
        reason: 'the helper must not have been restarted',
      );
      await value.stop();
      final stderrBytes = diagnostics
          .firstWhere(
            (d) => d.code == SpeakerObserverDiagnosticCode.helperStderr,
          )
          .value;
      expect(stderrBytes, greaterThanOrEqualTo(2 * 1024 * 1024));
      expect(codes(), contains(SpeakerObserverDiagnosticCode.stderrFlood));
    },
  );

  test('a burst of 10 000 frames is refused and the helper replaced', () async {
    final value = observer('burst');
    await value.start('s1');
    await eventually(
      () => pids().length >= 2 && observations().any((o) => o.epoch == 1),
      timeout: const Duration(seconds: 30),
    );
    expect(codes(), contains(SpeakerObserverDiagnosticCode.frameFlood));
    // The flood never reached consumers beyond the rate limit.
    // At 100 ms polls the limit is 40 frames per second.
    expect(
      observations().where((o) => o.epoch == 0).length,
      lessThanOrEqualTo(40),
    );
    expect(alive(pids().first), false);
    await value.stop();
  });

  group('the default launcher', () {
    test('a missing executable is a launch failure', () async {
      final value = observer(
        'ok',
        executable: '${root.path}/does-not-exist',
        arguments: const [],
      );
      await expectLater(
        value.inspect(),
        throwsA(
          isA<SpeakerObserverException>().having(
            (e) => e.failure,
            'failure',
            SpeakerObserverFailure.launchFailed,
          ),
        ),
      );
      expect(codes(), contains(SpeakerObserverDiagnosticCode.launchNotFound));
    });

    test('a file that is not executable is a launch failure', () async {
      final file = File('${root.path}/plain')..writeAsStringSync('#!/bin/sh\n');
      final chmod = await Process.run('/bin/chmod', ['600', file.path]);
      expect(chmod.exitCode, 0);
      final value = observer('ok', executable: file.path, arguments: const []);
      await expectLater(
        value.start('s1'),
        throwsA(
          isA<SpeakerObserverException>().having(
            (e) => e.failure,
            'failure',
            SpeakerObserverFailure.launchFailed,
          ),
        ),
      );
      expect(
        codes(),
        contains(SpeakerObserverDiagnosticCode.launchNotExecutable),
      );
    });
  });
}
