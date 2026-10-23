import 'dart:io';
import 'store_reader_fixture.dart';
import 'package:foresight_core/remote.dart'
    show StoreReader, HelperStatus, DesktopModelAssets;
import 'dart:async';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';

/// Explicit test adapter for the desktop capability contract. Production only
/// constructs RemoteDomain; widget fixtures can control core services directly.
class TestDesktopConnection implements DesktopConnection {
  final Domain domain;
  final Application application;
  StreamSubscription<void>? _changes;
  final _events = StreamController<void>.broadcast(sync: true);
  Future<void>? _closing;
  final _ready = Completer<void>();
  Future<void>? _initializing;
  @override
  Stream<void> get changes => _events.stream;
  Object _clientSessionGeneration = Object();
  @override
  Object get clientSessionGeneration => _clientSessionGeneration;

  /// Simulates actual connection replacement, not an ordinary helper event.
  void replaceClientSessionForTesting() {
    if (_closing != null) return;
    _clientSessionGeneration = Object();
    _events.add(null);
  }

  @override
  Future<void> get closed => _closing ?? Future<void>.value();
  @override
  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (_closing != null) {
      throw RpcError(RpcErrorCode.cancelled, 'Desktop connection closed');
    }
    await domain.helper.start();
    await _ready.future;
    if (_closing != null) {
      throw RpcError(RpcErrorCode.cancelled, 'Desktop connection closed');
    }
  }

  @override
  DesktopModelAssets get modelAssets => DesktopModelAssets(
    generation: Directory(
      "${File(domain.store.path).parent.path}/models/gemma4",
    ),
    speech: Directory("${File(domain.store.path).parent.path}/models/whisper"),
  );
  String? _workspaceEpoch;
  TestDesktopConnection(this.application) : domain = application.domain {
    domain.helper.onReady = () async {
      if (!_ready.isCompleted) _ready.complete();
    };
    if (domain is CommandFixtureDomain) {
      (domain as CommandFixtureDomain).application = application;
    }
    if (domain is AnswerFixtureDomain) {
      (domain as AnswerFixtureDomain).application = application;
    }
    _workspaceEpoch = _serviceEpoch;
    domain.helper.changed = () => _events.add(null);
    _changes = application.changes.stream.listen(
      (_) => domain.helper.changed?.call(),
    );
  }
  String? get _serviceEpoch {
    final epoch = store.workspaceEpoch;
    return epoch.isEmpty ? null : epoch;
  }

  @override
  String? get workspaceEpoch => _workspaceEpoch;
  @override
  bool get workspaceReplaced =>
      _serviceEpoch != null && _serviceEpoch != _workspaceEpoch;
  @override
  void adoptWorkspace() => _workspaceEpoch = _serviceEpoch;
  @override
  StoreReader get store => fixtureReader(domain.store);
  @override
  HelperStatus get helper => HelperStatus.fromEvent({
    'helper': domain.helper.snapshot?.toProto3Json(),
    'helper_state': domain.helper.state,
  });
  @override
  GenerationStatus? get generator => domain.generator;
  @override
  GenerationStatus get runtime => domain.generator!;
  @override
  GoogleAccount get googleAuth => application.googleAuth;
  @override
  ConnectedSources get google => application.google;
  @override
  Map<String, dynamic> get capture =>
      Map<String, dynamic>.from(application.captureState);
  @override
  Map<String, dynamic> get googleStatus =>
      Map<String, dynamic>.from(application.googleState);
  @override
  bool get webSearchAvailable => domain.webSearchAvailable;
  @override
  bool get sourcesPaused => domain.sourcesPaused;
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) {
    // Like RemoteDomain, by-ID edits name the workspace the views belong to.
    args = operation.scopedToWorkspace(args, _workspaceEpoch);
    return domain is CommandFixtureDomain
        ? (domain as CommandFixtureDomain).command(operation, args)
        : application.call(operation.wire, args);
  }

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) => application.call(
    operation.wire,
    operation.scopedToWorkspace(args, _workspaceEpoch),
    current: current,
  );
  @override
  Future<void> index(String id) => domain.index(id);
  @override
  Future<void> delete(String id) => domain.delete(id);
  @override
  Future<void> resume() => domain.resume();
  @override
  void pauseSources() => domain.pauseSources();
  @override
  void resumeSources() => domain.resumeSources();
  @override
  Future<void> waitForSourceWork() => domain.waitForSourceWork();
  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => domain is AnswerFixtureDomain
      ? (domain as AnswerFixtureDomain).askInConversation(
          question,
          conversation,
          requestId: requestId,
          meetingId: meetingId,
          current: current,
        )
      : application.askInConversation(
          question,
          conversation,
          requestId: requestId,
          meetingId: meetingId,
          current: current,
        );
  @override
  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => domain is AnswerFixtureDomain
      ? (domain as AnswerFixtureDomain).askWithWebInConversation(
          question,
          conversation,
          requestId: requestId,
          meetingId: meetingId,
          current: current,
        )
      : application.askWithWebInConversation(
          question,
          conversation,
          requestId: requestId,
          meetingId: meetingId,
          current: current,
        );
  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) => domain.graphEmbeddings(sources);
  @override
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) events,
  ) async {}
  @override
  Future<void> disableDesktopApprovals() async {}

  @override
  Future<void> setDesktopVisible(bool visible) async {}
  @override
  void close() {
    if (_closing != null) return;
    domain.helper.changed = null;
    domain.helper.onReady = null;
    if (!_ready.isCompleted) _ready.complete();
    application.google.close();
    // Cancel owned application timers before the first asynchronous join, as
    // the production service does when closing its application owner.
    final applicationClosing = application.close();
    domain.close();
    _closing = () async {
      await _changes?.cancel();
      await applicationClosing;
      await domain.helper.close();
      await _initializing?.then<void>((_) {}, onError: (Object _) {});
      domain.store.close();
      await _events.close();
    }();
  }
}

class CommandFixtureDomain extends Domain {
  late final Application application;
  CommandFixtureDomain(super.store, super.helper);
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) => application.call(operation.wire, args);
}

class AnswerFixtureDomain extends Domain {
  late final Application application;
  AnswerFixtureDomain(super.store, super.helper);
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => application.askInConversation(
    question,
    conversation,
    requestId: requestId,
    meetingId: meetingId,
    current: current,
  );
  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => application.askWithWebInConversation(
    question,
    conversation,
    requestId: requestId,
    meetingId: meetingId,
    current: current,
  );
}
