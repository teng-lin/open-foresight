import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Advisory only. Native recording admission independently enforces this floor.
const audioStorageReserveBytes = 64 * 1024 * 1024;

/// Two 48kHz mono PCM16 routes plus two 196-byte headers per five seconds,
/// rounded up. Assumes no compression savings. Frequent partial chunks, other
/// writers, quotas and filesystem metadata can reduce actual recording time.
const audioStorageBytesPerSecond = 192080;

int? estimatedAudioRecordingUs(int? availableBytes) {
  if (availableBytes == null || availableBytes < 0) return null;
  final usable = availableBytes - audioStorageReserveBytes;
  if (usable <= 0) return 0;
  final estimate =
      BigInt.from(usable) *
      BigInt.from(1000000) ~/
      BigInt.from(audioStorageBytesPerSecond);
  final maximum = BigInt.from(0x7fffffffffffffff);
  return (estimate > maximum ? maximum : estimate).toInt();
}

abstract interface class AudioStorageSpaceProbe {
  Future<int?> sample(String directory);
  bool get busy;
  bool get restartRequired;
  Future<void> close();
}

/// One fixed OS utility, with bounded output and observed launch/actual exit.
/// Timeout never abandons Process.start: late children enter the same retirement
/// path. Unknown retirement disables this probe, without stopping audio capture.
final class AudioStorageProcessProbe implements AudioStorageSpaceProbe {
  AudioStorageProcessProbe({
    this.timeout = const Duration(seconds: 2),
    this.terminateGrace = const Duration(milliseconds: 250),
    this.killGrace = const Duration(seconds: 1),
    Future<Process> Function(String, List<String>)? startProcess,
  }) : _start = startProcess ?? _startFixed;

  final Duration timeout, terminateGrace, killGrace;
  final Future<Process> Function(String, List<String>) _start;
  _SpaceOperation? _operation;
  bool _closed = false;

  static Future<Process> _startFixed(
    String executable,
    List<String> arguments,
  ) => Process.start(
    executable,
    arguments,
    workingDirectory: '/',
    includeParentEnvironment: false,
    environment: const {'LC_ALL': 'C', 'LANG': 'C', 'PATH': '/usr/bin:/bin'},
  );

  @override
  bool get busy => _operation != null && !_operation!.actuallyClosed;
  @override
  bool get restartRequired => _operation?.restartRequired ?? false;

  @override
  Future<int?> sample(String directory) {
    if (_closed || restartRequired) return Future.value(null);
    if (_operation case final active? when !active.actuallyClosed) {
      return active.result;
    }
    final operation = _operation = _SpaceOperation(
      start: () => _start(Platform.isMacOS ? '/bin/df' : '/usr/bin/df', [
        '-Pk',
        directory,
      ]),
      timeout: timeout,
      terminateGrace: terminateGrace,
      killGrace: killGrace,
    );
    return operation.result;
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _operation?.close();
  }
}

final class _SpaceOperation {
  _SpaceOperation({
    required Future<Process> Function() start,
    required this.timeout,
    required this.terminateGrace,
    required this.killGrace,
  }) {
    // Install observation before any deadline or caller can reject admission.
    _launch = Future.sync(start).then(
      _adopt,
      onError: (Object _, StackTrace __) {
        _launchSettled.complete();
        _invalid = true;
        actuallyClosed = true;
        _ready.complete();
      },
    );
    _launch.ignore();
    result = _run();
    result.ignore();
  }
  final Duration timeout, terminateGrace, killGrace;
  final _launchSettled = Completer<void>(), _ready = Completer<void>();
  final _cancelled = Completer<void>();
  final _stdoutDone = Completer<void>(), _stderrDone = Completer<void>();
  final _stdout = <int>[], _stderr = <int>[];
  late final Future<void> _launch;
  late final Future<int?> result;
  Future<void>? _retiring;
  Process? _process;
  StreamSubscription<List<int>>? _outSubscription, _errSubscription;
  Future<int>? _exit;
  int? _exitCode;
  bool _invalid = false, _closing = false;
  bool actuallyClosed = false, restartRequired = false;

  void _adopt(Process process) {
    _process = process;
    _exit = process.exitCode.then((code) => _exitCode = code);
    _exit!.ignore();
    try {
      process.stdin.close().ignore();
      _outSubscription = _listen(process.stdout, _stdout, _stdoutDone);
      _errSubscription = _listen(process.stderr, _stderr, _stderrDone);
      Future.wait<Object?>([_exit!, _stdoutDone.future, _stderrDone.future])
          .then(
            (_) {
              if (!_ready.isCompleted) _ready.complete();
            },
            onError: (Object _, StackTrace __) {
              _invalid = true;
              if (!_ready.isCompleted) _ready.complete();
            },
          )
          .ignore();
    } catch (_) {
      _invalid = true;
      if (!_cancelled.isCompleted) _cancelled.complete();
    } finally {
      _launchSettled.complete();
      if (_closing) _retireProcess().ignore();
    }
  }

  StreamSubscription<List<int>> _listen(
    Stream<List<int>> stream,
    List<int> bytes,
    Completer<void> done,
  ) => stream.listen(
    (chunk) {
      if (bytes.length + chunk.length <= 16384) {
        bytes.addAll(chunk);
      } else {
        _invalid = true;
        if (!_cancelled.isCompleted) _cancelled.complete();
      }
    },
    onError: (Object _, StackTrace __) {
      _invalid = true;
      if (!done.isCompleted) done.complete();
      if (!_cancelled.isCompleted) _cancelled.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  Future<int?> _run() async {
    try {
      await Future.any([_ready.future, _cancelled.future]).timeout(timeout);
    } catch (_) {
      _invalid = true;
    }
    if (_cancelled.isCompleted) _invalid = true;
    try {
      await close();
    } catch (_) {
      return null;
    }
    if (_invalid || _exitCode != 0) return null;
    return parseAudioStorageAvailableBytes(
      utf8.decode(_stdout, allowMalformed: true),
    );
  }

  Future<void> close() async {
    _closing = true;
    if (!_ready.isCompleted && !_cancelled.isCompleted) _cancelled.complete();
    try {
      await _launchSettled.future.timeout(killGrace);
      if (_process != null) await _retireProcess();
      if (!actuallyClosed) throw StateError('Storage probe exit unconfirmed');
    } catch (_) {
      restartRequired = true;
      throw StateError('Storage probe exit unconfirmed');
    }
  }

  Future<void> _retireProcess() => _retiring ??= () async {
    final process = _process!;
    if (_exitCode == null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await _exit!.timeout(terminateGrace);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await _exit!.timeout(killGrace);
      }
    }
    // Even a successful exit requires complete stream ownership retirement.
    await Future.wait([
      if (_outSubscription != null) _outSubscription!.cancel(),
      if (_errSubscription != null) _errSubscription!.cancel(),
    ]).timeout(killGrace);
    actuallyClosed = true;
  }();
}

/// POSIX -Pk has a header and one record. Reject ambiguous/truncated output;
/// the path is never returned, logged, or used to authorize media access.
int? parseAudioStorageAvailableBytes(String output) {
  final lines = output.trim().split('\n');
  if (lines.length != 2 || !lines.first.startsWith('Filesystem ')) return null;
  final values = lines.last.trim().split(RegExp(r'\s+'));
  if (values.length < 6 || !RegExp(r'^\d+$').hasMatch(values[3])) return null;
  final total = int.tryParse(values[1]);
  final used = int.tryParse(values[2]);
  final blocks = int.tryParse(values[3]);
  if (total == null ||
      used == null ||
      total < 0 ||
      used < 0 ||
      blocks == null ||
      blocks > total ||
      blocks > 0x7fffffffffffffff ~/ 1024 ||
      !RegExp(r'^\d+%$').hasMatch(values[4])) {
    return null;
  }
  return blocks * 1024;
}

/// Reads never await a probe. Scope changes and old/failed samples yield null;
/// one outstanding task and an attempt interval prevent polling amplification.
final class AudioStorageHeadroom {
  AudioStorageHeadroom({
    required this.directory,
    required this.scope,
    required this.nowUs,
    required this.changed,
    AudioStorageSpaceProbe? probe,
    this.refreshAfter = const Duration(seconds: 5),
    this.staleAfter = const Duration(seconds: 15),
  }) : _probe = probe ?? AudioStorageProcessProbe();
  final String directory;
  final String Function() scope;
  final int Function() nowUs;
  final void Function() changed;
  final Duration refreshAfter, staleAfter;
  final AudioStorageSpaceProbe _probe;
  String? _scope;
  int? _available, _sampledAt, _attemptedAt;
  Future<void>? _pending;
  bool _disposed = false;
  bool get busy => _probe.busy;
  bool get restartRequired => _probe.restartRequired;

  int? get estimatedRemainingRecordingUs {
    if (_disposed) return null;
    final current = scope(), now = nowUs();
    if (_scope != current || (_attemptedAt != null && now < _attemptedAt!)) {
      _scope = current;
      _available = _sampledAt = _attemptedAt = null;
    }
    if (_pending == null &&
        !_probe.restartRequired &&
        (_attemptedAt == null ||
            now - _attemptedAt! >= refreshAfter.inMicroseconds)) {
      _attemptedAt = now;
      _pending = Future.sync(() => _probe.sample(directory))
          .then(
            (bytes) {
              if (!_disposed && scope() == current && _scope == current) {
                _available = bytes;
                _sampledAt = now;
                try {
                  changed();
                } catch (_) {
                  /* Presentation does not own probe lifetime. */
                }
              }
            },
            onError: (Object _, StackTrace __) {
              if (!_disposed && scope() == current && _scope == current) {
                _available = _sampledAt = null;
              }
            },
          )
          .whenComplete(() => _pending = null);
      _pending!.ignore();
    }
    final sampled = _sampledAt;
    if (sampled == null ||
        now < sampled ||
        now - sampled >= staleAfter.inMicroseconds) {
      return null;
    }
    return estimatedAudioRecordingUs(_available);
  }

  Future<void> close() async {
    _disposed = true;
    _available = _sampledAt = null;
    await _probe.close();
    await _pending;
  }
}
