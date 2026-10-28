/// Process-supervised [MeetingSpeakerObserver]. Owns one helper child at a time,
/// reads it through bounded NDJSON, and terminates and reaps only the child it
/// started. Nothing here blocks the event loop: every wait is an awaited future
/// or timer. Diagnostics carry codes and counters only, never helper text,
/// participant names or transcript text.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'meeting_speaker_observer.dart';
import 'speaker_observation.dart';
import 'speaker_observer_protocol.dart';

typedef SpeakerHelperLauncher =
    Future<Process> Function(String executable, List<String> arguments);

enum SpeakerObserverDiagnosticCode {
  helperStarted,
  helperExited,
  protocolError,
  helperError,
  requestTimeout,
  stalled,
  restartScheduled,
  restartsExhausted,
  reapFailed,
  stderrFlood,
  clockMeasured,
}

/// A stage and a number (exit status, attempt, delay or error code index).
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
    this.exitGrace = const Duration(seconds: 1),
    this.termGrace = const Duration(milliseconds: 500),
    this.killGrace = const Duration(seconds: 2),
    this.maxRestarts = 5,
    this.backoffInitial = const Duration(milliseconds: 250),
    this.backoffMax = const Duration(seconds: 5),
    this.clockProbes = 3,
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
  final Duration exitGrace, termGrace, killGrace;
  final int maxRestarts;
  final Duration backoffInitial, backoffMax;

  /// Clock exchanges used to measure the helper-to-capture clock offset.
  final int clockProbes;
  final int maxStderrBytes, maxLineBytes;

  Duration get stallTimeout =>
      Duration(milliseconds: pollMs + readDeadlineMs) + stallSlack;

  void validate() {
    if (executable.isEmpty ||
        pollMs < 50 ||
        pollMs > 60000 ||
        readDeadlineMs < 1 ||
        readDeadlineMs > 600000 ||
        maxRestarts < 0 ||
        clockProbes < 0 ||
        maxStderrBytes < 0 ||
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
        stallSlack < Duration.zero) {
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
  });
  final int helperStarts,
      restarts,
      protocolErrors,
      stalls,
      observations,
      unavailableFrames;
}

typedef _ClockFix = ({int offsetUs, int uncertaintyUs});

/// One helper process: framing, request correlation and reaping.
final class _Connection {
  _Connection._(this._process, this._config, this._diagnostic);
  final Process _process;
  final SpeakerObserverConfig _config;
  final void Function(SpeakerObserverDiagnostic) _diagnostic;
  final ObserverFrameEncoder _encoder = ObserverFrameEncoder();
  final Map<String, Completer<ObserverFrame>> _pending = {};
  final Completer<HelloFrame> _hello = Completer();
  StreamSubscription<ObserverFrame>? _frames;
  StreamSubscription<List<int>>? _errors;
  Future<bool>? _terminating;
  bool _closing = false, _exited = false, _helloSeen = false;
  int stderrBytes = 0;

  /// Set by the owner.
  void Function(ObserverFrame frame)? onStream;
  void Function(SpeakerObserverException failure)? onFailure;
  SpeakerObserverException? failure;
  HelloFrame? hello;
  bool started = false, live = false;
  int epoch = 0;
  _ClockFix clock = (offsetUs: 0, uncertaintyUs: 0);

  static Future<_Connection> open(
    SpeakerObserverConfig config,
    SpeakerHelperLauncher launcher,
    void Function(SpeakerObserverDiagnostic) diagnostic,
  ) async {
    final Future<Process> launch;
    try {
      launch = launcher(config.executable, [
        ...config.arguments,
        '--protocol',
        '$speakerObserverProtocolVersion',
      ]);
    } on Object {
      throw const SpeakerObserverException(SpeakerObserverFailure.launchFailed);
    }
    final Process process;
    try {
      process = await launch.timeout(config.spawnTimeout);
    } on Object {
      // A late launch must not leak an unowned child.
      unawaited(
        launch.then<void>((late) {
          late.kill(ProcessSignal.sigkill);
        }, onError: (Object _, StackTrace _) {}),
      );
      throw const SpeakerObserverException(SpeakerObserverFailure.launchFailed);
    }
    final connection = _Connection._(process, config, diagnostic);
    connection._attach();
    diagnostic(
      const SpeakerObserverDiagnostic(
        SpeakerObserverDiagnosticCode.helperStarted,
      ),
    );
    try {
      connection.hello = await connection._hello.future.timeout(
        config.handshakeTimeout,
        onTimeout: () {
          final timeout = const SpeakerObserverException(
            SpeakerObserverFailure.handshakeTimeout,
          );
          connection.fail(timeout);
          throw timeout;
        },
      );
    } on SpeakerObserverException {
      await connection.terminate();
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
            if (error is ObserverProtocolException) {
              _diagnostic(
                SpeakerObserverDiagnostic(
                  SpeakerObserverDiagnosticCode.protocolError,
                  error.code.index,
                ),
              );
            }
            fail(
              const SpeakerObserverException(
                SpeakerObserverFailure.protocolError,
              ),
            );
          },
          onDone: () {
            // Stdout closing without an orderly stop means the helper went away.
            if (!_closing && !_exited) {
              fail(
                const SpeakerObserverException(
                  SpeakerObserverFailure.helperExited,
                ),
              );
            }
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
      _process.exitCode.then<void>((status) {
        _exited = true;
        _diagnostic(
          SpeakerObserverDiagnostic(
            SpeakerObserverDiagnosticCode.helperExited,
            status,
          ),
        );
        if (!_closing) {
          fail(
            const SpeakerObserverException(SpeakerObserverFailure.helperExited),
          );
        }
      }),
    );
  }

  void _onFrame(ObserverFrame frame) {
    if (_closing || failure != null) return;
    if (frame is HelloFrame) {
      if (_helloSeen ||
          (frame.platform != 'macos' && frame.platform != 'linux')) {
        return _protocolFailure();
      }
      _helloSeen = true;
      _hello.complete(frame);
      return;
    }
    if (!_helloSeen) return _protocolFailure();
    switch (frame) {
      case CapabilitiesFrame(:final id):
      case ClockFrame(:final id):
      case StoppedFrame(:final id):
        _reply(id, frame);
      case StartedFrame(:final id):
        started = true;
        _reply(id, frame);
      case ErrorFrame(:final id):
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
        if (!started) return _protocolFailure();
        onStream?.call(frame);
      case HelloFrame():
        break;
    }
  }

  void _reply(String id, ObserverFrame frame) {
    final completer = _pending.remove(id);
    if (completer == null) return _protocolFailure();
    completer.complete(frame);
  }

  void _protocolFailure() {
    _diagnostic(
      SpeakerObserverDiagnostic(
        SpeakerObserverDiagnosticCode.protocolError,
        ObserverProtocolErrorCode.malformed.index,
      ),
    );
    fail(const SpeakerObserverException(SpeakerObserverFailure.protocolError));
  }

  /// Record the first failure, release every waiter and tell the owner once.
  void fail(SpeakerObserverException exception) {
    if (failure != null || _closing) return;
    failure = exception;
    for (final completer in _pending.values) {
      completer.completeError(exception);
    }
    _pending.clear();
    if (!_hello.isCompleted) _hello.completeError(exception);
    onFailure?.call(exception);
  }

  Future<ObserverFrame> request(ObserverRequest request, Duration timeout) {
    final existing = failure;
    if (existing != null) return Future.error(existing);
    if (_closing || _exited) {
      return Future.error(
        const SpeakerObserverException(SpeakerObserverFailure.helperExited),
      );
    }
    final completer = Completer<ObserverFrame>();
    _pending[request.id] = completer;
    try {
      _process.stdin.add(_encoder.encode(request));
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
        fail(timedOut);
        throw timedOut;
      },
    );
  }

  /// Close stdin, then escalate TERM and KILL, each bounded. Only this child is
  /// signalled. Completes true once the exit status is observed.
  Future<bool> terminate() => _terminating ??= _terminate();

  Future<bool> _terminate() async {
    _closing = true;
    final cancelled =
        failure ??
        const SpeakerObserverException(SpeakerObserverFailure.cancelled);
    for (final completer in _pending.values) {
      completer.completeError(cancelled);
    }
    _pending.clear();
    if (!_hello.isCompleted) _hello.completeError(cancelled);
    unawaited(
      _process.stdin.close().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    var reaped = await _waitExit(_config.exitGrace);
    if (!reaped) {
      _process.kill();
      reaped = await _waitExit(_config.termGrace);
    }
    if (!reaped) {
      _process.kill(ProcessSignal.sigkill);
      reaped = await _waitExit(_config.killGrace);
    }
    unawaited(_frames?.cancel());
    unawaited(_errors?.cancel());
    return reaped;
  }

  Future<bool> _waitExit(Duration limit) => _process.exitCode
      .then((_) => true)
      .timeout(limit, onTimeout: () => false);
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
  _Connection? _conn;
  String? _session;
  int _generation = 0, _epoch = 0, _restarts = 0, _requestCounter = 0;
  Timer? _stall, _backoff;
  Completer<void>? _backoffWake;
  Future<void>? _startOp, _restartOp, _stopOp;
  Future<void> _oneShotTail = Future.value();
  bool _reapFailed = false, _disposed = false;
  String? _lastUnavailableReason;
  int? _lastUnavailableSince;
  SpeakerObserverStats _stats = const SpeakerObserverStats();

  SpeakerObserverStats get stats => _stats;

  @override
  Stream<SpeakerObserverEvent> get events => _events.stream;

  void _diagnostic(SpeakerObserverDiagnosticCode code, [int value = 0]) =>
      _onDiagnostic?.call(SpeakerObserverDiagnostic(code, value));

  void _count({
    int helperStarts = 0,
    int restarts = 0,
    int protocolErrors = 0,
    int stalls = 0,
    int observations = 0,
    int unavailableFrames = 0,
  }) {
    final s = _stats;
    _stats = SpeakerObserverStats(
      helperStarts: s.helperStarts + helperStarts,
      restarts: s.restarts + restarts,
      protocolErrors: s.protocolErrors + protocolErrors,
      stalls: s.stalls + stalls,
      observations: s.observations + observations,
      unavailableFrames: s.unavailableFrames + unavailableFrames,
    );
  }

  void Function(SpeakerObserverDiagnostic) get _connectionDiagnostic =>
      (diagnostic) {
        if (diagnostic.code == SpeakerObserverDiagnosticCode.protocolError) {
          _count(protocolErrors: 1);
        }
        if (diagnostic.code == SpeakerObserverDiagnosticCode.helperStarted) {
          _count(helperStarts: 1);
        }
        _onDiagnostic?.call(diagnostic);
      };

  String _nextId() => 'r${++_requestCounter}';

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
    if (_phase == _Phase.running && live != null) {
      return _capabilities(live, make(_nextId()));
    }
    if (_phase != _Phase.idle) {
      throw const SpeakerObserverException(SpeakerObserverFailure.busy);
    }
    // One short-lived helper per query, serialized.
    final previous = _oneShotTail;
    final done = Completer<void>();
    _oneShotTail = done.future;
    try {
      await previous;
      _requireUsable();
      if (_phase != _Phase.idle) {
        throw const SpeakerObserverException(SpeakerObserverFailure.busy);
      }
      final connection = await _Connection.open(
        config,
        _launcher,
        _connectionDiagnostic,
      );
      try {
        return await _capabilities(connection, make(_nextId()));
      } finally {
        await _reap(connection);
      }
    } finally {
      done.complete();
    }
  }

  Future<ObserverCapabilities> _capabilities(
    _Connection connection,
    ObserverRequest request,
  ) async {
    final reply = _expect<CapabilitiesFrame>(
      await connection.request(request, config.requestTimeout),
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

  T _expect<T extends ObserverFrame>(ObserverFrame frame) {
    if (frame is T) return frame;
    if (frame is ErrorFrame) {
      _diagnostic(SpeakerObserverDiagnosticCode.helperError);
      throw SpeakerObserverException(
        SpeakerObserverFailure.helperError,
        helperCode: frame.code,
      );
    }
    throw const SpeakerObserverException(SpeakerObserverFailure.protocolError);
  }

  Future<void> _reap(_Connection connection) async {
    if (await connection.terminate()) return;
    _reapFailed = true;
    _diagnostic(SpeakerObserverDiagnosticCode.reapFailed);
    throw const SpeakerObserverException(SpeakerObserverFailure.reapFailed);
  }

  void _requireUsable() {
    if (_disposed) throw StateError('Speaker observer is disposed');
    if (_reapFailed) {
      throw const SpeakerObserverException(SpeakerObserverFailure.reapFailed);
    }
  }

  // Session lifecycle.

  @override
  Future<void> start(String session) async {
    _requireUsable();
    if (_phase != _Phase.idle) {
      throw const SpeakerObserverException(SpeakerObserverFailure.busy);
    }
    // Validates the identifier exactly as the wire encoder will.
    ObserverFrameEncoder().encode(
      StartRequest(
        id: 'check',
        session: session,
        pollMs: config.pollMs,
        deadlineMs: config.readDeadlineMs,
      ),
    );
    _phase = _Phase.starting;
    _session = session;
    _epoch = 0;
    _restarts = 0;
    _lastUnavailableReason = null;
    final generation = ++_generation;
    final operation = _launchAndStart(session, 0);
    _startOp = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final _Connection connection;
    try {
      connection = await operation;
    } on Object {
      if (generation == _generation) _resetToIdle();
      rethrow;
    }
    if (generation != _generation) {
      await _reap(connection);
      throw const SpeakerObserverException(SpeakerObserverFailure.cancelled);
    }
    _goLive(connection);
  }

  void _goLive(_Connection connection) {
    _conn = connection;
    connection.live = true;
    _phase = _Phase.running;
    _lastUnavailableReason = null;
    _lastUnavailableSince = null;
    _emitState(ObserverStatus.running);
    _armStall(connection);
    // The helper may have failed between its start reply and now.
    final early = connection.failure;
    if (early != null) _onConnectionFailure(connection, early);
  }

  void _resetToIdle() {
    _phase = _Phase.idle;
    _conn = null;
    _session = null;
    _startOp = null;
    _stall?.cancel();
  }

  /// Spawn, handshake, measure the clock and start observing. On any failure the
  /// child is terminated and reaped before the error propagates.
  Future<_Connection> _launchAndStart(String session, int epoch) async {
    final connection = await _Connection.open(
      config,
      _launcher,
      _connectionDiagnostic,
    );
    connection
      ..epoch = epoch
      ..onStream = ((frame) => _onStreamFrame(connection, frame))
      ..onFailure = ((failure) => _onConnectionFailure(connection, failure));
    try {
      connection.clock = await _measureClock(connection);
      final reply = await connection.request(
        StartRequest(
          id: _nextId(),
          session: session,
          pollMs: config.pollMs,
          deadlineMs: config.readDeadlineMs,
        ),
        config.requestTimeout,
      );
      if (reply is CapabilitiesFrame) {
        // The helper cannot observe the meeting: not a transient failure.
        throw SpeakerObserverException(
          SpeakerObserverFailure.unavailable,
          availability: reply.state,
        );
      }
      final started = _expect<StartedFrame>(reply);
      if (started.session != session) {
        throw const SpeakerObserverException(
          SpeakerObserverFailure.protocolError,
        );
      }
      return connection;
    } on Object {
      await _reap(connection);
      rethrow;
    }
  }

  Future<_ClockFix> _measureClock(_Connection connection) async {
    _ClockFix? best;
    var bestRtt = 0;
    for (var i = 0; i < config.clockProbes; i++) {
      final before = _clockUs();
      final reply = _expect<ClockFrame>(
        await connection.request(
          ClockRequest(_nextId()),
          config.requestTimeout,
        ),
      );
      final after = _clockUs();
      final rtt = math.max(0, after - before);
      if (best == null || rtt < bestRtt) {
        bestRtt = rtt;
        best = (
          offsetUs: before + rtt ~/ 2 - reply.monotonicUs,
          // Helper times are whole milliseconds.
          uncertaintyUs: rtt ~/ 2 + 1000,
        );
      }
    }
    if (best != null) {
      _diagnostic(SpeakerObserverDiagnosticCode.clockMeasured, bestRtt);
    }
    return best ?? (offsetUs: 0, uncertaintyUs: 0);
  }

  void _emit(SpeakerObserverEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _emitState(ObserverStatus status, [SpeakerObserverFailure? failure]) =>
      _emit(
        ObserverStateEvent(
          _epoch,
          status: status,
          atUs: _clockUs(),
          restartCount: _restarts,
          failure: failure,
        ),
      );

  void _onStreamFrame(_Connection connection, ObserverFrame frame) {
    switch (frame) {
      case ObservationFrame(:final observation):
        if (observation.session != _session) {
          return connection.fail(
            const SpeakerObserverException(
              SpeakerObserverFailure.protocolError,
            ),
          );
        }
        _lastUnavailableReason = null;
        _count(observations: 1);
        _emit(
          ObservationEvent(
            connection.epoch,
            _qualified(observation, connection.epoch).shifted(
              connection.clock.offsetUs,
              extraUncertaintyUs: connection.clock.uncertaintyUs,
            ),
          ),
        );
      case UnavailableFrame():
        if (frame.session != _session) {
          return connection.fail(
            const SpeakerObserverException(
              SpeakerObserverFailure.protocolError,
            ),
          );
        }
        _count(unavailableFrames: 1);
        // A helper repeats the same unavailability every poll as a heartbeat.
        if (frame.reason != _lastUnavailableReason ||
            frame.sinceUs != _lastUnavailableSince) {
          _lastUnavailableReason = frame.reason;
          _lastUnavailableSince = frame.sinceUs;
          _emit(
            UnavailableEvent(
              connection.epoch,
              sinceUs:
                  frame.sinceUs +
                  connection.clock.offsetUs -
                  connection.clock.uncertaintyUs,
              reason: frame.reason,
            ),
          );
        }
      default:
        return;
    }
    _armStall(connection);
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
      _diagnostic(SpeakerObserverDiagnosticCode.stalled);
      _count(stalls: 1);
      connection.fail(
        const SpeakerObserverException(SpeakerObserverFailure.stalled),
      );
    });
  }

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
    _stall?.cancel();
    _restartOp = _restart(connection, failure).then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _phase = _Phase.failed;
        _emitState(ObserverStatus.failed);
      },
    );
  }

  Future<void> _restart(
    _Connection failed,
    SpeakerObserverException cause,
  ) async {
    final generation = _generation;
    _conn = null;
    final reaped = await failed.terminate();
    if (generation != _generation) return;
    if (!reaped) {
      _reapFailed = true;
      _diagnostic(SpeakerObserverDiagnosticCode.reapFailed);
      _phase = _Phase.failed;
      _emitState(ObserverStatus.failed, SpeakerObserverFailure.reapFailed);
      return;
    }
    _emitState(ObserverStatus.restarting, cause.failure);
    var latest = cause;
    while (generation == _generation) {
      if (_restarts >= config.maxRestarts) {
        _diagnostic(SpeakerObserverDiagnosticCode.restartsExhausted, _restarts);
        _phase = _Phase.failed;
        _emitState(ObserverStatus.failed, latest.failure);
        return;
      }
      final attempt = ++_restarts;
      _count(restarts: 1);
      final delay = _backoffFor(attempt);
      _diagnostic(
        SpeakerObserverDiagnosticCode.restartScheduled,
        delay.inMilliseconds,
      );
      if (!await _sleep(delay, generation)) return;
      _epoch++;
      try {
        final connection = await _launchAndStart(_session!, _epoch);
        if (generation != _generation) {
          await _reap(connection);
          return;
        }
        _goLive(connection);
        return;
      } on SpeakerObserverException catch (error) {
        if (generation != _generation) return;
        latest = error;
        if (error.failure == SpeakerObserverFailure.unavailable ||
            error.failure == SpeakerObserverFailure.reapFailed) {
          _phase = _Phase.failed;
          _emitState(ObserverStatus.failed, error.failure);
          return;
        }
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

  @override
  Future<void> stop() => _stopOp ??= _stop().whenComplete(() => _stopOp = null);

  Future<void> _stop() async {
    if (_phase == _Phase.idle && _startOp == null) return;
    _generation++;
    _stall?.cancel();
    _backoff?.cancel();
    final wake = _backoffWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    await _startOp;
    await _restartOp;
    _restartOp = null;
    final connection = _conn;
    _conn = null;
    var reaped = true;
    if (connection != null) {
      if (connection.live && connection.failure == null) {
        try {
          await connection.request(StopRequest(_nextId()), config.exitGrace);
        } on SpeakerObserverException {
          // Escalation below terminates and reaps regardless.
        }
      }
      reaped = await connection.terminate();
    }
    _emitState(ObserverStatus.stopped);
    _resetToIdle();
    if (!reaped) {
      _reapFailed = true;
      _diagnostic(SpeakerObserverDiagnosticCode.reapFailed);
      throw const SpeakerObserverException(SpeakerObserverFailure.reapFailed);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await stop();
    } finally {
      _disposed = true;
      await _events.close();
    }
  }
}

enum _Phase { idle, starting, running, restarting, failed }
