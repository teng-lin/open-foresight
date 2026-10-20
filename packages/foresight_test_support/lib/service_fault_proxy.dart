import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:foresight_core/foresight_core.dart'
    show createPrivateTempDirectory;

import 'test_paths.dart';

/// Which way a frame travels through a [ServiceFaultProxy].
enum ProxyDirection { toService, toClient }

/// One newline-delimited frame seen by the proxy, without its newline.
class ServiceFrame {
  ServiceFrame._(
    this.connection,
    this.direction,
    this.bytes,
    this.json,
    this.method,
  ) : text = utf8.decode(bytes, allowMalformed: true);

  final ProxyConnection connection;
  final ProxyDirection direction;
  final Uint8List bytes;
  final String text;

  /// The decoded frame, or null when it is not a JSON object.
  final Map<String, Object?>? json;

  /// A request's method; for a reply, the method of the request it answers.
  final String? method;

  int? get id => json?['id'] is int ? json!['id'] as int : null;
  String? get event =>
      json?['event'] is String ? json!['event'] as String : null;
  bool get done => json?['done'] == true;
  Map<String, Object?>? get error => json?['error'] is Map
      ? Map<String, Object?>.from(json!['error'] as Map)
      : null;

  @override
  String toString() =>
      'ServiceFrame(#${connection.index} ${direction.name} $text)';

  static Map<String, Object?>? _object(Uint8List bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map ? Map<String, Object?>.from(value) : null;
    } on FormatException {
      return null;
    }
  }
}

/// A connect to a service endpoint, refused or relayed.
class ProxyConnectAttempt {
  ProxyConnectAttempt._(this.endpoint, this.error, this.connection);

  /// The service socket path the caller asked for.
  final String endpoint;

  /// The exception the caller received when the real connect failed.
  final Object? error;

  final ProxyConnection? connection;
  bool get refused => error != null;
}

/// A held frame. Frames behind it in the same direction and connection wait.
class ProxyHold {
  ProxyHold._();
  final _reached = Completer<ServiceFrame>();
  final _released = Completer<void>();

  /// Completes when a matching frame arrives and is held.
  Future<ServiceFrame> get reached => _reached.future;

  /// Forward the held frame and everything queued behind it.
  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// Relays a test isolate's connections to service endpoints and lets the
/// test hold, cut, drop, inject and observe newline frames in either
/// direction. Every control returns a Future or a gate; none uses a timer.
///
/// ```dart
/// final proxy = ServiceFaultProxy();
/// final reply = proxy.hold(ProxyDirection.toClient, method: 'status');
/// final client = proxy.run(() => ensureService(profile));
/// await reply.reached; // the owner answered; the client has not seen it
/// reply.release();
/// await client;
/// await proxy.close();
/// ```
///
/// Only connects made through `Socket.connect` inside [run] are relayed, so
/// it covers `ensureService`, `ServiceClient`, `ServiceConnection` and
/// `RemoteDomain` in this isolate, not other processes or isolates.
class ServiceFaultProxy {
  ServiceFaultProxy({bool Function(String path)? endpoint})
    : _endpoint = endpoint ?? ((path) => path.endsWith('/application.sock'));

  final bool Function(String path) _endpoint;
  final _rules = <_Rule>[];
  final _observers = <_Observer>[];
  final _attemptObservers = <_AttemptObserver>[];

  /// Every connect attempt to a service endpoint, in order.
  final attempts = <ProxyConnectAttempt>[];

  /// Every relayed connection, in order.
  final connections = <ProxyConnection>[];

  /// Every frame that reached the proxy, whatever then happened to it.
  final frames = <ServiceFrame>[];

  Future<Directory>? _directory;
  var _relays = 0;
  var _closed = false;

  /// Run [body] with its service-endpoint connects relayed by this proxy.
  Future<T> run<T>(FutureOr<T> Function() body) async {
    if (_closed) throw StateError('Fault proxy is closed');
    await (_directory ??= createPrivateTempDirectory(
      shortTestTempRoot,
      'of-proxy-',
    ));
    final outer = Zone.current;
    return IOOverrides.runZoned<Future<T>>(
      () async => body(),
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) {
        if (host is InternetAddress &&
            host.type == InternetAddressType.unix &&
            _endpoint(host.address)) {
          return outer.run(() => _connect(host, port, timeout));
        }
        return outer.run(
          () => Socket.connect(
            host,
            port,
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
            timeout: timeout,
          ),
        );
      },
    );
  }

  /// Hold the next matching frame until [ProxyHold.release].
  ProxyHold hold(
    ProxyDirection direction, {
    String? method,
    int? id,
    String? event,
    bool Function(ServiceFrame frame)? where,
  }) {
    final gate = ProxyHold._();
    _rules.add(
      _Rule(direction, _match(method, id, event, where), _Action.hold, gate),
    );
    return gate;
  }

  /// Forward only the first [keepBytes] bytes of the next matching frame,
  /// never its newline, then half-close that direction. Later bytes in that
  /// direction are discarded, so the receiver sees a partial frame and EOF.
  Future<ServiceFrame> truncate(
    ProxyDirection direction, {
    required int keepBytes,
    String? method,
    int? id,
    String? event,
    bool Function(ServiceFrame frame)? where,
  }) {
    if (keepBytes < 0) throw ArgumentError.value(keepBytes, 'keepBytes');
    final rule = _Rule(
      direction,
      _match(method, id, event, where),
      _Action.truncate,
      null,
      keepBytes: keepBytes,
    );
    _rules.add(rule);
    return rule.applied.future;
  }

  /// Discard the next matching frame and destroy its connection.
  Future<ServiceFrame> drop(
    ProxyDirection direction, {
    String? method,
    int? id,
    String? event,
    bool Function(ServiceFrame frame)? where,
  }) {
    final rule = _Rule(
      direction,
      _match(method, id, event, where),
      _Action.drop,
      null,
    );
    _rules.add(rule);
    return rule.applied.future;
  }

  /// Write [frame] now, ahead of any held frames, on [connection] or the
  /// newest open one. A String or Map gets a newline; bytes are sent as-is.
  void inject(
    ProxyDirection direction,
    Object frame, {
    ProxyConnection? connection,
  }) {
    final target =
        connection ??
        connections.lastWhere(
          (candidate) => !candidate._finished,
          orElse: () => throw StateError('No open proxied connection'),
        );
    target.inject(direction, frame);
  }

  /// Completes when the [count]th matching frame from now is forwarded in
  /// full. Frames that passed before this call never count.
  Future<ServiceFrame> seen(
    ProxyDirection direction, {
    String? method,
    int? id,
    String? event,
    bool Function(ServiceFrame frame)? where,
    int count = 1,
  }) {
    if (count < 1) throw ArgumentError.value(count, 'count');
    final observer = _Observer(
      direction,
      _match(method, id, event, where),
      count,
    );
    _observers.add(observer);
    return observer.completer.future;
  }

  /// Completes at the [count]th connect attempt from now; [refused] filters
  /// by outcome. A retry loop anchors on this instead of on elapsed time.
  Future<ProxyConnectAttempt> attempt({bool? refused, int count = 1}) {
    if (count < 1) throw ArgumentError.value(count, 'count');
    final observer = _AttemptObserver(refused, count);
    _attemptObservers.add(observer);
    return observer.completer.future;
  }

  /// Destroy every relayed connection and remove the relay directory.
  Future<void> close() async {
    _closed = true;
    for (final connection in connections) {
      connection.destroy();
    }
    await Future.wait(connections.map((connection) => connection.closed));
    final directory = await _directory;
    if (directory != null && directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  bool Function(ServiceFrame) _match(
    String? method,
    int? id,
    String? event,
    bool Function(ServiceFrame frame)? where,
  ) =>
      (frame) =>
          (method == null || frame.method == method) &&
          (id == null || frame.id == id) &&
          (event == null || frame.event == event) &&
          (where == null || where(frame));

  void _record(ProxyConnectAttempt attempt) {
    attempts.add(attempt);
    _attemptObservers.removeWhere((observer) {
      if (observer.refused != null && observer.refused != attempt.refused) {
        return false;
      }
      if (--observer.remaining > 0) return false;
      observer.completer.complete(attempt);
      return true;
    });
  }

  Future<Socket> _connect(
    InternetAddress address,
    int port,
    Duration? timeout,
  ) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(address, port, timeout: timeout);
    } catch (error) {
      // The caller sees exactly what it would have seen without the proxy.
      _record(ProxyConnectAttempt._(address.address, error, null));
      rethrow;
    }
    // Pair the caller with a private relay socket under a short path.
    final directory = (await _directory)!;
    final relayPath = '${directory.path}/${_relays++}.sock';
    final server = await ServerSocket.bind(
      InternetAddress(relayPath, type: InternetAddressType.unix),
      0,
    );
    final accepted = Completer<Socket>();
    final subscription = server.listen(accepted.complete);
    try {
      final client = await Socket.connect(
        InternetAddress(relayPath, type: InternetAddressType.unix),
        0,
      );
      final relay = await accepted.future;
      final connection = ProxyConnection._(
        this,
        connections.length,
        address.address,
        relay,
        upstream,
      );
      connections.add(connection);
      _record(ProxyConnectAttempt._(address.address, null, connection));
      return client;
    } catch (_) {
      upstream.destroy();
      rethrow;
    } finally {
      await subscription.cancel();
      await server.close();
    }
  }

  /// Returns true when the frame should be forwarded unchanged.
  Future<bool> _apply(ServiceFrame frame) async {
    final index = _rules.indexWhere(
      (rule) => rule.direction == frame.direction && rule.matches(frame),
    );
    if (index < 0) return true;
    final rule = _rules.removeAt(index);
    switch (rule.action) {
      case _Action.hold:
        rule.gate!._reached.complete(frame);
        await rule.gate!._released.future;
        return true;
      case _Action.truncate:
        await frame.connection._truncate(
          frame.direction,
          frame.bytes.sublist(0, min(frame.bytes.length, rule.keepBytes)),
        );
        rule.applied.complete(frame);
        return false;
      case _Action.drop:
        frame.connection.destroy();
        rule.applied.complete(frame);
        return false;
    }
  }

  void _forwarded(ServiceFrame frame) {
    _observers.removeWhere((observer) {
      if (observer.direction != frame.direction || !observer.matches(frame)) {
        return false;
      }
      if (--observer.remaining > 0) return false;
      observer.completer.complete(frame);
      return true;
    });
  }
}

/// One relayed client connection: caller side and real service side.
class ProxyConnection {
  ProxyConnection._(
    this._proxy,
    this.index,
    this.endpoint,
    this._client,
    this._service,
  ) {
    _pump(ProxyDirection.toService, _client, _service);
    _pump(ProxyDirection.toClient, _service, _client);
  }

  final ServiceFaultProxy _proxy;

  /// Position in [ServiceFaultProxy.connections].
  final int index;

  /// The service socket path the caller asked for.
  final String endpoint;
  final Socket _client;
  final Socket _service;
  final _methods = <int, String>{};
  final _stopped = <ProxyDirection>{};
  final _ended = <ProxyDirection>{};
  final _endings = {
    for (final direction in ProxyDirection.values) direction: Completer<void>(),
  };
  final _closed = Completer<void>();
  bool _finished = false;

  /// Completes when both directions have ended.
  Future<void> get closed => _closed.future;

  /// Completes when the sender in [direction] closed its side or the
  /// connection was destroyed: `toService` ends when the client closes.
  Future<void> ended(ProxyDirection direction) => _endings[direction]!.future;

  /// Write [frame] now in [direction]. A String or Map gets a newline.
  void inject(ProxyDirection direction, Object frame) {
    final bytes = switch (frame) {
      String text => [...utf8.encode(text), 10],
      Map<dynamic, dynamic> value => [...utf8.encode(jsonEncode(value)), 10],
      List<int> raw => raw,
      _ => throw ArgumentError.value(frame, 'frame'),
    };
    _write(_target(direction), bytes);
  }

  /// Destroy both sides, as a crashed peer would.
  void destroy() {
    _stopped.addAll(ProxyDirection.values);
    _client.destroy();
    _service.destroy();
    _finished = true;
    for (final ending in _endings.values) {
      if (!ending.isCompleted) ending.complete();
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  Socket _target(ProxyDirection direction) =>
      direction == ProxyDirection.toService ? _service : _client;

  void _write(Socket target, List<int> bytes) {
    try {
      target.add(bytes);
    } catch (_) {
      // The peer already went away; its side reports that on its own.
    }
  }

  Future<void> _truncate(ProxyDirection direction, List<int> kept) async {
    _stopped.add(direction);
    final target = _target(direction);
    _write(target, kept);
    try {
      await target.flush();
      await target.close();
    } catch (_) {
      /* The receiver already closed. */
    }
  }

  void _pump(ProxyDirection direction, Socket source, Socket target) {
    unawaited(target.done.catchError((Object _) {}));
    final partial = BytesBuilder(copy: false);
    var queue = Future<void>.value();
    void enqueue(Future<void> Function() step) {
      queue = queue.then((_) => step()).catchError((Object _) => destroy());
    }

    Future<void> deliver(ServiceFrame frame) async {
      if (_stopped.contains(direction)) return;
      if (!await _proxy._apply(frame) || _stopped.contains(direction)) return;
      _write(target, [...frame.bytes, 10]);
      _proxy._forwarded(frame);
    }

    source.listen(
      (chunk) {
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 10) continue;
          partial.add(Uint8List.sublistView(chunk, start, i));
          final bytes = partial.takeBytes();
          final json = ServiceFrame._object(bytes);
          // Log on arrival, so frames queued behind a hold are visible.
          final frame = ServiceFrame._(
            this,
            direction,
            bytes,
            json,
            _method(direction, json),
          );
          _proxy.frames.add(frame);
          enqueue(() => deliver(frame));
          start = i + 1;
        }
        if (start < chunk.length) {
          partial.add(Uint8List.sublistView(chunk, start));
        }
      },
      onError: (Object _) {
        if (!_endings[direction]!.isCompleted) _endings[direction]!.complete();
        enqueue(() async => destroy());
      },
      onDone: () {
        // The sender has closed, even if earlier frames are still held.
        if (!_endings[direction]!.isCompleted) _endings[direction]!.complete();
        enqueue(() async {
          // Preserve a real peer's partial frame and EOF exactly.
          final rest = partial.takeBytes();
          if (!_stopped.contains(direction)) {
            if (rest.isNotEmpty) _write(target, rest);
            try {
              await target.flush();
              await target.close();
            } catch (_) {
              /* The receiver already closed. */
            }
          }
          _ended.add(direction);
          if (_ended.length == ProxyDirection.values.length) destroy();
        });
      },
      cancelOnError: true,
    );
  }

  String? _method(ProxyDirection direction, Map<String, Object?>? json) {
    final id = json?['id'];
    if (id is! int) return null;
    final method = json!['method'];
    if (direction == ProxyDirection.toService && method is String) {
      _methods[id] = method;
    }
    return _methods[id];
  }
}

enum _Action { hold, truncate, drop }

class _Rule {
  _Rule(
    this.direction,
    this.matches,
    this.action,
    this.gate, {
    this.keepBytes = 0,
  });
  final ProxyDirection direction;
  final bool Function(ServiceFrame) matches;
  final _Action action;
  final ProxyHold? gate;
  final int keepBytes;
  final applied = Completer<ServiceFrame>();
}

class _Observer {
  _Observer(this.direction, this.matches, this.remaining);
  final ProxyDirection direction;
  final bool Function(ServiceFrame) matches;
  int remaining;
  final completer = Completer<ServiceFrame>();
}

class _AttemptObserver {
  _AttemptObserver(this.refused, this.remaining);
  final bool? refused;
  int remaining;
  final completer = Completer<ProxyConnectAttempt>();
}
