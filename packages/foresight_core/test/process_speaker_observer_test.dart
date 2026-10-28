import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/capture_timeline.dart';
import 'package:foresight_core/src/meeting_speaker_observer.dart';
import 'package:foresight_core/src/process_speaker_observer.dart';
import 'package:foresight_core/src/speaker_attributor.dart';
import 'package:foresight_core/src/speaker_observation.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

import 'support/fake_speaker_helper.dart';

/// Small deadlines so supervision paths run quickly; healthy exchanges are
/// immediate and never depend on them. Stall detection is effectively off
/// unless a test asks for it.
SpeakerObserverConfig fastConfig({
  int maxRestarts = 5,
  Duration? restartRefillAfter = const Duration(minutes: 5),
  int pollMs = 50,
  int readDeadlineMs = 50,
  Duration stallSlack = const Duration(seconds: 5),
  int clockProbes = 3,
  int maxStderrBytes = 1024,
  int maxLineBytes = 262144,
  Duration spawn = const Duration(milliseconds: 300),
  Duration handshake = const Duration(milliseconds: 300),
  Duration request = const Duration(milliseconds: 300),
  Duration backoffMax = const Duration(milliseconds: 80),
  Duration grace = const Duration(milliseconds: 100),
  Duration? exitGrace,
  int? maxFramesPerSecond,
  Duration readSkew = const Duration(seconds: 5),
}) => SpeakerObserverConfig(
  executable: '/fake/helper',
  arguments: const ['--flag'],
  pollMs: pollMs,
  readDeadlineMs: readDeadlineMs,
  spawnTimeout: spawn,
  handshakeTimeout: handshake,
  requestTimeout: request,
  stallSlack: stallSlack,
  exitGrace: exitGrace ?? grace,
  termGrace: grace,
  killGrace: grace,
  maxRestarts: maxRestarts,
  restartRefillAfter: restartRefillAfter,
  backoffInitial: const Duration(milliseconds: 10),
  backoffMax: backoffMax,
  clockProbes: clockProbes,
  maxStderrBytes: maxStderrBytes,
  maxLineBytes: maxLineBytes,
  maxFramesPerSecond: maxFramesPerSecond,
  readSkew: readSkew,
);

/// Timeouts long enough that only cancellation can make an operation quick.
SpeakerObserverConfig patientConfig({
  Duration grace = const Duration(milliseconds: 150),
}) => fastConfig(
  spawn: const Duration(seconds: 20),
  handshake: const Duration(seconds: 20),
  request: const Duration(seconds: 20),
  grace: grace,
);

final class Harness {
  Harness({SpeakerObserverConfig? config, int Function()? clock}) {
    behaviors.add(HelperBehavior());
    observer = ProcessMeetingSpeakerObserver(
      config ?? fastConfig(),
      clockUs: clock ?? () => captureNow,
      launcher: _launch,
      onDiagnostic: diagnostics.add,
    );
    observer.events.listen(events.add);
  }
  late final ProcessMeetingSpeakerObserver observer;

  /// The default capture clock; tests move it.
  int captureNow = 5000000;
  final List<HelperBehavior> behaviors = [];
  final List<FakeHelper> helpers = [];
  final List<List<String>> arguments = [];
  final List<SpeakerObserverEvent> events = [];
  final List<SpeakerObserverDiagnostic> diagnostics = [];

  /// Every launch that happened while an earlier helper was still running.
  final List<int> overlaps = [];
  Object? launchError;
  Completer<Process>? hangingLaunch;

  /// Each launch takes the next delay (none left: immediate) to produce its
  /// child, as a slow exec would.
  final List<Duration> launchDelays = [];
  bool expectReapFailure = false;

  /// The behavior used for the Nth helper launched; later ones reuse the last.
  HelperBehavior behaviorFor(int index) =>
      behaviors[index < behaviors.length ? index : behaviors.length - 1];

  Future<Process> _launch(String executable, List<String> args) {
    arguments.add(args);
    final error = launchError;
    if (error != null) return Future.error(error);
    final hanging = hangingLaunch;
    if (hanging != null) return hanging.future;
    FakeHelper create() {
      for (var i = 0; i < helpers.length; i++) {
        if (!helpers[i].exited) overlaps.add(i);
      }
      final helper = FakeHelper(
        behaviorFor(helpers.length),
        pidValue: 1000 + helpers.length,
      );
      helpers.add(helper);
      return helper;
    }

    if (launchDelays.isNotEmpty) {
      return Future<Process>.delayed(launchDelays.removeAt(0), create);
    }
    return Future.value(create());
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

/// A test that never assigns [h] (or fails before it does) reports its own
/// failure rather than a late-initialisation error from teardown.
Harness? _current;
Harness get h => _current!;
set h(Harness value) => _current = value;

/// Broadcast events are delivered on a later microtask turn than their
/// emission; yield so assertions see everything emitted before this point.
Future<void> settle() => Future<void>.delayed(Duration.zero);

Matcher failureOf(SpeakerObserverFailure failure) =>
    isA<SpeakerObserverException>().having(
      (e) => e.failure,
      'failure',
      failure,
    );

Future<Object> errorOf(Future<Object?> future) =>
    future.then<Object>((_) => 'completed', onError: (Object e) => e);

void main() {
  setUp(() => _current = null);

  // Every test ends by disposing its observer. Disposal must not throw (unless
  // the test declared a reap failure), must leave every helper exited, no
  // timer pending, and no launch overlapping a live helper.
  tearDown(() async {
    final harness = _current;
    if (harness == null) return;
    if (harness.expectReapFailure) {
      await expectLater(
        harness.observer.dispose(),
        throwsA(failureOf(SpeakerObserverFailure.reapFailed)),
      );
      return;
    }
    await harness.observer.dispose();
    expect(harness.allReaped, true, reason: 'a helper outlived the observer');
    expect(harness.observer.debugActiveTimers, 0);
    expect(
      harness.overlaps,
      isEmpty,
      reason: 'a helper was launched while an earlier one was unreaped',
    );
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
      await Future.wait([h.observer.inspect(), h.observer.setup()]);
      expect(h.helpers, hasLength(2));
      expect(h.overlaps, isEmpty);
    });

    test('a failed query reaps its helper and the observer recovers', () async {
      h = Harness();
      h.behaviors
        ..first.answerCapabilities = false
        ..add(HelperBehavior());
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.requestTimeout)),
      );
      expect(h.helpers.first.exited, true);
      expect((await h.observer.inspect()).available, true);
    });

    test('launch errors are told apart in diagnostics', () async {
      h = Harness();
      h.launchError = const ProcessException('/fake/helper', [], 'x', 2);
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.launchFailed)),
      );
      h.launchError = const ProcessException('/fake/helper', [], 'x', 13);
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.launchFailed)),
      );
      h.launchError = StateError('other');
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
      expect(
        h.diagnosticCodes.where(
          (c) =>
              c == SpeakerObserverDiagnosticCode.launchNotFound ||
              c == SpeakerObserverDiagnosticCode.launchNotExecutable ||
              c == SpeakerObserverDiagnosticCode.launchFailed ||
              c == SpeakerObserverDiagnosticCode.launchTimeout,
        ),
        [
          SpeakerObserverDiagnosticCode.launchNotFound,
          SpeakerObserverDiagnosticCode.launchNotExecutable,
          SpeakerObserverDiagnosticCode.launchFailed,
          SpeakerObserverDiagnosticCode.launchTimeout,
        ],
      );
      // A child that finally starts after the deadline is not leaked.
      final late = FakeHelper(
        HelperBehavior()
          ..exitOnStdinClose = false
          ..exitOnTerm = false,
      );
      h.hangingLaunch!.complete(late);
      await eventually(() => late.exited);
      expect(late.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
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

    test('a helper that dies before its hello is a helper exit', () async {
      h = Harness();
      h.behaviors.single.exitBeforeHello = true;
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.helperExited)),
      );
      expect(
        h.diagnostics
            .firstWhere(
              (d) => d.code == SpeakerObserverDiagnosticCode.helperExited,
            )
            .value,
        127,
      );
      await expectLater(
        h.observer.start('s1'),
        throwsA(failureOf(SpeakerObserverFailure.helperExited)),
      );
    });

    test('a hello within the handshake deadline is accepted', () async {
      h = Harness();
      h.behaviors.single.helloDelay = const Duration(milliseconds: 100);
      expect((await h.observer.inspect()).available, true);
      h.behaviors.single.helloDelay = const Duration(milliseconds: 800);
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.handshakeTimeout)),
      );
    });

    test('a second hello is a protocol error', () async {
      h = Harness();
      h.behaviors.single.helloTwice = true;
      final error = await errorOf(h.observer.inspect());
      // The query may finish before the second hello is read; either way the
      // helper must not be trusted afterwards.
      if (error is SpeakerObserverException) {
        expect(error.failure, SpeakerObserverFailure.protocolError);
      }
      await settle();
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
      expect(h.observer.stats.protocolErrors, greaterThan(0));
    });

    test('an error reply surfaces only the stable helper code', () async {
      h = Harness();
      h.behaviors.single.answerCapabilities = false;
      final future = errorOf(h.observer.inspect());
      await eventually(
        () => h.helpers.isNotEmpty && h.helpers.single.requests.isNotEmpty,
      );
      h.helpers.single.send('error', {
        'id': h.helpers.single.requests.single['id'],
        'code': 'ax_failed',
        'message': 'SECRET NAME leaked',
      });
      final error = await future;
      expect(error, failureOf(SpeakerObserverFailure.helperError));
      expect((error as SpeakerObserverException).helperCode, 'ax_failed');
      expect(error.toString(), isNot(contains('SECRET')));
    });

    test('a reply of the wrong type is a protocol error', () async {
      h = Harness();
      h.behaviors.single.answerCapabilities = false;
      final future = errorOf(h.observer.inspect());
      await eventually(
        () => h.helpers.isNotEmpty && h.helpers.single.requests.isNotEmpty,
      );
      h.helpers.single.send('clock', {
        'id': h.helpers.single.requests.single['id'],
        'monotonic_ms': 5,
      });
      expect(await future, failureOf(SpeakerObserverFailure.protocolError));
      expect(h.observer.stats.protocolErrors, 1);
    });

    test(
      'a query cancelled by stop ends promptly and reaps its helper',
      () async {
        h = Harness(config: patientConfig());
        h.behaviors.single.answerCapabilities = false;
        final query = errorOf(h.observer.inspect());
        await eventually(
          () => h.helpers.isNotEmpty && h.helpers.single.requests.isNotEmpty,
        );
        final elapsed = Stopwatch()..start();
        await h.observer.stop();
        expect(await query, failureOf(SpeakerObserverFailure.cancelled));
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(h.allReaped, true);
      },
    );
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
      h = Harness();
      // Probe round trips of 400, 10 and 800 us: the fake advances the
      // observer's clock while "handling" each request, so the test does not
      // depend on how often the observer reads its clock.
      final trips = [400, 10, 800];
      var next = 0;
      h.behaviors.single.onClockRequest = (_) {
        h.captureNow += trips[next++];
      };
      await h.observer.start('s1');
      expect(next, 3);
      h.helpers.single.send('observation', observationFields('s1'));
      await eventually(() => h.observations.isNotEmpty);
      final observed = h.observations.single.observation;
      // The 10 us probe started at 5 000 400 us and the helper said 1 000 ms:
      // offset = 5 000 400 + 5 - 1 000 000, uncertainty 5 + 1000 us.
      expect(observed.readStartUs, 2000000 + 4000405 - 1005);
      expect(observed.readEndUs, 2010000 + 4000405 + 1005);
    });

    test('a clock that runs backward invalidates the probe', () async {
      h = Harness();
      h.behaviors.single.onClockRequest = (_) => h.captureNow -= 500;
      await expectLater(
        h.observer.start('s1'),
        throwsA(failureOf(SpeakerObserverFailure.clockUnavailable)),
      );
      expect(
        h.diagnosticCodes.where(
          (c) => c == SpeakerObserverDiagnosticCode.clockRejected,
        ),
        hasLength(3),
      );
      expect(h.allReaped, true);
    });

    test('each helper has its own clock measurement', () async {
      h = Harness();
      h.behaviors
        ..single.clockMs = 1000
        ..add(HelperBehavior()..clockMs = 3000);
      await h.observer.start('s1');
      h.helpers.first.send('observation', observationFields('s1'));
      await eventually(() => h.observations.length == 1);
      h.helpers.first.exit(1);
      await eventually(
        () =>
            h.helpers.length == 2 &&
            h.states.last.status == ObserverStatus.running,
      );
      h.helpers.last.send('observation', observationFields('s1'));
      await eventually(() => h.observations.length == 2);
      // The same helper-clock reading maps 2 s later through the second fix.
      expect(
        h.observations.first.observation.readStartUs -
            h.observations.last.observation.readStartUs,
        2000000,
      );
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
          })
          ..send('unavailable', {'session': 's1', 'since_ms': 1600});
        await eventually(
          () => h.events.whereType<UnavailableEvent>().length == 4,
        );
        final first = h.events.whereType<UnavailableEvent>().first;
        expect(first.reason, 'window_lost');
        // 1500 ms helper time => capture 5.5 s, widened by the 1 ms allowance.
        expect(first.sinceUs, 5500000 - 1000);
        expect(h.events.whereType<UnavailableEvent>().last.reason, '');
        expect(h.observer.stats.unavailableFrames, 5);
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

    test('an "available" answer to start is a protocol error', () async {
      h = Harness();
      h.behaviors.single
        ..startReply = 'unavailable'
        ..capabilityState = 'available';
      await expectLater(
        h.observer.start('s1'),
        throwsA(failureOf(SpeakerObserverFailure.protocolError)),
      );
      expect(h.observer.stats.protocolErrors, 1);
    });

    test('an error reply to start is a helper error', () async {
      h = Harness();
      h.behaviors.single.startReply = 'error';
      final error = await errorOf(h.observer.start('s1'));
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
        final result = errorOf(h.observer.start('s1'));
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
        expect(h.observer.stats.protocolErrors, 1);
      },
    );

    test('rejects invalid session identifiers and double starts', () async {
      h = Harness();
      await expectLater(
        h.observer.start(''),
        throwsA(failureOf(SpeakerObserverFailure.invalidArgument)),
      );
      await expectLater(
        h.observer.start('bad\nid'),
        throwsA(failureOf(SpeakerObserverFailure.invalidArgument)),
      );
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
      expect((await h.observer.inspect()).available, true);
      expect(h.helpers, hasLength(1));
      expect(h.helpers.single.requestTypes.last, 'capabilities');
    });

    test('a probe that times out does not kill the live session', () async {
      h = Harness();
      await h.observer.start('s1');
      final helper = h.helpers.single;
      helper.behavior.answerCapabilities = false;
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.requestTimeout)),
      );
      // The late answer is recognised, not treated as an unsolicited reply.
      helper.send('capabilities', {
        'id': helper.requests.last['id'],
        'state': 'available',
      });
      helper.send('observation', observationFields('s1'));
      await eventually(() => h.observations.isNotEmpty);
      expect(h.helpers, hasLength(1));
      expect(helper.exited, false);
      expect(
        h.diagnosticCodes,
        contains(SpeakerObserverDiagnosticCode.staleReply),
      );
      expect(h.states.map((s) => s.status), [ObserverStatus.running]);
    });

    test(
      'a reply to an id that was never issued is a protocol error',
      () async {
        h = Harness();
        await h.observer.start('s1');
        h.helpers.single.send('capabilities', {
          'id': 'nobody-asked',
          'state': 'available',
        });
        await eventually(() => h.helpers.length == 2);
        expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
      },
    );

    test('a query while starting is refused', () async {
      h = Harness();
      h.behaviors.single.answerClock = false;
      final start = errorOf(h.observer.start('s1'));
      await eventually(() => h.helpers.isNotEmpty);
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.busy)),
      );
      expect(await start, isA<SpeakerObserverException>());
    });

    test('start waits for a query already in flight', () async {
      h = Harness();
      h.behaviors
        ..first.answerCapabilities = false
        ..add(HelperBehavior());
      final query = errorOf(h.observer.inspect());
      await eventually(() => h.helpers.isNotEmpty);
      await h.observer.start('s1');
      expect(await query, failureOf(SpeakerObserverFailure.requestTimeout));
      expect(h.helpers, hasLength(2));
      expect(h.helpers.first.exited, true);
      expect(h.overlaps, isEmpty);
    });

    test(
      'stderr is drained and counted without blocking observation',
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
        await h.observer.stop();
        expect(
          h.diagnostics
              .firstWhere(
                (d) => d.code == SpeakerObserverDiagnosticCode.helperStderr,
              )
              .value,
          180,
        );
      },
    );
  });

  group('ownership of abandoned launches', () {
    test(
      'stop returns only after a late child that needs TERM is reaped',
      () async {
        // A child that ignores stdin EOF takes exitGrace (400 ms) to reap, longer
        // than the kill grace (100 ms) that bounds waiting for a launch.
        h = Harness(
          config: fastConfig(
            exitGrace: const Duration(milliseconds: 400),
            spawn: const Duration(seconds: 20),
          ),
        );
        h.launchDelays.add(const Duration(milliseconds: 20));
        h.behaviors.single.exitOnStdinClose = false;
        final start = errorOf(h.observer.start('s1'));
        await eventually(() => h.arguments.isNotEmpty);
        await h.observer.stop();
        expect(h.helpers, hasLength(1));
        expect(
          h.helpers.single.exited,
          true,
          reason: 'stop returned over a live child',
        );
        expect(await start, failureOf(SpeakerObserverFailure.cancelled));
        h.behaviors.single.exitOnStdinClose = true;
        await h.observer.start('s2');
        expect(h.overlaps, isEmpty);
      },
    );

    test(
      'a launch that outlived its timeout is reaped before the next launch',
      () async {
        h = Harness(
          config: fastConfig(exitGrace: const Duration(milliseconds: 300)),
        );
        // The first launch takes 500 ms against a 300 ms spawn timeout.
        h.launchDelays.addAll([
          const Duration(milliseconds: 500),
          Duration.zero,
        ]);
        h.behaviors.single.exitOnStdinClose = false;
        await expectLater(
          h.observer.start('s1'),
          throwsA(failureOf(SpeakerObserverFailure.launchFailed)),
        );
        h.behaviors.single.exitOnStdinClose = true;
        await h.observer.start('s2');
        expect(h.helpers, hasLength(2));
        expect(h.helpers.first.exited, true);
        expect(h.overlaps, isEmpty);
      },
    );

    test('dispose waits for a query that is still launching', () async {
      h = Harness(config: fastConfig(spawn: const Duration(seconds: 20)));
      h.launchDelays.add(const Duration(milliseconds: 80));
      final query = errorOf(h.observer.inspect());
      await eventually(() => h.arguments.isNotEmpty);
      await h.observer.dispose();
      expect(h.helpers, hasLength(1));
      expect(h.helpers.single.exited, true);
      expect(await query, failureOf(SpeakerObserverFailure.cancelled));
    });

    test('a query queued behind another is cancelled by stop', () async {
      h = Harness(config: patientConfig());
      h.behaviors.single.answerCapabilities = false;
      final first = errorOf(h.observer.inspect());
      final second = errorOf(h.observer.setup());
      await eventually(() => h.helpers.isNotEmpty);
      await h.observer.stop();
      expect(await first, failureOf(SpeakerObserverFailure.cancelled));
      expect(await second, failureOf(SpeakerObserverFailure.cancelled));
      expect(h.helpers, hasLength(1));
    });

    test('idle queries leave nothing registered for cancellation', () async {
      h = Harness();
      for (var i = 0; i < 20; i++) {
        await h.observer.inspect();
      }
      expect(h.observer.debugOpenCancelables, 0);
    });

    test(
      'frames that arrive during a stop do not arm the stall timer',
      () async {
        h = Harness(
          config: fastConfig(
            stallSlack: const Duration(milliseconds: 100),
            exitGrace: const Duration(milliseconds: 700),
          ),
        );
        h.behaviors.single
          ..answerStop = false
          ..exitOnStdinClose = false;
        await h.observer.start('s1');
        final stop = h.observer.stop();
        h.helpers.single.send('observation', observationFields('s1'));
        await stop;
        expect(h.observer.stats.stalls, 0);
        expect(
          h.diagnosticCodes,
          isNot(contains(SpeakerObserverDiagnosticCode.stalled)),
        );
      },
    );
  });

  group('a full request queue', () {
    test('a refused start is retried with a fresh identifier', () async {
      h = Harness();
      h.behaviors.single.busyRemaining = 2;
      await h.observer.start('s1');
      final starts = h.helpers.single.requests
          .where((r) => r['type'] == 'start')
          .toList();
      expect(starts, hasLength(3));
      expect(starts.map((r) => r['id']).toSet(), hasLength(3));
      expect(
        h.diagnostics
            .where((d) => d.code == SpeakerObserverDiagnosticCode.busyRetried)
            .map((d) => d.value),
        [1, 2],
      );
      await settle();
      expect(h.states.map((s) => s.status), [ObserverStatus.running]);
    });

    test('busy answers to clock probes and queries are retried too', () async {
      h = Harness();
      h.behaviors.single
        ..busyRemaining = 3
        ..busyTypes = {'clock', 'capabilities'};
      await h.observer.start('s1');
      expect((await h.observer.inspect()).available, true);
      expect(
        h.helpers.single.requestTypes.where((t) => t == 'clock'),
        hasLength(3 + 3),
      );
      h.behaviors.single.busyRemaining = 1;
      expect((await h.observer.inspect()).available, true);
    });

    test(
      'a start that stays busy fails with a retryable code and reaps',
      () async {
        h = Harness();
        h.behaviors.single.busyRemaining = -1;
        final error = await errorOf(h.observer.start('s1'));
        expect(error, failureOf(SpeakerObserverFailure.helperError));
        expect((error as SpeakerObserverException).helperCode, 'busy');
        expect(
          h.helpers.single.requestTypes.where((t) => t == 'start'),
          hasLength(4),
        );
        expect(h.allReaped, true);
        // Nothing was left behind: the very same start can be tried again.
        h.behaviors.single.busyRemaining = 0;
        await h.observer.start('s1');
      },
    );

    test('a restart refused as busy is retried inside the budget', () async {
      h = Harness();
      h.behaviors.add(HelperBehavior()..busyRemaining = -1);
      h.behaviors.add(HelperBehavior());
      await h.observer.start('s1');
      h.helpers.single.exit(1);
      await eventually(
        () =>
            h.helpers.length == 3 &&
            h.states.last.status == ObserverStatus.running,
      );
      expect(h.states.last.restartCount, 2);
    });

    test('stop ends a busy retry wait at once', () async {
      h = Harness(
        config: SpeakerObserverConfig(
          executable: '/fake/helper',
          pollMs: 50,
          readDeadlineMs: 50,
          backoffInitial: const Duration(seconds: 20),
          backoffMax: const Duration(seconds: 20),
          exitGrace: const Duration(milliseconds: 100),
          termGrace: const Duration(milliseconds: 100),
          killGrace: const Duration(milliseconds: 100),
        ),
      );
      h.behaviors.single.busyRemaining = -1;
      final start = errorOf(h.observer.start('s1'));
      await eventually(
        () => h.diagnosticCodes.contains(
          SpeakerObserverDiagnosticCode.busyRetried,
        ),
      );
      final elapsed = Stopwatch()..start();
      await h.observer.stop();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
      expect(await start, failureOf(SpeakerObserverFailure.cancelled));
    });
  });

  group('implausible input', () {
    test(
      'a read from the far future restarts the helper and does not poison attribution',
      () async {
        h = Harness();
        final session = SpeakerAttributionSession(session: 's1');
        h.observer.events.listen(session.apply);
        await h.observer.start('s1');
        // 2^49 ms is about 17 000 years ahead of the capture clock.
        h.helpers.single.send(
          'observation',
          observationFields('s1', startMs: 1 << 49),
        );
        await eventually(() => h.helpers.length == 2);
        expect(h.observer.stats.implausibleReads, 1);
        expect(
          h.diagnosticCodes,
          contains(SpeakerObserverDiagnosticCode.implausibleRead),
        );
        expect(h.observations, isEmpty);
        await eventually(() => h.states.last.status == ObserverStatus.running);
        h.captureNow = 8000000;
        for (var i = 0; i < 4; i++) {
          h.helpers.last.send(
            'observation',
            observationFields('s1', startMs: 3000 + 500 * i),
          );
        }
        await eventually(() => h.observations.length == 4);
        await settle();
        expect(session.rejectedObservationCount, 0);
        expect(session.history.readCount, 4);
      },
    );

    test('a read from before the session began is implausible', () async {
      h = Harness();
      // The helper believes it is 90 s into its clock; the capture clock is at
      // 100 s, so the offset is +10 s and a read at helper 2 s lands at 12 s,
      // far before the session began.
      h.captureNow = 100000000;
      h.behaviors.single.clockMs = 90000;
      await h.observer.start('s1');
      h.helpers.single.send(
        'observation',
        observationFields('s1', startMs: 92000),
      );
      await eventually(() => h.observations.isNotEmpty);
      expect(h.observer.stats.implausibleReads, 0);
      h.helpers.single.send(
        'observation',
        observationFields('s1', startMs: 2000),
      );
      await eventually(() => h.helpers.length == 2);
      expect(h.observer.stats.implausibleReads, 1);
    });

    test(
      'a read that took longer than any deadline allows is implausible',
      () async {
        h = Harness();
        await h.observer.start('s1');
        final fields = observationFields('s1', startMs: 2000)
          ..['read_end_ms'] = 2000 + 60000;
        h.helpers.single.send('observation', fields);
        await eventually(() => h.helpers.length == 2);
        expect(h.observer.stats.implausibleReads, 1);
      },
    );

    test(
      'a flood of frames is a protocol error, not a satisfied stall timer',
      () async {
        h = Harness(config: fastConfig(maxFramesPerSecond: 10));
        await h.observer.start('s1');
        for (var i = 0; i < 200; i++) {
          h.helpers.single.send('observation', observationFields('s1'));
        }
        await eventually(() => h.helpers.length == 2);
        expect(
          h.diagnosticCodes,
          contains(SpeakerObserverDiagnosticCode.frameFlood),
        );
        expect(h.observations.length, lessThanOrEqualTo(10));
        expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
      },
    );

    test('frames before start is acknowledged are protocol errors', () async {
      for (final frame in [
        {'type': 'observation', ...observationFields(r'$session')},
        {
          'type': 'unavailable',
          'session': r'$session',
          'reason': 'x',
          'since_ms': 1,
        },
      ]) {
        h = Harness();
        h.behaviors.single.beforeStarted = [frame];
        await expectLater(
          h.observer.start('s1'),
          throwsA(failureOf(SpeakerObserverFailure.protocolError)),
        );
        expect(h.allReaped, true);
        await h.observer.dispose();
        _current = null;
      }
    });

    test(
      'stdout stream errors are protocol errors and restart the helper',
      () async {
        h = Harness();
        await h.observer.start('s1');
        h.helpers.single.stdoutError();
        await eventually(() => h.helpers.length == 2);
        expect(h.states[1].failure, SpeakerObserverFailure.protocolError);
        expect(h.observer.stats.protocolErrors, 1);
      },
    );

    test('stderr stream errors are ignored', () async {
      h = Harness();
      await h.observer.start('s1');
      h.helpers.single.stderrError();
      h.helpers.single.send('observation', observationFields('s1'));
      await eventually(() => h.observations.isNotEmpty);
      expect(h.helpers, hasLength(1));
    });
  });

  group('broken pipes', () {
    test(
      'a stdin write that throws is a helper exit, not an uncaught error',
      () async {
        h = Harness();
        h.behaviors.single.stdinMode = 'throwOnAdd';
        await expectLater(
          h.observer.start('s1'),
          throwsA(failureOf(SpeakerObserverFailure.helperExited)),
        );
        expect(h.allReaped, true);
      },
    );

    test(
      'a stdin that fails after accepting writes restarts the helper',
      () async {
        h = Harness();
        await h.observer.start('s1');
        h.helpers.single.breakPipe();
        await eventually(() => h.helpers.length == 2);
        expect(h.states[1].failure, SpeakerObserverFailure.helperExited);
      },
    );

    test('a dead helper is never written to by stop or queries', () async {
      h = Harness(
        config: SpeakerObserverConfig(
          executable: '/fake/helper',
          pollMs: 50,
          readDeadlineMs: 50,
          backoffInitial: const Duration(seconds: 30),
          backoffMax: const Duration(seconds: 30),
          stallSlack: const Duration(seconds: 30),
          exitGrace: const Duration(milliseconds: 100),
          termGrace: const Duration(milliseconds: 100),
          killGrace: const Duration(milliseconds: 100),
        ),
      );
      await h.observer.start('s1');
      final requests = h.helpers.single.requests.length;
      h.helpers.single.exit(1);
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.restarting),
      );
      await expectLater(
        h.observer.inspect(),
        throwsA(failureOf(SpeakerObserverFailure.busy)),
      );
      await h.observer.stop();
      expect(h.helpers.single.requests.length, requests);
    });
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
      expect(h.states.last.failure, isNull);
      // Idempotent, and a new session may follow.
      await h.observer.stop();
      await h.observer.start('s2');
      expect(h.helpers, hasLength(2));
    });

    test('concurrent stops share one shutdown', () async {
      h = Harness();
      await h.observer.start('s1');
      await Future.wait([h.observer.stop(), h.observer.stop()]);
      await settle();
      expect(
        h.helpers.single.requestTypes.where((t) => t == 'stop'),
        hasLength(1),
      );
      expect(
        h.states.where((s) => s.status == ObserverStatus.stopped),
        hasLength(1),
      );
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
        await settle();
        final helper = h.helpers.single;
        expect(helper.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
        expect(helper.exited, true);
        expect(h.states.last.failure, SpeakerObserverFailure.shutdownTimeout);
        final order = h.diagnosticCodes.where(
          (c) =>
              c == SpeakerObserverDiagnosticCode.termSent ||
              c == SpeakerObserverDiagnosticCode.killSent,
        );
        expect(order, [
          SpeakerObserverDiagnosticCode.termSent,
          SpeakerObserverDiagnosticCode.killSent,
        ]);
      },
    );

    test(
      'an unkillable helper reports reap failure and blocks reuse',
      () async {
        h = Harness();
        h.expectReapFailure = true;
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

    test(
      'an error or foreign-session stop reply is reported as unclean',
      () async {
        for (final (reply, failure) in [
          ('error', SpeakerObserverFailure.helperError),
          ('wrong_session', SpeakerObserverFailure.protocolError),
        ]) {
          h = Harness();
          h.behaviors.single.stopReply = reply;
          await h.observer.start('s1');
          await h.observer.stop();
          await settle();
          expect(h.states.last.status, ObserverStatus.stopped);
          expect(h.states.last.failure, failure, reason: reply);
          expect(h.allReaped, true);
          await h.observer.dispose();
          _current = null;
        }
      },
    );

    test('a nonzero exit after stop is reported as unclean', () async {
      h = Harness();
      h.behaviors.single.stopExitStatus = 3;
      await h.observer.start('s1');
      await h.observer.stop();
      await settle();
      expect(h.states.last.failure, SpeakerObserverFailure.helperExited);
    });

    test(
      'stop cancels a start that is still handshaking, killing a stubborn helper',
      () async {
        h = Harness(config: patientConfig());
        h.behaviors.single
          ..sendHello = false
          ..exitOnStdinClose = false
          ..exitOnTerm = false;
        final start = errorOf(h.observer.start('s1'));
        await eventually(() => h.helpers.isNotEmpty);
        final elapsed = Stopwatch()..start();
        await h.observer.stop();
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(await start, failureOf(SpeakerObserverFailure.cancelled));
        expect(h.helpers.single.exited, true);
        expect(h.helpers.single.signals, contains(ProcessSignal.sigkill));
        // Nothing is left running that a new start could overlap.
        h.behaviors.single
          ..sendHello = true
          ..exitOnStdinClose = true
          ..exitOnTerm = true;
        await h.observer.start('s2');
        expect(h.overlaps, isEmpty);
      },
    );

    test('stop cancels a start stuck in the clock probes', () async {
      h = Harness(config: patientConfig());
      h.behaviors.single
        ..answerClock = false
        ..exitOnStdinClose = false
        ..exitOnTerm = false;
      final start = errorOf(h.observer.start('s1'));
      await eventually(
        () =>
            h.helpers.isNotEmpty &&
            h.helpers.single.requestTypes.contains('clock'),
      );
      final elapsed = Stopwatch()..start();
      await h.observer.stop();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
      expect(await start, failureOf(SpeakerObserverFailure.cancelled));
      expect(h.helpers.single.exited, true);
    });

    test('stop cancels a start waiting for its acknowledgement', () async {
      h = Harness(config: patientConfig());
      h.behaviors.single
        ..startReply = 'silent'
        ..exitOnStdinClose = false
        ..exitOnTerm = false;
      final start = errorOf(h.observer.start('s1'));
      await eventually(
        () =>
            h.helpers.isNotEmpty &&
            h.helpers.single.requestTypes.contains('start'),
      );
      await h.observer.stop();
      expect(await start, failureOf(SpeakerObserverFailure.cancelled));
      expect(h.helpers.single.exited, true);
    });

    test(
      'a started reply that arrives after stop began still leaves no helper',
      () async {
        h = Harness(config: patientConfig());
        h.behaviors.single
          ..startReply = 'silent'
          ..exitOnStdinClose = false
          ..exitOnTerm = false;
        final start = errorOf(h.observer.start('s1'));
        await eventually(
          () =>
              h.helpers.isNotEmpty &&
              h.helpers.single.requestTypes.contains('start'),
        );
        final helper = h.helpers.single;
        // The helper answers just as stop begins.
        final stop = h.observer.stop();
        helper.send('started', {
          'id': helper.requests.last['id'],
          'session': 's1',
          'target': {'pid': 1, 'window': 'w'},
        });
        await stop;
        // stop() has returned: the helper must already be gone, and the start
        // must have failed rather than leaving a running session behind.
        expect(helper.exited, true);
        expect(await start, failureOf(SpeakerObserverFailure.cancelled));
        expect(
          h.states.where((s) => s.status == ObserverStatus.running),
          isEmpty,
        );
      },
    );

    test(
      'stop with a launch that never returns does not wait for it',
      () async {
        h = Harness(config: fastConfig(spawn: const Duration(seconds: 20)));
        h.hangingLaunch = Completer<Process>();
        final start = errorOf(h.observer.start('s1'));
        await eventually(() => h.arguments.isNotEmpty);
        final elapsed = Stopwatch()..start();
        await h.observer.stop();
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(await start, failureOf(SpeakerObserverFailure.cancelled));
        // When the abandoned launch finally produces a child, it is reaped.
        final late = FakeHelper(
          HelperBehavior()
            ..exitOnStdinClose = false
            ..exitOnTerm = false,
        );
        h.hangingLaunch!.complete(late);
        await eventually(() => late.exited);
        expect(late.signals, contains(ProcessSignal.sigkill));
      },
    );

    test(
      'dispose during stop waits for it, and stop then dispose agree',
      () async {
        h = Harness();
        await h.observer.start('s1');
        final stop = h.observer.stop();
        final dispose = h.observer.dispose();
        await Future.wait([stop, dispose]);
        expect(h.allReaped, true);
        await h.observer.dispose();
      },
    );

    test('dispose stops and closes the event stream', () async {
      h = Harness();
      var closed = false;
      h.observer.events.listen((_) {}, onDone: () => closed = true);
      await h.observer.start('s1');
      await h.observer.dispose();
      expect(h.allReaped, true);
      await eventually(() => closed);
      await expectLater(h.observer.start('s2'), throwsStateError);
    });

    test(
      'restarting the same observer for the same session never reuses a ref',
      () async {
        h = Harness();
        final session = SpeakerAttributionSession(session: 's1');
        h.observer.events.listen(session.apply);
        await h.observer.start('s1');
        h.captureNow = 5000000;
        h.helpers.single.send(
          'observation',
          observationFields(
            's1',
            startMs: 1200,
            participants: [participant('p1', 'Ada')],
          ),
        );
        await eventually(() => h.observations.length == 1);
        await h.observer.stop();
        h.captureNow = 5800000;
        await h.observer.start('s1');
        h.helpers.last.send(
          'observation',
          observationFields(
            's1',
            startMs: 1900,
            participants: [participant('p1', 'Bob')],
          ),
        );
        await eventually(() => h.observations.length == 2);
        expect(h.observations.first.observation.speakers.single.ref, '0:p1');
        expect(h.observations.last.observation.speakers.single.ref, '1:p1');
        expect(h.observations.last.epoch, 1);
      },
    );
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
      expect(h.states[1].epoch, 0);
      expect(h.states.last.restartCount, 1);
      expect(h.observer.stats.restarts, 1);
      expect(h.observer.stats.protocolErrors, greaterThan(0));
      h.helpers.last.send('observation', observationFields('s1'));
      await eventually(() => h.observations.isNotEmpty);
      expect(h.observations.single.epoch, 1);
      expect(h.observations.single.observation.participants.single.ref, '1:p1');
    });

    test('a replaced helper that keeps talking emits nothing', () async {
      h = Harness();
      h.behaviors.single
        ..exitOnStdinClose = false
        ..exitOnTerm = false;
      h.behaviors.add(HelperBehavior());
      await h.observer.start('s1');
      final old = h.helpers.single;
      old.sendRaw('garbage');
      // Until it is killed the old helper still writes valid frames.
      for (var i = 0; i < 5; i++) {
        old.send('observation', observationFields('s1'));
      }
      await eventually(() => h.helpers.length == 2 && old.exited);
      await settle();
      expect(h.observations.where((o) => o.epoch == 0), isEmpty);
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
      await errorOf(h.observer.start('s1'));
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
      await h.observer.stop();
      await settle();
      expect(h.states.last.status, ObserverStatus.stopped);
    });

    test('with no restart budget a failure is final at once', () async {
      h = Harness(config: fastConfig(maxRestarts: 0));
      await h.observer.start('s1');
      h.helpers.single.exit(1);
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.failed),
      );
      expect(h.helpers, hasLength(1));
      expect(h.states.map((s) => s.status), [
        ObserverStatus.running,
        ObserverStatus.restarting,
        ObserverStatus.failed,
      ]);
    });

    test('the budget refills after a healthy interval', () async {
      h = Harness(
        config: fastConfig(
          maxRestarts: 1,
          restartRefillAfter: const Duration(milliseconds: 120),
        ),
      );
      await h.observer.start('s1');
      for (var round = 1; round <= 3; round++) {
        // Healthy for longer than the refill interval, then an isolated crash.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        h.helpers.last.exit(1);
        await eventually(
          () =>
              h.helpers.length == round + 1 &&
              h.states.last.status == ObserverStatus.running,
        );
      }
      expect(h.states.any((s) => s.status == ObserverStatus.failed), false);
      expect(
        h.diagnosticCodes,
        contains(SpeakerObserverDiagnosticCode.restartRefilled),
      );
    });

    test(
      'without refilling, isolated crashes eventually exhaust the budget',
      () async {
        h = Harness(
          config: fastConfig(maxRestarts: 1, restartRefillAfter: null),
        );
        await h.observer.start('s1');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        h.helpers.last.exit(1);
        await eventually(
          () =>
              h.helpers.length == 2 &&
              h.states.last.status == ObserverStatus.running,
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        h.helpers.last.exit(1);
        await eventually(
          () => h.states.any((s) => s.status == ObserverStatus.failed),
        );
      },
    );

    test(
      'a restart that finds a permission problem gives up and says why',
      () async {
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
        final failed = h.states.last;
        expect(failed.failure, SpeakerObserverFailure.unavailable);
        expect(failed.availability, ObserverAvailability.permissionDenied);
        expect(h.helpers, hasLength(2));
      },
    );

    test(
      'a restart that finds no meeting is retried within the budget',
      () async {
        h = Harness();
        h.behaviors
          ..add(
            HelperBehavior()
              ..startReply = 'unavailable'
              ..capabilityState = 'no_meeting',
          )
          ..add(
            HelperBehavior()
              ..startReply = 'unavailable'
              ..capabilityState = 'zoom_not_running',
          )
          ..add(HelperBehavior());
        await h.observer.start('s1');
        h.helpers.single.exit(1);
        await eventually(
          () =>
              h.helpers.length == 4 &&
              h.states.last.status == ObserverStatus.running,
        );
        expect(h.states.last.restartCount, 3);
      },
    );

    test(
      'a persistent no-meeting answer ends in a failure that carries it',
      () async {
        h = Harness(config: fastConfig(maxRestarts: 2));
        h.behaviors.add(
          HelperBehavior()
            ..startReply = 'unavailable'
            ..capabilityState = 'no_meeting',
        );
        await h.observer.start('s1');
        h.helpers.single.exit(1);
        await eventually(
          () => h.states.any((s) => s.status == ObserverStatus.failed),
        );
        expect(h.states.last.availability, ObserverAvailability.noMeeting);
        expect(h.helpers, hasLength(3));
      },
    );

    test('a helper error code survives to the final failure', () async {
      h = Harness(config: fastConfig(maxRestarts: 1));
      h.behaviors.add(HelperBehavior()..startReply = 'error');
      await h.observer.start('s1');
      h.helpers.single.exit(1);
      await eventually(
        () => h.states.any((s) => s.status == ObserverStatus.failed),
      );
      expect(h.states.last.failure, SpeakerObserverFailure.helperError);
      expect(h.states.last.helperCode, 'ax_failed');
    });

    test(
      'an unexpected error while restarting is reported, not swallowed',
      () async {
        var armed = false;
        h = Harness(
          clock: () {
            if (armed && h.helpers.length >= 2) {
              armed = false;
              throw StateError('clock broke');
            }
            return 5000000;
          },
        );
        await h.observer.start('s1');
        armed = true;
        h.helpers.single.exit(1);
        await eventually(
          () => h.states.any((s) => s.status == ObserverStatus.failed),
        );
        expect(h.states.last.failure, SpeakerObserverFailure.internalError);
        expect(
          h.diagnosticCodes,
          contains(SpeakerObserverDiagnosticCode.internalError),
        );
        expect(h.allReaped, true);
      },
    );

    test('a failed helper that cannot be reaped ends supervision', () async {
      h = Harness();
      h.expectReapFailure = true;
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

    test(
      'a handshake whose helper cannot be reaped blocks every restart',
      () async {
        h = Harness();
        h.expectReapFailure = true;
        h.behaviors.add(
          HelperBehavior()
            ..sendHello = false
            ..exitOnStdinClose = false
            ..exitOnTerm = false
            ..exitOnKill = false,
        );
        await h.observer.start('s1');
        // The first restart attempt hangs in its handshake on an unkillable
        // helper; no further helper may be launched over it.
        h.helpers.first.exit(1);
        await eventually(
          () => h.states.any((s) => s.status == ObserverStatus.failed),
        );
        expect(h.states.last.failure, SpeakerObserverFailure.reapFailed);
        expect(h.helpers.length, lessThanOrEqualTo(2));
      },
    );

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

    test(
      'stopping while a restart is launching or handshaking leaves nothing behind',
      () async {
        for (final stage in ['launch', 'handshake', 'clock']) {
          h = Harness(config: patientConfig());
          h.behaviors.add(
            HelperBehavior()
              ..sendHello = stage != 'handshake'
              ..answerClock = stage != 'clock'
              ..exitOnStdinClose = false
              ..exitOnTerm = false,
          );
          await h.observer.start('s1');
          if (stage == 'launch') h.hangingLaunch = Completer<Process>();
          h.helpers.single.exit(1);
          if (stage == 'launch') {
            await eventually(() => h.arguments.length >= 2);
          } else {
            await eventually(() => h.helpers.length == 2);
          }
          final elapsed = Stopwatch()..start();
          await h.observer.stop();
          expect(
            elapsed.elapsed,
            lessThan(const Duration(seconds: 3)),
            reason: stage,
          );
          expect(h.allReaped, true, reason: stage);
          await settle();
          expect(h.states.last.status, ObserverStatus.stopped);
          await h.observer.dispose();
          _current = null;
        }
      },
    );

    test('a failed restart attempt is retried within the limit', () async {
      h = Harness();
      await h.observer.start('s1');
      h.launchError = const ProcessException('/fake/helper', []);
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
  });

  group('configuration', () {
    test('rejects invalid configuration', () {
      for (final bad in [
        const SpeakerObserverConfig(executable: ''),
        const SpeakerObserverConfig(executable: 'x', pollMs: 10),
        const SpeakerObserverConfig(executable: 'x', readDeadlineMs: 0),
        const SpeakerObserverConfig(executable: 'x', maxRestarts: -1),
        const SpeakerObserverConfig(executable: 'x', clockProbes: 0),
        const SpeakerObserverConfig(executable: 'x', maxFramesPerSecond: 0),
        const SpeakerObserverConfig(
          executable: 'x',
          restartRefillAfter: Duration.zero,
        ),
        const SpeakerObserverConfig(
          executable: 'x',
          requestTimeout: Duration.zero,
        ),
        // A helper may be mid-read when asked to stop.
        const SpeakerObserverConfig(
          executable: 'x',
          readDeadlineMs: 2000,
          exitGrace: Duration(seconds: 1),
        ),
      ]) {
        expect(
          () => ProcessMeetingSpeakerObserver(bad, clockUs: () => 0),
          throwsArgumentError,
        );
      }
    });

    test('defaults are valid and tie the read gap to the poll period', () {
      const config = SpeakerObserverConfig(executable: 'x');
      config.validate();
      expect(config.maxReadGapUs, 3500000);
      expect(
        const SpeakerObserverConfig(executable: 'x', pollMs: 5000).maxReadGapUs,
        (3 * 5000 + 2000) * 1000,
      );
      expect(config.frameRateLimit, 20);
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
    });
  });

  group('attribution integration', () {
    test('observer events drive attribution across a restart', () async {
      // The capture clock stands still, so allow reads far ahead of it.
      h = Harness(config: fastConfig(readSkew: const Duration(seconds: 60)));
      final session = SpeakerAttributionSession(session: 's1');
      h.observer.events.listen(session.apply);
      await h.observer.start('s1');
      Future<void> read(FakeHelper helper, int ms) async =>
          helper.send('observation', observationFields('s1', startMs: ms));
      for (var ms = 1000; ms <= 3000; ms += 500) {
        await read(h.helpers.single, ms);
      }
      await eventually(() => h.observations.length == 5);
      h.helpers.single.exit(1);
      await eventually(
        () =>
            h.helpers.length == 2 &&
            h.states.last.status == ObserverStatus.running,
      );
      for (var ms = 4000; ms <= 6000; ms += 500) {
        await read(h.helpers.last, ms);
      }
      await eventually(() => h.observations.length == 10);
      await settle();
      MappedAudioRange range(double a, double b) => MappedAudioRange(
        source: AudioSource.playback,
        sampleStart: 0,
        sampleEnd: 1,
        pieces: [
          MappedAudioPiece(
            sampleStart: 0,
            sampleEnd: 1,
            startUs: (a * 1e6).round(),
            endUs: (b * 1e6).round(),
          ),
        ],
        uncertaintyUs: 0,
        gapUs: 0,
        hasDiscontinuity: false,
        crossesRateChange: false,
      );
      AttributionDecision at(double a, double b) =>
          session.attributor.attribute(
            session.history,
            source: AudioSource.playback,
            mapped: range(a, b),
          );
      // Helper 1000 ms is capture 5 s. Before the crash: Ada, epoch 0.
      expect(at(5.2, 6.8).participantRef, '0:p1');
      // The restart interval is blind.
      expect(at(7.0, 7.5).state, isNot(SpeakerDecisionState.named));
      // After: the same person under the new epoch's reference.
      expect(at(8.5, 9.8).participantRef, '1:p1');
    });
  });
}
