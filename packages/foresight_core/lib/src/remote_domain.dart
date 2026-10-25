import 'client_command.dart';
import 'client_requests.dart';
import 'operation_descriptors.dart';
import 'operation_requests/graph_inputs.dart';
import 'model_asset_status.dart';
import 'desktop_status.dart';
import 'cancellation.dart';
export 'recording_status.dart' show RemoteRecording;
import 'rpc_error.dart';
import 'operations.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' show min;
import 'remote_google.dart';
export 'remote_google.dart' show RemoteGoogleAuth, RemoteGoogleConnections;
import 'desktop_connection.dart';
import 'helper_status.dart';
import 'sqlite_store_reader.dart';
import 'store_reader.dart';
import 'persistence/read_schema_guard.dart';
import 'profile_paths.dart';
import 'service_client.dart';
import 'service_startup.dart';
import 'service_ownership.dart';
import 'service_socket.dart' show probeSocketPath;

/// Whether a failed request never took effect, so it may be sent once more
/// after a handoff: a closing owner refused it, or it was never sent.
bool _resendable(RpcError error) =>
    isClosingRefusal(error) || error.reason == RpcErrorReason.notSent;

/// Desktop facade: reads use SQLite WAL snapshots; all writes and workers are
/// delegated to the single application service. No migrations run in this client.
class RemoteDomain
    implements
        DesktopConnection,
        CaptureLevelEvents,
        RemoteGoogleOwner,
        ModelAssetProgressSource {
  @override
  ModelAssetDownloadPresentation modelAssetDownload =
      const ModelAssetDownloadPresentation();
  @override
  StoreReader get store => _reader;
  final SqliteStoreReader _reader;
  @override
  HelperStatus get helper => _helper.value;
  final _helper = _RemoteHelperState();
  final _changes = StreamController<void>.broadcast(sync: true);
  Future<void>? _closed;
  final _closedSignal = Completer<void>();
  @override
  Stream<void> get changes => _changes.stream;
  Object _clientSessionGeneration = Object();
  @override
  Object get clientSessionGeneration => _clientSessionGeneration;
  @override
  Future<void> initialize() async {
    if (_disposed) throw RpcError(RpcErrorCode.cancelled, 'Workspace closed');
    _notifyChanges();
  }

  void _notifyChanges() {
    if (_disposed) return;
    _changes.add(null);
  }

  @override
  DesktopModelAssets get modelAssets => DesktopModelAssets(
    generation: Directory('${_profile.data}/models/gemma4'),
    speech: Directory('${_profile.data}/models/whisper'),
  );
  @override
  GenerationStatus? generator;
  @override
  late final GoogleAccount googleAuth = RemoteGoogleAuth(this);
  @override
  late final ConnectedSources google = RemoteGoogleConnections(
    this,
    googleAuth,
  );
  ServiceClient client;
  @override
  final RemoteRuntime runtime;
  final ProfilePaths _profile;
  void Function(Map<String, dynamic>)? _approvalEvents;
  // The connection the desktop approval host is attached on.
  ServiceClient? _attached;
  bool _desktopVisible = false;
  bool? _attachedVisible;
  bool _desktopDisplaced = false;
  int _approvalGeneration = 0;
  final _attachments =
      <ServiceClient, ({int generation, Future<void> future})>{};
  final _visibilityUpdates =
      <ServiceClient, ({int generation, Future<void> future})>{};
  bool _approvalsCurrent(int generation) =>
      !_disposed &&
      _approvalEvents != null &&
      generation == _approvalGeneration;
  @override
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) events,
  ) async {
    _approvalEvents = events;
    final generation = _approvalGeneration;
    for (var attempt = 0; ; attempt++) {
      if (!_approvalsCurrent(generation)) return;
      final current = client;
      try {
        await _attachDesktop(current);
        return;
      } on RpcError catch (error) {
        if (!_approvalsCurrent(generation)) return;
        if (attempt > 0 || !_resendable(error)) rethrow;
        await _awaitReconnect(current, error);
      }
    }
  }

  Future<void> _attachDesktop(ServiceClient connection) async {
    final generation = _approvalGeneration;
    while (_approvalsCurrent(generation) && identical(client, connection)) {
      if (_desktopDisplaced && !_desktopVisible) return;
      if (identical(_attached, connection)) {
        await _syncDesktopVisibility(connection, generation);
        return;
      }
      // Reconnect and lifecycle callbacks share one token-consuming attach.
      final existing = _attachments[connection];
      if (existing != null) {
        try {
          await existing.future;
        } catch (_) {
          // A disabled host's request must settle before consuming a fresh
          // token, but its failure does not belong to the new host generation.
          if (existing.generation == generation) rethrow;
        }
        continue;
      }
      final pending = _performDesktopAttach(connection, generation);
      _attachments[connection] = (generation: generation, future: pending);
      try {
        await pending;
      } finally {
        if (identical(_attachments[connection]?.future, pending)) {
          _attachments.remove(connection);
        }
      }
    }
  }

  Future<void> _performDesktopAttach(
    ServiceClient connection,
    int generation,
  ) async {
    final visible = _desktopVisible;
    await connection.call(Operation.securityAttachDesktop.wire, {
      'token': File('${_profile.data}/.desktop-capability').readAsStringSync(),
      'visible': visible,
    });
    if (!_approvalsCurrent(generation) || !identical(client, connection)) {
      return;
    }
    _attached = connection;
    _attachedVisible = visible;
    _desktopDisplaced = false;
    await _syncDesktopVisibility(connection, generation);
  }

  Future<void> _syncDesktopVisibility(
    ServiceClient connection,
    int generation,
  ) async {
    while (_approvalsCurrent(generation) &&
        identical(_attached, connection) &&
        _attachedVisible != _desktopVisible) {
      final existing = _visibilityUpdates[connection];
      if (existing != null) {
        try {
          await existing.future;
        } catch (_) {
          if (existing.generation == generation) rethrow;
        }
        continue;
      }
      final visible = _desktopVisible;
      final pending = connection.call(
        Operation.securityDesktopVisibility.wire,
        {'visible': visible},
      );
      final update = pending.then<void>((_) {
        if (_approvalsCurrent(generation) && identical(_attached, connection)) {
          _attachedVisible = visible;
        }
      });
      _visibilityUpdates[connection] = (generation: generation, future: update);
      try {
        await update;
      } finally {
        if (identical(_visibilityUpdates[connection]?.future, update)) {
          _visibilityUpdates.remove(connection);
        }
      }
    }
  }

  @override
  Future<void> setDesktopVisible(bool visible) async {
    _desktopVisible = visible;
    if (_approvalEvents == null) return;
    final generation = _approvalGeneration;
    try {
      await enableDesktopApprovals(_approvalEvents!);
    } on RpcError catch (error) {
      if (error.code != RpcErrorCode.denied) rethrow;
      // Another verified desktop took the host while this window was hidden.
      // A newly visible verified window can take ownership with the fresh token.
      if (!_approvalsCurrent(generation)) return;
      _attached = null;
      _attachedVisible = null;
      _desktopDisplaced = true;
      if (!_desktopVisible) return;
      await enableDesktopApprovals(_approvalEvents!);
    }
  }

  @override
  Future<void> disableDesktopApprovals() async {
    // The service denies the approvals still open, but their
    // approval_closed would find no listener; close their dialogs first.
    _closeOpenApprovals();
    _approvalGeneration++;
    _approvalEvents = null;
    _attached = null;
    _attachedVisible = null;
    _desktopDisplaced = false;
    await client.call(Operation.securityDetachDesktop.wire);
  }

  bool _disposed = false;
  Future<void>? _reconnection;
  // Completes with the outcome of the current or next reconnect attempt.
  Completer<void>? _attempt;
  Map<String, dynamic> capture = {};
  @override
  CapturePresentation get capturePresentation =>
      CapturePresentation.fromWire(capture);
  @override
  GooglePresentation get googlePresentation =>
      GooglePresentation.fromWire(googleStatus);
  @override
  Map<String, dynamic> googleStatus = {};
  bool _paused = false;
  int _sourceControlRevision = 0;
  bool _webSearchAvailable = false;
  @override
  bool get webSearchAvailable => _webSearchAvailable;
  StreamSubscription<Map<String, dynamic>>? _events;
  StreamSubscription<void>? _readEvents;
  String? _workspaceEpoch, _serviceEpoch;

  /// An event or status names an epoch other than the current one. It can
  /// be late, from a connection a reconnect replaced, or predate a clear,
  /// so the profile's database decides which epoch is current: a late
  /// event must neither reset the views again nor take the epoch back.
  void _observeEpoch(String reported) {
    if (reported == _serviceEpoch) return;
    final stored = _storedEpoch();
    _serviceEpoch = stored.isEmpty ? reported : stored;
  }

  String _storedEpoch() {
    try {
      return store.workspaceEpoch;
    } on IncompatibleReadSchema {
      rethrow;
    } catch (_) {
      // A store that cannot be read, or is closed, leaves the service's word.
      return '';
    }
  }

  @override
  String? get workspaceEpoch => _workspaceEpoch;
  @override
  bool get workspaceReplaced =>
      _serviceEpoch != null && _serviceEpoch != _workspaceEpoch;
  @override
  void adoptWorkspace() => _workspaceEpoch = _serviceEpoch;
  RemoteDomain._(this._reader, this.client, this.runtime, this._profile) {
    _closedSignal.future.ignore();
    _readEvents = _reader.activityChanges.listen((_) {
      if (_disposed || _reader.failure == null) return;
      _helper.state = _reader.failure!.message;
      _notifyChanges();
    });
    runtime.onCancel = (requestId) =>
        _cancellations[requestId] = ++_cancellationSequence;
    _listen();
  }
  // The sequence number of the latest cancel for each request ID, or of all
  // answers under null. A cancel during a handoff must stop the resend.
  final _cancellations = <String?, int>{};
  int _cancellationSequence = 0;
  final _captureLevels = StreamController<List<double>>.broadcast();
  @override
  Stream<List<double>> get captureLevels => _captureLevels.stream;
  String? _eventSignature;
  Object? _dataRevision;
  Object? _readerSessionGeneration;
  void _apply(Map<String, dynamic> event, {bool forceNotify = false}) {
    if (event['event'] == 'capture_levels') {
      final volumes = (event['volumes'] as List)
          .map((n) => (n as num).toDouble())
          .toList();
      modelAssetDownload = ModelAssetDownloadPresentation.fromWire(
        event['model_asset_download'],
      );
      capture = {...capture, 'volumes': volumes};
      _captureLevels.add(volumes);
      return;
    }
    if (event['event'] == 'approval' || event['event'] == 'approval_closed') {
      final id = event['approval_id'];
      if (id is String && event['event'] == 'approval') {
        _openApprovals.add(id);
      } else {
        _openApprovals.remove(id);
      }
      _approvalEvents?.call(event);
      return;
    }
    _reader.validateSchema();
    final signature = jsonEncode(event);
    if (_eventSignature == signature && !forceNotify) return;
    _eventSignature = signature;
    final previousEpoch = _serviceEpoch;
    final epoch = event['workspace_epoch'];
    if (epoch is String) {
      _observeEpoch(epoch);
      // The first epoch names the workspace the desktop starts in. A later one
      // waits for the desktop to drop views that hold older IDs.
      _workspaceEpoch ??= _serviceEpoch;
    }
    final revision = event['revision'];
    if (_dataRevision != revision ||
        previousEpoch != _serviceEpoch ||
        !identical(_readerSessionGeneration, _clientSessionGeneration)) {
      _dataRevision = revision;
      _readerSessionGeneration = _clientSessionGeneration;
      _reader.invalidate();
    }
    _webSearchAvailable = event['web_search_available'] == true;
    googleStatus = Map<String, dynamic>.from(event['google'] as Map? ?? {});
    capture = Map<String, dynamic>.from(event['capture'] as Map? ?? {});
    _paused = event['sources_paused'] == true;
    _sourceControlRevision++;
    runtime.state = Map<String, dynamic>.from(
      event['generation'] as Map? ?? {},
    );
    generator = runtime.state.isEmpty ? null : runtime;
    _helper.snapshot = event['helper'] == null
        ? null
        : HelperStatus.fromEvent(event).snapshot;
    _helper.state =
        event['helper_state'] as String? ??
        (_helper.snapshot == null ? 'disconnected' : 'live (service)');
    _notifyChanges();
  }

  /// Events a connection sends before it is listened to are lost, and its
  /// startup status can predate a clear among them. The profile already
  /// holds that clear's epoch, so read it once the connection is listened to.
  void _recheckWorkspace() {
    final stored = _storedEpoch();
    if (stored.isEmpty || stored == _serviceEpoch) return;
    _serviceEpoch = stored;
    _workspaceEpoch ??= stored;
    _reader.invalidate();
    _notifyChanges();
  }

  // Approvals shown for the current connection that have not closed yet.
  final _openApprovals = <String>{};

  /// The service denies a lost connection's approvals, but their
  /// approval_closed can no longer arrive. Close their dialogs here.
  void _closeOpenApprovals() {
    for (final id in _openApprovals.toList()) {
      _apply({'event': 'approval_closed', 'approval_id': id});
    }
  }

  void _listen() {
    final connection = client;
    _events = connection.events.stream.listen(
      (event) {
        try {
          _apply(event);
        } on IncompatibleReadSchema catch (error) {
          _helper.state = error.rpcError.message;
          _notifyChanges();
        }
      },
      onDone: () {
        _closeOpenApprovals();
        // A connection already replaced needs no second reconnect.
        if (!_disposed && identical(client, connection)) {
          unawaited(_reconnect());
        }
      },
    );
  }

  Future<void> _reconnect() => _reconnection ??= _reconnectLoop().whenComplete(
    () => _reconnection = null,
  );

  /// Waits out the pause between failed reconnect attempts instead of a
  /// timer. Tests set it to observe the backoff without waiting it out; a
  /// wake or [close] still ends the pause.
  Future<void> Function(Duration pause)? reconnectPause;

  /// The least time from the end of one reconnect attempt to the next,
  /// whatever ends the pause early, so requests cannot cause a launch storm.
  static const reconnectFloor = Duration(seconds: 1);

  /// Whether a reconnect, or its pause after a failed attempt, is under way.
  bool get reconnecting => _reconnection != null;

  // The pause after a failed attempt, while one runs, and its timers.
  Completer<void>? _pause;
  Timer? _pauseTimer, _wakeTimer, _probeTimer;
  final _sinceAttempt = Stopwatch();

  /// How long a reconnect waits for its desktop approval attach; the same
  /// bound as a startup status probe. Tests shorten it.
  Duration attachLimit = const Duration(seconds: 30);

  /// The pause after [failures] consecutive failed reconnect attempts: 1 s,
  /// doubling up to 30 s.
  static Duration reconnectBackoff(int failures) =>
      Duration(seconds: min(1 << min(failures - 1, 5), 30));

  Future<void> _reconnectLoop() async {
    // Waiters see only failures they await; an unobserved one is not an error.
    var attempt = _attempt = Completer<void>()..future.ignore();
    // A start that keeps failing, such as one with a corrupt database or an
    // update in progress, now fails at once; retrying every second would
    // launch a service every second for as long as the desktop runs. The
    // first attempt is immediate and a success starts over.
    var failures = 0;
    while (!_disposed) {
      _helper.state = 'application service disconnected; reconnecting';
      _notifyChanges();
      ServiceClient? next;
      try {
        final startup = await ensureServiceSnapshot(_profile);
        next = startup.client;
        if (_disposed) {
          await next.close();
          break;
        }
        await _events?.cancel();
        // A cancelled subscription reports no end; its approvals are lost too.
        _closeOpenApprovals();
        if (_disposed) {
          await next.close();
          break;
        }
        // Retire feature publications before exposing any replacement state or
        // admitting work on this client, independently of SQLite read identity.
        _clientSessionGeneration = Object();
        client = next;
        runtime.client = next;
        // The next owner may serve from another runtime.
        _reader.retarget(next.endpoint);
        _listen();
        // Replacement is observable even when its status is byte-identical.
        _apply(startup.status, forceNotify: true);
        _recheckWorkspace();
        if (_approvalEvents != null) {
          // An owner that answers status but never the attach must not hold
          // the reconnect, and with it every request waiting for it. A
          // timeout fails this attempt like any other: the connection is
          // retired and the next attempt follows the backoff.
          await _attachDesktop(next).timeout(
            attachLimit,
            onTimeout: () => throw TimeoutException(
              'Application service did not attach the desktop approval '
              'window within ${attachLimit.inSeconds} s',
            ),
          );
        }
        attempt.complete();
        return;
      } catch (error, stack) {
        // Requests may already have gone to [next], for example while its
        // attach timed out; the owner may still answer them.
        if (next != null) _retire(next);
        _helper.state = 'application service reconnect failed: $error';
        _notifyChanges();
        attempt.completeError(error, stack);
        attempt = _attempt = Completer<void>()..future.ignore();
        _sinceAttempt
          ..reset()
          ..start();
        if (!_disposed) await _pauseReconnect(reconnectBackoff(++failures));
      }
    }
    attempt.completeError(RpcError(RpcErrorCode.cancelled, 'Workspace closed'));
  }

  /// Wait [pause] before the next attempt. A request waiting for the
  /// reconnect ([_wakeReconnect]) ends it once [reconnectFloor] has passed
  /// since the last attempt, and [close] ends it at once. So does an owner
  /// that starts serving meanwhile, such as one an agent or the command
  /// line started: the backoff only spaces this desktop's own launches.
  /// Only an endpoint that did not accept when the pause began counts, so
  /// an owner that keeps failing the attempt is not retried every second.
  Future<void> _pauseReconnect(Duration pause) async {
    final done = _pause = Completer<void>();
    void end() {
      if (!done.isCompleted) done.complete();
    }

    final custom = reconnectPause;
    if (custom == null) {
      _pauseTimer = Timer(pause, end);
    } else {
      unawaited(custom(pause).then((_) => end(), onError: (Object _) => end()));
    }
    try {
      final accepting = await _endpointAccepts();
      if (!done.isCompleted && !accepting) {
        var probing = false;
        _probeTimer = Timer.periodic(reconnectFloor, (_) async {
          if (probing || done.isCompleted) return;
          probing = true;
          try {
            if (await _endpointAccepts()) end();
          } finally {
            probing = false;
          }
        });
      }
      await done.future;
    } finally {
      for (final timer in [_pauseTimer, _wakeTimer, _probeTimer]) {
        timer?.cancel();
      }
      _pauseTimer = _wakeTimer = _probeTimer = null;
      if (identical(_pause, done)) _pause = null;
    }
  }

  // Replaced connections still waiting for their owner's answers.
  final _retired = <ServiceClient>{};
  void _retire(ServiceClient connection) {
    _retired.add(connection);
    unawaited(connection.closed.then((_) => _retired.remove(connection)));
    connection.retire();
  }

  /// Whether a service accepts connections at this profile's endpoint now.
  Future<bool> _endpointAccepts() async {
    try {
      return (await probeSocketPath(serviceEndpoint(_profile)))?.live ?? false;
    } catch (_) {
      return false;
    }
  }

  /// End the pause after a failed attempt early, for a request that waits
  /// for the reconnect; never sooner than [reconnectFloor] after that
  /// attempt. The backoff itself is kept for the attempts that follow.
  void _wakeReconnect() {
    final done = _pause;
    if (done == null || done.isCompleted) return;
    final left = reconnectFloor - _sinceAttempt.elapsed;
    _wakeTimer?.cancel();
    _wakeTimer = Timer(left.isNegative ? Duration.zero : left, () {
      if (!done.isCompleted) done.complete();
    });
  }

  /// Hand off from [failed], whose request [cause] was refused by a closing
  /// owner or never sent, and wait for the next reconnect attempt. It
  /// re-attaches desktop approvals and refreshes status before this returns.
  /// If that attempt fails, [cause] reaches the caller; reconnecting goes on.
  Future<void> _awaitReconnect(ServiceClient failed, RpcError cause) async {
    if (_disposed) throw cause;
    // Another request already moved to the next owner.
    if (!identical(client, failed)) return;
    unawaited(_reconnect());
    final attempt = _attempt!.future;
    // Someone waits for this reconnect; a pause after failures need not
    // run its full length.
    _wakeReconnect();
    // The closing owner answers the other requests on [failed] itself, with
    // a refusal (they are sent once more) or its own outcomeUnknown. Closing
    // the connection now would fail them all locally as outcomeUnknown, so
    // it is retired: nothing new is sent on it, and it closes once they
    // settle. The handoff in ensureService waits for the owner itself.
    _retire(failed);
    try {
      await attempt;
    } catch (_) {
      throw cause;
    }
  }

  /// Whether a cancel made from now on applies to [method] with [args]. The
  /// old connection cannot carry a cancel for a request it refused; one made
  /// during the handoff applies to the resend.
  bool Function() _cancelledSince(String method, Map<String, dynamic> args) {
    final sent = _cancellationSequence;
    return () =>
        cancellableAnswers.contains(method) &&
        ((_cancellations[null] ?? 0) > sent ||
            (args['requestId'] is String &&
                (_cancellations[args['requestId']] ?? 0) > sent));
  }

  /// One request, sent once more on the next owner if this one refused it
  /// while closing, or it was never sent, before any result (SL-9). A request
  /// whose outcome is unknown is never resent.
  Future<Object?> _call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final cancelledSince = _cancelledSince(method, args);
    for (var attempt = 0; ; attempt++) {
      final current = client;
      var received = false;
      Object? result;
      try {
        await for (final value in current.stream(method, args)) {
          received = true;
          result = value;
        }
        return result;
      } on RpcError catch (error) {
        if (attempt > 0 || received || !_resendable(error)) rethrow;
        await _awaitReconnect(current, error);
        if (cancelledSince()) {
          throw operationCancelled();
        }
      }
    }
  }

  /// [createdForTesting] sees the domain once it is built, including one
  /// a failed connect disposes of.
  static Future<RemoteDomain> connect(
    ProfilePaths profile, {
    Duration startupTimeout = const Duration(minutes: 3),
    void Function(RemoteDomain domain)? createdForTesting,
  }) async {
    final startup = await ensureServiceSnapshot(
      profile,
      startupTimeout: startupTimeout,
    );
    SqliteStoreReader? store;
    RemoteDomain? domain;
    try {
      store = SqliteStoreReader.open(
        '${profile.data}/application.db',
        profile: profile.identity,
        connection: startup.client.endpoint,
      );
      domain = RemoteDomain._(
        store,
        startup.client,
        RemoteRuntime(startup.client),
        profile,
      );
      createdForTesting?.call(domain);
      domain._apply(startup.status);
      domain._recheckWorkspace();
      return domain;
    } catch (_) {
      // No caller holds this domain: end its connection, any reconnect,
      // its helper and its read-only store, whichever exist.
      domain?.close();
      await domain?.closed;
      await store?.close();
      await startup.client.close();
      rethrow;
    }
  }

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_approvalEvents != null &&
        (operation == Operation.sourcesImportFile ||
            operation == Operation.sourcesImportDirectory)) {
      final path = args['path'] as String;
      await _call(Operation.securityAllowImportRoot.wire, {
        'path': operation == Operation.sourcesImportDirectory
            ? path
            : File(path).parent.path,
      });
    }
    final epochBefore = _serviceEpoch;
    final Object? result;
    try {
      result = await _call(
        operation.wire,
        operation.scopedToWorkspace(args, _workspaceEpoch),
      );
    } on RpcError catch (error) {
      if (operation != Operation.workspaceClear ||
          error.reason != RpcErrorReason.outcomeUnknown) {
        rethrow;
      }
      return _settleLostClear(error, epochBefore);
    }
    if (operation == Operation.workspaceClear) {
      try {
        _apply(
          Map<String, dynamic>.from(
            await client.call(Operation.status.wire) as Map,
          ),
        );
      } catch (_) {
        // Deletion was acknowledged. A later snapshot/reconnect can refresh
        // status; failure here must not prevent the caller's local UI reset.
      }
    }
    return result;
  }

  /// A clear whose reply was lost renews the epoch in its own transaction, so
  /// the next owner's status shows whether it committed.
  Future<Object?> _settleLostClear(RpcError lost, String? before) async {
    if (before == null) throw lost;
    try {
      _apply(
        Map<String, dynamic>.from(await _call(Operation.status.wire) as Map),
      );
    } catch (_) {
      throw lost;
    }
    if (_serviceEpoch != before) return null;
    throw RpcError(
      RpcErrorCode.unavailable,
      'The service stopped before clearing the workspace; nothing was '
      'cleared. Try again.',
    );
  }

  /// A streamed request, sent once more on the next owner like [_call]: if
  /// this one refused it while closing, or it was never sent, before any
  /// value (SL-9).
  Stream<Object?> _streamCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function()? current,
  ) {
    late StreamController<Object?> controller;
    StreamSubscription<Object?>? subscription;
    Timer? timer;
    void end([Object? error, StackTrace? stack]) {
      if (controller.isClosed) return;
      if (error != null) controller.addError(error, stack);
      timer?.cancel();
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    void cancelled() => end(operationCancelled());

    late Map<String, dynamic> scoped;
    late bool Function() cancelledSince;
    var received = false, resent = false;
    void send(ServiceClient connection) {
      var resending = false;
      subscription = connection
          .stream(operation.wire, scoped)
          .listen(
            (value) {
              received = true;
              if (controller.isClosed) return;
              if (!(current?.call() ?? true)) {
                cancelled();
              } else {
                controller.add(value);
              }
            },
            onError: (Object error, StackTrace stack) {
              if (controller.isClosed) return;
              if (resent ||
                  received ||
                  error is! RpcError ||
                  !_resendable(error)) {
                controller.addError(error, stack);
                return;
              }
              resent = resending = true;
              unawaited(
                _awaitReconnect(connection, error).then(
                  (_) {
                    // The caller stopped listening during the handoff.
                    if (controller.isClosed || !controller.hasListener) return;
                    if (cancelledSince() || !(current?.call() ?? true)) {
                      cancelled();
                    } else {
                      send(client);
                    }
                  },
                  onError: (Object failure, StackTrace failureStack) =>
                      end(failure, failureStack),
                ),
              );
            },
            onDone: () {
              if (!resending) end();
            },
          );
    }

    controller = StreamController<Object?>(
      onListen: () {
        if (!(current?.call() ?? true)) {
          cancelled();
          return;
        }
        scoped = operation.scopedToWorkspace(args, _workspaceEpoch);
        cancelledSince = _cancelledSince(operation.wire, scoped);
        send(client);
        if (current != null) {
          timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
            if (!current()) cancelled();
          });
        }
      },
      onCancel: () async {
        timer?.cancel();
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) async {
    Object? result;
    await for (final value in _streamCurrent(operation, args, current)) {
      result = value;
    }
    return result;
  }

  @override
  Future<void> index(String id) async {
    await sourcesIndexDescriptor.send(this, SourcesIndexInput(id: id));
  }

  @override
  Future<void> delete(String id) async {
    await sourcesDeleteDescriptor.send(this, SourcesDeleteInput(id: id));
  }

  @override
  Stream<Object?> googleSignIn(Operation operation) =>
      client.stream(operation.wire);

  @override
  Future<void> resume() async {
    await applicationResumeDescriptor.send(
      this,
      const ApplicationResumeInput(),
    );
  }

  @override
  bool get sourcesPaused => _paused;
  @override
  void pauseSources() {
    _sourceControl(Operation.sourcesPause, true);
  }

  @override
  void resumeSources() {
    _sourceControl(Operation.sourcesResume, false);
  }

  void _sourceControl(Operation operation, bool paused) {
    final previous = _paused;
    final revision = ++_sourceControlRevision;
    _paused = paused;
    final work = operation == Operation.sourcesPause
        ? sourcesPauseDescriptor.send(this, const SourcesPauseInput())
        : sourcesResumeDescriptor.send(this, const SourcesResumeInput());
    unawaited(
      work.catchError((Object error) {
        if (!_disposed) {
          if (revision == _sourceControlRevision) _paused = previous;
          _helper.state = 'Source control failed: $error';
          _notifyChanges();
        }
      }),
    );
  }

  @override
  Future<void> waitForSourceWork() async {
    while (_paused) {
      if (_disposed) throw RpcError(RpcErrorCode.cancelled, 'Workspace closed');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Stream<String> ask(String question) => askInConversation(question, 'desktop');

  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    if (current != null && !current()) {
      throw operationCancelled('Answer cancelled');
    }
    await for (final value in _streamCurrent(Operation.answerStream, {
      'question': question,
      'conversation': conversation,
      if (requestId != null) 'requestId': requestId,
      if (meetingId != null) 'meeting_id': meetingId,
    }, current)) {
      if (current != null && !current()) {
        throw operationCancelled('Answer cancelled');
      }
      yield value as String;
    }
  }

  @override
  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    if (current != null && !current()) {
      throw operationCancelled('Answer cancelled');
    }
    await for (final value in _streamCurrent(Operation.answerStream, {
      'question': question,
      'conversation': conversation,
      'web_search': true,
      if (requestId != null) 'requestId': requestId,
      if (meetingId != null) 'meeting_id': meetingId,
    }, current)) {
      if (current != null && !current()) {
        throw operationCancelled('Answer cancelled');
      }
      yield value as String;
    }
  }

  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) async {
    return graphEmbeddingsDescriptor.send(
      this,
      GraphEmbeddingsInput(sources: decodeGraphSources(sources, 'sources')),
    );
  }

  @override
  void close() {
    if (_closed != null) return;
    _disposed = true;
    final pause = _pause;
    if (pause != null && !pause.isCompleted) pause.complete();
    _closed = _closeResources();
    unawaited(
      _closed!.then(
        _closedSignal.complete,
        onError: _closedSignal.completeError,
      ),
    );
  }

  @override
  Future<void> get closed => _closedSignal.future;

  Future<void> _closeResources() async {
    final sockets = Future.wait([
      for (final retired in _retired.toList()) retired.close(),
      client.close(),
    ]);
    await _events?.cancel();
    await _readEvents?.cancel();
    await sockets;
    await _reconnection;
    await _reader.close();
    await _changes.close();
    await _captureLevels.close();
  }
}

final class _RemoteHelperState {
  HelperStatus value = const HelperStatus();
  HelperSnapshot? get snapshot => value.snapshot;
  set snapshot(HelperSnapshot? snapshot) =>
      value = HelperStatus(state: value.state, snapshot: snapshot);
  set state(String state) =>
      value = HelperStatus(state: state, snapshot: value.snapshot);
}

class RemoteRuntime implements GenerationStatus {
  ServiceClient client;
  Map<String, dynamic> state = {};
  // Tells the domain, so an answer waiting for a handoff is not resent.
  void Function(String? requestId)? onCancel;
  RemoteRuntime(this.client);
  @override
  Map<String, dynamic> get effectiveState => state;
  @override
  bool get generating => state['generating'] == true;
  @override
  bool cancel({String? requestId}) {
    onCancel?.call(requestId);
    return client.cancelAnswers(requestId: requestId);
  }

  @override
  void close() {} // The service owns this worker.
}
