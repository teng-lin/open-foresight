import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/meeting_speaker_observer.dart';
import 'package:foresight_core/src/process_speaker_observer.dart';
import 'package:foresight_core/src/speaker_observation.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

import 'support/fake_speaker_helper.dart';

/// Small deadlines so supervision paths run quickly; healthy exchanges are
/// immediate and never depend on them.
SpeakerObserverConfig fastConfig({
  int maxRestarts = 5,
  int pollMs = 50,
  int readDeadlineMs = 50,
  Duration stallSlack = const Duration(seconds: 5),
  int clockProbes = 3,
  int maxStderrBytes = 1024,
  int maxLineBytes = 262144,
}) => SpeakerObserverConfig(
  executable: '/fake/helper',
  arguments: const ['--flag'],
  pollMs: pollMs,
  readDeadlineMs: readDeadlineMs,
  spawnTimeout: const Duration(milliseconds: 300),
  handshakeTimeout: const Duration(milliseconds: 300),
  requestTimeout: const Duration(milliseconds: 300),
  stallSlack: stallSlack,
  exitGrace: const Duration(milliseconds: 100),
  termGrace: const Duration(milliseconds: 100),
  killGrace: const Duration(milliseconds: 100),
  maxRestarts: maxRestarts,
  backoffInitial: const Duration(milliseconds: 10),
  backoffMax: const Duration(milliseconds: 80),
  clockProbes: clockProbes,
  maxStderrBytes: maxStderrBytes,
  maxLineBytes: maxLineBytes,
);

final class Harness {
  Harness({SpeakerObserverConfig? config, int Function()? clock}) {
    behaviors.add(HelperBehavior());
    observer = ProcessMeetingSpeakerObserver(
      config ?? fastConfig(),
      clockUs: clock ?? () => 5000000,
      launcher: _launch,
      onDiagnostic: diagnostics.add,
    );
    observer.events.listen(events.add);
  }
  late final ProcessMeetingSpeakerObserver observer;
  final List<HelperBehavior> behaviors = [];
  final List<FakeHelper> helpers = [];
  final List<List<String>> arguments = [];
  final List<SpeakerObserverEvent> events = [];
  final List<SpeakerObserverDiagnostic> diagnostics = [];
  Object? launchError;
  Completer<Process>? hangingLaunch;

  /// The behavior used for the Nth helper launched; later ones reuse the last.
  HelperBehavior behaviorFor(int index) =>
      behaviors[index < behaviors.length ? index : behaviors.length - 1];

  Future<Process> _launch(String executable, List<String> args) {
    arguments.add(args);
    final error = launchError;
    if (error != null) return Future.error(error);
    final hanging = hangingLaunch;
    if (hanging != null) return hanging.future;
    final helper = FakeHelper(
      behaviorFor(helpers.length),
      pidValue: 1000 + helpers.length,
    );
    helpers.add(helper);
    return Future.value(helper);
  }

  List<ObserverStateEvent> get states =>
      events.whereType<ObserverStateEvent>().toList();
  List<ObservationEvent> get observations =>
      events.whereType<ObservationEvent>().toList();
  List<SpeakerObserverDiagnosticCode> get diagnosticCodes => [
    for (final d in diagnostics) d.code,
  ];
  bool get allReaped => helpers.every((h) => h.exited);
}

/// Broadcast events are delivered on a later microtask turn than their
/// emission; yield so assertions see everything emitted before this point.
Future<void> settle() => Future<void>.delayed(Duration.zero);

Matcher failureOf(SpeakerObserverFailure failure) =>
    isA<SpeakerObserverException>().having(
      (e) => e.failure,
      'failure',
      failure,
    );

void main() {
  late Harness h;
  tearDown(() async {
    await h.observer
        .dispose()
        .timeout(const Duration(seconds: 3), onTimeout: () {})
        .catchError((Object _) {});
  });

  group('capabilities', () {
    test('inspect uses a one-shot helper and reaps it', () async {
      h = Harness();
      h.behaviors.single
        ..capabilityState = 'needs_setup'
        ..capabilityReason = 'ax_untrusted';
      final capabilities = await h.observer.inspect();
      expect(capabilities.state, ObserverAvailability.needsSetup);
      expect(capabilities.reason, 'ax_untrusted');
      expect(capabilities.zoomVersion, '7.2.2.88465');
      expect(capabilities.platform, 'macos');
      expect(capabilities.helper, 'fake_helper');
      expect(capabilities.available, false);
      expect(h.arguments.single, ['--flag', '--protocol', '1']);
      expect(h.helpers.single.requestTypes, ['capabilities']);
      expect(h.helpers.single.stdinClosed, true);
      expect(h.allReaped, true);
      expect(h.helpers.single.signals, isEmpty);
    });

    test('setup sends an explicit setup request', () async {
      h = Harness();
      final capabilities = await h.observer.setup();
      expect(capabilities.available, true);
      expect(h.helpers.single.requestTypes, ['setup']);
    });

    test('concurrent queries are serialized: one helper at a time', () async {
      h = Harness();
      final first = h.observer.inspect();
      final second = h.observer.setup();
      await Future.wait([first, second]);
      expect(h.helpers, hasLength(2));
      expect(h.helpers.every((helper) => helper.exited), true);
    });

    test('a failed query reaps its helper and the observer recovers', () async {
      h = Harness();
      h.behaviors.add(HelperBehavior());
      h.behaviors.first.answerCapabilities = false;
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.requestTimeout)),
      );
      expect(h.helpers.first.exited, true);
      expect((await h.observer.inspect()).available, true);
    });

    test('a launch failure and a launch hang are reported', () async {
      h = Harness();
      h.launchError = ProcessException('/fake/helper', const []);
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.launchFailed)),
      );
      h.launchError = null;
      h.hangingLaunch = Completer<Process>();
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.launchFailed)),
      );
      // A child that finally starts after the deadline is not leaked.
      final late = FakeHelper(HelperBehavior());
      h.hangingLaunch!.complete(late);
      await eventually(() => late.signals.contains(ProcessSignal.sigkill));
    });

    test('a synchronous launcher failure is a launch failure', () async {
      final observer = ProcessMeetingSpeakerObserver(
        fastConfig(),
        clockUs: () => 0,
        launcher: (_, _) => throw StateError('no'),
      );
      await expectLater(
        observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.launchFailed)),
      );
      await observer.dispose();
      h = Harness();
    });

    test('a silent helper times out its handshake and is killed', () async {
      h = Harness();
      h.behaviors.single
        ..sendHello = false
        ..exitOnStdinClose = false;
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.handshakeTimeout)),
      );
      expect(h.helpers.single.signals, [ProcessSignal.sigterm]);
      expect(h.allReaped, true);
    });

    test('a hello from an unknown platform is a protocol error', () async {
      h = Harness();
      h.behaviors.single.platform = 'windows';
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.protocolError)),
      );
      expect(h.allReaped, true);
    });

    test('an error reply surfaces only the stable helper code', () async {
      h = Harness();
      h.behaviors.single.answerCapabilities = false;
      final future = h.observer.inspect();
      await eventually(
        () => h.helpers.isNotEmpty && h.helpers.single.requests.isNotEmpty,
      );
      final id = h.helpers.single.requests.single['id'];
      h.helpers.single.send('error', {
        'id': id,
        'code': 'ax_failed',
        'message': 'SECRET NAME leaked',
      });
      final error = await future.then<Object>(
        (_) => 'ok',
        onError: (Object e) => e,
      );
      expect(error, failureOf(SpeakerObserverFailure.helperError));
      expect((error as SpeakerObserverException).helperCode, 'ax_failed');
      expect(error.toString(), isNot(contains('SECRET')));
    });
  });

  group('session', () {
    test('handshakes, measures the clock and starts observing', () async {
      h = Harness();
      await h.observer.start('s1');
      await settle();
      final helper = h.helpers.single;
      expect(helper.requestTypes, ['clock', 'clock', 'clock', 'start']);
      final start = helper.requests.last;
      expect(start['session'], 's1');
      expect(start['poll_ms'], 50);
      expect(start['deadline_ms'], 50);
      expect(h.states.map((e) => e.status), [ObserverStatus.running]);
      expect(h.observer.stats.helperStarts, 1);
    });

    test(
      'observations are shifted to the capture clock with qualified refs',
      () async {
        h = Harness();
        // Helper clock 1000 ms is capture 5 000 000 us: offset +4 000 000 us.
        await h.observer.start('s1');
        h.helpers.single.send(
          'observation',
          observationFields('s1', startMs: 2000),
        );
        await eventually(() => h.observations.isNotEmpty);
        final observed = h.observations.single.observation;
        // Zero round trip leaves only the one millisecond rounding allowance.
        expect(observed.readStartUs, 6000000 - 1000);
        expect(observed.readEndUs, 6010000 + 1000);
        expect(observed.participants.single.ref, '0:p1');
        expect(observed.speakers.single.ref, '0:p1');
        expect(observed.participants.single.name, 'Ada Lovelace');
        expect(h.observations.single.epoch, 0);
        expect(h.observer.stats.observations, 1);
      },
    );

    test('keeps the lowest-latency clock probe', () async {
      // Probe round trips: 400 us, 10 us and 800 us. The 10 us probe wins.
      final steps = [0, 400, 1000, 1010, 2000, 2800];
      var index = 0, now = 0;
      h = Harness(
        clock: () {
          if (index < steps.length) now = steps[index++];
          return now;
        },
      );
      await h.observer.start('s1');
      h.helpers.single.send('observation', observationFields('s1'));
      await eventually(() => h.observations.isNotEmpty);
      final observed = h.observations.single.observation;
      // offset = 1005 - 1 000 000 us; widened by rtt/2 + 1 ms = 1005 us.
      expect(observed.readStartUs, 2000000 - 998995 - 1005);
      expect(observed.readEndUs, 2010000 - 998995 + 1005);
    });

    test(
      'unavailable frames become events, deduplicating heartbeats',
      () async {
        h = Harness();
        await h.observer.start('s1');
        final helper = h.helpers.single;
        helper
          ..send('unavailable', {
            'session': 's1',
            'reason': 'window_lost',
            'since_ms': 1500,
          })
          ..send('unavailable', {
            'session': 's1',
            'reason': 'window_lost',
            'since_ms': 1500,
          })
          ..send('observation', observationFields('s1'))
          ..send('unavailable', {
            'session': 's1',
            'reason': 'window_lost',
            'since_ms': 1500,
          })
          ..send('unavailable', {
            'session': 's1',
            'reason': 'ax_denied',
            'since_ms': 1500,
          });
        await eventually(
          () => h.events.whereType<UnavailableEvent>().length == 3,
        );
        final first = h.events.whereType<UnavailableEvent>().first;
        expect(first.reason, 'window_lost');
        // 1500 ms helper time => capture 5.5 s, widened by the 1 ms allowance.
        expect(first.sinceUs, 5500000 - 1000);
        expect(h.observer.stats.unavailableFrames, 4);
      },
    );

    test(
      'an unavailable answer to start is not retried and reaps the child',
      () async {
        h = Harness();
        h.behaviors.single
          ..startReply = 'unavailable'
          ..capabilityState = 'permission_denied'
          ..capabilityReason = 'ax_untrusted';
        await expectLater(
          h.observer.start('s1'),
          throwsA(
            isA<SpeakerObserverException>()
                .having(
                  (e) => e.failure,
                  'failure',
                  SpeakerObserverFailure.unavailable,
                )
                .having(
                  (e) => e.availability,
                  'state',
                  ObserverAvailability.permissionDenied,
                ),
          ),
        );
        expect(h.helpers, hasLength(1));
        expect(h.allReaped, true);
        // The observer is reusable.
        h.behaviors.single.startReply = 'started';
        await h.observer.start('s2');
        expect(h.helpers, hasLength(2));
      },
    );

    test('an error reply to start is a helper error', () async {
      h = Harness();
      h.behaviors.single.startReply = 'error';
      final error = await h.observer
          .start('s1')
          .then<Object>((_) => 'ok', onError: (Object e) => e);
      expect(error, failureOf(SpeakerObserverFailure.helperError));
      expect((error as SpeakerObserverException).helperCode, 'ax_failed');
      expect(error.toString(), isNot(contains('SECRET')));
      expect(h.allReaped, true);
    });

    test('a start that is never answered times out and reaps', () async {
      h = Harness();
      h.behaviors.single.startReply = 'silent';
      await expectLater(
        h.observer.start('s1'),
        throwsA(failureOf(SpeakerObserverFailure.requestTimeout)),
      );
      expect(h.allReaped, true);
    });

    test(
      'a start acknowledged for a different session is a protocol error',
      () async {
        h = Harness();
        h.behaviors.single.startReply = 'silent';
        final result = h.observer
            .start('s1')
            .then<Object>((_) => 'ok', onError: (Object e) => e);
        await eventually(
          () =>
              h.helpers.isNotEmpty &&
              h.helpers.single.requestTypes.contains('start'),
        );
        h.helpers.single.send('started', {
          'id': h.helpers.single.requests.last['id'],
          'session': 'other',
          'target': {'pid': 1, 'window': 'w'},
        });
        expect(await result, failureOf(SpeakerObserverFailure.protocolError));
        expect(h.allReaped, true);
      },
    );

    test('rejects invalid session identifiers and double starts', () async {
      h = Harness();
      await expectLater(h.observer.start(''), throwsArgumentError);
      await expectLater(h.observer.start('bad\nid'), throwsArgumentError);
      expect(h.helpers, isEmpty);
      await h.observer.start('s1');
      await expectLater(
        h.observer.start('s2'),
        throwsA(failureOf(SpeakerObserverFailure.busy)),
      );
    });

    test('inspect during a session reuses the live helper', () async {
      h = Harness();
      await h.observer.start('s1');
      final capabilities = await h.observer.inspect();
      expect(capabilities.available, true);
      expect(h.helpers, hasLength(1));
      expect(h.helpers.single.requestTypes.last, 'capabilities');
    });

    test('a query while starting is refused', () async {
      h = Harness();
      h.behaviors.single.answerClock = false;
      final start = h.observer.start('s1');
      await eventually(() => h.helpers.isNotEmpty);
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.busy)),
      );
      await expectLater(start, throwsA(isA<SpeakerObserverException>()));
    });

    test(
      'stderr is drained and bounded without blocking observation',
      () async {
        h = Harness(config: fastConfig(maxStderrBytes: 100));
        await h.observer.start('s1');
        h.helpers.single
          ..writeStderr(60)
          ..writeStderr(60)
          ..writeStderr(60)
          ..send('observation', observationFields('s1'));
        await eventually(() => h.observations.isNotEmpty);
        expect(
          h.diagnosticCodes.where(
            (c) => c == SpeakerObserverDiagnosticCode.stderrFlood,
          ),
          hasLength(1),
        );
      },
    );
  });

  group('shutdown', () {
    test('stop sends stop, finishes the interval and reaps', () async {
      h = Harness();
      await h.observer.start('s1');
      await h.observer.stop();
      await settle();
      final helper = h.helpers.single;
      expect(helper.requestTypes.last, 'stop');
      expect(helper.exited, true);
      expect(helper.signals, isEmpty);
      expect(h.states.last.status, ObserverStatus.stopped);
      // Idempotent, and a new session may follow.
      await h.observer.stop();
      await h.observer.start('s2');
      expect(h.helpers, hasLength(2));
    });

    test(
      'an unresponsive helper is terminated, then killed, and reaped',
      () async {
        h = Harness();
        h.behaviors.single
          ..answerStop = false
          ..exitOnStdinClose = false
          ..exitOnTerm = false;
        await h.observer.start('s1');
        await h.observer.stop();
        final helper = h.helpers.single;
        expect(helper.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
        expect(helper.exited, true);
      },
    );

    test(
      'an unkillable helper reports reap failure and blocks reuse',
      () async {
        h = Harness();
        h.behaviors.single
          ..answerStop = false
          ..exitOnStdinClose = false
          ..exitOnTerm = false
          ..exitOnKill = false;
        await h.observer.start('s1');
        await expectLater(
          h.observer.stop(),
          throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
        );
        expect(
          h.diagnosticCodes,
          contains(SpeakerObserverDiagnosticCode.reapFailed),
        );
        await expectLater(
          h.observer.start('s2'),
          throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
        );
        await expectLater(
          h.observer.inspect(),
          throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
        );
        expect(h.helpers, hasLength(1));
      },
    );

    test('stop while starting cancels the start and leaks no child', () async {
      h = Harness();
      h.behaviors.single.answerClock = false;
      final start = h.observer
          .start('s1')
          .then<Object>((_) => 'started', onError: (Object e) => e);
      await eventually(() => h.helpers.isNotEmpty);
      final stop = h.observer.stop();
      // The pending start fails on its request timeout; stop then completes.
      await stop;
      expect(await start, isA<SpeakerObserverException>());
      expect(h.allReaped, true);
      h.behaviors.single.answerClock = true;
      await h.observer.start('s2');
    });

    test('stopping while a start would succeed cancels it and reaps', () async {
      h = Harness();
      h.behaviors.single
        ..answerClock = false
        ..startReply = 'silent';
      final start = h.observer
          .start('s1')
          .then<Object>((_) => 'started', onError: (Object e) => e);
      await eventually(() => h.helpers.isNotEmpty);
      final helper = h.helpers.single;
      final stop = h.observer.stop();
      // Complete the handshake by hand after stop was requested.
      var answered = 0;
      while (true) {
        await eventually(() => helper.requests.length > answered);
        final request = helper.requests[answered++];
        if (request['type'] == 'start') break;
        helper.send('clock', {'id': request['id'], 'monotonic_ms': 1000});
      }
      helper.send('started', {
        'id': helper.requests.last['id'],
        'session': 's1',
        'target': {'pid': 1, 'window': 'w'},
      });
      await stop;
      expect(await start, failureOf(SpeakerObserverFailure.cancelled));
      expect(helper.exited, true);
      expect(h.helpers, hasLength(1));
    });

    test('an unkillable one-shot helper reports reap failure', () async {
      h = Harness();
      h.behaviors.single
        ..exitOnStdinClose = false
        ..exitOnTerm = false
        ..exitOnKill = false;
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
      );
      await expectLater(
        h.observer.start('s1'),
        throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
      );
    });

    test('dispose stops and closes the event stream', () async {
      h = Harness();
      var closed = false;
      h.observer.events.listen((_) {}, onDone: () => closed = true);
      await h.observer.start('s1');
      await h.observer.dispose();
      expect(h.allReaped, true);
      await eventually(() => closed);
      await expectLater(h.observer.start('s2'), throwsStateError);
      await h.observer.dispose();
    });
  });

  group('restarts', () {
    test('a protocol violation restarts with a new epoch and refs', () async {
      h = Harness();
      await h.observer.start('s1');
      h.helpers.single.sendRaw('this is not json');
      await eventually(
        () => h.states.any(
          (s) => s.status == ObserverStatus.running && s.epoch == 1,
        ),
      );
      expect(h.helpers, hasLength(2));
      expect(h.helpers.first.exited, true);
      expect(h.states.map((s) => s.status), [
        ObserverStatus.running,
        ObserverStatus.restarting,
        ObserverStatus.running,
      ]);
      expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
      expect(h.states.last.restartCount, 1);
      expect(h.observer.stats.restarts, 1);
      expect(h.observer.stats.protocolErrors, greaterThan(0));
      h.helpers.last.send('observation', observationFields('s1'));
      await eventually(() => h.observations.isNotEmpty);
      expect(h.observations.single.epoch, 1);
      expect(h.observations.single.observation.participants.single.ref, '1:p1');
    });

    test('a helper exit restarts it', () async {
      h = Harness();
      await h.observer.start('s1');
      h.helpers.single.exit(9);
      await eventually(
        () =>
            h.helpers.length == 2 &&
            h.states.last.status == ObserverStatus.running,
      );
      expect(h.states[1].failure, SpeakerObserverFailure.helperExited);
      expect(
        h.diagnostics
            .where((d) => d.code == SpeakerObserverDiagnosticCode.helperExited)
            .first
            .value,
        9,
      );
    });

    test('a stalled helper is terminated and replaced', () async {
      h = Harness(
        config: fastConfig(stallSlack: const Duration(milliseconds: 100)),
      );
      await h.observer.start('s1');
      // No frames for pollMs + deadline + slack (200 ms): stall.
      await eventually(() => h.helpers.length == 2);
      expect(h.helpers.first.exited, true);
      expect(h.states[1].failure, SpeakerObserverFailure.stalled);
      expect(h.observer.stats.stalls, greaterThan(0));
    });

    test('frames keep a helper alive past the stall timeout', () async {
      h = Harness(
        config: fastConfig(stallSlack: const Duration(milliseconds: 500)),
      );
      await h.observer.start('s1');
      final helper = h.helpers.single;
      final timer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => helper.send('observation', observationFields('s1')),
      );
      addTearDown(timer.cancel);
      // Well past the 600 ms stall timeout.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(h.helpers, hasLength(1));
      expect(h.observer.stats.stalls, 0);
    });

    test('restarts are bounded and back off exponentially', () async {
      h = Harness(config: fastConfig(stallSlack: const Duration(seconds: 30)));
      // Every helper answers start, then exits immediately.
      h.behaviors.single.onStarted = (helper) => helper.exit(1);
      await h.observer.start('s1').catchError((Object _) {});
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.failed),
        timeout: const Duration(seconds: 5),
      );
      expect(h.helpers, hasLength(6));
      final delays = [
        for (final d in h.diagnostics)
          if (d.code == SpeakerObserverDiagnosticCode.restartScheduled) d.value,
      ];
      expect(delays, [10, 20, 40, 80, 80]);
      expect(
        h.diagnosticCodes,
        contains(SpeakerObserverDiagnosticCode.restartsExhausted),
      );
      expect(h.states.last.failure, SpeakerObserverFailure.helperExited);
      expect(h.states.last.restartCount, 5);
      expect(h.allReaped, true);
      // Stop returns a failed observer to idle.
      await h.observer.stop();
      await settle();
      expect(h.states.last.status, ObserverStatus.stopped);
    });

    test('a restart that finds the meeting unobservable gives up', () async {
      h = Harness();
      h.behaviors.add(
        HelperBehavior()
          ..startReply = 'unavailable'
          ..capabilityState = 'permission_denied',
      );
      await h.observer.start('s1');
      h.helpers.single.exit(1);
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.failed),
      );
      expect(h.states.last.failure, SpeakerObserverFailure.unavailable);
      expect(h.helpers, hasLength(2));
    });

    test('a failed helper that cannot be reaped ends supervision', () async {
      h = Harness();
      h.behaviors.single
        ..exitOnStdinClose = false
        ..exitOnTerm = false
        ..exitOnKill = false;
      await h.observer.start('s1');
      h.helpers.single.sendRaw('not json');
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.failed),
      );
      expect(h.states.last.failure, SpeakerObserverFailure.reapFailed);
      expect(h.helpers, hasLength(1));
      expect(
        h.diagnosticCodes,
        contains(SpeakerObserverDiagnosticCode.reapFailed),
      );
      await expectLater(
        h.observer.start('s2'),
        throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
      );
    });

    test('an unavailable frame for another session fails the helper', () async {
      h = Harness();
      await h.observer.start('s1');
      h.helpers.single.send('unavailable', {
        'session': 'other',
        'reason': 'x',
        'since_ms': 1,
      });
      await eventually(() => h.helpers.length == 2);
      expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
    });

    test('stopping during backoff cancels the pending restart', () async {
      h = Harness(
        config: SpeakerObserverConfig(
          executable: '/fake/helper',
          backoffInitial: const Duration(seconds: 30),
          backoffMax: const Duration(seconds: 30),
          pollMs: 50,
          readDeadlineMs: 50,
          stallSlack: const Duration(seconds: 30),
          exitGrace: const Duration(milliseconds: 100),
          termGrace: const Duration(milliseconds: 100),
          killGrace: const Duration(milliseconds: 100),
        ),
      );
      await h.observer.start('s1');
      h.helpers.single.exit(1);
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.restarting),
      );
      await h.observer.stop();
      await settle();
      expect(h.helpers, hasLength(1));
      expect(h.states.last.status, ObserverStatus.stopped);
    });

    test('a failed restart attempt is retried within the limit', () async {
      h = Harness();
      await h.observer.start('s1');
      h.launchError = ProcessException('/fake/helper', const []);
      h.helpers.single.exit(1);
      await eventually(() => h.arguments.length >= 3);
      h.launchError = null;
      await eventually(
        () => h.states.any(
          (s) => s.status == ObserverStatus.running && s.restartCount >= 2,
        ),
      );
    });

    test('observations for another session fail the helper', () async {
      h = Harness();
      await h.observer.start('s1');
      h.helpers.single.send('observation', observationFields('other'));
      await eventually(() => h.helpers.length == 2);
      expect(h.observations, isEmpty);
      expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
    });

    test(
      'an unsolicited error frame restarts and never exposes its text',
      () async {
        h = Harness();
        await h.observer.start('s1');
        h.helpers.single.send('error', {
          'code': 'ax_timeout',
          'message': 'SECRET NAME',
        });
        await eventually(() => h.helpers.length == 2);
        expect(h.states[1].failure, SpeakerObserverFailure.helperError);
        for (final d in h.diagnostics) {
          expect('${d.code} ${d.value}', isNot(contains('SECRET')));
        }
      },
    );

    test('an over-long line is a protocol error', () async {
      h = Harness(config: fastConfig(maxLineBytes: 512));
      await h.observer.start('s1');
      h.helpers.single.sendBytes(List.filled(600, 0x61));
      await eventually(() => h.helpers.length == 2);
      expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
    });

    test(
      'observations before start is acknowledged are protocol errors',
      () async {
        h = Harness();
        h.behaviors.single.startReply = 'silent';
        final start = h.observer
            .start('s1')
            .then<Object>((_) => 'ok', onError: (Object e) => e);
        await eventually(
          () =>
              h.helpers.isNotEmpty &&
              h.helpers.single.requestTypes.contains('start'),
        );
        h.helpers.single.send('observation', observationFields('s1'));
        expect(await start, failureOf(SpeakerObserverFailure.protocolError));
      },
    );
  });

  group('configuration', () {
    test('rejects invalid configuration', () {
      for (final bad in [
        SpeakerObserverConfig(executable: ''),
        const SpeakerObserverConfig(executable: 'x', pollMs: 10),
        const SpeakerObserverConfig(executable: 'x', readDeadlineMs: 0),
        const SpeakerObserverConfig(executable: 'x', maxRestarts: -1),
        const SpeakerObserverConfig(
          executable: 'x',
          requestTimeout: Duration.zero,
        ),
      ]) {
        expect(
          () => ProcessMeetingSpeakerObserver(bad, clockUs: () => 0),
          throwsArgumentError,
        );
      }
    });

    test('the unsupported observer is a harmless stand-in', () async {
      const observer = UnsupportedMeetingSpeakerObserver();
      expect(
        (await observer.inspect()).state,
        ObserverAvailability.unsupportedPlatform,
      );
      expect((await observer.setup()).available, false);
      await expectLater(
        observer.start('s'),
        throwsA(failureOf(SpeakerObserverFailure.unavailable)),
      );
      await observer.stop();
      await observer.dispose();
      expect(await observer.events.isEmpty, true);
      h = Harness();
    });
  });
}
