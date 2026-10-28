import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/meeting_speaker_observer.dart';
import 'package:foresight_core/src/process_speaker_observer.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Supervision against a real child process speaking the protocol over pipes.
void main() {
  final script = File(
    'test/support/fake_speaker_helper_main.dart',
  ).absolute.path;

  late Directory root;
  late File pidFile;
  late List<SpeakerObserverEvent> events;
  late List<SpeakerObserverDiagnostic> diagnostics;

  setUp(() {
    root = createTestTempDirectorySync('observer-');
    pidFile = File('${root.path}/pids');
    events = [];
    diagnostics = [];
  });

  ProcessMeetingSpeakerObserver observer(String scenario) {
    final value = ProcessMeetingSpeakerObserver(
      SpeakerObserverConfig(
        executable: Platform.resolvedExecutable,
        arguments: [
          script,
          '--scenario=$scenario',
          '--pidfile=${pidFile.path}',
          '--statefile=${root.path}/state',
        ],
        pollMs: 50,
        readDeadlineMs: 500,
        spawnTimeout: const Duration(seconds: 20),
        handshakeTimeout: const Duration(seconds: 20),
        requestTimeout: const Duration(seconds: 10),
        stallSlack: const Duration(seconds: 10),
        exitGrace: const Duration(milliseconds: 400),
        termGrace: const Duration(milliseconds: 400),
        killGrace: const Duration(seconds: 5),
        backoffInitial: const Duration(milliseconds: 20),
        backoffMax: const Duration(milliseconds: 100),
      ),
      clockUs: () => DateTime.now().microsecondsSinceEpoch,
      onDiagnostic: diagnostics.add,
    );
    value.events.listen(events.add);
    addTearDown(() async {
      try {
        await value.dispose().timeout(const Duration(seconds: 15));
      } on Object {
        // The assertions below report the actual outcome.
      }
    });
    return value;
  }

  List<String> pids() =>
      pidFile.existsSync() ? pidFile.readAsLinesSync().toList() : [];

  Future<bool> alive(String pid) async =>
      (await Process.run('/bin/kill', [
        '-0',
        pid,
      ]).timeout(const Duration(seconds: 5))).exitCode ==
      0;

  List<ObservationEvent> observations() =>
      events.whereType<ObservationEvent>().toList();

  test(
    'orderly lifecycle: capabilities, observations, stop, child reaped',
    () async {
      final value = observer('ok');
      expect((await value.inspect()).available, true);
      final oneShot = pids().single;
      expect(await alive(oneShot), false, reason: 'one-shot helper reaped');

      await value.start('s1');
      await eventually(
        () => observations().length >= 3,
        timeout: const Duration(seconds: 10),
      );
      final first = observations().first.observation;
      expect(first.session, 's1');
      expect(first.participants.single.ref, '0:p1');
      // The clock probe lands helper reads within a second of now.
      expect(
        (first.readStartUs - DateTime.now().microsecondsSinceEpoch).abs(),
        lessThan(2000000),
      );
      final live = pids().last;
      expect(await alive(live), true);
      await value.stop();
      expect(await alive(live), false);
      expect(
        diagnostics.map((d) => d.code),
        isNot(contains(SpeakerObserverDiagnosticCode.reapFailed)),
      );
    },
  );

  test('a TERM-resistant helper is killed and reaped on stop', () async {
    final value = observer('hang');
    await value.start('s1');
    final pid = pids().last;
    expect(await alive(pid), true);
    final elapsed = Stopwatch()..start();
    await value.stop();
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 10)));
    expect(
      await alive(pid),
      false,
      reason: 'stop must SIGKILL and reap the owned child',
    );
  });

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
    expect(await alive(first), false);
    final second = pids().last;
    expect(await alive(second), true);
    await value.stop();
    expect(await alive(second), false);
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
      expect(await alive(pids().first), false);
      expect(
        diagnostics.map((d) => d.code),
        contains(SpeakerObserverDiagnosticCode.protocolError),
      );
      await value.stop();
      for (final pid in pids()) {
        expect(await alive(pid), false);
      }
    },
  );
}
