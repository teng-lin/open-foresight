import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'google_auth.dart';
import 'google_connections.dart';
import 'domain.dart';
import 'helper.dart';
import 'native.dart';
import 'profile_paths.dart';
import 'recording.dart';
import 'service.dart';
import 'store.dart';
import 'generated/helper_control.pb.dart' as control;

/// Desktop facade: reads use SQLite WAL snapshots; all writes and workers are
/// delegated to the single application service. No migrations run in this client.
class RemoteDomain extends Domain {
  ServiceClient client;
  final RemoteRuntime runtime;
  final ProfilePaths profile;
  void Function(Map<String, dynamic>)? _approvalEvents;
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) events,
  ) async {
    _approvalEvents = events;
    await client.call('security.attach_desktop', {
      'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
    });
  }

  Future<void> disableDesktopApprovals() async {
    _approvalEvents = null;
    await client.call('security.detach_desktop');
  }

  bool _disposed = false;
  bool _reconnecting = false;
  Map<String, dynamic> capture = {};
  Map<String, dynamic> googleStatus = {};
  bool _paused = false;
  int _sourceControlRevision = 0;
  bool _webSearchAvailable = false;
  @override
  bool get webSearchAvailable => _webSearchAvailable;
  StreamSubscription<Map<String, dynamic>>? _events;
  RemoteDomain._(
    super.store,
    super.helper,
    this.client,
    this.runtime,
    this.profile,
  ) {
    _listen();
  }
  void _apply(Map<String, dynamic> event) {
    if (event['event'] == 'approval' || event['event'] == 'approval_closed') {
      _approvalEvents?.call(event);
      return;
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

  void _listen() {
    _events = client.events.stream.listen(
      _apply,
      onDone: () {
        if (!_disposed) unawaited(_reconnect());
      },
    );
  }

  Future<void> _reconnect() async {
    if (_reconnecting || _disposed) return;
    _reconnecting = true;
    try {
      while (!_disposed) {
        helper.state = 'application service disconnected; reconnecting';
        helper.changed?.call();
        try {
          final next = await ensureService(profile);
          if (_disposed) {
            await next.close();
            return;
          }
          client = next;
          runtime.client = next;
          _listen();
          final approvals = _approvalEvents;
          if (approvals != null) await enableDesktopApprovals(approvals);
          _apply(Map<String, dynamic>.from(await next.call('status') as Map));
          return;
        } catch (error) {
          helper.state = 'application service reconnect failed: $error';
          helper.changed?.call();
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  static Future<RemoteDomain> connect(ProfilePaths profile) async {
    final client = await ensureService(profile);
    final runtime = RemoteRuntime(client);
    final domain = RemoteDomain._(
      Store.readOnly('${profile.data}/application.db'),
      RemoteHelper(
        '${File(serviceEndpoint(profile)).parent.path}/helper.sock',
        '${profile.data}/helper',
      ),
      client,
      runtime,
      profile,
    );
    final status = Map<String, dynamic>.from(
      await client.call('status') as Map,
    );
    domain._apply(status);
    return domain;
  }

  @override
  Future<Object?> command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_approvalEvents != null &&
        (method == 'sources.import_file' ||
            method == 'sources.import_directory')) {
      final path = args['path'] as String;
      await client.call('security.allow_import_root', {
        'path': method == 'sources.import_directory'
            ? path
            : File(path).parent.path,
      });
    }
    return client.call(method, args);
  }

  Stream<Object?> _streamCurrent(
    String method,
    Map<String, dynamic> args,
    bool Function()? current,
  ) {
    late StreamController<Object?> controller;
    StreamSubscription<Object?>? subscription;
    Timer? timer;
    void cancelled() {
      if (controller.isClosed) return;
      controller.addError(StateError('Operation cancelled'));
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
            .stream(method, args)
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
    String method,
    Map<String, dynamic> args,
    bool Function() current,
  ) async {
    Object? result;
    await for (final value in _streamCurrent(method, args, current)) {
      result = value;
    }
    return result;
  }

  @override
  Future<void> index(String id) async {
    await command('sources.index', {'id': id});
  }

  @override
  Future<void> delete(String id) async {
    await command('sources.delete', {'id': id});
  }

  @override
  Future<void> resume() async {
    await command('application.resume');
  }

  @override
  bool get sourcesPaused => _paused;
  @override
  void pauseSources() {
    _sourceControl('sources.pause', true);
  }

  @override
  void resumeSources() {
    _sourceControl('sources.resume', false);
  }

  void _sourceControl(String method, bool paused) {
    final previous = _paused;
    final revision = ++_sourceControlRevision;
    _paused = paused;
    unawaited(
      command(method).catchError((Object error) {
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
      if (_disposed) throw StateError('Workspace closed');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    if (current != null && !current()) throw StateError('Answer cancelled');
    await for (final value in _streamCurrent('answer.stream', {
      'question': question,
      'conversation': conversation,
      if (requestId != null) 'requestId': requestId,
      if (meetingId != null) 'meeting_id': meetingId,
    }, current)) {
      if (current != null && !current()) throw StateError('Answer cancelled');
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
    if (current != null && !current()) throw StateError('Answer cancelled');
    await for (final value in _streamCurrent('answer.stream', {
      'question': question,
      'conversation': conversation,
      'web_search': true,
      if (requestId != null) 'requestId': requestId,
      if (meetingId != null) 'meeting_id': meetingId,
    }, current)) {
      if (current != null && !current()) throw StateError('Answer cancelled');
      yield value as String;
    }
  }

  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) async {
    final result =
        await command('graph.embeddings', {'sources': sources}) as Map;
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
    unawaited(_events?.cancel());
    unawaited(client.close());
    super.close();
  }
}

/// Service events are authoritative; the desktop never starts a second watcher
/// against the runtime directory from its own launch environment.
class RemoteHelper extends Helper {
  RemoteHelper(super.socket, super.storage) : super(manageProcess: false);
  @override
  Future<void> start() async {
    changed?.call();
    await onReady?.call();
  }
}

class RemoteRuntime implements NativeRuntime {
  ServiceClient client;
  Map<String, dynamic> state = {};
  RemoteRuntime(this.client);
  @override
  Map<String, dynamic> get effectiveState => state;
  @override
  bool get generating => state['generating'] == true;
  @override
  bool cancel({String? requestId}) =>
      client.cancelAnswers(requestId: requestId);
  @override
  void close() {} // The service owns this worker.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RemoteRecording implements Recording {
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
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RemoteGoogleAuth implements GoogleAuth {
  final RemoteDomain domain;
  RemoteGoogleAuth(this.domain);
  @override
  bool get connected => domain.googleStatus['connected'] == true;
  @override
  String get email => domain.googleStatus['email'] as String? ?? '';
  @override
  String get account => domain.googleStatus['account'] as String? ?? '';
  @override
  String get loadError => domain.googleStatus['loadError'] as String? ?? '';
  @override
  bool get signingIn => domain.googleStatus['signingIn'] == true;
  @override
  GoogleClient? get client =>
      domain.googleStatus['configured'] == true ? GoogleClient('', '') : null;
  Future<void> _call(String op, [Map<String, dynamic> a = const {}]) async {
    domain.googleStatus = Map<String, dynamic>.from(
      await domain.command(op, a) as Map,
    );
  }

  @override
  Future<void> configure(File file) =>
      _call('google.configure', {'path': file.path});
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) async {
    try {
      await for (final value in domain.client.stream('google.sign_in')) {
        final state = Map<String, dynamic>.from(value as Map);
        if (state['authorization_url'] is String) {
          await openBrowser(Uri.parse(state['authorization_url'] as String));
        } else {
          domain.googleStatus = state;
        }
      }
    } catch (_) {
      await _call('google.cancel_sign_in');
      rethrow;
    }
  }

  @override
  void cancelSignIn() {
    unawaited(_call('google.cancel_sign_in'));
  }

  @override
  Future<void> disconnect() => _call('google.disconnect');
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RemoteGoogleConnections implements GoogleConnections {
  @override
  final RemoteDomain domain;
  @override
  final GoogleAuth auth;
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
      (await domain.command('google.drive_files', {
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
    await domain.command('google.import_file', {'id': fileId});
  }

  @override
  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
  }) async {
    await domain.command('google.import_folder', {'id': folderId});
  }

  @override
  Future<void> importLastYear() async {
    await domain.command('google.import_year');
  }

  @override
  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
  }) async {
    await domain.command('google.calendar');
  }

  @override
  Future<void> refresh() async {
    await domain.command('google.refresh');
  }

  @override
  Future<void> importAttachments(int meeting) async {
    await domain.command('google.attachments', {'id': meeting});
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

  @override
  Future<void> reminders(
    DateTime now,
    Future<void> Function(String) deliver,
  ) async {} // Service timer owns delivery.
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
