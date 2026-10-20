import 'rpc_error.dart';
import 'operations.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' show min;
import 'google_auth.dart';
import 'desktop_connection.dart';
import 'helper.dart';
import 'profile_paths.dart';
import 'service.dart';
import 'store.dart';
import 'generated/helper_control.pb.dart' as control;
import 'generated/rag_service.pbgrpc.dart' show RagServiceClient;
import 'package:grpc/service_api.dart' as grpc_api;

/// Whether a failed request never took effect, so it may be sent once more
/// after a handoff: a closing owner refused it, or it was never sent.
bool _resendable(RpcError error) =>
    isClosingRefusal(error) || error.reason == RpcErrorReason.notSent;

/// Desktop facade: reads use SQLite WAL snapshots; all writes and workers are
/// delegated to the single application service. No migrations run in this client.
class RemoteDomain implements DesktopConnection, CaptureLevelEvents {
  @override
  final Store store;
  @override
  final RemoteHelper helper;
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
  final ProfilePaths profile;
  void Function(Map<String, dynamic>)? _approvalEvents;
  // The connection the desktop approval host is attached on.
  ServiceClient? _attached;
  @override
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) events,
  ) async {
    _approvalEvents = events;
    for (var attempt = 0; ; attempt++) {
      final current = client;
      // A reconnect attaches its new connection itself.
      if (identical(_attached, current)) return;
      try {
        await _attachDesktop(current);
        return;
      } on RpcError catch (error) {
        if (attempt > 0 || !_resendable(error)) rethrow;
        await _awaitReconnect(current, error);
      }
    }
  }

  Future<void> _attachDesktop(ServiceClient connection) async {
    await connection.call(Operation.securityAttachDesktop.wire, {
      'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
    });
    _attached = connection;
  }

  @override
  Future<void> disableDesktopApprovals() async {
    // The service denies the approvals still open, but their
    // approval_closed would find no listener; close their dialogs first.
    _closeOpenApprovals();
    _approvalEvents = null;
    _attached = null;
    await client.call(Operation.securityDetachDesktop.wire);
  }

  bool _disposed = false;
  Future<void>? _reconnection;
  // Completes with the outcome of the current or next reconnect attempt.
  Completer<void>? _attempt;
  @override
  Map<String, dynamic> capture = {};
  @override
  Map<String, dynamic> googleStatus = {};
  bool _paused = false;
  int _sourceControlRevision = 0;
  bool _webSearchAvailable = false;
  @override
  bool get webSearchAvailable => _webSearchAvailable;
  StreamSubscription<Map<String, dynamic>>? _events;
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
  RemoteDomain._(
    this.store,
    this.helper,
    this.client,
    this.runtime,
    this.profile,
  ) {
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
  void _apply(Map<String, dynamic> event) {
    if (event['event'] == 'capture_levels') {
      final volumes = (event['volumes'] as List)
          .map((n) => (n as num).toDouble())
          .toList();
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
    final signature = jsonEncode(event);
    if (_eventSignature == signature) return;
    _eventSignature = signature;
    final epoch = event['workspace_epoch'];
    if (epoch is String) {
      _observeEpoch(epoch);
      // The first epoch names the workspace the desktop starts in. A later one
      // waits for the desktop to drop views that hold older IDs.
      _workspaceEpoch ??= _serviceEpoch;
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
    helper.snapshot = event['helper'] == null
        ? null
        : (control.State()..mergeFromProto3Json(event['helper']));
    helper.state =
        event['helper_state'] as String? ??
        (helper.snapshot == null ? 'disconnected' : 'live (service)');
    helper.changed?.call();
  }

  /// Events a connection sends before it is listened to are lost, and its
  /// startup status can predate a clear among them. The profile already
  /// holds that clear's epoch, so read it once the connection is listened to.
  void _recheckWorkspace() {
    final stored = _storedEpoch();
    if (stored.isEmpty || stored == _serviceEpoch) return;
    _serviceEpoch = stored;
    _workspaceEpoch ??= stored;
    helper.changed?.call();
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
      _apply,
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

  /// Waits between failed reconnect attempts. Tests replace it to observe
  /// the backoff without waiting it out.
  Future<void> Function(Duration pause) reconnectPause = Future<void>.delayed;

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
      helper.state = 'application service disconnected; reconnecting';
      helper.changed?.call();
      ServiceClient? next;
      try {
        final startup = await ensureServiceSnapshot(profile);
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
        client = next;
        runtime.client = next;
        // The next owner may serve from another runtime.
        helper.retarget(_helperSocket(next));
        _listen();
        _apply(startup.status);
        _recheckWorkspace();
        if (_approvalEvents != null) {
          // An owner that answers status but never the attach must not hold
          // the reconnect, and with it every request waiting for it. A
          // timeout fails this attempt like any other: the connection is
          // closed and the next attempt follows the backoff.
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
        await next?.close();
        helper.state = 'application service reconnect failed: $error';
        helper.changed?.call();
        attempt.completeError(error, stack);
        attempt = _attempt = Completer<void>()..future.ignore();
        await reconnectPause(reconnectBackoff(++failures));
      }
    }
    attempt.completeError(RpcError(RpcErrorCode.cancelled, 'Workspace closed'));
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
    // The closing owner answers the other requests on [failed] itself, with
    // a refusal (they are sent once more) or its own outcomeUnknown. Closing
    // the connection now would fail them all locally as outcomeUnknown, so
    // it is retired: nothing new is sent on it, and it closes once they
    // settle. The handoff in ensureService waits for the owner itself.
    failed.retire();
    try {
      await attempt;
    } catch (_) {
      throw cause;
    }
  }

  /// One request, sent once more on the next owner if this one refused it
  /// while closing, or it was never sent, before any result (SL-9). A request
  /// whose outcome is unknown is never resent.
  Future<Object?> _call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final sent = _cancellationSequence;
    bool cancelledSince() =>
        cancellableAnswers.contains(method) &&
        ((_cancellations[null] ?? 0) > sent ||
            (args['requestId'] is String &&
                (_cancellations[args['requestId']] ?? 0) > sent));
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
        // The old connection cannot carry a cancel for a request it refused;
        // one made during the handoff applies to the resend.
        if (cancelledSince()) {
          throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
        }
      }
    }
  }

  /// The helper beside the endpoint [client] reached. Reading the endpoint
  /// record again could name another runtime by now (L9).
  static String _helperSocket(ServiceClient client) =>
      '${File(client.endpoint).parent.path}/helper.sock';

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
    Store? store;
    RemoteDomain? domain;
    try {
      store = Store.readOnly('${profile.data}/application.db');
      domain = RemoteDomain._(
        store,
        RemoteHelper(_helperSocket(startup.client), '${profile.data}/helper'),
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
      await domain?.helper.close();
      store?.close();
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

  Stream<Object?> _streamCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function()? current,
  ) {
    late StreamController<Object?> controller;
    StreamSubscription<Object?>? subscription;
    Timer? timer;
    void cancelled() {
      if (controller.isClosed) return;
      controller.addError(
        RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      );
      timer?.cancel();
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    controller = StreamController<Object?>(
      onListen: () {
        if (!(current?.call() ?? true)) {
          cancelled();
          return;
        }
        subscription = client
            .stream(
              operation.wire,
              operation.scopedToWorkspace(args, _workspaceEpoch),
            )
            .listen(
              (value) {
                if (controller.isClosed) return;
                if (!(current?.call() ?? true)) {
                  cancelled();
                } else {
                  controller.add(value);
                }
              },
              onError: (Object error, StackTrace stack) {
                if (!controller.isClosed) controller.addError(error, stack);
              },
              onDone: () {
                timer?.cancel();
                unawaited(controller.close());
              },
            );
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
    await command(Operation.sourcesIndex, {'id': id});
  }

  @override
  Future<void> delete(String id) async {
    await command(Operation.sourcesDelete, {'id': id});
  }

  @override
  Future<void> resume() async {
    await command(Operation.applicationResume);
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
    unawaited(
      command(operation).catchError((Object error) {
        if (!_disposed) {
          if (revision == _sourceControlRevision) _paused = previous;
          helper.state = 'Source control failed: $error';
          helper.changed?.call();
        }
        return null;
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
      throw RpcError(RpcErrorCode.cancelled, 'Answer cancelled');
    }
    await for (final value in _streamCurrent(Operation.answerStream, {
      'question': question,
      'conversation': conversation,
      if (requestId != null) 'requestId': requestId,
      if (meetingId != null) 'meeting_id': meetingId,
    }, current)) {
      if (current != null && !current()) {
        throw RpcError(RpcErrorCode.cancelled, 'Answer cancelled');
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
      throw RpcError(RpcErrorCode.cancelled, 'Answer cancelled');
    }
    await for (final value in _streamCurrent(Operation.answerStream, {
      'question': question,
      'conversation': conversation,
      'web_search': true,
      if (requestId != null) 'requestId': requestId,
      if (meetingId != null) 'meeting_id': meetingId,
    }, current)) {
      if (current != null && !current()) {
        throw RpcError(RpcErrorCode.cancelled, 'Answer cancelled');
      }
      yield value as String;
    }
  }

  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) async {
    final result =
        await command(Operation.graphEmbeddings, {'sources': sources}) as Map;
    return result.map(
      (k, v) => MapEntry(
        k as String,
        (v as List).map((n) => (n as num).toDouble()).toList(),
      ),
    );
  }

  @override
  void close() {
    _disposed = true;
    unawaited(_captureLevels.close());
    unawaited(_events?.cancel());
    unawaited(client.close());
  }
}

/// The desktop's view of the helper its service owns. Service events are
/// authoritative; the desktop never starts a second watcher against the
/// runtime directory from its own launch environment. Nothing connects
/// through this helper, but its socket names the connected owner's helper
/// and moves with that owner to another runtime after a reconnect (L9).
class RemoteHelper extends Helper {
  RemoteHelper(super.socket, super.storage)
    : _socket = socket,
      super(manageProcess: false);
  String _socket;
  // Until a retarget, the channel and client the Helper built for the first
  // socket. Lazy, because the Helper constructor reads them through these
  // overrides.
  late grpc_api.ClientChannel _channel = super.channel;
  late RagServiceClient _client = super.client;
  @override
  String get socket => _socket;
  @override
  grpc_api.ClientChannel get channel => _channel;
  @override
  RagServiceClient get client => _client;

  /// Name the helper at [socket], beside the endpoint a reconnect reached.
  void retarget(String socket) {
    if (socket == _socket || stopping) return;
    final previous = _channel;
    _socket = socket;
    _channel = helperChannel(socket);
    _client = helperClient(_channel);
    unawaited(previous.terminate());
  }

  @override
  Future<void> start() async {
    changed?.call();
    await onReady?.call();
  }
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

class RemoteRecording implements RecordingStatus {
  final Map<String, dynamic> snapshot;
  RemoteRecording(this.snapshot);
  @override
  bool get finishing => snapshot['finishing'] == true;
  @override
  bool get paused => snapshot['paused'] == true;
  @override
  Map<String, dynamic> get echoCancellationState => Map<String, dynamic>.from(
    snapshot['echo_cancellation'] as Map? ??
        {'requested': false, 'active': false},
  );
  @override
  List<int> get sampleCounts =>
      (snapshot['samples'] as List? ?? []).cast<int>();
  @override
  List<double> get peakVolumes => (snapshot['peaks'] as List? ?? [])
      .map((v) => (v as num).toDouble())
      .toList();
  @override
  DateTime get lastAudioActivity => DateTime.fromMillisecondsSinceEpoch(
    snapshot['last_audio'] as int? ?? DateTime.now().millisecondsSinceEpoch,
  );
  @override
  List<double> get currentVolumes => (snapshot['volumes'] as List? ?? [])
      .map((v) => (v as num).toDouble())
      .toList();
  @override
  void dispose() {}
}

class RemoteGoogleAuth implements GoogleAccount {
  final RemoteDomain domain;
  RemoteGoogleAuth(this.domain);
  @override
  bool get connected => domain.googleStatus['connected'] == true;
  @override
  String get email => domain.googleStatus['email'] as String? ?? '';
  @override
  String get displayName => domain.googleStatus['displayName'] as String? ?? '';
  @override
  String get photoUrl => domain.googleStatus['photoUrl'] as String? ?? '';
  @override
  String get account => domain.googleStatus['account'] as String? ?? '';
  @override
  String get loadError => domain.googleStatus['loadError'] as String? ?? '';
  @override
  bool get signingIn => domain.googleStatus['signingIn'] == true;
  @override
  GoogleClient? get client =>
      domain.googleStatus['configured'] == true ? GoogleClient('', '') : null;
  Future<void> _call(
    Operation operation, [
    Map<String, dynamic> a = const {},
  ]) async {
    domain.googleStatus = Map<String, dynamic>.from(
      await domain.command(operation, a) as Map,
    );
  }

  @override
  Future<void> configure(File file) =>
      _call(Operation.googleConfigure, {'path': file.path});
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) =>
      _signIn(openBrowser, Operation.googleSignIn);
  @override
  Future<void> addAccount(Future<void> Function(Uri) openBrowser) =>
      _signIn(openBrowser, Operation.googleAddAccount);
  @override
  List<Map<String, Object?>> get accounts =>
      (domain.googleStatus['accounts'] as List? ?? [])
          .map((value) => Map<String, Object?>.from(value as Map))
          .toList();
  @override
  Future<void> switchAccount(String id) =>
      _call(Operation.googleSwitchAccount, {'id': id});
  @override
  Future<void> signOutAccount(String id) =>
      _call(Operation.googleSignOutAccount, {'id': id});

  Future<void> _signIn(
    Future<void> Function(Uri) openBrowser,
    Operation operation,
  ) async {
    try {
      await for (final value in domain.client.stream(operation.wire)) {
        final state = Map<String, dynamic>.from(value as Map);
        if (state['authorization_url'] is String) {
          await openBrowser(Uri.parse(state['authorization_url'] as String));
        } else {
          domain.googleStatus = state;
        }
      }
    } catch (_) {
      await _call(Operation.googleCancelSignIn);
      rethrow;
    }
  }

  @override
  void cancelSignIn() {
    unawaited(_call(Operation.googleCancelSignIn));
  }

  @override
  Future<void> disconnect() => _call(Operation.googleDisconnect);
  @override
  Future<void> close() async {}
}

class RemoteGoogleConnections implements ConnectedSources {
  final RemoteDomain domain;
  final GoogleAccount auth;
  RemoteGoogleConnections(this.domain, this.auth);
  @override
  int get lastCompletedRefreshMs =>
      domain.googleStatus['lastRefresh'] as int? ?? 0;
  @override
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  }) async =>
      (await domain.command(Operation.googleDriveFiles, {
                'parent': parent,
                'query': query,
                'modifiedAfter': modifiedAfter?.toIso8601String(),
              })
              as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  @override
  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
  }) async {
    await domain.command(Operation.googleImportFile, {'id': fileId});
  }

  @override
  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
  }) async {
    await domain.command(Operation.googleImportFolder, {'id': folderId});
  }

  @override
  Future<void> importLastYear() async {
    await domain.command(Operation.googleImportYear);
  }

  @override
  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
  }) async {
    await domain.command(Operation.googleCalendar);
  }

  @override
  Future<void> refresh() async {
    await domain.command(Operation.googleRefresh);
  }

  @override
  Future<void> importAttachments(int meeting) async {
    await domain.command(Operation.googleAttachments, {'id': meeting});
  }

  @override
  List<Map<String, dynamic>> attachments(int meeting) {
    final row = domain.store.rows(
      'SELECT metadata FROM calendar_events WHERE meeting_id=?',
      [meeting],
    ).firstOrNull;
    if (row == null) return [];
    return ((jsonDecode(row['metadata'] as String) as Map)['attachments']
                as List? ??
            [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<void> reminders(
    DateTime now,
    Future<void> Function(String) deliver,
  ) async {} // Service timer owns delivery.
  void close() {}
}
