import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'domain.dart';
import 'helper.dart';
import 'model_setup.dart';
import 'profile_paths.dart';
import 'store.dart';

const maxServiceMessage = 16 * 1024 * 1024;

/// The profile lock is independent of runtime overrides. An endpoint record lets
/// clients attach to that owner even when launched with a different runtime.
String serviceEndpoint(ProfilePaths profile) {
  privateDirectory(profile.data);
  final record = File('${profile.data}/.application-endpoint.json');
  if (FileSystemEntity.typeSync(record.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('Service endpoint record must not be a symbolic link');
  }
  if (record.existsSync()) {
    final value = jsonDecode(record.readAsStringSync()) as Map;
    if (value['data'] != profile.data || value['runtime'] is! String) {
      throw StateError('Invalid application service endpoint record');
    }
    final runtime = value['runtime'] as String;
    privateDirectory(runtime);
    return '$runtime/application.sock';
  }
  return '${profile.runtime}/application.sock';
}

/// Newline framed, multiplexed local RPC. No network listener is opened.
class ServiceClient {
  final Socket socket;
  final _methods = <int, String>{};
  final _pending = <int, StreamController<Map<String, dynamic>>>{};
  final events = StreamController<Map<String, dynamic>>.broadcast();
  int _next = 0;
  bool _closed = false;
  bool get isClosed => _closed;
  ServiceClient._(this.socket) {
    unawaited(socket.done.catchError((Object _) {}));
    var bytes = 0;
    socket
        .map((chunk) {
          bytes += chunk.length;
          if (bytes > maxServiceMessage)
            throw StateError('Service message too large');
          return chunk;
        })
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            bytes = 0;
            try {
              final value = jsonDecode(line) as Map<String, dynamic>;
              if (value['event'] != null) {
                events.add(value);
                return;
              }
              final controller = _pending[value['id']];
              if (controller == null) return;
              controller.add(value);
              if (value['done'] == true) {
                _pending.remove(value['id']);
                _methods.remove(value['id']);
                unawaited(controller.close());
              }
            } catch (e, st) {
              _fail(e, st);
            }
          },
          onError: (Object e, StackTrace st) => _fail(e, st),
          onDone: () => _fail(
            StateError('Application service disconnected'),
            StackTrace.current,
          ),
        );
  }
  static Future<ServiceClient> connect(String path) async => ServiceClient._(
    await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 2),
    ),
  );
  void _fail(Object error, StackTrace st) {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      c.addError(error, st);
      unawaited(c.close());
    }
    _pending.clear();
    _methods.clear();
    unawaited(events.close());
    socket.destroy();
  }

  Stream<Object?> stream(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    final id = ++_next;
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController(
      onCancel: () {
        _methods.remove(id);
        if (_pending.remove(id) != null && !_closed)
          socket.writeln(jsonEncode({'cancel': id}));
      },
    );
    if (_closed) {
      controller.addError(StateError('Application service disconnected'));
      unawaited(controller.close());
    } else {
      _pending[id] = controller;
      _methods[id] = method;
      socket.writeln(jsonEncode({'id': id, 'method': method, 'args': args}));
    }
    return controller.stream
        .where((v) => v.containsKey('result') || v.containsKey('error'))
        .map((v) {
          if (v['error'] != null) throw StateError(v['error'] as String);
          return v['result'];
        });
  }

  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    Object? result;
    await for (final value in stream(method, args)) {
      result = value;
    }
    return result;
  }

  bool cancelAnswers() {
    final ids = _methods.entries
        .where((e) => e.value == 'answer.stream')
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      socket.writeln(jsonEncode({'cancel': id}));
      final pending = _pending.remove(id);
      _methods.remove(id);
      pending?.addError(StateError('Answer cancelled'));
      if (pending != null) unawaited(pending.close());
    }
    return ids.isNotEmpty;
  }

  Future<void> close() async {
    _fail(StateError('Client closed'), StackTrace.current);
  }
}

/// Reattach on the next request after a disconnect; never replay a request
/// whose commit status is unknown.
class ServiceConnection {
  final ProfilePaths profile;
  ServiceClient? _client;
  Future<ServiceClient>? _connecting;
  bool _closed = false;
  ServiceConnection(this.profile);
  Future<ServiceClient> connect() async {
    if (_closed) throw StateError('Client closed');
    final current = _client;
    if (current != null && !current.isClosed) return current;
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<ServiceClient> _open() async {
    final client = await ensureService(profile);
    if (_closed) {
      await client.close();
      throw StateError('Client closed');
    }
    return _client = client;
  }

  Stream<Object?> stream(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async* {
    final client = await connect();
    yield* client.stream(method, args);
  }

  Future<void> close() async {
    _closed = true;
    await _client?.close();
  }
}

class _RequestLease {
  final String id;
  final String method;
  bool cancelled = false;
  _RequestLease(this.id, this.method);
}

class ApplicationService {
  final Domain domain;
  final ServerSocket listener;
  final String path;
  final RandomAccessFile lock;
  final _clients = <Socket>{};
  final _leases = <Socket, Map<int, _RequestLease>>{};
  final _subscriptions = <Socket, Map<int, StreamSubscription<Object?>>>{};
  StreamSubscription<void>? _changes;
  Timer? _heartbeat;
  bool _closing = false;
  int _connectionSequence = 0;
  Future<void> _ready = Future<void>.value();
  ApplicationService._(this.domain, this.listener, this.path, this.lock) {
    listener.listen(_accept);
    _changes = domain.application.changes.stream.listen((_) => _broadcast());
    _heartbeat = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _broadcast(),
    );
  }
  static Future<ApplicationService> start(ProfilePaths profile) async {
    privateDirectory(profile.data);
    // Configure native state only when a native installation is present. Tests
    // and administration may use the storage-only service without model workers.
    if (runtimeConfiguration['FORESIGHT_NATIVE'] != null)
      configureProfileRuntime(profile.data);
    privateDirectory(profile.runtime);
    final path = '${profile.runtime}/application.sock';
    final lock = File(
      '${profile.data}/.application.lock',
    ).openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
    Store? store;
    Helper? helper;
    ServerSocket? listener;
    try {
      final stale = File(path);
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound)
        stale.deleteSync();
      store = Store('${profile.data}/application.db');
      store.db.execute(
        "UPDATE meetings SET state='interrupted' WHERE state IN ('recording','transcribing')",
      );
      helper = Helper(
        '${profile.runtime}/helper.sock',
        '${profile.data}/helper',
      );
      final domain = Domain(store, helper);
      domain.application.startBackground();
      listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      if ((await Process.run('chmod', ['600', path])).exitCode != 0)
        throw StateError('Cannot protect application socket');
      final endpoint = File('${profile.data}/.application-endpoint.json');
      final temporary = File('${endpoint.path}.$pid');
      temporary.writeAsStringSync(
        jsonEncode({'data': profile.data, 'runtime': profile.runtime}),
      );
      if (Process.runSync('/bin/chmod', ['600', temporary.path]).exitCode !=
          0) {
        throw StateError('Cannot protect service endpoint record');
      }
      temporary.renameSync(endpoint.path);
      final service = ApplicationService._(domain, listener, path, lock);
      final manifest = runtimeConfiguration['FORESIGHT_MODEL_MANIFEST'];
      if (manifest != null && File(manifest).existsSync()) {
        domain.initialize(
          registerInstalledModels(store, manifest).then<void>((_) {}),
        );
      }
      helper.changed = service._broadcast;
      helper.onReady = domain.resume;
      service._ready = helper.start().catchError((Object e) {
        stderr.writeln('Helper startup: $e');
        service._broadcast();
      });
      return service;
    } catch (_) {
      await listener?.close();
      await helper?.close();
      store?.close();
      lock.closeSync();
      rethrow;
    }
  }

  void _send(Socket client, Map<String, Object?> message) {
    try {
      client.writeln(jsonEncode(message));
    } catch (_) {
      client.destroy();
    }
  }

  void _broadcast() {
    if (_closing) return;
    final message = {
      'event': 'changed',
      'capture': domain.application.captureState,
      'revision': domain.store.dataRevision,
      'sources_paused': domain.sourcesPaused,
      'generation': domain.application.generationState,
      'google': domain.application.googleState,
      'helper': domain.helper.snapshot?.toProto3Json(),
    };
    for (final client in _clients) {
      _send(client, message);
    }
  }

  void _accept(Socket client) {
    final conversation =
        'connection-$pid-${DateTime.now().microsecondsSinceEpoch}-${++_connectionSequence}';
    unawaited(client.done.catchError((Object _) {}));
    _clients.add(client);
    _subscriptions[client] = {};
    _leases[client] = {};
    var bytes = 0;
    client
        .map((chunk) {
          bytes += chunk.length;
          if (bytes > maxServiceMessage) throw StateError('Request too large');
          return chunk;
        })
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            bytes = 0;
            try {
              final request = jsonDecode(line) as Map<String, dynamic>;
              if (request['cancel'] is int) {
                _cancel(client, request['cancel'] as int);
                return;
              }
              final id = request['id'];
              if (id is! int ||
                  request['method'] is! String ||
                  request['args'] is! Map)
                throw FormatException('Invalid request');
              if ((_subscriptions[client]?.length ?? 0) >= 32) {
                _send(client, {
                  'id': id,
                  'error': 'Too many active requests',
                  'done': true,
                });
                return;
              }
              final args = Map<String, dynamic>.from(request['args'] as Map);
              args.putIfAbsent('conversation', () => conversation);
              final lease = _RequestLease(
                'rpc-$conversation-$id',
                request['method'] as String,
              );
              _leases[client]![id] = lease;
              args['requestId'] = lease.id;
              final Stream<Object?> results =
                  request['method'] == 'answer.stream'
                  ? Stream.fromFuture(_ready).asyncExpand(
                      (_) => domain.askInConversation(
                        args['question'] as String,
                        args['conversation'] as String,
                        requestId: lease.id,
                      ),
                    )
                  : request['method'] == 'google.sign_in'
                  ? domain.application.signIn(lease.id)
                  : Stream.fromFuture(
                      _execute(request['method'] as String, args, lease),
                    );
              _subscriptions[client]![id] = results.listen(
                (value) =>
                    _send(client, {'id': id, 'result': value, 'done': false}),
                onError: (Object e) {
                  _send(client, {
                    'id': id,
                    'error': e.toString(),
                    'done': true,
                  });
                  _subscriptions[client]?.remove(id);
                  _leases[client]?.remove(id);
                },
                onDone: () {
                  _send(client, {'id': id, 'done': true});
                  _subscriptions[client]?.remove(id);
                  _leases[client]?.remove(id);
                },
                cancelOnError: true,
              );
            } catch (e) {
              _send(client, {'error': e.toString(), 'done': true});
            }
          },
          onError: (Object _) => client.destroy(),
          onDone: () {
            _clients.remove(client);
            for (final id in _leases[client]?.keys.toList() ?? <int>[]) {
              _cancel(client, id);
            }
            _leases.remove(client);
            for (final s
                in _subscriptions.remove(client)?.values ??
                    <StreamSubscription<Object?>>[]) {
              unawaited(s.cancel());
            }
            client.destroy();
          },
        );
  }

  Future<Object?> _execute(
    String method,
    Map<String, dynamic> args,
    _RequestLease lease,
  ) async {
    if (!{
      'status',
      'audio.capabilities',
      'audio.request_microphone',
      'sources.list',
      'sources.get',
      'notes.list',
      'notes.save',
      'meetings.list',
      'meetings.get',
      'meetings.create',
      'meetings.notes',
      'preferences.set',
      'artifacts.edit',
      'google.status',
      'google.configure',
    }.contains(method))
      await _ready;
    return domain.application.call(
      method,
      args,
      current: () => !lease.cancelled,
    );
  }

  void _cancel(Socket client, int id) {
    final lease = _leases[client]?.remove(id);
    if (lease != null) {
      lease.cancelled = true;
      if (lease.method == 'google.sign_in')
        domain.application.cancelSignIn(lease.id);
      domain.generator?.cancel(requestId: lease.id);
    }
    unawaited(_subscriptions[client]?.remove(id)?.cancel());
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _heartbeat?.cancel();
    await _changes?.cancel();
    Object? failure;
    try {
      await domain.application.close();
    } catch (error) {
      failure = error;
    }
    domain.close();
    domain.generator?.close();
    await domain.helper.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    await listener.close();
    domain.store.close();
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound)
      File(path).deleteSync();
    lock.closeSync();
    if (failure != null)
      throw StateError('Application shutdown failed: $failure');
  }
}

/// Attach first; competing launchers may race safely on the service's OS lock.
Future<ServiceClient> ensureService(ProfilePaths profile) async {
  var path = serviceEndpoint(profile);
  try {
    return await ServiceClient.connect(path);
  } on SocketException {
    /* launch */
  }
  privateDirectory(profile.data);
  privateDirectory(profile.runtime);
  final executable = runtimeConfiguration['FORESIGHT_SERVICE'];
  if (executable == null || !File(executable).existsSync())
    throw StateError(
      'Set FORESIGHT_SERVICE to the application-service executable',
    );
  await Process.start(
    executable,
    const [],
    mode: ProcessStartMode.detached,
    environment: {
      ...runtimeConfiguration.environment,
      'FORESIGHT_DATA': profile.data,
      'FORESIGHT_RUNTIME': profile.runtime,
    },
  );
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      path = serviceEndpoint(profile);
      return await ServiceClient.connect(path);
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError(
    'Application service did not start. Run $executable directly to inspect the startup error.',
  );
}
