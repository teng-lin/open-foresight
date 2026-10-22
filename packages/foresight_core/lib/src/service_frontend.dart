import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'application_service.dart';
import 'platform_services.dart';
import 'profile_paths.dart';
import 'service_diagnostics.dart';
import 'service_framing.dart';
import 'service_gates.dart';
import 'service_ownership.dart';
import 'service_protocol.dart';
import 'service_socket.dart';

/// Public socket transport lives on the main service isolate. The complete
/// Domain (SQLite connections, native handles, model ownership, approvals and
/// request leases) lives in one long-lived worker isolate. Byte streams preserve
/// multiplexed requests, events, cancellation and shutdown acknowledgements.
///
/// Once the worker begins closing (its `draining` message) or this frontend is
/// asked to close, new connections are no longer bridged: [_refuse] answers
/// their requests with the closing refusal until the public socket is removed.
/// Attached clients keep their bridges, so they receive the worker's terminal
/// frames and refusals before it closes their connections. Only a worker that
/// exits unexpectedly leaves them with a bare EOF.
class IsolatedApplicationService {
  final String _dataPath;
  final ReceivePort _messages;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  final _peers = <Socket>{};
  final _refused = <Socket>{};
  final _bridges = <Future<void>>{};
  SendPort? _control;
  ServiceSocketBinding? _binding;
  Future<void>? _listening;
  bool _publicClosing = false;
  String? _publicPath;
  String? _workerPath;
  Object? _failure;
  // This frontend asked the worker to close.
  bool _closing = false;
  // The worker announced that it is closing.
  bool _workerClosing = false;
  // New connections get the closing refusal instead of a bridge.
  bool _draining = false;
  Future<void>? _shutdown;
  Future<void>? _finishing;
  final _workerExited = Completer<void>();
  bool _publicRemoved = false;
  // Set once the public socket is released; later refusals end at once.
  bool _refusalsEnded = false;
  Future<void> get closed => _closed.future;
  IsolatedApplicationService._(
    this._dataPath,
    this._messages,
    this._errors,
    this._exits,
  );

  static Future<IsolatedApplicationService> start(ProfilePaths profile) async {
    // The worker only gets the runtime path; check its parent here.
    privateRuntime(profile);
    final host = IsolatedApplicationService._(
      profile.data,
      ReceivePort(),
      ReceivePort(),
      ReceivePort(),
    );
    host._messages.listen(host._message);
    host._errors.listen((dynamic error) {
      traceServiceTransport(() => 'worker uncaught error $error');
      host._failure = StateError('Application worker failed: $error');
      if (!host._ready.isCompleted) host._ready.completeError(host._failure!);
    });
    host._exits.listen((_) {
      traceServiceTransport(
        () => 'worker exit received failed=${host._failure != null}',
      );
      final unexpected =
          host._ready.isCompleted && !host._closing && !host._workerClosing;
      if (!host._workerExited.isCompleted) host._workerExited.complete();
      if (!host._ready.isCompleted) {
        host._ready.completeError(
          host._failure ??
              StateError('Application worker exited during startup'),
        );
      }
      if (unexpected) host._workerLost();
      unawaited(host._finish());
    });
    var spawned = false;
    try {
      final releaseLocalOwner = retainLocalServiceOwner(profile.data);
      unawaited(host.closed.whenComplete(releaseLocalOwner));
      await Isolate.spawn(
        _applicationServiceWorker,
        [
          host._messages.sendPort,
          profile.data,
          profile.runtime,
          Map<String, String>.from(runtimeConfiguration.environment),
        ],
        onError: host._errors.sendPort,
        onExit: host._exits.sendPort,
        debugName: 'foresight-domain',
      );
      spawned = true;
      await host._ready.future;
      return host;
    } catch (_) {
      host._control?.send('close');
      if (spawned) await host._workerExited.future;
      await host._finish();
      rethrow;
    }
  }

  void _message(dynamic message) {
    if (message is SendPort) {
      _control = message;
      return;
    }
    final value = message as List;
    if (value.first == 'ready') {
      _workerPath = value[1] as String;
      _publicPath = value[2] as String;
      final listening = _listen();
      _listening = listening;
      unawaited(
        listening.then(
          (_) {
            if (!_ready.isCompleted) _ready.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!_ready.isCompleted) _ready.completeError(error, stack);
          },
        ),
      );
    } else if (value.first == 'draining') {
      traceServiceTransport(() => 'worker draining received');
      _workerClosing = true;
      _draining = true;
    } else if (value.first == 'closing') {
      traceServiceTransport(() => 'worker ownership closing received');
      unawaited(
        _removePublicSocket(workerOwnsLock: true).then(
          (_) => _control?.send('frontend_closed'),
          onError: (Object error) {
            _failure ??= error;
            _control?.send('frontend_failed');
          },
        ),
      );
    } else if (value.first == 'failure') {
      traceServiceTransport(() => 'worker failure received ${value[1]}');
      _failure = value.length > 2 && value[2] == true
          ? ServiceOwnershipContended(value[1] as String)
          : StateError(value[1] as String);
      if (!_ready.isCompleted) _ready.completeError(_failure!);
    }
  }

  Future<void> _listen() async {
    final path = _publicPath!;
    traceServiceTransport(() => 'frontend bind $path');
    // The domain worker already holds both ownership locks, so a competing
    // launcher of this profile cannot remove the live owner's socket or
    // endpoint record, and a socket that still accepts here belongs to
    // another profile.
    await clearStaleServiceSocket(path);
    final binding = await ServiceSocketBinding.bind(path);
    _binding = binding;
    if (_publicClosing) {
      await binding.close();
      throw StateError('Service closed before socket publication');
    }
    await publishServiceSocket(binding, _accept);
    traceServiceTransport(() => 'frontend listening ${binding.identity}');
  }

  void _accept(Socket client) {
    if (_draining) {
      _refuse(client);
      return;
    }
    final bridge = _bridge(client);
    _bridges.add(bridge);
    unawaited(bridge.whenComplete(() => _bridges.remove(bridge)));
  }

  Future<void> _bridge(Socket client) async {
    final peer = identityHashCode(client);
    traceServiceTransport(() => 'frontend accept peer=$peer');
    _peers.add(client);
    Socket? backend;
    try {
      traceServiceTransport(
        () => 'frontend backend connect peer=$peer $_workerPath',
      );
      backend = await Socket.connect(
        InternetAddress(_workerPath!, type: InternetAddressType.unix),
        0,
      );
      traceServiceTransport(() => 'frontend backend connected peer=$peer');
      _peers.add(backend);
      if (_draining) {
        // The worker began closing while this connected; nothing was sent.
        backend.destroy();
        _peers.remove(client);
        _refuse(client);
        return;
      }
      // pipe applies stream backpressure and flushes before closing. Keeping
      // both directions alive is necessary for approval and cancel frames.
      Future<void> copy(Socket source, Socket target, String direction) async {
        try {
          Stream<List<int>> chunks = source.cast<List<int>>();
          if (runtimeConfiguration['FORESIGHT_SERVICE_TRACE'] == '1') {
            var first = true;
            chunks = chunks.map((chunk) {
              if (first) {
                first = false;
                traceServiceTransport(
                  () =>
                      'frontend first bytes peer=$peer direction=$direction '
                      'length=${chunk.length}',
                );
              }
              return chunk;
            });
          }
          await target.addStream(chunks);
          await target.flush();
        } finally {
          traceServiceTransport(
            () => 'frontend copy closed peer=$peer $direction',
          );
          // Socket.close only half-closes its write side. Once either peer
          // reaches EOF, flush that direction and release both read sides.
          source.destroy();
          target.destroy();
        }
      }

      await Future.wait<void>([
        copy(client, backend, 'to-worker'),
        copy(backend, client, 'from-worker'),
      ]);
    } catch (error) {
      traceServiceTransport(() => 'frontend bridge failed peer=$peer $error');
      backend?.destroy();
      if (backend == null && _draining) {
        // A closing worker no longer accepts; this client sent nothing yet.
        _peers.remove(client);
        _refuse(client);
      } else {
        client.destroy();
      }
    } finally {
      _peers.remove(client);
      if (backend != null) _peers.remove(backend);
    }
  }

  /// Answer every request on [client] with the closing refusal instead of
  /// bridging it, until the public socket is removed. A launcher waits for
  /// this connection's EOF before it probes the profile lock.
  void _refuse(Socket client) {
    if (_refusalsEnded) {
      client.destroy();
      return;
    }
    final peer = identityHashCode(client);
    traceServiceTransport(() => 'frontend refuse peer=$peer');
    _refused.add(client);
    unawaited(client.done.catchError((Object _) {}));
    final frames = ServiceFrameSplitter(maxServiceMessage);
    void stop() {
      _refused.remove(client);
      client.destroy();
    }

    client.listen(
      (chunk) {
        final complete = frames.add(chunk);
        if (complete == null) {
          stop();
          return;
        }
        for (final frame in complete) {
          final request = decodeServiceFrame(frame);
          final id = request?['id'];
          if (request == null || (id is! int && request['cancel'] is! int)) {
            traceServiceTransport(
              () => 'frontend refused malformed peer=$peer',
            );
            stop();
            return;
          }
          // Nothing was dispatched, so there is nothing to cancel.
          if (id is! int) continue;
          try {
            client.add(
              utf8.encode(
                '${jsonEncode({'id': id, 'error': serviceClosingRefusal().toJson(), 'done': true})}\n',
              ),
            );
          } catch (_) {
            stop();
            return;
          }
        }
      },
      onError: (Object _) => stop(),
      onDone: stop,
      cancelOnError: true,
    );
  }

  /// A worker that dies without closing leaves its sockets open with nobody
  /// reading them. Refuse new connections and end attached ones now: only
  /// this crash path gives clients a bare EOF.
  void _workerLost() {
    traceServiceTransport(() => 'worker exited unexpectedly');
    _failure ??= StateError('Application worker exited unexpectedly');
    _draining = true;
    for (final peer in _peers.toList()) {
      peer.destroy();
    }
  }

  Future<void> close() => _shutdown ??= () async {
    traceServiceTransport(() => 'frontend close closing=$_closing');
    if (!_closing) {
      _closing = true;
      // Attached clients keep their bridges: the worker answers each request
      // in flight with a terminal frame and refuses later ones before it
      // closes their connections. New connections are refused here.
      _draining = true;
      _control?.send('close');
    }
    await closed;
    if (_failure != null) throw _failure!;
  }();

  Future<void> _removePublicSocket({bool workerOwnsLock = false}) async {
    traceServiceTransport(
      () => 'frontend remove socket owns_lock=$workerOwnsLock',
    );
    _publicClosing = true;
    // Join startup before cleanup so a pending bind cannot publish afterwards.
    try {
      await _listening;
    } catch (_) {
      // Startup reports its original error through _ready.
    }
    await _binding?.close();
    traceServiceTransport(() => 'frontend listener closed');
    try {
      if (_publicRemoved || _publicPath == null) return;
      // The public socket no longer accepts, but its path still exists.
      if (serviceGatesEnabled) await serviceGate('frontend.listener_closed');
      RandomAccessFile? ownership;
      if (!workerOwnsLock) {
        // An unexpected worker exit may release its lock before this isolate
        // processes the exit message. A new process can already own the
        // profile. Reacquire ownership before touching its public socket path.
        try {
          traceServiceTransport(() => 'frontend reacquiring ownership');
          ownership = await File(
            '$_dataPath/.application.lock',
          ).open(mode: FileMode.append);
          ownership.lockSync(FileLock.exclusive);
          traceServiceTransport(() => 'frontend ownership reacquired');
        } on FileSystemException {
          await ownership?.close();
          return;
        }
      }
      try {
        // Unlink only the socket this frontend published. A replacement, or
        // an owner in this process or of another profile sharing the runtime
        // directory, may own the path now.
        final removed = await _binding?.unpublish() ?? false;
        traceServiceTransport(
          () => removed
              ? 'frontend socket removed $_publicPath'
              : 'frontend leaves $_publicPath to its owner',
        );
        _publicRemoved = true;
      } finally {
        await ownership?.close();
      }
    } finally {
      // Refused clients wait for this EOF before probing the profile lock.
      // A bridge that fails later must not leave a new refusal open.
      _refusalsEnded = true;
      final refused = _refused.toList();
      _refused.clear();
      // A refusal can still be queued for a client that reads slowly. Its
      // EOF alone would leave that request outcomeUnknown, never resent, so
      // deliver the refusals first, within the same bound as a closing
      // owner's terminal frames.
      await Future.wait([
        for (final client in refused) flushServiceSocketQuietly(client),
      ]).timeout(serviceClosingFlushBound, onTimeout: () => const []);
      for (final client in refused) {
        client.destroy();
      }
    }
  }

  Future<void> _finish() => _finishing ??= _finishOnce();
  Future<void> _finishOnce() async {
    traceServiceTransport(() => 'frontend finish begin');
    if (_closed.isCompleted) return;
    // The worker has exited. New clients are refused until the public socket
    // is gone, if the worker did not already release it.
    _draining = true;
    if (serviceGatesEnabled) await serviceGate('frontend.draining');
    try {
      await _removePublicSocket();
      // The worker flushes an idle-stop acknowledgement before exiting.
      await Future.wait(_bridges.toList()).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      for (final peer in _peers.toList()) {
        peer.destroy();
      }
    } catch (error) {
      _failure ??= error;
      for (final peer in _peers.toList()) {
        peer.destroy();
      }
    } finally {
      _messages.close();
      _errors.close();
      _exits.close();
      if (!_closed.isCompleted) _closed.complete();
    }
  }
}

void _applicationServiceWorker(List<Object?> configuration) {
  runApplicationWorkerZone(() async {
    try {
      await _runApplicationServiceWorker(configuration);
    } catch (error, stack) {
      // Include failures before the main worker lifecycle installs its own
      // handler (for example while installing the inherited environment).
      (configuration[0] as SendPort).send(['failure', '$error\n$stack']);
    }
  });
}

/// Keep recoverable asynchronous errors local to the worker. Startup and main
/// lifecycle failures are reported by the worker's failure message; uncaught
/// fatal isolate errors still reach Isolate.spawn's separate onError port.
void runApplicationWorkerZone(Future<void> Function() worker) {
  // ignore: discarded_futures
  runZonedGuarded(worker, (error, stack) {
    stderr.writeln('Application worker asynchronous error: $error\n$stack');
  });
}

Future<void> _runApplicationServiceWorker(List<Object?> configuration) async {
  final parent = configuration[0] as SendPort;
  installServiceWorkerEnvironment(
    (configuration[3] as Map).cast<String, String>(),
  );
  traceServiceTransport(() => 'worker starting');
  final control = ReceivePort();
  parent.send(control.sendPort);
  ApplicationService? service;
  final stop = Completer<void>();
  final frontendClosed = Completer<void>();
  control.listen((message) {
    if (message == 'frontend_closed') {
      if (!frontendClosed.isCompleted) frontendClosed.complete();
    } else if (message == 'frontend_failed') {
      if (!frontendClosed.isCompleted) {
        frontendClosed.completeError(
          StateError('Public service socket cleanup failed'),
        );
      }
    } else if (!stop.isCompleted) {
      stop.complete();
    }
  });
  try {
    final profile = ProfilePaths(
      configuration[1] as String,
      configuration[2] as String,
    );
    service = await ApplicationService.start(
      profile,
      internalWorker: true,
      onDraining: () => parent.send(['draining']),
      beforeReleaseOwnership: () {
        parent.send(['closing']);
        return frontendClosed.future;
      },
    );
    final readyService = service;
    traceServiceTransport(() => 'worker ready ${readyService.path}');
    // The public socket belongs beside the worker socket, in the runtime this
    // start created or adopted. Reading the record again could disagree.
    parent.send([
      'ready',
      service.path,
      '${File(service.path).parent.path}/application.sock',
    ]);
    await Future.any([stop.future, service.closed]);
    traceServiceTransport(() => 'worker close begin');
    await service.close();
    traceServiceTransport(() => 'worker close complete');
    // Let an idle-stop request flush its final acknowledgement after close.
    await Future<void>.delayed(Duration.zero);
  } catch (error, stack) {
    traceServiceTransport(() => 'worker main failed $error\n$stack');
    parent.send([
      'failure',
      '$error\n$stack',
      error is ServiceOwnershipContended,
    ]);
    try {
      await service?.close();
    } catch (_) {}
  } finally {
    traceServiceTransport(() => 'worker main finally');
    control.close();
  }
}
