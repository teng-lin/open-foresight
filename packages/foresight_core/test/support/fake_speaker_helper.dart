import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How a scripted helper reacts. Fields are read when the event occurs, so a
/// test may change them while the observer runs.
class HelperBehavior {
  /// Capture-clock-independent helper clock reported to `clock` requests.
  int clockMs = 1000;
  bool sendHello = true;
  String platform = 'macos';

  /// `started`, `unavailable` (answer start with capabilities), `error`, `silent`.
  String startReply = 'started';
  String capabilityState = 'available';
  String capabilityReason = '';
  bool answerStop = true;

  /// `ok`, `error` or `wrong_session`.
  String stopReply = 'ok';
  int stopExitStatus = 0;
  bool exitOnStdinClose = true;
  bool exitOnTerm = true;
  bool exitOnKill = true;
  bool answerClock = true;
  bool answerCapabilities = true;

  /// Exits without a hello, as a helper killed by dyld or code signing would.
  bool exitBeforeHello = false;
  int exitBeforeHelloStatus = 127;
  bool helloTwice = false;
  Duration? helloDelay;

  /// Frames sent after `start` is received but before `started` is answered.
  List<Map<String, Object?>> beforeStarted = const [];

  /// Called when a clock request arrives, before it is answered; lets a test
  /// move the observer's clock to script a round trip.
  void Function(FakeHelper helper)? onClockRequest;

  /// `normal`, `throwOnAdd` (writes fail at once) or `breakPipe` (writes are
  /// accepted, then stdin.done fails as after EPIPE).
  String stdinMode = 'normal';

  /// Frames emitted right after `started`, as maps without `v`/`seq`.
  List<Map<String, Object?>> afterStart = const [];
  void Function(FakeHelper helper)? onStarted;
}

Map<String, Object?> participant(
  String ref,
  String name, {
  bool self = false,
}) => {'ref': ref, 'name': name, 'self': self};

Map<String, Object?> observationFields(
  String session, {
  int startMs = 2000,
  List<Map<String, Object?>>? participants,
  List<Map<String, Object?>>? speakers,
  bool complete = true,
}) => {
  'session': session,
  'read_start_ms': startMs,
  'read_end_ms': startMs + 10,
  'target': {'pid': 7, 'window': 'w1'},
  'complete': complete,
  'parser_version': 'mac-1',
  'participants': participants ?? [participant('p1', 'Ada Lovelace')],
  'speakers':
      speakers ??
      [
        {'ref': 'p1', 'method': 'participant_status'},
      ],
};

/// A scripted in-memory helper process.
class FakeHelper implements Process {
  FakeHelper(this.behavior, {this.pidValue = 4242}) {
    _stdinController.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onStdinDone);
    // The observer closes stdin; the fake only reports that close.
    // ignore: close_sinks
    stdin = _FakeStdin(_stdinController, behavior.stdinMode);
    if (behavior.exitBeforeHello) {
      scheduleMicrotask(() => exit(behavior.exitBeforeHelloStatus));
    } else if (behavior.sendHello) {
      void hello() {
        send('hello', {
          'helper': 'fake_helper',
          'helper_version': '1.0.0',
          'parser_version': 'mac-1',
          'platform': behavior.platform,
        });
        if (behavior.helloTwice) {
          send('hello', {
            'helper': 'fake_helper',
            'helper_version': '1.0.0',
            'parser_version': 'mac-1',
            'platform': behavior.platform,
          });
        }
      }

      final delay = behavior.helloDelay;
      if (delay == null) {
        scheduleMicrotask(hello);
      } else {
        Timer(delay, hello);
      }
    }
  }
  final HelperBehavior behavior;
  final int pidValue;
  final StreamController<List<int>> _stdoutController = StreamController();
  final StreamController<List<int>> _stderrController = StreamController();
  // The observer owns closing stdin; the fake only observes that close.
  // ignore: close_sinks
  final StreamController<List<int>> _stdinController = StreamController();
  final Completer<int> _exit = Completer();
  final List<Map<String, dynamic>> requests = [];
  final List<ProcessSignal> signals = [];
  int _seq = 0;
  bool stdinClosed = false;
  String? session;

  bool get exited => _exit.isCompleted;

  @override
  // ignore: close_sinks
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _stdoutController.stream;
  @override
  Stream<List<int>> get stderr => _stderrController.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => pidValue;

  List<String> get requestTypes => [
    for (final r in requests) r['type'] as String,
  ];

  void send(String type, [Map<String, Object?> fields = const {}]) {
    if (_stdoutController.isClosed) return;
    sendRaw(jsonEncode({'v': 1, 'type': type, 'seq': _seq++, ...fields}));
  }

  void sendRaw(String text) {
    if (_stdoutController.isClosed) return;
    _stdoutController.add(utf8.encode('$text\n'));
  }

  void sendBytes(List<int> bytes) {
    if (_stdoutController.isClosed) return;
    _stdoutController.add(bytes);
  }

  /// A stream error on stdout / stderr, as from a read failure.
  void stdoutError() => _stdoutController.addError(const SocketException('x'));
  void stderrError() => _stderrController.addError(const SocketException('x'));

  /// stdin.done fails, as after a write to a vanished reader.
  void breakPipe() => (stdin as _FakeStdin).breakPipe();

  void writeStderr(int bytes) {
    if (_stderrController.isClosed) return;
    _stderrController.add(List.filled(bytes, 0x65));
  }

  void exit(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_stdoutController.close());
    unawaited(_stderrController.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (exited) return false;
    if (signal == ProcessSignal.sigkill
        ? behavior.exitOnKill
        : behavior.exitOnTerm) {
      exit(-signal.signalNumber);
    }
    return true;
  }

  void _onStdinDone() {
    stdinClosed = true;
    if (behavior.exitOnStdinClose) exit(0);
  }

  void _onLine(String line) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    requests.add(request);
    final id = request['id'];
    switch (request['type']) {
      case 'capabilities' || 'setup':
        if (!behavior.answerCapabilities) return;
        send('capabilities', {
          'id': id,
          'state': behavior.capabilityState,
          'reason': behavior.capabilityReason,
          'zoom_version': '7.2.2.88465',
          'locale': 'en',
        });
      case 'clock':
        if (!behavior.answerClock) return;
        behavior.onClockRequest?.call(this);
        send('clock', {'id': id, 'monotonic_ms': behavior.clockMs});
      case 'start':
        session = request['session'] as String;
        for (final frame in behavior.beforeStarted) {
          final copy = Map<String, Object?>.of(frame);
          final type = copy.remove('type')! as String;
          if (copy['session'] == r'$session') copy['session'] = session;
          send(type, copy);
        }
        switch (behavior.startReply) {
          case 'started':
            send('started', {
              'id': id,
              'session': session,
              'target': {'pid': 7, 'window': 'w1'},
            });
            for (final frame in behavior.afterStart) {
              final copy = Map<String, Object?>.of(frame);
              final type = copy.remove('type')! as String;
              if (copy['session'] == r'$session') copy['session'] = session;
              send(type, copy);
            }
            behavior.onStarted?.call(this);
          case 'unavailable':
            send('capabilities', {
              'id': id,
              'state': behavior.capabilityState,
              'reason': behavior.capabilityReason,
            });
          case 'error':
            send('error', {
              'id': id,
              'code': 'ax_failed',
              'message': 'SECRET NAME leaked',
            });
          default:
            break;
        }
      case 'stop':
        if (!behavior.answerStop) return;
        if (behavior.stopReply == 'error') {
          send('error', {'id': id, 'code': 'stop_failed', 'message': 'x'});
        } else if (behavior.stopReply == 'wrong_session') {
          send('stopped', {'id': id, 'session': 'someone-else'});
        } else {
          send('stopped', {'id': id, 'session': session ?? 's'});
        }
        exit(behavior.stopExitStatus);
    }
  }
}

/// A stdin whose failure modes a test can choose.
class _FakeStdin implements IOSink {
  _FakeStdin(this._controller, this._mode);
  final StreamController<List<int>> _controller;
  final String _mode;
  final Completer<void> _done = Completer();
  @override
  Encoding encoding = utf8;

  void breakPipe() {
    if (!_done.isCompleted) {
      _done.completeError(const SocketException('Broken pipe'));
    }
  }

  @override
  void add(List<int> data) {
    if (_mode == 'throwOnAdd') throw StateError('StreamSink is closed');
    if (!_controller.isClosed) _controller.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}
