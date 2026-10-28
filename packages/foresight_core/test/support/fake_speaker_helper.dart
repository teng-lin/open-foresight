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
  bool exitOnStdinClose = true;
  bool exitOnTerm = true;
  bool exitOnKill = true;
  bool answerClock = true;
  bool answerCapabilities = true;

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
    stdin = IOSink(_stdinController.sink);
    if (behavior.sendHello) {
      scheduleMicrotask(
        () => send('hello', {
          'helper': 'fake_helper',
          'helper_version': '1.0.0',
          'parser_version': 'mac-1',
          'platform': behavior.platform,
        }),
      );
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
        send('clock', {'id': id, 'monotonic_ms': behavior.clockMs});
      case 'start':
        session = request['session'] as String;
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
        send('stopped', {'id': id, 'session': session ?? 's'});
        exit(0);
    }
  }
}
