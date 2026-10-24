export 'model_identity.dart'
    show dedicatedQueryModelKind, dedicatedQueryBackend, portableQueryBackend;
import 'rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'runtime_execution_policy.dart';

abstract interface class QueryCompletionRuntime {
  Future<String> complete(String prompt, String requestId);
  void cancel(String requestId);
  Future<void> close();
}

abstract interface class QueryRuntimeReadiness {
  bool get ready;
}

class _QueryRequest {
  final String id;
  final result = Completer<String>();
  bool cancelled = false;
  _QueryRequest(this.id) {
    result.future.ignore();
  }
}

/// The reconstructed CPU detector has its own process and fresh per-call cache.
/// Killing this process cancels only its owned detection, including model load.
class DedicatedQueryRuntime
    implements QueryCompletionRuntime, QueryRuntimeReadiness {
  DedicatedQueryRuntime({
    required this.python,
    required this.worker,
    required this.model,
    this.timeout = const Duration(minutes: 2),
    Future<Process> Function(String, List<String>)? startProcess,
  }) : _startProcess =
           startProcess ??
           ((python, arguments) => Process.start(python, arguments));
  final String python, worker, model;
  final Duration timeout;
  final Future<Process> Function(String, List<String>) _startProcess;
  final _retired = <Future<int>>{};
  Future<void>? _closing;
  Process? _process;
  Future<void>? _starting;
  _QueryRequest? _active;
  Completer<void>? _ready;
  int _epoch = 0;
  bool _closed = false;
  String _stderr = '';
  @override
  bool get ready => _process != null && _ready?.isCompleted == true;

  void _fail(Object error) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    final active = _active;
    if (active != null && !active.result.isCompleted) {
      active.result.completeError(error);
    }
  }

  void _stop(Object error) {
    _epoch++;
    _fail(error);
    final process = _process;
    _process = null;
    // There are no subprocesses in this adapter. Do not signal shared workers.
    if (process != null) {
      final exited = process.exitCode;
      _retired.add(exited);
      unawaited(
        exited.then<void>(
          (_) {
            _retired.remove(exited);
          },
          onError: (Object error, StackTrace stack) {
            _retired.remove(exited);
          },
        ),
      );
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> _start() async {
    if (_process != null) return;
    final executable = requireInstalledRuntime(python);
    final selectedWorker = requireInstalledRuntime(worker);
    final epoch = _epoch;
    final process = await _startProcess(executable, [
      if (executable != selectedWorker) ...['-I', '-B', selectedWorker],
      '--model',
      model,
    ]);
    if (_closed || epoch != _epoch) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw RpcError(
        RpcErrorCode.cancelled,
        'Dedicated query detection cancelled',
      );
    }
    _process = process;
    _stderr = '';
    final ready = _ready = Completer<void>();
    ready.future.ignore();
    void streamError(Object error) {
      if (identical(_process, process)) _stop(error);
    }

    process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((
      text,
    ) {
      if (!identical(_process, process)) return;
      _stderr += text;
      if (_stderr.length > 4096) {
        _stderr = _stderr.substring(_stderr.length - 4096);
      }
    }, onError: streamError);
    void frame(String line) {
      final frame = jsonDecode(line);
      if (frame is! Map) throw const FormatException('Invalid detector frame');
      if (frame['type'] == 'ready') {
        if (ready.isCompleted) {
          throw const FormatException('Repeated detector ready');
        }
        ready.complete();
      } else if (frame['type'] == 'fatal') {
        _stop(
          StateError(
            'Dedicated query detector unavailable: ${frame['message']}',
          ),
        );
      } else {
        final active = _active;
        if (active == null || frame['id'] != active.id) {
          throw const FormatException('Unowned detector response');
        }
        if (frame['type'] == 'error') {
          active.result.completeError(StateError('${frame['message']}'));
        } else if (frame['type'] == 'result' && frame['text'] is String) {
          // Preserve decoder output verbatim; recovered downstream parsing
          // owns sanitation, question splitting and trimming.
          active.result.complete(frame['text'] as String);
        } else {
          throw const FormatException('Invalid detector response');
        }
      }
    }

    // Bound partial lines as well as complete frames; LineSplitter alone
    // would retain an unlimited unterminated worker response.
    const maxFrame = 1024 * 1024;
    var pending = '';
    process.stdout.transform(utf8.decoder).listen((chunk) {
      if (!identical(_process, process)) return;
      try {
        pending += chunk;
        while (true) {
          final end = pending.indexOf('\n');
          if (end < 0) break;
          if (end > maxFrame) {
            throw const FormatException('Detector frame exceeds 1 MiB');
          }
          final line = pending.substring(0, end);
          pending = pending.substring(end + 1);
          frame(line);
          if (!identical(_process, process)) return;
        }
        if (pending.length > maxFrame) {
          throw const FormatException('Detector frame exceeds 1 MiB');
        }
      } catch (error) {
        streamError(error);
      }
    }, onError: streamError);
    unawaited(
      process.exitCode.then((code) {
        if (!identical(_process, process)) return;
        _process = null;
        _fail(StateError('Dedicated query detector exited ($code): $_stderr'));
      }),
    );
    await ready.future;
  }

  @override
  Future<String> complete(String prompt, String requestId) async {
    if (_closed) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Dedicated query detector is closed',
      );
    }
    if (_active != null) {
      throw RpcError(RpcErrorCode.busy, 'Dedicated query detector is busy');
    }
    final request = _active = _QueryRequest(requestId);
    final timer = Timer(timeout, () {
      if (identical(_active, request)) {
        _stop(TimeoutException('Dedicated query detection timed out', timeout));
      }
    });
    try {
      await (_starting = _start());
      if (!request.result.isCompleted) {
        _process!.stdin.writeln(
          jsonEncode({
            'id': requestId,
            'prompt': prompt,
            'max_output_tokens': 512,
          }),
        );
        await _process!.stdin.flush();
      }
      return await request.result.future;
    } catch (error) {
      if (_closed || request.cancelled) {
        final failure =
            error is RpcError && error.code == RpcErrorCode.cancelled
            ? error
            : RpcError(
                RpcErrorCode.cancelled,
                'Dedicated query detection cancelled',
              );
        _stop(failure);
        throw failure;
      }
      _stop(error);
      rethrow;
    } finally {
      _starting = null;
      timer.cancel();
      if (identical(_active, request)) _active = null;
    }
  }

  @override
  void cancel(String requestId) {
    if (_active?.id == requestId) {
      _active!.cancelled = true;
      _stop(
        RpcError(RpcErrorCode.cancelled, 'Dedicated query detection cancelled'),
      );
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final process = _process;
    final busy = _active != null;
    _epoch++;
    _fail(RpcError(RpcErrorCode.cancelled, 'Dedicated query detector closed'));
    _process = null;
    if (process != null) {
      if (busy) {
        process.kill(ProcessSignal.sigkill);
      } else {
        try {
          // An idle worker exits normally on EOF; bound shutdown in case a
          // damaged worker stops reading. Active inference is killed directly.
          await process.stdin.close().timeout(const Duration(seconds: 1));
          await process.exitCode.timeout(const Duration(seconds: 1));
        } catch (_) {
          process.kill(ProcessSignal.sigkill);
        }
      }
    }
    try {
      await _starting;
    } catch (_) {
      // Cancellation during launch/load is already delivered to the caller.
    }
    if (process != null) await process.exitCode;
    // Cancellation/error detaches a killed worker before a later request can
    // restart it. Keep ownership until exit even when it is no longer current.
    while (_retired.isNotEmpty) {
      await Future.wait(_retired.toList());
    }
  }
}
