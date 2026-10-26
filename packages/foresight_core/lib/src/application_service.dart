import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:clock/clock.dart';
import 'application.dart';
import 'agent_access.dart';
import 'domain.dart';
import 'helper.dart';
import 'model_setup.dart';
import 'operations.dart';
import 'operation_requests.dart';
import 'operation_descriptor.dart';
import 'platform_services.dart';
import 'persistence/read_schema_guard.dart';
import 'profile_paths.dart';
import 'rpc_error.dart';
import 'service_admission.dart';
import 'service_diagnostics.dart';
import 'service_gates.dart';
import 'service_framing.dart';
import 'service_lifetime.dart';
import 'service_idle_shutdown.dart';
import 'service_message_writer.dart';
import 'service_operation_handlers.dart';
import 'service_resources.dart';
import 'service_ownership.dart';
import 'service_protocol.dart';
import 'service_socket.dart';
import 'service_startup.dart';
import 'store.dart';
import 'web_search.dart';
import 'unix_peer_identity.dart';
import 'operation_admission.dart';

const _outcomeUnknownMessage =
    'Application service stopped before this request finished; it may or may '
    'not have completed.';

class ApplicationService {
  final Domain domain;
  final Application application;
  late final AgentAccessGate access;
  final ServerSocket listener;
  final ServiceSocketBinding _binding;
  final String path;
  final RandomAccessFile lock;
  final InstallationLock? installationLock;
  final _clients = <Socket>{};
  final bool _internalWorker;
  final DesktopPeerVerifier _verifyDesktopPeer;
  final _verifiedDesktopClients = <Socket>{};
  late final _messages = ServiceMessageWriter(
    (client, id) => _cancel(client, id),
  );
  final _subscriptions = <Socket, Map<int, StreamSubscription<Object?>>>{};
  final _controlCalls = <Socket, Map<int, Object>>{};
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _captureLevels;
  Timer? _heartbeat;
  Timer? _pendingBroadcast;
  late String _broadcastEpoch;
  final _ledger = ServiceRequestLedger();
  final _desktopClients = <Socket>{};
  Timer? _lifetime;
  final DateTime _started;
  DateTime? lastAgentActivity;
  DateTime? lastDesktopDeparture;
  Duration _desktopDetachGrace = const Duration(seconds: 1);
  bool _closing = false;
  double _lastIdleMinutes = 30;
  bool _schemaReadsRetired = false;
  int get dispatchedCount => _ledger.dispatchedCount;
  bool get desktopShutdownScheduled =>
      lastDesktopDeparture != null && !_closing;
  bool get _agentWorkInFlight => _ledger.agentWorkInFlight;
  Map<Socket, Map<int, ServiceRequestLease>> get _leases => _ledger.leases;
  double get _idleMinutes {
    if (!_schemaReadsRetired) {
      try {
        final value =
            double.tryParse(
              domain.store.preference('serviceIdleMinutes', '30'),
            ) ??
            30;
        _lastIdleMinutes = !value.isFinite || value <= 0 ? 0 : value;
      } on IncompatibleReadSchema {
        // Retire unsupported storage reads while request errors and shutdown
        // settle. The last verified policy still governs this service owner.
        _retireSchemaReads();
      }
    }
    return _lastIdleMinutes;
  }

  void _retireSchemaReads() {
    _schemaReadsRetired = true;
    _heartbeat?.cancel();
    _pendingBroadcast?.cancel();
    _pendingBroadcast = null;
  }

  ServiceLifetimeSnapshot get _lifetimeSnapshot => ServiceLifetimeSnapshot(
    started: _started,
    lastAgentActivity: lastAgentActivity,
    lastDesktopDeparture: lastDesktopDeparture,
    idleMinutes: _idleMinutes,
    desktopDetachGrace: _desktopDetachGrace,
    pinned: _desktopClients.isNotEmpty || access.hasHost,
    busy:
        _ledger.operationsBusy ||
        application.recording != null ||
        application.backgroundBusy,
    agentWorkInFlight: _agentWorkInFlight,
    mutating: domain.mutating,
    closing: _closing,
  );

  void _exitIfIdle() {
    _lifetime?.cancel();
    _lifetime = null;
    if (_closing) return;
    final now = domain.clock.now();
    final state = _lifetimeSnapshot;
    if (state.shouldExit(now)) {
      unawaited(
        close().catchError((Object error) {
          stderr.writeln('Automatic service exit: $error');
        }),
      );
      return;
    }
    final after = state.exitAfter;
    var delay = const Duration(seconds: 30);
    if (after != null && after.isAfter(now) && after.difference(now) < delay) {
      delay = after.difference(now);
    }
    _lifetime = domain.createTimer(delay, _exitIfIdle);
  }

  void _dispatch(ServiceRequestLease lease) {
    if (!_ledger.dispatch(lease)) return;
    if (lease.agent &&
        !lease.cancelled &&
        lease.operation.descriptor.stampsAgentActivity) {
      lastAgentActivity = domain.clock.now();
      lastDesktopDeparture = null;
    }
    _exitIfIdle();
  }

  void _settle(ServiceRequestLease lease) {
    if (!_ledger.settle(lease)) return;
    if (lease.agent && lease.operation.descriptor.stampsAgentActivity) {
      lastAgentActivity = domain.clock.now();
    }
    _exitIfIdle();
  }

  /// Test-only readiness barrier for helper-dependent operation fixtures.
  Future<void> get ready => _ready;
  Future<void>? _shutdown;
  void Function()? _onDraining;
  Future<void> Function()? _beforeReleaseOwnership;
  final _closed = Completer<void>();
  Future<void> get closed => _closed.future;
  int _connectionSequence = 0;
  Future<void> _ready = Future<void>.value();
  ApplicationService._(
    this.domain,
    this._binding,
    this.path,
    this.lock,
    this.installationLock,
    this.application,
    this._internalWorker,
    this._verifyDesktopPeer,
  ) : listener = _binding.listener,
      _started = domain.clock.now() {
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
      (host, event) => _messages.send(host as Socket, event),
      rotateToken: (next) {
        // Never expose a replacement token through a permissive staging file.
        final suffix = base64Url.encode(
          List<int>.generate(16, (_) => Random.secure().nextInt(256)),
        );
        final staging = File('${tokenFile.path}.$suffix.next');
        staging.createSync(exclusive: true);
        try {
          protectPrivateFile(staging.path);
          staging.writeAsStringSync(next);
          staging.renameSync(tokenFile.path);
        } finally {
          if (staging.existsSync()) staging.deleteSync();
        }
      },
    );
    _broadcastEpoch = domain.store.workspaceEpoch;
    _changes = application.changes.stream.listen((_) {
      _broadcast();
      _exitIfIdle();
    });
    _captureLevels = application.captureLevelChanges.stream.listen((_) {
      if (_closing) return;
      for (final client in _clients) {
        _messages.send(client, {
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

  /// Stop the timers and subscriptions of a service whose startup failed.
  void _discard() {
    _lifetime?.cancel();
    _heartbeat?.cancel();
    _pendingBroadcast?.cancel();
    unawaited(_changes?.cancel());
    unawaited(_captureLevels?.cancel());
  }

  /// [desktopDetachGrace] is how long the service waits for a desktop to
  /// reattach after its approval connection closes before it shuts down.
  /// An explicit [configuration], else the owner snapshot bound by
  /// [runWithRuntimeConfiguration], is captured once here and every
  /// service-owned consumer receives that immutable snapshot. Outside any
  /// owner scope, startup decisions use one boundary snapshot taken here while
  /// the long-lived owners stay legacy boundary consumers, as before injection.
  static Future<ApplicationService> start(
    ProfilePaths profile, {
    SearchCallbacks? webSearch,
    bool internalWorker = false,
    Duration desktopDetachGrace = const Duration(seconds: 1),
    Clock? clock,
    Timer Function(Duration, void Function())? createTimer,
    Duration? helperStartupProbeTimeout,
    void Function()? onDraining,
    Future<void> Function()? beforeReleaseOwnership,
    DesktopPeerVerifier? desktopPeerVerifier,
    void Function()? onProfileOwned,
    RuntimeConfiguration? configuration,
  }) async {
    final scoped = configuration == null ? currentOwnerRuntimeSnapshot : null;
    final captured = runtimeSnapshot(configuration);
    // This must precede native loads, database opens, and worker creation.
    final installationLock = acquireInstallationLock(configuration: captured);
    void Function()? releaseLocalOwner;
    try {
      releaseLocalOwner = retainLocalServiceOwner(profile.data);
      Future<ApplicationService> startOwned() => _start(
        profile,
        installationLock,
        captured,
        injected: configuration != null || scoped != null,
        explicit: configuration != null,
        webSearch: webSearch,
        internalWorker: internalWorker,
        clock: clock,
        createTimer: createTimer,
        helperStartupProbeTimeout: helperStartupProbeTimeout,
        desktopPeerVerifier: desktopPeerVerifier,
        onProfileOwned: onProfileOwned,
      );
      // An explicit snapshot is also bound as this owner's scope, so the store,
      // its read worker and in-service defaults capture the same snapshot.
      final service = await (configuration == null
          ? startOwned()
          : runWithRuntimeConfiguration(captured, startOwned));
      service._desktopDetachGrace = desktopDetachGrace;
      service._onDraining = onDraining;
      service._beforeReleaseOwnership = beforeReleaseOwnership;
      unawaited(service.closed.whenComplete(releaseLocalOwner));
      return service;
    } catch (_) {
      releaseLocalOwner?.call();
      installationLock?.closeSync();
      rethrow;
    }
  }

  static Future<ApplicationService> _start(
    ProfilePaths profile,
    InstallationLock? installationLock,
    RuntimeConfiguration captured, {
    required bool injected,
    required bool explicit,
    SearchCallbacks? webSearch,
    bool internalWorker = false,
    Clock? clock,
    Timer Function(Duration, void Function())? createTimer,
    Duration? helperStartupProbeTimeout,
    DesktopPeerVerifier? desktopPeerVerifier,
    void Function()? onProfileOwned,
  }) async {
    final lock = await acquireServiceProfileLock(
      profile,
      launchWithdrawn: () =>
          serviceLaunchLeaseWithdrawn(profile, configuration: captured),
      // Unless the caller owns an explicit snapshot, the legacy boundary keeps
      // receiving profile defaults for callers outside the ports; this
      // service's own snapshot is derived below.
      configuration: explicit ? captured : null,
    );
    final owned = injected
        ? profileServiceConfiguration(profile, captured)
        : null;
    // Startup's own view, after the lock added any profile defaults.
    final configuration = owned ?? legacyRuntimeSnapshot();
    Store? store;
    Helper? helper;
    Application? startedApplication;
    ServiceSocketBinding? binding;
    final endpointRecord = File('${profile.data}/$serviceEndpointRecordName');
    final temporary = File('${endpointRecord.path}.$pid');
    // A predecessor's valid record names the runtime this attempt adopts. Keep
    // it if startup fails; remove only a record this attempt published itself.
    var adoptedRecord = false;
    var publishedRecord = false;
    String? claimed;
    try {
      onProfileOwned?.call();
      // This owner holds the profile lock; any endpoint record is a
      // predecessor's. Claim it before anything that can wait.
      claimed = claimServiceEndpointRecord(profile.data);
      if (serviceGatesEnabled) await serviceGate('start.locked');
      // Only an owner writes temporary records, so any left now are stale.
      serviceEndpointEntries(
        profile.data,
        serviceEndpointTemporary,
      ).forEach(deleteServiceEndpointEntry);
      // An unclean predecessor can leave a healthy helper at this endpoint.
      // Reuse that runtime until a clean shutdown releases its workers. An
      // invalid record names no usable runtime, so it is not adopted.
      final adopted = await adoptServiceProfileRuntime(profile, claimed);
      adoptedRecord = adopted.adopted;
      profile = adopted.profile;
      final path =
          '${profile.runtime}/${internalWorker ? 'worker' : 'application'}.sock';
      await clearStaleServiceSocket(path);
      sweepStaleSpeechAudio(profile.data);
      store = Store('${profile.data}/application.db');
      await store.verifyRegisteredModels(rejectInvalidRegistrations: true);
      store.meetingStore.interruptActiveCaptures();
      helper = Helper(
        '${profile.runtime}/helper.sock',
        '${profile.data}/helper',
        startupProbeTimeout:
            helperStartupProbeTimeout ?? const Duration(milliseconds: 400),
        configuration: owned,
      );
      final domain = Domain(
        store,
        helper,
        webSearch: webSearch,
        clock: clock,
        createTimer: createTimer,
        configuration: owned,
      );
      final application = Application(domain)..profileId = profile.identity;
      startedApplication = application;
      application.importPolicy = ImportPolicy(profile.data, () {
        final saved = store!.preference('importRoots', '[]');
        return (jsonDecode(saved) as List).cast<String>();
      });
      application.startBackground();
      binding = await ServiceSocketBinding.bind(path);
      temporary.writeAsStringSync(
        jsonEncode({'data': profile.data, 'runtime': profile.runtime}),
        flush: true,
      );
      if (Process.runSync('/bin/chmod', ['600', temporary.path]).exitCode !=
          0) {
        throw StateError('Cannot protect service endpoint record');
      }
      temporary.renameSync(endpointRecord.path);
      publishedRecord = true;
      // The published record names the adopted runtime, if any.
      deleteServiceEndpointEntry(claimed);
      final service = ApplicationService._(
        domain,
        binding,
        path,
        lock,
        installationLock,
        application,
        internalWorker,
        desktopPeerVerifier ??
            (owned == null
                ? verifyInstalledDesktopPeer
                : installedDesktopPeerVerifier(owned)),
      );
      try {
        await publishServiceSocket(binding, service._accept);
      } catch (_) {
        service._discard();
        rethrow;
      }
      final manifest = configuration['FORESIGHT_MODEL_MANIFEST'];
      if (manifest != null && File(manifest).existsSync()) {
        domain.initialize(
          registerInstalledModels(
            store,
            manifest,
            configuration: configuration,
          ).then<void>((_) {}),
        );
      }
      helper.changed = () {
        service._broadcast();
        service._exitIfIdle();
      };
      helper.onReady = () async {
        await domain.resume();
        await application.recoverMeetingIndexes();
      };
      service._ready = helper.start().catchError((Object e) {
        stderr.writeln('Helper startup: $e');
        service._broadcast();
      });
      service._exitIfIdle();
      return service;
    } catch (_) {
      await ServiceStartupResources(
        lock: lock,
        store: store,
        helper: helper,
        application: startedApplication,
        binding: binding,
        endpointRecord: endpointRecord,
        temporary: temporary,
        publishedRecord: publishedRecord,
        adoptedRecord: adoptedRecord,
        claimed: claimed,
      ).rollback();
      rethrow;
    }
  }

  void _broadcast() {
    if (_closing || _schemaReadsRetired) return;
    try {
      // Workspace replacement must retire old desktop views immediately.
      if (domain.store.workspaceEpoch != _broadcastEpoch) {
        _flushBroadcast();
        return;
      }
    } on IncompatibleReadSchema {
      _retireSchemaReads();
      return;
    }
    // Bound background progress traffic while retaining its latest snapshot.
    // Keeping the first deadline prevents a continuous producer from starving
    // presentation updates indefinitely.
    _pendingBroadcast ??= domain.createTimer(
      const Duration(milliseconds: 100),
      _flushBroadcast,
    );
  }

  void _flushBroadcast() {
    _pendingBroadcast?.cancel();
    _pendingBroadcast = null;
    if (_closing || _schemaReadsRetired) return;
    late final Map<String, Object?> message;
    try {
      message = {
        'event': 'changed',
        'capture': application.captureState,
        'model_asset_download': application.modelAssetDownloadState,
        'revision': domain.store.dataRevision,
        'sources_paused': domain.sourcesPaused,
        'generation': application.generationState,
        'web_search_available': domain.webSearchAvailable,
        'google': application.googleState,
        'helper': domain.helper.snapshot?.toProto3Json(),
        'helper_state': domain.helper.state,
        'workspace_epoch': domain.store.workspaceEpoch,
      };
      _broadcastEpoch = message['workspace_epoch']! as String;
    } on IncompatibleReadSchema {
      _retireSchemaReads();
      return;
    }
    for (final client in _clients) {
      _messages.send(client, message);
    }
  }

  void _accept(Socket client) {
    if (_internalWorker) {
      try {
        final peer = unixPeerIdentity(client);
        if (peer.pid != pid || peer.uid != effectiveUserId) {
          client.destroy();
          return;
        }
      } catch (_) {
        client.destroy();
        return;
      }
    } else if (_verifyDesktopPeer(client)) {
      _verifiedDesktopClients.add(client);
    }
    var needsFrontendIdentity = _internalWorker;
    traceServiceTransport(
      () => 'worker accept peer=${identityHashCode(client)}',
    );
    final conversation =
        'connection-$pid-${DateTime.now().microsecondsSinceEpoch}-${++_connectionSequence}';
    unawaited(client.done.catchError((Object _) {}));
    _clients.add(client);
    _subscriptions[client] = {};
    _controlCalls[client] = {};
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
            // A decoder may already hold additional frames when a preceding
            // duplicate closes this connection. None may acquire a new owner.
            if (!_clients.contains(client)) return;
            bytes = 0;
            int? responseId;
            try {
              final request = decodeServiceObject(line);
              if (needsFrontendIdentity) {
                needsFrontendIdentity = false;
                if (request['_frontend_peer'] is! Map) {
                  client.destroy();
                  return;
                }
                final peer = request['_frontend_peer'] as Map;
                if (peer['verified_desktop'] == true) {
                  _verifiedDesktopClients.add(client);
                }
                return;
              }
              traceServiceTransport(
                () =>
                    'worker request peer=${identityHashCode(client)} '
                    'id=${request['id']} method=${request['method']}',
              );
              if (request['cancel'] is int) {
                _cancel(client, request['cancel'] as int);
                return;
              }
              responseId = request['id'] is int ? request['id'] as int : null;
              // Check the wire id before operation/argument decoding too:
              // a malformed duplicate must not terminate the original call.
              if (responseId != null &&
                  (_leases[client]?.containsKey(responseId) == true ||
                      _subscriptions[client]?.containsKey(responseId) == true ||
                      _controlCalls[client]?.containsKey(responseId) == true)) {
                // No independent reply identity exists for the duplicate.
                // Retire the connection instead of sending an ambiguous done.
                _disconnect(client);
                return;
              }
              final envelope = ServiceCallEnvelope.decode(request);
              final id = envelope.id;
              if (_closing) {
                _messages.send(client, {
                  'id': id,
                  'error': serviceClosingRefusal().toJson(),
                  'done': true,
                });
                return;
              }
              final typed = envelope.decodeOperation(conversation);
              _enforceCapability(client, typed);
              // Bootstrap routes retain their historical no-lease/no-epoch
              // admission; ordinary and stream calls check epoch below.
              if (!typed.operation.descriptor.createsLease &&
                  typed is! ServiceStopIfIdleRequest) {
                try {
                  final result = _serviceHandlers
                      .registry(
                        ServiceRequestContext(
                          client,
                          id,
                          null,
                          _verifiedDesktopClients.contains(client),
                        ),
                      )
                      .invoke(typed);
                  if (result != true) {
                    throw StateError(
                      'Bootstrap handler must settle synchronously',
                    );
                  }
                  _messages.send(client, {
                    'id': id,
                    'result': true,
                    'done': true,
                  });
                } catch (e, stack) {
                  _messages.send(client, {
                    'id': id,
                    'error': requestFailure(e, stack).toJson(),
                    'done': true,
                  });
                }
                return;
              }
              if (typed is StatusRequest && typed.desktop) {
                // Reserve desktop lifetime atomically before its startup snapshot.
                // This authenticates liveness only: visible approvals still need
                // security.attach_desktop and its separate host assignment.
                if (!_verifiedDesktopClients.contains(client) ||
                    typed.token != access.desktopToken ||
                    access.desktopToken.isEmpty) {
                  _messages.send(client, {
                    'id': id,
                    'error': RpcError(
                      RpcErrorCode.denied,
                      'Invalid desktop capability',
                    ).toJson(),
                    'done': true,
                  });
                  return;
                }
                _desktopClients.add(client);
                lastDesktopDeparture = null;
                _exitIfIdle();
              }
              if ((_subscriptions[client]?.length ?? 0) +
                      (_controlCalls[client]?.length ?? 0) >=
                  32) {
                _messages.send(client, {
                  'id': id,
                  'error': RpcError(
                    RpcErrorCode.busy,
                    'Too many active requests',
                  ).toJson(),
                  'done': true,
                });
                return;
              }
              if (typed is ServiceStopIfIdleRequest) {
                final owner = Object();
                _controlCalls[client]![id] = owner;
                unawaited(
                  _serviceHandlers
                      .registry(ServiceRequestContext(client, id))
                      .dispatch(typed)
                      .whenComplete(() {
                        if (identical(_controlCalls[client]?[id], owner)) {
                          _controlCalls[client]?.remove(id);
                        }
                      }),
                );
                return;
              }
              _admitRequest(client, id, typed);
            } catch (e, stack) {
              _messages.send(client, {
                if (responseId != null) 'id': responseId,
                'error': requestFailure(e, stack).toJson(),
                'done': true,
              });
            }
          },
          onError: (Object _) => client.destroy(),
          onDone: () => _disconnect(client),
        );
  }

  void _disconnect(Socket client) {
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
    _controlCalls.remove(client);
    _verifiedDesktopClients.remove(client);
    for (final id in _leases[client]?.keys.toList() ?? <int>[]) {
      _cancel(client, id, reevaluate: false);
    }
    _leases.remove(client);
    for (final s
        in _subscriptions.remove(client)?.values ??
            <StreamSubscription<Object?>>[]) {
      unawaited(_cancelSubscription(s));
    }
    client.destroy();
    if (_desktopClients.remove(client)) {
      final now = domain.clock.now();
      if (_lifetimeSnapshot.shouldArmDesktopDeparture(now)) {
        lastDesktopDeparture = now;
      }
    }
    _exitIfIdle();
  }

  void _enforceCapability(Socket client, OperationRequest request) =>
      enforceOperationCapability(
        access,
        client,
        request,
        verifiedDesktop: _verifiedDesktopClients.contains(client),
        desktopPinned: _desktopClients.isNotEmpty,
      );

  /// Epoch/approval and lease creation stay one synchronous admission turn;
  /// stream/future completion settles the same dispatched producer ledger.
  void _admitRequest(Socket client, int id, OperationRequest typed) {
    final lease = ServiceRequestLease(
      typed.context.requestId!,
      typed.operation,
      agent: !_desktopClients.contains(client),
    );
    _leases[client]![id] = lease;
    lease.waiting = true;
    final results = Stream.fromFuture(
      Future.sync(() {
        // A request from a cleared workspace fails before it can
        // ask the desktop for approval.
        application.checkRequestWorkspaceEpoch(typed);
        if (typed.operation.descriptor.approval == ApprovalPolicy.overwrite &&
            !access.isHost(client)) {
          final before = replacementSnapshot(
            domain.store.contentHistory,
            typed,
          );
          lease.validateReplacement = () {
            if (replacementSnapshot(domain.store.contentHistory, typed) !=
                before) {
              throw RpcError(
                RpcErrorCode.cancelled,
                'Content changed while awaiting approval; retry to review the current revision',
              );
            }
          };
        }
        return access.authorize(
          client,
          lease.method,
          typed.rawArguments,
          current: () => !lease.cancelled,
          existingContent:
              replacementSnapshot(domain.store.contentHistory, typed) != null,
        );
      }),
    ).asyncExpand((_) => _results(client, typed, lease));
    bool ownsRequest() => identical(_leases[client]?[id], lease);
    void releaseRequest() {
      if (ownsRequest()) {
        _subscriptions[client]?.remove(id);
        _leases[client]?.remove(id);
      }
      if (lease.streamed) _settle(lease);
      _exitIfIdle();
    }

    _subscriptions[client]![id] = results.listen(
      (value) {
        if (ownsRequest()) {
          _messages.send(client, {'id': id, 'result': value, 'done': false});
        }
      },
      onError: (Object e, StackTrace stack) {
        if (!ownsRequest()) {
          releaseRequest();
          return;
        }
        if (typed.operation.descriptor.scope == OperationScope.service &&
            typed.operation.notifiesChanges) {
          _flushBroadcast();
        }
        _messages.send(client, {
          'id': id,
          'error': requestFailure(e, stack).toJson(),
          'done': true,
        });
        releaseRequest();
      },
      onDone: () {
        if (!ownsRequest()) {
          releaseRequest();
          return;
        }
        if (typed.operation.descriptor.scope == OperationScope.service &&
            typed.operation.notifiesChanges) {
          _flushBroadcast();
        }
        _messages.send(client, {'id': id, 'done': true});
        releaseRequest();
      },
      cancelOnError: true,
    );
  }

  /// Operations handled by this service's concrete typed dispatch table.
  Set<Operation> get registeredOperations =>
      _serviceHandlers.registry().operations;

  late final _serviceHandlers = ServiceOperationHandlers(
    access: access,
    desktopClients: _desktopClients,
    onAttached: () {
      lastDesktopDeparture = null;
      _exitIfIdle();
    },
    onDetached: _exitIfIdle,
    stopRecording: application.stopRecording,
    preference: domain.store.preference,
    setPreference: domain.store.setPreference,
    stopIfIdle: _stopIfIdle,
    answerResults: _answerResults,
    signInResults: _signInResults,
  );

  Stream<Object?> _answerResults(
    AnswerStreamRequest request,
    ServiceRequestLease lease,
  ) {
    lease.streamed = true;
    lease.helperWait = true;
    return Stream.fromFuture(_ready).asyncExpand((_) {
      if (lease.cancelled) {
        throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
      }
      _dispatch(lease);
      return (request.webSearch
          ? application.askWithWebInConversation
          : application.askInConversation)(
        request.question,
        request.context.conversation!,
        requestId: lease.id,
        meetingId: request.meetingId,
        current: () => !lease.cancelled,
      );
    });
  }

  Stream<Object?> _signInResults(
    ServiceRequestLease lease, {
    required bool addAccount,
  }) {
    lease.streamed = true;
    _dispatch(lease);
    return application.signIn(lease.id, addAccount: addAccount);
  }

  Stream<Object?> _results(
    Socket client,
    OperationRequest request,
    ServiceRequestLease lease,
  ) {
    if (lease.cancelled) {
      return Stream.error(
        RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      );
    }
    if (request.operation.descriptor.scope == OperationScope.service) {
      final result = _serviceHandlers
          .registry(ServiceRequestContext(client, 0, lease))
          .invoke(request);
      if (result is! Stream<Object?>) {
        throw RpcError(
          RpcErrorCode.internal,
          'Stream handler returned no stream',
        );
      }
      return result;
    }
    final work = _execute(request, lease);
    work.whenComplete(() => _settle(lease)).ignore();
    return Stream.fromFuture(work);
  }

  Future<void> _stopIfIdle(
    Socket client,
    int id,
    ServiceStopIfIdleRequest request,
  ) async {
    try {
      _enforceCapability(client, request);
      final guard = ServiceIdleShutdownGuard(
        configuration: domain.configuration,
        helper: domain.helper,
        recording: () => application.recording != null,
        operationsBusy: () => _ledger.operationsBusy,
        backgroundBusy: () => application.backgroundBusy,
      );
      guard.validateOwner(request);
      guard.checkBusy();
      final inspection = guard.inspectHelper();
      if (inspection != null) {
        guard.requireVerified(await inspection);
        if (_closing) throw serviceClosingRefusal();
        guard.checkBusy();
      }
      _enforceCapability(client, request);
      await close(acknowledgementClient: client);
      if (!domain.helper.shutdownVerified) {
        throw StateError(
          'Helper shutdown could not be verified. The application was not cleared for upgrade.',
        );
      }
      _messages.send(client, {
        'id': id,
        'result': {'stopped': true, 'shutdown_verified': true},
        'done': true,
      });
    } catch (error) {
      _messages.send(client, {
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
    OperationRequest request,
    ServiceRequestLease lease,
  ) async {
    final method = request.operation.wire;
    // Nothing has been dispatched yet, so these are closing refusals too.
    if (_closing) throw serviceClosingRefusal();
    if (request.operation.descriptor.requiresHelper) {
      lease.helperWait = true;
      await _ready;
    }
    if (_closing) throw serviceClosingRefusal();
    if (request.operation.descriptor.capability ==
            CapabilityPolicy.hostedRecording &&
        !access.hasVisibleHost) {
      throw RpcError(
        RpcErrorCode.denied,
        'Recording requires an open desktop indicator',
      );
    }
    if (lease.cancelled) {
      throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
    }
    try {
      lease.validateReplacement?.call();
    } on IncompatibleReadSchema catch (error) {
      _retireSchemaReads();
      throw error.rpcError;
    }
    _dispatch(lease);
    final Object? result;
    try {
      result = await application.callRequest(
        request,
        current: () => !lease.cancelled,
      );
    } finally {
      // Desktop commands synchronously consume the state after their reply.
      // Preserve event-before-reply even for a failed or held request.
      if (request.operation.notifiesChanges) _flushBroadcast();
    }
    // The operation has committed; a lifecycle test may hold its reply here.
    if (serviceGatesEnabled) await serviceGate('request.committed.$method');
    if (method == Operation.status.wire) {
      return {...result as Map, 'lifetime': _lifetimeSnapshot.toJson()};
    }
    return result;
  }

  void _cancel(Socket client, int id, {bool reevaluate = true}) {
    final lease = _leases[client]?.remove(id);
    if (lease != null) {
      lease.cancelled = true;
      domain.checkCancellations();
      if (lease.method == Operation.googleSignIn.wire ||
          lease.method == Operation.googleAddAccount.wire) {
        application.cancelSignIn(lease.id);
      }
      if (!application.cancelMeetingWorkflowRequest(lease.id) &&
          !application.cancelSummaryRequest(lease.id)) {
        domain.generator?.cancel(requestId: lease.id);
      }
    }
    final subscription = _subscriptions[client]?.remove(id);
    if (subscription != null) {
      unawaited(_cancelSubscription(subscription, lease));
    }
    if (reevaluate) _exitIfIdle();
  }

  Future<void> _cancelSubscription(
    StreamSubscription<Object?> subscription, [
    ServiceRequestLease? lease,
  ]) async {
    try {
      await subscription.cancel();
    } catch (error) {
      // Async generators can fail during cancellation cleanup. Keep that failure
      // scoped to the cancelled request rather than terminating the service.
      stderr.writeln('Request cancellation cleanup: $error');
    } finally {
      if (lease?.streamed ?? false) _settle(lease!);
      _exitIfIdle();
    }
  }

  Future<void> close({Socket? acknowledgementClient}) => _shutdown ??=
      _close(acknowledgementClient: acknowledgementClient).whenComplete(() {
        if (!_closed.isCompleted) _closed.complete();
      });

  Future<void> _close({Socket? acknowledgementClient}) async {
    _closing = true;
    _heartbeat?.cancel();
    _lifetime?.cancel();
    _pendingBroadcast?.cancel();
    domain.helper.onReady = null;
    // An isolated frontend refuses new connections from here on.
    _onDraining?.call();
    // Every request in flight gets a terminal frame before its lease is
    // cancelled. Nothing awaits before this loop, so no request can complete
    // in between: a client sees either its result or this error (SL-4). One
    // still waiting for approval or the helper was never dispatched, so it is
    // refused like a new request and may be sent to the next owner; any
    // other may have taken effect.
    final unknown = RpcError(
      RpcErrorCode.unavailable,
      _outcomeUnknownMessage,
      reason: RpcErrorReason.outcomeUnknown,
    ).toJson();
    final refused = serviceClosingRefusal().toJson();
    for (final client in _leases.keys.toList()) {
      final leases = _leases[client]!;
      for (final id in leases.keys.toList()) {
        _messages.send(client, {
          'id': id,
          'error': leases[id]!.waiting ? refused : unknown,
          'done': true,
        });
        _cancel(client, id);
      }
    }
    Object? failure;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        failure ??= error;
      }
    }

    // New requests are refused and in-flight leases cancelled from here.
    if (serviceGatesEnabled) await serviceGate('close.begin');
    // Every request that was in flight has been sent its terminal frame.
    if (serviceGatesEnabled) await serviceGate('close.leases_terminated');
    // Application.close synchronously rejects new business calls and cancels
    // background timers before its first await.
    await attempt(application.close);
    await attempt(() async {
      await _changes?.cancel();
      await _captureLevels?.cancel();
    });
    await attempt(domain.close);
    await attempt(domain.drain);
    await attempt(domain.helper.close);
    if (serviceGatesEnabled) await serviceGate('close.helper_closed');
    // Stop accepting first, so every connection is flushed and closed below.
    await attempt(listener.close);
    // Deliver terminal frames and closing refusals before the connections
    // close, but never let a client that stopped reading hold shutdown.
    final peers = [
      for (final client in _clients)
        if (client != acknowledgementClient) client,
    ];
    await Future.wait([
      for (final peer in peers) flushServiceSocketQuietly(peer),
    ]).timeout(serviceClosingFlushBound, onTimeout: () => const []);
    for (final peer in peers) {
      peer.destroy();
    }
    if (serviceGatesEnabled) await serviceGate('close.listener_closed');
    await attempt(domain.store.close);
    // The listener is closed, so another profile's owner sharing this runtime
    // may have published at this path since; remove only this socket (S3).
    await attempt(_binding.unpublish);
    if (serviceGatesEnabled) await serviceGate('close.before_frontend_release');
    await attempt(() async {
      await _beforeReleaseOwnership?.call();
    });
    // The record outlives every socket of this owner: worker socket, public
    // socket, record, then lock. A record therefore always means its owner is
    // live, draining or crashed (SL-3).
    await attempt(() async {
      final endpoint = File(
        '${File(domain.store.path).parent.path}/.application-endpoint.json',
      );
      if (serviceGatesEnabled) {
        await serviceGate('close.before_record_delete');
      }
      if (domain.helper.shutdownVerified &&
          failure == null &&
          endpoint.existsSync()) {
        endpoint.deleteSync();
      }
    });
    if (serviceGatesEnabled) await serviceGate('close.before_lock_release');
    await attempt(lock.closeSync);
    await attempt(() => installationLock?.closeSync());
    if (failure != null) {
      throw StateError('Application shutdown failed: $failure');
    }
  }
}
