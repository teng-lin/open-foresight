import 'application.dart';
import 'rpc_error.dart';
import 'operations.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'agent_access.dart';
import 'domain.dart';
import 'web_search.dart';
import 'helper.dart';
import 'model_setup.dart';
import 'profile_paths.dart';
import 'store.dart';
import 'service_socket.dart';

const maxServiceMessage = 16 * 1024 * 1024;

void _traceServiceTransport(String message) {
  if (runtimeConfiguration['FORESIGHT_SERVICE_TRACE'] == '1') {
    final bounded = message.length > 16384
        ? message.substring(0, 16384)
        : message;
    stderr.writeln(
      'Service transport $pid ${DateTime.now().toIso8601String()} $bounded',
    );
  }
}

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
  final int _maxMessageBytes;
  final _methods = <int, String>{};
  final _requestIds = <int, String>{};
  final _pending = <int, StreamController<Map<String, dynamic>>>{};
  final events = StreamController<Map<String, dynamic>>.broadcast();
  int _next = 0;
  bool _closed = false;
  bool get isClosed => _closed;
  ServiceClient._(this.socket, this._maxMessageBytes) {
    unawaited(socket.done.catchError((Object _) {}));
    var bytes = 0;
    socket
        .map((chunk) {
          bytes += chunk.length;
          if (bytes > _maxMessageBytes) {
            throw StateError('Service message too large');
          }
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
                _requestIds.remove(value['id']);
                unawaited(controller.close());
              }
            } catch (e, st) {
              _fail(e, st);
            }
          },
          onError: (Object e, StackTrace st) => _fail(e, st),
          onDone: () => _fail(
            RpcError(
              RpcErrorCode.unavailable,
              'Application service disconnected',
            ),
            StackTrace.current,
          ),
        );
  }

  /// Bound each reply frame; the default matches the service's 16 MiB limit.
  static Future<ServiceClient> connect(
    String path, {
    int maxMessageBytes = maxServiceMessage,
  }) async {
    if (maxMessageBytes < 1) {
      throw ArgumentError.value(maxMessageBytes, 'maxMessageBytes');
    }
    return ServiceClient._(
      await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 2),
      ),
      maxMessageBytes,
    );
  }

  void _fail(Object error, StackTrace st) {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      c.addError(error, st);
      unawaited(c.close());
    }
    _pending.clear();
    _methods.clear();
    _requestIds.clear();
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
        _requestIds.remove(id);
        if (_pending.remove(id) != null && !_closed) {
          socket.writeln(jsonEncode({'cancel': id}));
        }
      },
    );
    if (_closed) {
      controller.addError(
        RpcError(RpcErrorCode.unavailable, 'Application service disconnected'),
      );
      unawaited(controller.close());
    } else {
      _pending[id] = controller;
      _methods[id] = method;
      if (args['requestId'] is String) {
        _requestIds[id] = args['requestId'] as String;
      }
      socket.writeln(jsonEncode({'id': id, 'method': method, 'args': args}));
    }
    return controller.stream
        .where((v) => v.containsKey('result') || v.containsKey('error'))
        .map((v) {
          if (v['error'] != null) throw RpcError.from(v['error'] as Object);
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

  bool cancelAnswers({String? requestId}) {
    final ids = _methods.entries
        .where(
          (entry) =>
              {
                Operation.answerStream.wire,
                Operation.answer.wire,
                Operation.meetingsGenerate.wire,
                Operation.meetingsEnhance.wire,
              }.contains(entry.value) &&
              (requestId == null || _requestIds[entry.key] == requestId),
        )
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      socket.writeln(jsonEncode({'cancel': id}));
      final pending = _pending.remove(id);
      _methods.remove(id);
      _requestIds.remove(id);
      pending?.addError(RpcError(RpcErrorCode.cancelled, 'Answer cancelled'));
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
  final Application application;
  late final AgentAccessGate access;
  final ServerSocket listener;
  final String path;
  final RandomAccessFile lock;
  final RandomAccessFile? installationLock;
  final _clients = <Socket>{};
  final _leases = <Socket, Map<int, _RequestLease>>{};
  final _subscriptions = <Socket, Map<int, StreamSubscription<Object?>>>{};
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _captureLevels;
  Timer? _heartbeat;
  bool _closing = false;
  Future<void>? _shutdown;
  Future<void> Function()? _beforeReleaseOwnership;
  final _closed = Completer<void>();
  Future<void> get closed => _closed.future;
  int _connectionSequence = 0;
  Future<void> _ready = Future<void>.value();
  ApplicationService._(
    this.domain,
    ServiceSocketBinding binding,
    this.path,
    this.lock,
    this.installationLock,
    this.application,
  ) : listener = binding.listener {
    final token = base64Url.encode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final tokenFile = File(
      '${File(domain.store.path).parent.path}/.desktop-capability',
    );
    if (FileSystemEntity.typeSync(tokenFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Desktop capability must not be a symbolic link');
    }
    tokenFile.writeAsStringSync(token);
    if (Process.runSync('/bin/chmod', ['600', tokenFile.path]).exitCode != 0) {
      throw StateError('Cannot protect desktop capability');
    }
    access = AgentAccessGate(
      token,
      (host, event) => _send(host as Socket, event),
    );
    binding.publish(_accept);
    _changes = application.changes.stream.listen((_) => _broadcast());
    _captureLevels = application.captureLevelChanges.stream.listen((_) {
      if (_closing) return;
      for (final client in _clients) {
        _send(client, {
          'event': 'capture_levels',
          'volumes': application.recording?.currentVolumes ?? <double>[],
        });
      }
    });
    _heartbeat = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _broadcast(),
    );
  }
  static Future<ApplicationService> start(
    ProfilePaths profile, {
    SearchCallbacks? webSearch,
    bool internalWorker = false,
  }) async {
    // This must precede native loads, database opens, and worker creation.
    final installationLock = acquireInstallationLock();
    try {
      return await _start(
        profile,
        installationLock,
        webSearch: webSearch,
        internalWorker: internalWorker,
      );
    } catch (_) {
      installationLock?.closeSync();
      rethrow;
    }
  }

  static Future<ApplicationService> _start(
    ProfilePaths profile,
    RandomAccessFile? installationLock, {
    SearchCallbacks? webSearch,
    bool internalWorker = false,
  }) async {
    privateDirectory(profile.data);
    // Configure native state only when a native installation is present. Tests
    // and administration may use the storage-only service without model workers.
    if (runtimeConfiguration['FORESIGHT_NATIVE'] != null) {
      configureProfileRuntime(profile.data);
    }
    privateDirectory(profile.runtime);
    var path = '${profile.runtime}/application.sock';
    final lock = File(
      '${profile.data}/.application.lock',
    ).openSync(mode: FileMode.append);
    try {
      if (Process.runSync('/bin/chmod', [
            '600',
            '${profile.data}/.application.lock',
          ]).exitCode !=
          0) {
        throw StateError('Cannot protect profile ownership lock');
      }
      lock.lockSync(FileLock.exclusive);
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
    Store? store;
    Helper? helper;
    ServiceSocketBinding? binding;
    try {
      // An unclean predecessor can leave a healthy helper at this endpoint.
      // Reuse that runtime until a clean shutdown releases its workers.
      path = serviceEndpoint(profile);
      profile = ProfilePaths(profile.data, File(path).parent.path);
      // Every supported public socket path must also fit the private endpoint.
      if (internalWorker) path = '${profile.runtime}/worker.sock';
      final stale = File(path);
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
        stale.deleteSync();
      }
      sweepStaleSpeechAudio(profile.data);
      store = Store('${profile.data}/application.db');
      await store.verifyRegisteredModels(rejectInvalidRegistrations: true);
      final interrupted = store
          .rows(
            "SELECT id FROM meetings WHERE state IN ('recording','transcribing','paused')",
          )
          .map((row) => row['id'] as int)
          .toList();
      store.db.execute(
        "UPDATE meetings SET state='interrupted' WHERE state IN ('recording','transcribing','paused')",
      );
      helper = Helper(
        '${profile.runtime}/helper.sock',
        '${profile.data}/helper',
      );
      final domain = Domain(store, helper, webSearch: webSearch);
      final application = Application(domain);
      application.importPolicy = ImportPolicy(profile.data, () {
        final saved = store!.preference('importRoots', '[]');
        return (jsonDecode(saved) as List).cast<String>();
      });
      application.startBackground();
      binding = await ServiceSocketBinding.bind(path);
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
      final service = ApplicationService._(
        domain,
        binding,
        path,
        lock,
        installationLock,
        application,
      );
      final manifest = runtimeConfiguration['FORESIGHT_MODEL_MANIFEST'];
      if (manifest != null && File(manifest).existsSync()) {
        domain.initialize(
          registerInstalledModels(store, manifest).then<void>((_) {}),
        );
      }
      helper.changed = service._broadcast;
      helper.onReady = () async {
        await domain.resume();
        for (final id in interrupted.toList()) {
          try {
            await application.indexMeeting(id);
            interrupted.remove(id);
          } catch (error) {
            stderr.writeln('Interrupted meeting indexing: $error');
          }
        }
      };
      service._ready = helper.start().catchError((Object e) {
        stderr.writeln('Helper startup: $e');
        service._broadcast();
      });
      return service;
    } catch (_) {
      await binding?.listener.close();
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
        File(path).deleteSync();
      }
      await helper?.close();
      store?.close();
      lock.closeSync();
      rethrow;
    }
  }

  void _send(Socket client, Map<String, Object?> message) {
    try {
      _traceServiceTransport(
        'worker send peer=${identityHashCode(client)} id=${message['id']} '
        'event=${message['event']} done=${message['done']}',
      );
      client.writeln(jsonEncode(message));
    } catch (_) {
      client.destroy();
    }
  }

  void _broadcast() {
    if (_closing) return;
    final message = {
      'event': 'changed',
      'capture': application.captureState,
      'revision': domain.store.dataRevision,
      'sources_paused': domain.sourcesPaused,
      'generation': application.generationState,
      'web_search_available': domain.webSearchAvailable,
      'google': application.googleState,
      'helper': domain.helper.snapshot?.toProto3Json(),
      'helper_state': domain.helper.state,
    };
    for (final client in _clients) {
      _send(client, message);
    }
  }

  void _accept(Socket client) {
    _traceServiceTransport('worker accept peer=${identityHashCode(client)}');
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
              _traceServiceTransport(
                'worker request peer=${identityHashCode(client)} '
                'id=${request['id']} method=${request['method']}',
              );
              if (request['cancel'] is int) {
                _cancel(client, request['cancel'] as int);
                return;
              }
              final id = request['id'];
              if (id is! int ||
                  request['method'] is! String ||
                  request['args'] is! Map) {
                throw FormatException('Invalid request');
              }
              if (_closing) {
                _send(client, {
                  'id': id,
                  'error': RpcError(
                    RpcErrorCode.unavailable,
                    'Application service is shutting down; retry after it exits.',
                  ).toJson(),
                  'done': true,
                });
                return;
              }
              final method = request['method'] as String;
              final securityArgs = Map<String, dynamic>.from(
                request['args'] as Map,
              );
              if (method.startsWith('security.')) {
                try {
                  if (method == Operation.securityAttachDesktop.wire) {
                    access.attach(client, securityArgs['token'] as String);
                  } else if (method == Operation.securityDetachDesktop.wire) {
                    if (!access.isHost(client)) {
                      throw RpcError(
                        RpcErrorCode.denied,
                        'Not the desktop approval connection',
                      );
                    }
                    access.detach(client);
                    unawaited(
                      application.stopRecording().catchError((Object error) {
                        stderr.writeln(
                          'Stop recording on desktop detach: $error',
                        );
                      }),
                    );
                  } else if (method == Operation.securityDecide.wire) {
                    access.decide(
                      client,
                      securityArgs['approval_id'] as String,
                      securityArgs['allow'] == true,
                    );
                  } else if (method == Operation.securityAllowImportRoot.wire) {
                    if (!access.isHost(client)) {
                      throw RpcError(
                        RpcErrorCode.denied,
                        'Only the desktop can select import folders',
                      );
                    }
                    final root = Directory(
                      securityArgs['path'] as String,
                    ).resolveSymbolicLinksSync();
                    final roots =
                        (jsonDecode(
                                  domain.store.preference('importRoots', '[]'),
                                )
                                as List)
                            .cast<String>();
                    domain.store.setPreference(
                      'importRoots',
                      jsonEncode({...roots, root}.toList()),
                    );
                  } else {
                    throw StateError('Unknown security operation');
                  }
                  _send(client, {'id': id, 'result': true, 'done': true});
                } catch (e) {
                  _send(client, {
                    'id': id,
                    'error': RpcError.from(e).toJson(),
                    'done': true,
                  });
                }
                return;
              }
              if (request['method'] == Operation.serviceStopIfIdle.wire) {
                unawaited(
                  _stopIfIdle(
                    client,
                    id,
                    Map<String, dynamic>.from(request['args'] as Map),
                  ),
                );
                return;
              }
              if ((_subscriptions[client]?.length ?? 0) >= 32) {
                _send(client, {
                  'id': id,
                  'error': RpcError(
                    RpcErrorCode.busy,
                    'Too many active requests',
                  ).toJson(),
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
              final results = Stream.fromFuture(
                access.authorize(
                  client,
                  lease.method,
                  args,
                  current: () => !lease.cancelled,
                ),
              ).asyncExpand((_) => _results(client, args, lease));
              _subscriptions[client]![id] = results.listen(
                (value) =>
                    _send(client, {'id': id, 'result': value, 'done': false}),
                onError: (Object e) {
                  _send(client, {
                    'id': id,
                    'error': RpcError.from(e).toJson(),
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
              _send(client, {'error': RpcError.from(e).toJson(), 'done': true});
            }
          },
          onError: (Object _) => client.destroy(),
          onDone: () {
            final wasHost = access.isHost(client);
            access.detach(client);
            if (wasHost) {
              unawaited(
                application.stopRecording().catchError((Object e) {
                  stderr.writeln('Stop capture after desktop closed: $e');
                }),
              );
            }
            _clients.remove(client);
            for (final id in _leases[client]?.keys.toList() ?? <int>[]) {
              _cancel(client, id);
            }
            _leases.remove(client);
            for (final s
                in _subscriptions.remove(client)?.values ??
                    <StreamSubscription<Object?>>[]) {
              unawaited(_cancelSubscription(s));
            }
            client.destroy();
          },
        );
  }

  Stream<Object?> _results(
    Socket client,
    Map<String, dynamic> args,
    _RequestLease lease,
  ) {
    if (lease.cancelled) {
      return Stream.error(
        RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      );
    }
    if (lease.method == Operation.answerStream.wire) {
      return Stream.fromFuture(_ready).asyncExpand(
        (_) =>
            (args['web_search'] == true
            ? application.askWithWebInConversation
            : application.askInConversation)(
              args['question'] as String,
              args['conversation'] as String,
              requestId: lease.id,
              meetingId: args['meeting_id'] as int?,
              current: () => !lease.cancelled,
            ),
      );
    }
    if (lease.method == Operation.googleSignIn.wire) {
      return application.signIn(lease.id);
    }
    return Stream.fromFuture(_execute(lease.method, args, lease));
  }

  Future<void> _stopIfIdle(
    Socket client,
    int id,
    Map<String, dynamic> args,
  ) async {
    try {
      if ((args['expected_pid'] != null && args['expected_pid'] != pid) ||
          (args['installation_root'] != null &&
              args['installation_root'] != configuredInstallationRoot) ||
          (args['runtime_revision'] != null &&
              args['runtime_revision'] !=
                  runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'])) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Application service ownership changed before idle shutdown; retry without replacing the app.',
        );
      }
      final capture = application.captureState;
      if (capture['active'] == true || capture['finishing'] == true) {
        throw RpcError(
          RpcErrorCode.busy,
          'Recording is active or finalizing. Stop recording and wait for the final transcript before upgrading.',
        );
      }
      // The request callback and close's barrier execute without yielding. In
      // particular, a recording-start request awaiting helper/model readiness
      // must not slip between an idle status check and shutdown acceptance.
      if (_leases.values.any(
        (leases) =>
            leases.values.any((lease) => lease.method != Operation.status.wire),
      )) {
        throw RpcError(
          RpcErrorCode.busy,
          'Application operations are in progress. Retry the upgrade after they finish.',
        );
      }
      await close(acknowledgementClient: client);
      if (!domain.helper.shutdownVerified) {
        throw StateError(
          'Helper shutdown could not be verified. The application was not cleared for upgrade.',
        );
      }
      _send(client, {
        'id': id,
        'result': {'stopped': true, 'shutdown_verified': true},
        'done': true,
      });
    } catch (error) {
      _send(client, {
        'id': id,
        'error': RpcError.from(error).toJson(),
        'done': true,
      });
    }
    try {
      await client.flush();
    } catch (_) {
      /* Missing acknowledgement is failure for the caller. */
    }
    if (_closing) client.destroy();
  }

  Future<Object?> _execute(
    String method,
    Map<String, dynamic> args,
    _RequestLease lease,
  ) async {
    if (_closing) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Application service is shutting down',
      );
    }
    if (Operation.parse(method).requiresHelper) await _ready;
    if (_closing) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Application service is shutting down',
      );
    }
    if ((method == Operation.meetingsStart.wire ||
            method == Operation.meetingsResume.wire) &&
        !access.hasHost) {
      throw RpcError(
        RpcErrorCode.denied,
        'Recording requires an open desktop indicator',
      );
    }
    return application.call(method, args, current: () => !lease.cancelled);
  }

  void _cancel(Socket client, int id) {
    final lease = _leases[client]?.remove(id);
    if (lease != null) {
      lease.cancelled = true;
      if (lease.method == Operation.googleSignIn.wire) {
        application.cancelSignIn(lease.id);
      }
      domain.generator?.cancel(requestId: lease.id);
    }
    final subscription = _subscriptions[client]?.remove(id);
    if (subscription != null) unawaited(_cancelSubscription(subscription));
  }

  Future<void> _cancelSubscription(
    StreamSubscription<Object?> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (error) {
      // Async generators can fail during cancellation cleanup. Keep that failure
      // scoped to the cancelled request rather than terminating the service.
      stderr.writeln('Request cancellation cleanup: $error');
    }
  }

  Future<void> close({Socket? acknowledgementClient}) => _shutdown ??=
      _close(acknowledgementClient: acknowledgementClient).whenComplete(() {
        if (!_closed.isCompleted) _closed.complete();
      });

  Future<void> _close({Socket? acknowledgementClient}) async {
    _closing = true;
    _heartbeat?.cancel();
    Object? failure;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        failure ??= error;
      }
    }

    // Application.close synchronously rejects new business calls and cancels
    // background timers before its first await.
    await attempt(application.close);
    await attempt(() async {
      await _changes?.cancel();
      await _captureLevels?.cancel();
    });
    await attempt(domain.close);
    await attempt(() => domain.generator?.close());
    await attempt(domain.helper.close);
    for (final client in _clients.toList()) {
      if (client != acknowledgementClient) client.destroy();
    }
    await attempt(listener.close);
    await attempt(domain.store.close);
    await attempt(() {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
        File(path).deleteSync();
      }
      final endpoint = File(
        '${File(domain.store.path).parent.path}/.application-endpoint.json',
      );
      if (domain.helper.shutdownVerified &&
          failure == null &&
          endpoint.existsSync()) {
        endpoint.deleteSync();
      }
    });
    await attempt(() async {
      await _beforeReleaseOwnership?.call();
    });
    await attempt(lock.closeSync);
    await attempt(() => installationLock?.closeSync());
    if (failure != null) {
      throw StateError('Application shutdown failed: $failure');
    }
  }
}

/// Public socket transport lives on the main service isolate. The complete
/// Domain (SQLite connections, native handles, model ownership, approvals and
/// request leases) lives in one long-lived worker isolate. Byte streams preserve
/// multiplexed requests, events, cancellation and shutdown acknowledgements.
class IsolatedApplicationService {
  final String _dataPath;
  final ReceivePort _messages;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  final _peers = <Socket>{};
  final _bridges = <Future<void>>{};
  SendPort? _control;
  ServiceSocketBinding? _binding;
  Future<void>? _listening;
  bool _publicClosing = false;
  String? _publicPath;
  String? _workerPath;
  Object? _failure;
  bool _closing = false;
  Future<void>? _shutdown;
  Future<void>? _finishing;
  final _workerExited = Completer<void>();
  bool _publicRemoved = false;
  Future<void> get closed => _closed.future;
  IsolatedApplicationService._(
    this._dataPath,
    this._messages,
    this._errors,
    this._exits,
  );

  static Future<IsolatedApplicationService> start(ProfilePaths profile) async {
    final host = IsolatedApplicationService._(
      profile.data,
      ReceivePort(),
      ReceivePort(),
      ReceivePort(),
    );
    host._messages.listen(host._message);
    host._errors.listen((dynamic error) {
      _traceServiceTransport('worker uncaught error $error');
      host._failure = StateError('Application worker failed: $error');
      if (!host._ready.isCompleted) host._ready.completeError(host._failure!);
    });
    host._exits.listen((_) {
      _traceServiceTransport(
        'worker exit received failed=${host._failure != null}',
      );
      if (!host._workerExited.isCompleted) host._workerExited.complete();
      if (!host._ready.isCompleted) {
        host._ready.completeError(
          host._failure ??
              StateError('Application worker exited during startup'),
        );
      }
      unawaited(host._finish());
    });
    var spawned = false;
    try {
      await Isolate.spawn(
        _applicationServiceWorker,
        [
          host._messages.sendPort,
          profile.data,
          profile.runtime,
          Map<String, String>.from(runtimeConfiguration.environment),
          host._errors.sendPort,
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
    } else if (value.first == 'closing') {
      _traceServiceTransport('worker ownership closing received');
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
      _traceServiceTransport('worker failure received ${value[1]}');
      _failure = StateError(value[1] as String);
      if (!_ready.isCompleted) _ready.completeError(_failure!);
    }
  }

  Future<void> _listen() async {
    final path = _publicPath!;
    _traceServiceTransport('frontend bind $path');
    // The domain worker already holds both ownership locks. A competing
    // launcher cannot remove the live owner's socket or endpoint record.
    final stale = File(path);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      stale.deleteSync();
    }
    final binding = await ServiceSocketBinding.bind(path);
    _binding = binding;
    if (_publicClosing) {
      await binding.close();
      throw StateError('Service closed before socket publication');
    }
    binding.publish((client) {
      final bridge = _bridge(client);
      _bridges.add(bridge);
      unawaited(bridge.whenComplete(() => _bridges.remove(bridge)));
    });
    _traceServiceTransport('frontend listening');
  }

  Future<void> _bridge(Socket client) async {
    final peer = identityHashCode(client);
    _traceServiceTransport('frontend accept peer=$peer closing=$_closing');
    if (_closing) {
      client.destroy();
      return;
    }
    _peers.add(client);
    Socket? backend;
    try {
      _traceServiceTransport(
        'frontend backend connect peer=$peer $_workerPath',
      );
      backend = await Socket.connect(
        InternetAddress(_workerPath!, type: InternetAddressType.unix),
        0,
      );
      _traceServiceTransport('frontend backend connected peer=$peer');
      _peers.add(backend);
      if (_closing) {
        client.destroy();
        backend.destroy();
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
                _traceServiceTransport(
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
          _traceServiceTransport('frontend copy closed peer=$peer $direction');
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
      _traceServiceTransport('frontend bridge failed peer=$peer $error');
      client.destroy();
      backend?.destroy();
    } finally {
      _peers.remove(client);
      if (backend != null) _peers.remove(backend);
    }
  }

  Future<void> close() => _shutdown ??= () async {
    _traceServiceTransport('frontend close closing=$_closing');
    if (!_closing) {
      _closing = true;
      // An explicit stop must make cached clients observe EOF immediately.
      // Keep worker cleanup and ownership release independent of frontend pipes;
      // the worker-initiated idle-stop path still flushes its acknowledgement.
      for (final peer in _peers.toList()) {
        peer.destroy();
      }
      _control?.send('close');
    }
    await closed;
    if (_failure != null) throw _failure!;
  }();

  Future<void> _removePublicSocket({bool workerOwnsLock = false}) async {
    _traceServiceTransport('frontend remove socket owns_lock=$workerOwnsLock');
    _publicClosing = true;
    // Join startup before cleanup so a pending bind cannot publish afterwards.
    try {
      await _listening;
    } catch (_) {
      // Startup reports its original error through _ready.
    }
    await _binding?.close();
    _traceServiceTransport('frontend listener closed');
    if (_publicRemoved || _publicPath == null) return;
    RandomAccessFile? ownership;
    if (!workerOwnsLock) {
      // An unexpected worker exit may release its lock before this isolate
      // processes the exit message. A new process can already own the profile.
      // Reacquire ownership before touching its public socket path.
      try {
        _traceServiceTransport('frontend reacquiring ownership');
        ownership = await File(
          '$_dataPath/.application.lock',
        ).open(mode: FileMode.append);
        await ownership.lock(FileLock.exclusive);
        _traceServiceTransport('frontend ownership reacquired');
      } on FileSystemException {
        await ownership?.close();
        return;
      }
    }
    try {
      final path = File(_publicPath!);
      if (await path.exists()) await path.delete();
      _publicRemoved = true;
      _traceServiceTransport('frontend socket removed ${path.path}');
    } finally {
      await ownership?.close();
    }
  }

  Future<void> _finish() => _finishing ??= _finishOnce();
  Future<void> _finishOnce() async {
    _traceServiceTransport('frontend finish begin');
    if (_closed.isCompleted) return;
    _closing = true;
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
  // The guarded zone reports all asynchronous failures through the error port.
  // ignore: discarded_futures
  runZonedGuarded(() => _runApplicationServiceWorker(configuration), (
    error,
    stack,
  ) {
    stderr.writeln('Application worker asynchronous error: $error\n$stack');
    (configuration[4] as SendPort).send(['$error', '$stack']);
  });
}

Future<void> _runApplicationServiceWorker(List<Object?> configuration) async {
  final parent = configuration[0] as SendPort;
  runtimeConfiguration.environment
    ..clear()
    ..addAll((configuration[3] as Map).cast<String, String>());
  _traceServiceTransport('worker starting');
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
    service = await ApplicationService.start(profile, internalWorker: true);
    _traceServiceTransport('worker ready ${service.path}');
    service._beforeReleaseOwnership = () {
      parent.send(['closing']);
      return frontendClosed.future;
    };
    parent.send(['ready', service.path, serviceEndpoint(profile)]);
    await Future.any([stop.future, service.closed]);
    _traceServiceTransport('worker close begin');
    await service.close();
    _traceServiceTransport('worker close complete');
    // Let an idle-stop request flush its final acknowledgement after close.
    await Future<void>.delayed(Duration.zero);
  } catch (error, stack) {
    _traceServiceTransport('worker main failed $error\n$stack');
    parent.send(['failure', '$error\n$stack']);
    try {
      await service?.close();
    } catch (_) {}
  } finally {
    _traceServiceTransport('worker main finally');
    control.close();
  }
}

Future<ServiceClient> _connectCompatibleService(String path) async {
  final client = await ServiceClient.connect(path);
  if (runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'] != null) {
    try {
      validateServiceCompatibility(
        await client.call(Operation.status.wire) as Map,
      );
    } catch (_) {
      await client.close();
      rethrow;
    }
  }
  return client;
}

/// Start packaged services as applications through LaunchServices so macOS can
/// attribute protected operations to the service bundle. Installed TCC attribution
/// still requires an integration check.
/// Forward profile/runtime overrides explicitly; an agent host's unrelated
/// environment must not become command-line arguments or service configuration.
({String executable, List<String> arguments}) serviceLaunchCommand(
  String executable,
  Map<String, String> environment, {
  bool? macOS,
}) {
  if (macOS ?? Platform.isMacOS) {
    final canonical = File(executable).resolveSymbolicLinksSync();
    const executableMarker = '.app/Contents/MacOS/';
    final marker = canonical.lastIndexOf(executableMarker);
    if (marker >= 0 &&
        !canonical.substring(marker + executableMarker.length).contains('/')) {
      final bundle = canonical.substring(0, marker + 4);
      if (!File('$bundle/Contents/Info.plist').existsSync()) {
        throw StateError(
          'Application service bundle is missing Info.plist: $bundle',
        );
      }
      return (
        executable: '/usr/bin/open',
        arguments: [
          '-g',
          '-n',
          for (final entry in environment.entries)
            if (entry.key.startsWith('FORESIGHT_') ||
                entry.key == 'PYTHONPYCACHEPREFIX') ...[
              '--env',
              '${entry.key}=${entry.value}',
            ],
          bundle,
        ],
      );
    }
  }
  return (executable: executable, arguments: const []);
}

/// Attach first; competing launchers may race safely on the service's OS lock.
Future<ServiceClient> ensureService(ProfilePaths profile) async {
  var path = serviceEndpoint(profile);
  try {
    return await _connectCompatibleService(path);
  } on SocketException {
    /* launch */
  }
  privateDirectory(profile.data);
  privateDirectory(profile.runtime);
  final executable = runtimeConfiguration['FORESIGHT_SERVICE'];
  if (executable == null || !File(executable).existsSync()) {
    throw StateError(
      'Set FORESIGHT_SERVICE to the application-service executable',
    );
  }
  final environment = {
    ...runtimeConfiguration.environment,
    'FORESIGHT_DATA': profile.data,
    'FORESIGHT_RUNTIME': profile.runtime,
  };
  final launch = serviceLaunchCommand(executable, environment);
  String? startupLog;
  if (launch.executable == '/usr/bin/open') {
    startupLog = '${profile.runtime}/service-startup.log';
    if (FileSystemEntity.typeSync(startupLog, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError(
        'Service startup log must not be a symbolic link: $startupLog',
      );
    }
    File(startupLog).openSync(mode: FileMode.append).closeSync();
    final protect = await Process.run('/bin/chmod', ['600', startupLog]);
    if (protect.exitCode != 0) throw StateError('Cannot protect $startupLog');
    launch.arguments.insertAll(2, ['--stderr', startupLog]);
    final result = await Process.run(launch.executable, launch.arguments);
    if (result.exitCode != 0) {
      throw StateError(
        'LaunchServices could not start the application service: ${result.stderr}. See $startupLog.',
      );
    }
  } else {
    await Process.start(
      launch.executable,
      launch.arguments,
      mode: ProcessStartMode.detached,
      environment: environment,
    );
  }
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      path = serviceEndpoint(profile);
      return await _connectCompatibleService(path);
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError(
    startupLog == null
        ? 'Application service did not start. Run $executable directly to inspect the startup error.'
        : 'Application service did not start. Inspect $startupLog for startup diagnostics.',
  );
}
