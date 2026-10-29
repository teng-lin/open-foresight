/// Process-supervised [MeetingSpeakerObserver]. Owns one helper child at a time,
/// reads it through bounded NDJSON, and terminates and reaps only the children
/// it started. Nothing here blocks the event loop: every wait is an awaited
/// future or timer. Diagnostics carry codes and counters only, never helper
/// text, participant names or transcript text.
///
/// Ownership rules:
/// - A helper child is owned from the moment its launch is requested until its
///   exit status is observed. A launch that completes after it was abandoned
///   (timeout or [stop]) is drained and reaped as an orphan, and [stop] awaits
///   that reap.
/// - A new helper is never launched while an earlier one is unreaped.
/// - [stop] cancels any start, restart or one-shot query in flight, reaps
///   everything and reports a reap failure; after one, the observer refuses
///   further use because a child may still be running.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'meeting_speaker_observer.dart';
import 'speaker_observation.dart';
import 'speaker_observer_protocol.dart';

typedef SpeakerHelperLauncher =
    Future<Process> Function(String executable, List<String> arguments);

enum SpeakerObserverDiagnosticCode {
  helperStarted,
  helperExited,
  helperStderr,
  protocolError,
  helperError,
  requestTimeout,
  stalled,
  restartScheduled,
  restartRefilled,
  restartsExhausted,
  reapFailed,
  termSent,
  killSent,
  stderrFlood,
  stopRefusedBusy,
  clockMeasured,
  clockRejected,
  clockShifted,
  busyRetried,
  launchNotFound,
  launchNotExecutable,
  launchTimeout,
  launchFailed,
  implausibleRead,
  frameFlood,
  staleReply,
  internalError,
}

/// A stage and a number (exit status, byte count, attempt, delay or error code
/// index). Never helper-supplied text.
final class SpeakerObserverDiagnostic {
  const SpeakerObserverDiagnostic(this.code, [this.value = 0]);
  final SpeakerObserverDiagnosticCode code;
  final int value;
}

final class SpeakerObserverConfig {
  const SpeakerObserverConfig({
    required this.executable,
    this.arguments = const [],
    this.pollMs = 500,
    this.readDeadlineMs = 2000,
    this.spawnTimeout = const Duration(seconds: 5),
    this.handshakeTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 5),
    this.stallSlack = const Duration(seconds: 1),
    this.exitGrace = const Duration(seconds: 3),
    this.termGrace = const Duration(milliseconds: 500),
    this.killGrace = const Duration(seconds: 2),
    this.maxRestarts = 5,
    this.restartRefillAfter = const Duration(minutes: 5),
    this.backoffInitial = const Duration(milliseconds: 250),
    this.backoffMax = const Duration(seconds: 5),
    this.clockProbes = 3,
    this.clockRecheck = const Duration(seconds: 30),
    this.clockJumpTolerance = const Duration(milliseconds: 250),
    this.readSkew = const Duration(seconds: 5),
    this.maxFramesPerSecond,
    this.maxStderrBytes = 64 * 1024,
    this.maxLineBytes = speakerObserverMaxLineBytes,
  });

  /// The helper binary, and arguments placed before `--protocol 1`.
  final String executable;
  final List<String> arguments;

  /// Polling period and per-read deadline requested of the helper. A started
  /// helper must emit one `observation` or `unavailable` frame per poll, so
  /// silence for longer than poll + deadline + [stallSlack] is a stall.
  final int pollMs, readDeadlineMs;
  final Duration spawnTimeout, handshakeTimeout, requestTimeout, stallSlack;

  /// Waits after closing stdin / `stop`, then after SIGTERM, then after SIGKILL.
  /// [exitGrace] must cover the read deadline the helper was given, because a
  /// helper may be mid-read when it is asked to stop.
  final Duration exitGrace, termGrace, killGrace;

  /// Restarts allowed per budget. The budget refills (back to zero used) when a
  /// helper had been running for [restartRefillAfter] before it failed, so
  /// isolated crashes hours apart never exhaust it; null disables refilling.
  /// Zero disables restarting.
  final int maxRestarts;
  final Duration? restartRefillAfter;
  final Duration backoffInitial, backoffMax;

  /// Clock exchanges used to measure the helper-to-capture clock offset; at
  /// least one, because an unmeasured offset would silently claim exactness.
  final int clockProbes;

  /// How often the helper clock is measured again while running (null: never).
  /// The offset between the helper's clock and the capture clock is not
  /// constant: the macOS helper counts system sleep and native capture does
  /// not, so every sleep moves it.
  final Duration? clockRecheck;

  /// A re-measured offset that differs from the one in use by more than both
  /// measurements' uncertainty plus this is a shift: the reads timed since the
  /// last measurement are retracted and the new offset is used.
  final Duration clockJumpTolerance;

  /// How far a helper read may lie in the observer's future, or before the
  /// session began, before it counts as a protocol violation.
  final Duration readSkew;

  /// Stream frames (observations and unavailability) accepted per second.
  /// Null derives `max(20, 4000 / pollMs)`; more is a flooding helper.
  final int? maxFramesPerSecond;
  final int maxStderrBytes, maxLineBytes;

  Duration get stallTimeout =>
      Duration(milliseconds: pollMs + readDeadlineMs) + stallSlack;

  int get frameRateLimit => maxFramesPerSecond ?? math.max(20, 4000 ~/ pollMs);

  /// The read gap beyond which an attribution history should stop treating two
  /// equal reads as continuous: three polls plus one read deadline.
  int get maxReadGapUs => (3 * pollMs + readDeadlineMs) * 1000;

  void validate() {
    if (executable.isEmpty ||
        pollMs < 100 ||
        pollMs > 5000 ||
        readDeadlineMs < 100 ||
        readDeadlineMs > 30000 ||
        maxRestarts < 0 ||
        clockProbes < 1 ||
        maxStderrBytes < 0 ||
        (maxFramesPerSecond != null && maxFramesPerSecond! < 1) ||
        (restartRefillAfter != null && restartRefillAfter! <= Duration.zero) ||
        (clockRecheck != null && clockRecheck! <= Duration.zero) ||
        clockJumpTolerance < Duration.zero ||
        [
          spawnTimeout,
          handshakeTimeout,
          requestTimeout,
          exitGrace,
          termGrace,
          killGrace,
          backoffInitial,
          backoffMax,
        ].any((d) => d <= Duration.zero) ||
        stallSlack < Duration.zero ||
        readSkew < Duration.zero ||
        exitGrace < Duration(milliseconds: readDeadlineMs)) {
      throw ArgumentError('Invalid speaker observer configuration');
    }
  }
}

final class SpeakerObserverStats {
  const SpeakerObserverStats({
    this.helperStarts = 0,
    this.restarts = 0,
    this.protocolErrors = 0,
    this.stalls = 0,
    this.observations = 0,
    this.unavailableFrames = 0,
    this.implausibleReads = 0,
  });
  final int helperStarts,
      restarts,
      protocolErrors,
      stalls,
      observations,
      unavailableFrames,
      implausibleReads;
}

typedef _ClockFix = ({int offsetUs, int uncertaintyUs});

typedef _ReapResult = ({
  bool reaped,
  int? status,
  bool termSent,
  bool killSent,
});

/// Close stdin, then escalate TERM and KILL, each wait bounded. Only [process]
/// is signalled. Completes once the exit status is observed or all waits ran
/// out.
Future<_ReapResult> _reapProcess(
  Process process,
  SpeakerObserverConfig config,
  void Function(SpeakerObserverDiagnostic) diagnostic,
) async {
  unawaited(
    process.stdin.close().then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    ),
  );
  int? status;
  Future<bool> exited(Duration limit) => process.exitCode
      .then((code) {
        status = code;
        return true;
      })
      .timeout(limit, onTimeout: () => false);
  var reaped = await exited(config.exitGrace);
  var term = false, kill = false;
  if (!reaped) {
    term = true;
    diagnostic(
      const SpeakerObserverDiagnostic(SpeakerObserverDiagnosticCode.termSent),
    );
    process.kill();
    reaped = await exited(config.termGrace);
  }
  if (!reaped) {
    kill = true;
    diagnostic(
      const SpeakerObserverDiagnostic(SpeakerObserverDiagnosticCode.killSent),
    );
    process.kill(ProcessSignal.sigkill);
    reaped = await exited(config.killGrace);
  }
  return (reaped: reaped, status: status, termSent: term, killSent: kill);
}

/// A launch that was abandoned (timeout or cancellation) and may still
/// produce a child. The launch half ([launched]) can hang forever, so callers
/// bound their wait for it; once a child exists ([process] is set) its reap
/// ([reaped]) is always awaited, because that half is bounded by the grace
/// periods and a child must never outlive the observer's claim to be stopped.
final class _Orphan {
  _Orphan(
    Future<Process> launch,
    this.launchAge,
    SpeakerObserverConfig config,
    void Function(SpeakerObserverDiagnostic) diagnostic,
  ) {
    launched = launch.then<bool>((child) {
      process = child;
      return true;
    }, onError: (Object _, StackTrace _) => false);
    reaped = launched.then<bool>((ok) async {
      final child = process;
      if (!ok || child == null) return true;
      unawaited(
        child.stdout.drain<void>().then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      unawaited(
        child.stderr.drain<void>().then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      return (await _reapProcess(child, config, diagnostic)).reaped;
    });
  }
  late final Future<bool> launched, reaped;
  Process? process;

  /// Time since the launch was requested.
  final Stopwatch launchAge;
}

SpeakerObserverDiagnosticCode _launchDiagnostic(Object error) {
  if (error is ProcessException) {
    // errno: ENOENT and ENOTDIR mean no such file; EACCES and ENOEXEC mean it
    // cannot be run.
    if (error.errorCode == 2 || error.errorCode == 20) {
      return SpeakerObserverDiagnosticCode.launchNotFound;
    }
    if (error.errorCode == 13 || error.errorCode == 8) {
      return SpeakerObserverDiagnosticCode.launchNotExecutable;
    }
  }
  return SpeakerObserverDiagnosticCode.launchFailed;
}

/// One helper process: framing, request correlation and reaping.
final class _Connection {
  _Connection._(this._process, this._config, this._diagnostic);
  final Process _process;
  final SpeakerObserverConfig _config;
  final void Function(SpeakerObserverDiagnostic) _diagnostic;
  final ObserverFrameEncoder _encoder = ObserverFrameEncoder();
  final Map<String, Completer<ObserverFrame>> _pending = {};
  final Set<String> _abandoned = {};
  final Completer<HelloFrame> _hello = Completer();
  final Completer<void> _ended = Completer();
  final Stopwatch _window = Stopwatch()..start();
  StreamSubscription<ObserverFrame>? _frames;
  StreamSubscription<List<int>>? _errors;
  Future<_ReapResult>? _terminating;
  bool _closing = false, _exited = false, _helloSeen = false;
  int _windowFrames = 0;

  /// The latest `error` code other than `busy`, and how long ago it arrived. A
  /// helper that ends its own session (a source that only a restart can fix)
  /// writes such an error and then exits, so the code names the exit.
  String? _lastErrorCode;
  final Stopwatch _lastErrorAge = Stopwatch();

  /// Stdout reached its end (or failed); the exit handler waits for it so that
  /// frames written just before the exit are not lost to the exit event.
  final Completer<void> _stdoutDone = Completer();
  Timer? _drainTimer;
  static const Duration _exitDrain = Duration(milliseconds: 250);
  int stderrBytes = 0;

  /// Set by the owner.
  void Function(ObserverFrame frame)? onStream;
  void Function(SpeakerObserverException failure)? onFailure;
  SpeakerObserverException? failure;
  HelloFrame? hello;
  bool started = false, live = false;

  /// The latest stream frame was `unavailable`: the helper reports that only
  /// when it changes, so silence is normal and liveness needs a probe.
  bool quiet = false;
  int epoch = 0;
  _ClockFix clock = (offsetUs: 0, uncertaintyUs: 0);

  /// Capture time at which [clock] was last confirmed, the end of the latest
  /// read that was not ahead of the capture clock, and whether a recheck is
  /// under way.
  int clockVerifiedUs = 0, lastGoodEndUs = 0;
  bool rechecking = false;

  /// Launch, handshake. [cancel] aborts a launch in flight; [onCreated] runs as
  /// soon as the child exists so the owner can cancel the handshake through
  /// [fail]; [reap] terminates a connection that failed its handshake and
  /// [orphan] adopts a launch that finished too late.
  static Future<_Connection> open(
    SpeakerObserverConfig config,
    SpeakerHelperLauncher launcher,
    void Function(SpeakerObserverDiagnostic) diagnostic, {
    required Future<void> cancel,
    required void Function(_Connection connection) onCreated,
    required Future<void> Function(_Connection connection) reap,
    required void Function(Future<Process> launch, Stopwatch age) orphan,
  }) async {
    final launchAge = Stopwatch()..start();
    final Future<Process> launch;
    try {
      launch = launcher(config.executable, [
        ...config.arguments,
        '--protocol',
        '$speakerObserverProtocolVersion',
      ]);
    } on Object catch (error) {
      diagnostic(SpeakerObserverDiagnostic(_launchDiagnostic(error)));
      throw const SpeakerObserverException(SpeakerObserverFailure.launchFailed);
    }
    final ready = Completer<Process>();
    final timer = Timer(config.spawnTimeout, () {
      if (ready.isCompleted) return;
      diagnostic(
        const SpeakerObserverDiagnostic(
          SpeakerObserverDiagnosticCode.launchTimeout,
        ),
      );
      ready.completeError(
        const SpeakerObserverException(SpeakerObserverFailure.launchFailed),
      );
    });
    unawaited(
      cancel.then<void>((_) {
        if (!ready.isCompleted) {
          ready.completeError(
            const SpeakerObserverException(SpeakerObserverFailure.cancelled),
          );
        }
      }),
    );
    unawaited(
      launch.then<void>(
        (process) {
          if (!ready.isCompleted) ready.complete(process);
        },
        onError: (Object error, StackTrace _) {
          if (ready.isCompleted) return;
          diagnostic(SpeakerObserverDiagnostic(_launchDiagnostic(error)));
          ready.completeError(
            const SpeakerObserverException(SpeakerObserverFailure.launchFailed),
          );
        },
      ),
    );
    final Process process;
    try {
      process = await ready.future;
    } on SpeakerObserverException {
      // The child may still appear; it must not outlive its abandonment.
      orphan(launch, launchAge);
      rethrow;
    } finally {
      timer.cancel();
    }
    final connection = _Connection._(process, config, diagnostic);
    connection._attach();
    diagnostic(
      const SpeakerObserverDiagnostic(
        SpeakerObserverDiagnosticCode.helperStarted,
      ),
    );
    onCreated(connection);
    try {
      connection.hello = await connection._hello.future.timeout(
        config.handshakeTimeout,
        onTimeout: () {
          const timeout = SpeakerObserverException(
            SpeakerObserverFailure.handshakeTimeout,
          );
          connection.fail(timeout);
          throw timeout;
        },
      );
    } on SpeakerObserverException {
      await reap(connection);
      rethrow;
    }
    return connection;
  }

  void _attach() {
    _frames =
        decodeObserverFrames(
          _process.stdout,
          maxLineBytes: _config.maxLineBytes,
        ).listen(
          _onFrame,
          onError: (Object error, StackTrace _) {
            if (!_stdoutDone.isCompleted) _stdoutDone.complete();
            protocolFailure(
              error is ObserverProtocolException
                  ? error.code
                  : ObserverProtocolErrorCode.malformed,
            );
          },
          onDone: () {
            if (!_stdoutDone.isCompleted) _stdoutDone.complete();
            // Stdout closing without an orderly stop means the helper went away.
            if (!_closing && !_exited) fail(_exitFailure());
          },
          cancelOnError: true,
        );
    _errors = _process.stderr.listen(
      (chunk) {
        final before = stderrBytes;
        stderrBytes += chunk.length;
        if (before <= _config.maxStderrBytes &&
            stderrBytes > _config.maxStderrBytes) {
          _diagnostic(
            const SpeakerObserverDiagnostic(
              SpeakerObserverDiagnosticCode.stderrFlood,
            ),
          );
        }
      },
      onError: (Object _, StackTrace _) {},
      cancelOnError: false,
    );
    unawaited(
      _process.stdin.done.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (!_closing) {
            fail(
              const SpeakerObserverException(
                SpeakerObserverFailure.helperExited,
              ),
            );
          }
        },
      ),
    );
    unawaited(
      _process.exitCode.then<void>((status) async {
        _exited = true;
        _diagnostic(
          SpeakerObserverDiagnostic(
            SpeakerObserverDiagnosticCode.helperExited,
            status,
          ),
        );
        if (_closing) return;
        await _drainStdout();
        if (!_closing) fail(_exitFailure());
      }),
    );
  }

  /// Gives frames the helper wrote just before it exited a bounded chance to
  /// arrive: the exit event and the data in the pipe are not ordered.
  Future<void> _drainStdout() async {
    if (_stdoutDone.isCompleted) return;
    _drainTimer = Timer(_exitDrain, () {
      if (!_stdoutDone.isCompleted) _stdoutDone.complete();
    });
    await _stdoutDone.future;
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  /// An unexpected exit. A helper that reported why just before leaving (the
  /// terminal `error` of a source-ended session) has that reason attached.
  SpeakerObserverException _exitFailure() {
    final code = _lastErrorCode;
    final recent = code != null && _lastErrorAge.elapsed <= _config.exitGrace;
    return SpeakerObserverException(
      SpeakerObserverFailure.helperExited,
      helperCode: recent ? code : null,
    );
  }

  void _onFrame(ObserverFrame frame) {
    if (_closing || failure != null) return;
    if (frame is HelloFrame) {
      if (_helloSeen ||
          (frame.platform != 'macos' && frame.platform != 'linux')) {
        return protocolFailure();
      }
      _helloSeen = true;
      _hello.complete(frame);
      return;
    }
    if (!_helloSeen) return protocolFailure();
    switch (frame) {
      case CapabilitiesFrame(:final id):
      case ClockFrame(:final id):
      case StoppedFrame(:final id):
        _reply(id, frame);
      case StartedFrame(:final id):
        started = true;
        _reply(id, frame);
      case ErrorFrame(:final id):
        if (frame.code != 'busy') {
          _lastErrorCode = frame.code;
          _lastErrorAge
            ..reset()
            ..start();
        }
        if (id == null) {
          _diagnostic(
            const SpeakerObserverDiagnostic(
              SpeakerObserverDiagnosticCode.helperError,
            ),
          );
          fail(
            SpeakerObserverException(
              SpeakerObserverFailure.helperError,
              helperCode: frame.code,
            ),
          );
        } else {
          _reply(id, frame);
        }
      case ObservationFrame() || UnavailableFrame():
        if (!started) return protocolFailure();
        // One stream frame per poll is expected; a helper that floods would
        // otherwise keep the stall timer satisfied forever.
        if (_window.elapsedMilliseconds >= 1000) {
          _window
            ..reset()
            ..start();
          _windowFrames = 0;
        }
        if (++_windowFrames > _config.frameRateLimit) {
          _diagnostic(
            const SpeakerObserverDiagnostic(
              SpeakerObserverDiagnosticCode.frameFlood,
            ),
          );
          return protocolFailure();
        }
        onStream?.call(frame);
      case HelloFrame():
        break;
    }
  }

  void _reply(String id, ObserverFrame frame) {
    final completer = _pending.remove(id);
    if (completer != null) {
      completer.complete(frame);
      return;
    }
    if (_abandoned.remove(id)) {
      // The reply to a request that already timed out without failing the
      // helper (a query on a live session).
      _diagnostic(
        const SpeakerObserverDiagnostic(
          SpeakerObserverDiagnosticCode.staleReply,
        ),
      );
      return;
    }
    protocolFailure();
  }

  /// The helper broke the protocol in some way the codec could not see.
  void protocolFailure([
    ObserverProtocolErrorCode code = ObserverProtocolErrorCode.malformed,
  ]) {
    if (_closing || failure != null) return;
    _diagnostic(
      SpeakerObserverDiagnostic(
        SpeakerObserverDiagnosticCode.protocolError,
        code.index,
      ),
    );
    fail(const SpeakerObserverException(SpeakerObserverFailure.protocolError));
  }

  /// Record the first failure, release every waiter and tell the owner once.
  void fail(SpeakerObserverException exception) {
    if (failure != null || _closing) return;
    failure = exception;
    if (!_ended.isCompleted) _ended.complete();
    for (final completer in _pending.values) {
      completer.completeError(exception);
    }
    _pending.clear();
    if (!_hello.isCompleted) _hello.completeError(exception);
    // Stop reading whatever else a failed helper has buffered. The pipe is
    // paused, not cancelled: a helper writing into a closed pipe may die by
    // itself, which would hide whether it honours signals; it is terminated
    // and reaped deliberately instead.
    _frames?.pause();
    onFailure?.call(exception);
  }

  /// With [failOnTimeout] false a timeout leaves the helper running (a probe on
  /// a live session must not kill it); the late reply is then ignored.
  Future<ObserverFrame> request(
    ObserverRequest request,
    Duration timeout, {
    bool failOnTimeout = true,
  }) {
    final existing = failure;
    if (existing != null) return Future.error(existing);
    if (_closing || _exited) {
      return Future.error(
        const SpeakerObserverException(SpeakerObserverFailure.helperExited),
      );
    }
    final List<int> bytes;
    try {
      bytes = _encoder.encode(request);
    } on ArgumentError {
      return Future.error(
        const SpeakerObserverException(SpeakerObserverFailure.invalidArgument),
      );
    }
    final completer = Completer<ObserverFrame>();
    _pending[request.id] = completer;
    try {
      _process.stdin.add(bytes);
    } on Object {
      _pending.remove(request.id);
      const lost = SpeakerObserverException(
        SpeakerObserverFailure.helperExited,
      );
      fail(lost);
      return Future.error(lost);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(request.id);
        _diagnostic(
          const SpeakerObserverDiagnostic(
            SpeakerObserverDiagnosticCode.requestTimeout,
          ),
        );
        const timedOut = SpeakerObserverException(
          SpeakerObserverFailure.requestTimeout,
        );
        if (failOnTimeout) {
          fail(timedOut);
        } else {
          _abandoned.add(request.id);
          if (_abandoned.length > 16) _abandoned.remove(_abandoned.first);
        }
        throw timedOut;
      },
    );
  }

  Future<_ReapResult> terminate() => _terminating ??= _terminate();

  /// Completes when the connection failed or began terminating.
  Future<void> get ended => _ended.future;

  Future<_ReapResult> _terminate() async {
    _closing = true;
    _drainTimer?.cancel();
    _drainTimer = null;
    if (!_stdoutDone.isCompleted) _stdoutDone.complete();
    if (!_ended.isCompleted) _ended.complete();
    final cancelled =
        failure ??
        const SpeakerObserverException(SpeakerObserverFailure.cancelled);
    for (final completer in _pending.values) {
      completer.completeError(cancelled);
    }
    _pending.clear();
    if (!_hello.isCompleted) _hello.completeError(cancelled);
    final result = await _reapProcess(_process, _config, _diagnostic);
    unawaited(_frames?.cancel());
    unawaited(_errors?.cancel());
    if (stderrBytes > 0) {
      _diagnostic(
        SpeakerObserverDiagnostic(
          SpeakerObserverDiagnosticCode.helperStderr,
          stderrBytes,
        ),
      );
    }
    return result;
  }
}

final class ProcessMeetingSpeakerObserver implements MeetingSpeakerObserver {
  ProcessMeetingSpeakerObserver(
    this.config, {
    required int Function() clockUs,
    SpeakerHelperLauncher launcher = Process.start,
    void Function(SpeakerObserverDiagnostic)? onDiagnostic,
  }) : _clockUs = clockUs,
       _launcher = launcher,
       _onDiagnostic = onDiagnostic {
    config.validate();
  }
  final SpeakerObserverConfig config;
  final int Function() _clockUs;
  final SpeakerHelperLauncher _launcher;
  final void Function(SpeakerObserverDiagnostic)? _onDiagnostic;
  final StreamController<SpeakerObserverEvent> _events =
      StreamController.broadcast();

  _Phase _phase = _Phase.idle;

  /// The connection being started, run or (for a one-shot) queried.
  _Connection? _conn;
  _Connection? _shot;
  String? _session;

  /// Helper process starts across the observer's whole life: refs are
  /// qualified with it, so no two helpers' refs can ever alias, even across
  /// stop and start with the same session identifier.
  int _epochCounter = 0;
  int _generation = 0, _epoch = 0, _restarts = 0, _requestCounter = 0;
  int _sessionStartUs = 0;
  Timer? _stall, _backoff, _clockTimer;
  Completer<void>? _backoffWake;
  final Set<Completer<void>> _cancelables = {};
  final Set<Timer> _retryTimers = {};
  int _oneShots = 0;
  Future<void>? _startOp, _restartOp, _stopOp, _disposeOp;
  Future<void> _oneShotTail = Future.value();
  final Set<_Orphan> _orphans = {};
  final Stopwatch _liveFor = Stopwatch();
  bool _reapFailed = false, _disposing = false;
  String? _lastUnavailableReason;
  int? _lastUnavailableSince;
  SpeakerObserverStats _stats = const SpeakerObserverStats();

  SpeakerObserverStats get stats => _stats;

  /// Launches currently cancellable, for tests asserting nothing accumulates.
  @visibleForTesting
  int get debugOpenCancelables => _cancelables.length;

  /// Active timers, for tests asserting that nothing outlives the observer.
  @visibleForTesting
  int get debugActiveTimers =>
      (_stall?.isActive == true ? 1 : 0) +
      (_backoff?.isActive == true ? 1 : 0) +
      (_clockTimer?.isActive == true ? 1 : 0) +
      _retryTimers.where((timer) => timer.isActive).length;

  @override
  Stream<SpeakerObserverEvent> get events => _events.stream;

  void _report(SpeakerObserverDiagnostic diagnostic) {
    switch (diagnostic.code) {
      case SpeakerObserverDiagnosticCode.protocolError:
        _count(protocolErrors: 1);
      case SpeakerObserverDiagnosticCode.helperStarted:
        _count(helperStarts: 1);
      case SpeakerObserverDiagnosticCode.implausibleRead:
        _count(implausibleReads: 1);
      default:
        break;
    }
    _onDiagnostic?.call(diagnostic);
  }

  void _diagnostic(SpeakerObserverDiagnosticCode code, [int value = 0]) =>
      _report(SpeakerObserverDiagnostic(code, value));

  void _count({
    int helperStarts = 0,
    int restarts = 0,
    int protocolErrors = 0,
    int stalls = 0,
    int observations = 0,
    int unavailableFrames = 0,
    int implausibleReads = 0,
  }) {
    final s = _stats;
    _stats = SpeakerObserverStats(
      helperStarts: s.helperStarts + helperStarts,
      restarts: s.restarts + restarts,
      protocolErrors: s.protocolErrors + protocolErrors,
      stalls: s.stalls + stalls,
      observations: s.observations + observations,
      unavailableFrames: s.unavailableFrames + unavailableFrames,
      implausibleReads: s.implausibleReads + implausibleReads,
    );
  }

  String _nextId() => 'r${++_requestCounter}';

  // Reaping.

  Future<_ReapResult> _reap(_Connection connection) async {
    final result = await connection.terminate();
    if (!result.reaped) {
      _reapFailed = true;
      _diagnostic(SpeakerObserverDiagnosticCode.reapFailed);
    }
    return result;
  }

  void _adoptOrphan(Future<Process> launch, Stopwatch age) {
    final orphan = _Orphan(launch, age, config, _report);
    _orphans.add(orphan);
    unawaited(
      orphan.reaped
          .then<void>((ok) {
            if (!ok) {
              _reapFailed = true;
              _diagnostic(SpeakerObserverDiagnosticCode.reapFailed);
            }
          })
          .whenComplete(() => _orphans.remove(orphan)),
    );
  }

  /// Stop tracking launches that have outlived two spawn timeouts (the one
  /// that abandoned them and one more wait) without producing a child. They are still drained and reaped in the background if
  /// they ever do (their reap keeps running and reports a failure), but they no
  /// longer make every later call wait for them.
  void _pruneOrphans() {
    _orphans.removeWhere(
      (orphan) =>
          orphan.process == null &&
          orphan.launchAge.elapsed > config.spawnTimeout * 2,
    );
  }

  /// Wait until no abandoned launch has a live child. A launch still pending
  /// after [launchBound] owns nothing yet and is left to the background reaper;
  /// once a child exists its reap is always awaited.
  Future<void> _settleOrphans(Duration launchBound) async {
    _pruneOrphans();
    if (_orphans.isEmpty) return;
    final orphans = _orphans.toList();
    await Future.wait([
      for (final orphan in orphans) orphan.launched,
    ]).timeout(launchBound, onTimeout: () => const []);
    await Future.wait([
      for (final orphan in orphans)
        if (orphan.process != null) orphan.reaped,
    ]);
  }

  void _requireUsable() {
    if (_disposing) throw StateError('Speaker observer is disposed');
    if (_reapFailed) {
      throw const SpeakerObserverException(SpeakerObserverFailure.reapFailed);
    }
  }

  /// Launch and handshake one helper, unless [generation] was cancelled. Any
  /// abandoned launch is settled first, so two helpers are never alive at once.
  Future<_Connection> _open(
    int generation, {
    void Function(_Connection connection)? created,
  }) async {
    final cancel = Completer<void>();
    _cancelables.add(cancel);
    try {
      // Registered first, so a stop cuts the wait for an abandoned launch short.
      await Future.any<void>([
        _settleOrphans(config.spawnTimeout),
        cancel.future,
      ]);
      _requireCurrent(generation);
      return await _Connection.open(
        config,
        _launcher,
        _report,
        cancel: cancel.future,
        onCreated: (connection) {
          connection.epoch = _epochCounter++;
          _epoch = connection.epoch;
          connection
            ..onStream = ((frame) => _onStreamFrame(connection, frame))
            ..onFailure = ((failure) =>
                _onConnectionFailure(connection, failure));
          _conn = connection;
          created?.call(connection);
        },
        reap: _reap,
        orphan: _adoptOrphan,
      );
    } finally {
      _cancelables.remove(cancel);
    }
  }

  // Queries.

  @override
  Future<ObserverCapabilities> inspect() =>
      _query((id) => CapabilitiesRequest(id));

  @override
  Future<ObserverCapabilities> setup() => _query((id) => SetupRequest(id));

  Future<ObserverCapabilities> _query(
    ObserverRequest Function(String id) make,
  ) async {
    _requireUsable();
    final live = _conn;
    if (_phase == _Phase.running && live != null && live.live) {
      // Never let a slow probe kill the recording's observer.
      return _capabilities(live, make, failOnTimeout: false);
    }
    if (_phase != _Phase.idle) {
      throw const SpeakerObserverException(SpeakerObserverFailure.busy);
    }
    final generation = _generation;
    final previous = _oneShotTail;
    final done = Completer<void>();
    _oneShotTail = done.future;
    _oneShots++;
    try {
      await previous;
      _requireUsable();
      // A stop (or start) since this query was queued cancels it.
      _requireCurrent(generation);
      if (_phase != _Phase.idle) {
        throw const SpeakerObserverException(SpeakerObserverFailure.busy);
      }
      _Connection? mine;
      try {
        final connection = await _open(
          generation,
          created: (created) => mine = created,
        );
        _shot = connection;
        try {
          return await _capabilities(connection, make);
        } finally {
          await _reap(connection);
        }
      } finally {
        final own = mine;
        if (own != null) {
          if (identical(_shot, own)) _shot = null;
          if (identical(_conn, own)) _conn = null;
        }
        if (_reapFailed) {
          // ignore: control_flow_in_finally
          throw const SpeakerObserverException(
            SpeakerObserverFailure.reapFailed,
          );
        }
      }
    } finally {
      _oneShots--;
      done.complete();
    }
  }

  /// The helper's request queue was full (`error` / `busy`): nothing changed
  /// and the request may simply be sent again, so it is, a few times, with a
  /// fresh identifier. The wait ends early if the connection does.
  Future<ObserverFrame> _request(
    _Connection connection,
    ObserverRequest Function(String id) make, {
    bool failOnTimeout = true,
    void Function()? beforeAttempt,
  }) async {
    for (var attempt = 0; ; attempt++) {
      beforeAttempt?.call();
      final reply = await connection.request(
        make(_nextId()),
        config.requestTimeout,
        failOnTimeout: failOnTimeout,
      );
      if (reply is! ErrorFrame || reply.code != 'busy' || attempt >= 3) {
        return reply;
      }
      _diagnostic(SpeakerObserverDiagnosticCode.busyRetried, attempt + 1);
      final wake = Completer<void>();
      final timer = Timer(config.backoffInitial, () {
        if (!wake.isCompleted) wake.complete();
      });
      _retryTimers.add(timer);
      unawaited(
        connection.ended.then<void>((_) {
          if (!wake.isCompleted) wake.complete();
        }),
      );
      await wake.future;
      timer.cancel();
      _retryTimers.remove(timer);
    }
  }

  Future<ObserverCapabilities> _capabilities(
    _Connection connection,
    ObserverRequest Function(String id) make, {
    bool failOnTimeout = true,
  }) async {
    final reply = _expect<CapabilitiesFrame>(
      connection,
      await _request(connection, make, failOnTimeout: failOnTimeout),
    );
    final hello = connection.hello;
    return ObserverCapabilities(
      state: reply.state,
      reason: reply.reason,
      zoomVersion: reply.zoomVersion,
      locale: reply.locale,
      helper: hello?.helper,
      helperVersion: hello?.helperVersion,
      parserVersion: hello?.parserVersion,
      platform: hello?.platform,
    );
  }

  T _expect<T extends ObserverFrame>(
    _Connection connection,
    ObserverFrame frame,
  ) {
    if (frame is T) return frame;
    if (frame is ErrorFrame) {
      _diagnostic(SpeakerObserverDiagnosticCode.helperError);
      throw SpeakerObserverException(
        SpeakerObserverFailure.helperError,
        helperCode: frame.code,
      );
    }
    connection.protocolFailure();
    throw const SpeakerObserverException(SpeakerObserverFailure.protocolError);
  }

  // Session lifecycle.

  @override
  Future<void> start(String session) async {
    _requireUsable();
    if (_phase != _Phase.idle) {
      throw const SpeakerObserverException(SpeakerObserverFailure.busy);
    }
    try {
      // Validates the identifier exactly as the wire encoder will.
      ObserverFrameEncoder().encode(
        StartRequest(
          id: 'check',
          session: session,
          pollMs: config.pollMs,
          deadlineMs: config.readDeadlineMs,
        ),
      );
    } on ArgumentError {
      throw const SpeakerObserverException(
        SpeakerObserverFailure.invalidArgument,
      );
    }
    _phase = _Phase.starting;
    _session = session;
    _restarts = 0;
    _lastUnavailableReason = null;
    _lastUnavailableSince = null;
    _sessionStartUs = _clockUs();
    final generation = ++_generation;
    final operation = _runStart(session, generation);
    _startOp = operation;
    await operation;
  }

  /// The whole start sequence, including cleanup after a failure or a stop that
  /// raced it, so that awaiting this future means no helper is left behind.
  Future<void> _runStart(String session, int generation) async {
    try {
      await _oneShotTail;
      _requireCurrent(generation);
      final connection = await _launchAndStart(session, generation);
      if (generation != _generation) {
        await _reap(connection);
        _forget(connection);
        throw const SpeakerObserverException(SpeakerObserverFailure.cancelled);
      }
      _goLive(connection);
    } on Object {
      if (generation == _generation) _resetToIdle();
      rethrow;
    }
  }

  void _requireCurrent(int generation) {
    if (generation != _generation) {
      throw const SpeakerObserverException(SpeakerObserverFailure.cancelled);
    }
  }

  void _forget(_Connection connection) {
    if (identical(_conn, connection)) _conn = null;
  }

  /// Stop watching the live helper: stall detection and clock rechecks.
  void _disarm() {
    _stall?.cancel();
    _clockTimer?.cancel();
  }

  void _armClockRecheck(_Connection connection) {
    _clockTimer?.cancel();
    final every = config.clockRecheck;
    if (every == null) return;
    _clockTimer = Timer(every, () {
      unawaited(_recheckClock(connection));
    });
  }

  void _goLive(_Connection connection) {
    _conn = connection;
    connection.live = true;
    _phase = _Phase.running;
    _lastUnavailableReason = null;
    _lastUnavailableSince = null;
    _liveFor
      ..reset()
      ..start();
    _emitState(ObserverStatus.running);
    _armStall(connection);
    _armClockRecheck(connection);
    // The helper may have failed between its start reply and now.
    final early = connection.failure;
    if (early != null) _onConnectionFailure(connection, early);
  }

  void _resetToIdle() {
    _phase = _Phase.idle;
    _conn = null;
    _session = null;
    _startOp = null;
    _disarm();
  }

  /// Spawn, handshake, measure the clock and start observing. On any failure the
  /// child is terminated and reaped before the error propagates.
  Future<_Connection> _launchAndStart(String session, int generation) async {
    final connection = await _open(generation);
    try {
      _requireCurrent(generation);
      connection.clock = await _measureClock(connection);
      connection.clockVerifiedUs = connection.lastGoodEndUs = _clockUs();
      _requireCurrent(generation);
      final reply = await _request(
        connection,
        (id) => StartRequest(
          id: id,
          session: session,
          pollMs: config.pollMs,
          deadlineMs: config.readDeadlineMs,
        ),
      );
      _requireCurrent(generation);
      if (reply is CapabilitiesFrame) {
        if (reply.state == ObserverAvailability.available) {
          // "Available" answers a capabilities request, not a start.
          connection.protocolFailure();
          throw const SpeakerObserverException(
            SpeakerObserverFailure.protocolError,
          );
        }
        // The helper cannot observe the meeting.
        throw SpeakerObserverException(
          SpeakerObserverFailure.unavailable,
          availability: reply.state,
        );
      }
      final started = _expect<StartedFrame>(connection, reply);
      if (started.session != session) {
        connection.protocolFailure();
        throw const SpeakerObserverException(
          SpeakerObserverFailure.protocolError,
        );
      }
      _requireCurrent(generation);
      return connection;
    } on Object {
      await _reap(connection);
      _forget(connection);
      rethrow;
    }
  }

  Future<_ClockFix> _measureClock(
    _Connection connection, {
    bool failOnTimeout = true,
  }) async {
    _ClockFix? best;
    var bestRtt = 0;
    for (var i = 0; i < config.clockProbes; i++) {
      var before = 0;
      final reply = _expect<ClockFrame>(
        connection,
        await _request(
          connection,
          (id) => ClockRequest(id),
          // Anchor the round trip to the attempt that was answered.
          beforeAttempt: () => before = _clockUs(),
          failOnTimeout: failOnTimeout,
        ),
      );
      final after = _clockUs();
      if (after < before) {
        // The observer's own clock went backward: this probe proves nothing.
        _diagnostic(SpeakerObserverDiagnosticCode.clockRejected);
        continue;
      }
      final rtt = after - before;
      if (best == null || rtt < bestRtt) {
        bestRtt = rtt;
        best = (
          offsetUs: before + rtt ~/ 2 - reply.monotonicUs,
          // Helper times are whole milliseconds.
          uncertaintyUs: rtt ~/ 2 + 1000,
        );
      }
    }
    if (best == null) {
      throw const SpeakerObserverException(
        SpeakerObserverFailure.clockUnavailable,
      );
    }
    _diagnostic(SpeakerObserverDiagnosticCode.clockMeasured, bestRtt);
    return best;
  }

  /// Measure the helper clock again while the session runs. Reads timed with
  /// an offset that proved wrong are retracted from the last confirmation on;
  /// otherwise the offset is simply confirmed. Returns whether it had shifted.
  ///
  /// [goodUntilUs], when known, is the last time the old offset was seen to be
  /// right (the end of the last read that was not ahead of the capture clock);
  /// only reads after it are retracted.
  Future<bool> _recheckClock(_Connection connection, {int? goodUntilUs}) async {
    bool current() =>
        identical(connection, _conn) &&
        connection.live &&
        connection.failure == null &&
        _phase == _Phase.running;
    if (!current() || connection.rechecking) return false;
    connection.rechecking = true;
    try {
      final fix = await _measureClock(connection, failOnTimeout: false);
      if (!current()) return false;
      final previous = connection.clock;
      final limit =
          previous.uncertaintyUs +
          fix.uncertaintyUs +
          config.clockJumpTolerance.inMicroseconds;
      final shift = fix.offsetUs - previous.offsetUs;
      final since = goodUntilUs == null
          ? connection.clockVerifiedUs
          : math.max(connection.clockVerifiedUs, goodUntilUs);
      connection.clockVerifiedUs = _clockUs();
      if (shift.abs() <= limit) return false;
      _diagnostic(
        SpeakerObserverDiagnosticCode.clockShifted,
        shift.abs() ~/ 1000,
      );
      connection.clock = fix;
      connection.lastGoodEndUs = connection.clockVerifiedUs;
      _emit(
        UnavailableEvent(
          connection.epoch,
          sinceUs: since,
          reason: 'clock_shift',
          retractsReads: true,
        ),
      );
      return true;
    } on SpeakerObserverException catch (error) {
      if (error.failure == SpeakerObserverFailure.requestTimeout) {
        _stalled(connection);
      }
      return false;
    } finally {
      connection.rechecking = false;
      if (current()) _armClockRecheck(connection);
    }
  }

  void _emit(SpeakerObserverEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _emitState(
    ObserverStatus status, {
    SpeakerObserverFailure? failure,
    ObserverAvailability? availability,
    String? helperCode,
  }) => _emit(
    ObserverStateEvent(
      _epoch,
      status: status,
      atUs: _clockUs(),
      restartCount: _restarts,
      failure: failure,
      availability: availability,
      helperCode: helperCode,
    ),
  );

  void _onStreamFrame(_Connection connection, ObserverFrame frame) {
    switch (frame) {
      case ObservationFrame(:final observation):
        if (observation.session != _session) {
          return connection.protocolFailure();
        }
        final shifted = _qualified(observation, connection.epoch).shifted(
          connection.clock.offsetUs,
          extraUncertaintyUs: connection.clock.uncertaintyUs,
        );
        if (!_plausible(shifted.readStartUs, shifted.readEndUs) ||
            observation.readEndUs - observation.readStartUs >
                (config.readDeadlineMs + config.readSkew.inMilliseconds) *
                    1000) {
          return _implausible(connection);
        }
        _checkAhead(connection, shifted.readEndUs);
        _lastUnavailableReason = null;
        connection.quiet = false;
        _count(observations: 1);
        _emit(ObservationEvent(connection.epoch, shifted));
      case UnavailableFrame():
        if (frame.session != _session) return connection.protocolFailure();
        final since =
            frame.sinceUs +
            connection.clock.offsetUs -
            connection.clock.uncertaintyUs;
        if (!_plausible(since, since)) return _implausible(connection);
        connection.quiet = true;
        _count(unavailableFrames: 1);
        // A helper repeats the same unavailability every poll as a heartbeat.
        if (frame.reason != _lastUnavailableReason ||
            frame.sinceUs != _lastUnavailableSince) {
          _lastUnavailableReason = frame.reason;
          _lastUnavailableSince = frame.sinceUs;
          _emit(
            UnavailableEvent(
              connection.epoch,
              sinceUs: since,
              reason: frame.reason,
            ),
          );
        }
      default:
        return;
    }
    // Frames still arrive while a stop is under way; they must not re-arm a
    // timer that stop has just disarmed.
    if (_phase == _Phase.running) _armStall(connection);
  }

  /// A time on the capture clock that the helper could not have observed: well
  /// in the observer's future, or before the session began.
  bool _plausible(int startUs, int endUs) {
    final skew = config.readSkew.inMicroseconds;
    return endUs <= _clockUs() + skew && startUs >= _sessionStartUs - skew;
  }

  /// A read cannot end after the moment its frame arrives. One that does by
  /// more than the clock's own tolerance means the offset moved (system sleep),
  /// so it is measured again; the read is kept, and retracted if it was wrong.
  void _checkAhead(_Connection connection, int readEndUs) {
    final slack =
        connection.clock.uncertaintyUs +
        config.clockJumpTolerance.inMicroseconds;
    if (readEndUs > _clockUs() + slack) {
      unawaited(
        _recheckClock(connection, goodUntilUs: connection.lastGoodEndUs),
      );
    } else if (!connection.rechecking) {
      connection.lastGoodEndUs = math.max(connection.lastGoodEndUs, readEndUs);
    }
  }

  /// A read the helper could not have made. Before blaming the helper its
  /// clock offset is measured again: a shifted offset (system sleep) explains
  /// the read, which is dropped, and the next ones are timed correctly. With
  /// the offset unchanged the read is the helper's fault. Reads that arrive
  /// while the measurement runs are dropped.
  void _implausible(_Connection connection) {
    _diagnostic(SpeakerObserverDiagnosticCode.implausibleRead);
    if (connection.rechecking) return;
    unawaited(
      _recheckClock(connection).then<void>((shifted) {
        if (!shifted && connection.live && connection.failure == null) {
          connection.protocolFailure();
        }
      }),
    );
  }

  static SpeakerObservation _qualified(SpeakerObservation o, int epoch) {
    String ref(String raw) => '$epoch:$raw';
    return SpeakerObservation(
      session: o.session,
      readStartUs: o.readStartUs,
      readEndUs: o.readEndUs,
      target: o.target,
      complete: o.complete,
      parserVersion: o.parserVersion,
      participants: [
        for (final p in o.participants)
          ObservedParticipant(ref: ref(p.ref), name: p.name, isSelf: p.isSelf),
      ],
      speakers: [
        for (final s in o.speakers)
          SpeakerCandidate(ref: ref(s.ref), method: s.method),
      ],
    );
  }

  void _armStall(_Connection connection) {
    _stall?.cancel();
    _stall = Timer(config.stallTimeout, () {
      if (connection.quiet) {
        unawaited(_probe(connection));
        return;
      }
      _stalled(connection);
    });
  }

  void _stalled(_Connection connection) {
    _diagnostic(SpeakerObserverDiagnosticCode.stalled);
    _count(stalls: 1);
    connection.fail(
      const SpeakerObserverException(SpeakerObserverFailure.stalled),
    );
  }

  /// While the helper reports `unavailable` it sends nothing until that
  /// changes, so a hung polling thread would look like a quiet one. A
  /// capabilities request is answered by the polling thread between reads: an
  /// answer, even a refusal, proves it is alive; none within the request
  /// timeout is a stall.
  Future<void> _probe(_Connection connection) async {
    try {
      await connection.request(
        CapabilitiesRequest(_nextId()),
        config.requestTimeout,
        failOnTimeout: false,
      );
    } on SpeakerObserverException catch (error) {
      if (error.failure == SpeakerObserverFailure.requestTimeout) {
        _stalled(connection);
      }
      return;
    }
    if (identical(connection, _conn) &&
        connection.live &&
        _phase == _Phase.running &&
        connection.failure == null) {
      _armStall(connection);
    }
  }

  // Restarts.

  void _onConnectionFailure(
    _Connection connection,
    SpeakerObserverException failure,
  ) {
    if (!identical(connection, _conn) ||
        !connection.live ||
        _phase != _Phase.running) {
      return;
    }
    _phase = _Phase.restarting;
    _disarm();
    final refill = config.restartRefillAfter;
    if (refill != null && _restarts > 0 && _liveFor.elapsed >= refill) {
      // The helper ran healthily for long enough: isolated crashes hours
      // apart must not add up to a permanent failure.
      _diagnostic(SpeakerObserverDiagnosticCode.restartRefilled, _restarts);
      _restarts = 0;
    }
    _restartOp = _restart(connection, failure, _generation).then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _diagnostic(SpeakerObserverDiagnosticCode.internalError);
        _phase = _Phase.failed;
        _emitState(
          ObserverStatus.failed,
          failure: SpeakerObserverFailure.internalError,
        );
      },
    );
  }

  /// Helper answers that more attempts cannot change: setup, permission and
  /// version problems. `zoomNotRunning`, `noMeeting` and plain `unavailable`
  /// are transient (the meeting window may reappear) and retried within the
  /// restart budget.
  static bool _terminal(SpeakerObserverException error) =>
      error.failure == SpeakerObserverFailure.reapFailed ||
      (error.failure == SpeakerObserverFailure.unavailable &&
          switch (error.availability) {
            ObserverAvailability.zoomNotRunning ||
            ObserverAvailability.noMeeting ||
            ObserverAvailability.unavailable => false,
            _ => true,
          });

  void _terminalFailure(SpeakerObserverException error) {
    _phase = _Phase.failed;
    _emitState(
      ObserverStatus.failed,
      failure: error.failure,
      availability: error.availability,
      helperCode: error.helperCode,
    );
  }

  Future<void> _restart(
    _Connection failed,
    SpeakerObserverException cause,
    int generation,
  ) async {
    _conn = null;
    await _reap(failed);
    if (generation != _generation) return;
    if (_reapFailed) {
      return _terminalFailure(
        const SpeakerObserverException(SpeakerObserverFailure.reapFailed),
      );
    }
    _emitState(
      ObserverStatus.restarting,
      failure: cause.failure,
      availability: cause.availability,
      helperCode: cause.helperCode,
    );
    var latest = cause;
    while (generation == _generation) {
      if (_reapFailed) {
        return _terminalFailure(
          const SpeakerObserverException(SpeakerObserverFailure.reapFailed),
        );
      }
      if (_restarts >= config.maxRestarts) {
        _diagnostic(SpeakerObserverDiagnosticCode.restartsExhausted, _restarts);
        return _terminalFailure(latest);
      }
      final attempt = ++_restarts;
      _count(restarts: 1);
      final delay = _backoffFor(attempt);
      _diagnostic(
        SpeakerObserverDiagnosticCode.restartScheduled,
        delay.inMilliseconds,
      );
      if (!await _sleep(delay, generation)) return;
      try {
        final connection = await _launchAndStart(_session!, generation);
        if (generation != _generation) {
          await _reap(connection);
          _forget(connection);
          return;
        }
        _goLive(connection);
        return;
      } on SpeakerObserverException catch (error) {
        if (generation != _generation ||
            error.failure == SpeakerObserverFailure.cancelled) {
          return;
        }
        latest = error;
        if (_terminal(error)) return _terminalFailure(error);
      } on Object {
        _diagnostic(SpeakerObserverDiagnosticCode.internalError);
        return _terminalFailure(
          const SpeakerObserverException(SpeakerObserverFailure.internalError),
        );
      }
    }
  }

  Duration _backoffFor(int attempt) {
    final scaled =
        config.backoffInitial.inMicroseconds * (1 << math.min(attempt - 1, 20));
    return Duration(
      microseconds: math.min(scaled, config.backoffMax.inMicroseconds),
    );
  }

  /// Cancelable delay; false when the session was stopped meanwhile.
  Future<bool> _sleep(Duration delay, int generation) {
    final wake = Completer<void>();
    _backoffWake = wake;
    _backoff = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.then((_) => generation == _generation);
  }

  // Shutdown.

  @override
  Future<void> stop() => _stopOp ??= _stop().whenComplete(() => _stopOp = null);

  Future<void> _stop() async {
    _pruneOrphans();
    if (_phase == _Phase.idle &&
        _startOp == null &&
        _shot == null &&
        _oneShots == 0 &&
        _orphans.isEmpty &&
        _conn == null) {
      if (_reapFailed) {
        throw const SpeakerObserverException(SpeakerObserverFailure.reapFailed);
      }
      return;
    }
    final session = _session;
    _generation++;
    _phase = _Phase.stopping;
    _disarm();
    _backoff?.cancel();
    final wake = _backoffWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    for (final cancel in _cancelables.toList()) {
      if (!cancel.isCompleted) cancel.complete();
    }
    // Cancel work that has not produced a running session yet.
    final pending = _conn;
    if (pending != null && !pending.live) {
      pending.fail(
        const SpeakerObserverException(SpeakerObserverFailure.cancelled),
      );
    }
    _shot?.fail(
      const SpeakerObserverException(SpeakerObserverFailure.cancelled),
    );
    final start = _startOp;
    if (start != null) await start.then<void>((_) {}, onError: (Object _) {});
    final restart = _restartOp;
    if (restart != null) await restart;
    _restartOp = null;
    await _oneShotTail;
    // A launch still pending after one kill grace owns nothing yet and is left
    // to the background reaper (the next stop or dispose waits for it again);
    // a child that exists is always reaped before stop returns.
    await _settleOrphans(config.killGrace);
    final connection = _conn;
    _conn = null;
    SpeakerObserverFailure? unclean;
    if (connection != null) {
      if (connection.live && connection.failure == null) {
        try {
          final reply = await connection.request(
            StopRequest(_nextId()),
            config.exitGrace,
          );
          if (reply is ErrorFrame && reply.code == 'busy') {
            _diagnostic(SpeakerObserverDiagnosticCode.stopRefusedBusy);
          }
          // Stop is only sent after an accepted start, so the helper must echo
          // that session: a null session answers a stop that precedes a start.
          if (reply is! StoppedFrame || reply.session != session) {
            unclean = reply is ErrorFrame
                ? SpeakerObserverFailure.helperError
                : SpeakerObserverFailure.protocolError;
          }
        } on SpeakerObserverException catch (error) {
          unclean = error.failure == SpeakerObserverFailure.requestTimeout
              ? SpeakerObserverFailure.shutdownTimeout
              : error.failure;
        }
      } else {
        unclean = connection.failure?.failure;
      }
      final result = await _reap(connection);
      if (result.termSent || result.killSent) {
        unclean ??= SpeakerObserverFailure.shutdownTimeout;
      } else if (result.reaped && result.status != 0) {
        unclean ??= SpeakerObserverFailure.helperExited;
      }
    }
    _emitState(ObserverStatus.stopped, failure: unclean);
    _resetToIdle();
    if (_reapFailed) {
      throw const SpeakerObserverException(SpeakerObserverFailure.reapFailed);
    }
  }

  @override
  Future<void> dispose() => _disposeOp ??= _dispose();

  Future<void> _dispose() async {
    _disposing = true;
    try {
      await stop();
    } finally {
      await _events.close();
    }
  }
}

enum _Phase { idle, starting, running, restarting, stopping, failed }
