import 'application_services/model_asset_acquisition.dart';
import 'operations.dart';
import 'operation_requests.dart';
import 'operation_registry.dart';
import 'operation_descriptor.dart';
import 'application_services/meeting_operations.dart';
import 'application_services/workspace_operations.dart';
import 'application_services/runtime_operations.dart';
import 'application_services/google_maintenance.dart';
import 'application_services/generation_coordinator.dart';
import 'application_services/model_registry.dart';
import 'application_services/answer_coordinator.dart';
import 'application_services/automatic_answer_coordinator.dart';
import 'application_services/meeting_questions.dart';
import 'application_services/recording_controller.dart';
import 'application_services/meeting_indexer.dart';
import 'application_services/note_enhancement_coordinator.dart';
import 'application_services/capture_activity.dart';
import 'application_services/meeting_workflow_coordinator.dart';
import 'application_services/source_operations.dart';
import 'application_services/summary_coordinator.dart';
import 'application_services/workspace_admin.dart';
import 'persistence/application_queries.dart' as workspace;
import 'persistence/meeting_queries.dart';
import 'persistence/read_schema_guard.dart';
export 'request_fingerprint.dart' show requestArgumentsDigest;
import 'rpc_error.dart';
import 'request_errors.dart';
import 'agent_access.dart';
import 'dart:async';
import 'package:meta/meta.dart';
import 'dart:io';
import 'domain.dart';
import 'model_gate.dart';
import 'recording.dart';
import 'proactive_questions.dart';
import 'dedicated_query_runtime.dart';
import 'store.dart';
import 'google_auth.dart';
import 'google_connections.dart';

/// Application operations shared by the desktop and external clients.
/// This object, its database, and its capture/model handles belong to one owner.
class Application implements ModelGate, GenerationReservationGate {
  /// User content erased atomically by workspace.clear.
  static const workspaceContentTables = workspace.workspaceContentTables;

  final Domain domain;
  ImportPolicy? get importPolicy => _sources.importPolicy;
  set importPolicy(ImportPolicy? value) => _sources.importPolicy = value;

  /// The identity (`ProfilePaths.identity`) of the profile whose service hosts
  /// this application. Status reports it, so a client of another profile that
  /// reaches this service never attaches to or stops it (SL-7).
  final _identity = ApplicationIdentity();
  String? get profileId => _identity.profileId;
  set profileId(String? value) => _identity.profileId = value;
  Store get store => domain.store;
  final changes = StreamController<void>.broadcast();
  final captureLevelChanges = StreamController<void>.broadcast();
  final _capture = CaptureActivity();
  Recording? get recording => _recordingController.recording;
  @visibleForTesting
  set recording(Recording? value) => _recordingController.recording = value;
  int? get recordingMeeting => _recordingController.recordingMeeting;
  @visibleForTesting
  set recordingMeeting(int? value) =>
      _recordingController.recordingMeeting = value;
  DateTime? get recordingBegan => _recordingController.recordingBegan;
  @visibleForTesting
  set recordingBegan(DateTime? value) =>
      _recordingController.recordingBegan = value;
  String get recordingState => _recordingController.recordingState;
  @visibleForTesting
  set recordingState(String value) =>
      _recordingController.recordingState = value;
  Map<String, String> get provisionalTranscript =>
      _recordingController.provisionalTranscript;
  bool _closed = false;
  Future<void>? _closing;
  bool get _clearingWorkspace => _workspace.clearing;
  late final GenerationCoordinator _generation = GenerationCoordinator(
    restoring: () => domain.restoring,
    generating: () => domain.generator?.generating ?? false,
    recording: () => recording != null,
    closed: () => _closed,
    yieldAutomatic: () async {
      if (proactive.running) await proactive.yieldToForeground();
      await _notes.yieldToForeground();
    },
  );
  @override
  bool get modelBusy => _generation.modelBusy;
  @override
  bool get generationReserved => _generation.generationReserved;
  late final ProactiveQuestions proactive = ProactiveQuestions(
    store: store,
    busy: () =>
        modelBusy ||
        generationReserved ||
        domain.generator == null ||
        domain.generator!.generating ||
        domain.sourcesPaused,
    changed: changed,
    cancel: (request) => _automaticAnswers.cancel(request),
    detect: _detectQuestions,
    answer: (id, question, request) =>
        _automaticAnswers.run(id, question, request),
  );
  late final AutomaticAnswerCoordinator _automaticAnswers =
      AutomaticAnswerCoordinator(
        domain: domain,
        answers: () => _answers,
        indexMeeting: (id) => indexMeeting(id),
        cancelDetection: (request) => _models.cancelDetection(request),
        changed: changed,
      );
  final GoogleAuth? _auth;
  final AnswerGateway? _providedAnswers;
  late final ModelRegistry _models;

  Application(
    this.domain, {
    GoogleAuth? auth,
    QueryCompletionRuntime? queryRuntime,
    AnswerGateway? answers,
  }) : _auth = auth,
       _providedAnswers = answers {
    _models = ModelRegistry(
      domain: domain,
      queryRuntime: queryRuntime,
      changed: changed,
      ownsDetection: (request) => proactive.ownsRequest(request),
      wakeDetection: () => proactive.wake(),
      invalidateEmbeddings: () => _notes.invalidateEmbeddings(),
    );
    domain.modelGate = this;
    domain.onBackgroundSettled = changed;
    domain.indexMeetingTranscript = _meetingIndexer.indexMeeting;
    _googleMaintenance.initialize();
  }

  Stream<String> ask(String question) => askInConversation(question, 'desktop');
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => _answers.ask(
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
  }) => _answers.ask(
    question,
    conversation,
    useWeb: true,
    requestId: requestId,
    meetingId: meetingId,
    current: current,
  );

  Future<int> autoAssignLabel(String name, {bool Function()? current}) =>
      _sources.autoAssignLabel(name, current: current);

  Future<List<String>> _detectQuestions(String text, String request) =>
      _models.detectQuestions(text, request);

  late final GoogleAuth googleAuth =
      _auth ?? GoogleAuth(Directory('${File(store.path).parent.path}/google'));
  late final MeetingQueries _meetings = store.meetingQueries;
  late final SummaryCoordinator _summary = SummaryCoordinator(
    domain: domain,
    generation: _generation,
    meetings: _meetings,
    modelDigest: () => _models.generationDigest,
    changed: changed,
  );
  late final MeetingWorkflowCoordinator _workflow = MeetingWorkflowCoordinator(
    domain: domain,
    generation: _generation,
    modelDigest: () => _models.generationDigest,
    changed: changed,
    wakeAutomatic: () => proactive.wake(),
  );
  late final NoteEnhancementCoordinator _notes = NoteEnhancementCoordinator(
    domain: domain,
    generation: _generation,
    proactive: proactive,
    meetings: _meetings,
    capture: _capture,
    changed: changed,
    indexSource: _workflow.indexSource,
    modelDigest: () => _models.generationDigest,
  );
  late final MeetingIndexer _meetingIndexer = MeetingIndexer(
    domain: domain,
    meetings: _meetings,
    capture: _capture,
    changed: changed,
  );
  late final RecordingController _recordingController = RecordingController(
    domain: domain,
    generation: _generation,
    proactive: proactive,
    notes: _notes,
    indexer: _meetingIndexer,
    capture: _capture,
    meetings: _meetings,
    changed: changed,
    levelsChanged: () {
      if (!_closed) captureLevelChanges.add(null);
    },
  );
  late final MeetingQuestions _questions = MeetingQuestions(
    domain: domain,
    coordinator: _generation,
    meetings: _meetings,
    modelDigest: () => _models.generationDigest,
  );
  late final AnswerGateway _answers =
      _providedAnswers ??
      AnswerCoordinator(
        domain: domain,
        proactive: proactive,
        notes: _notes,
        generation: _generation,
        profileId: () => profileId,
      );
  late final GoogleMaintenance _googleMaintenance = GoogleMaintenance(
    domain: domain,
    auth: googleAuth,
    meetings: _meetings,
    changed: changed,
  );
  late final SourceOperations _sources = SourceOperations(
    domain: domain,
    accounts: _googleMaintenance,
  );
  late final WorkspaceAdmin _workspace = WorkspaceAdmin(
    domain: domain,
    persistence: workspace.WorkspacePersistence(store),
    proactive: proactive,
    accounts: _googleMaintenance,
  );
  late final ModelAssetAcquisitionCoordinator _assetDownloads =
      ModelAssetAcquisitionCoordinator(store: store, changed: changed);
  late final RuntimeOperations _runtime = RuntimeOperations(
    domain: domain,
    identity: _identity,
    assetDownloads: _assetDownloads,
    generation: _generation,
    models: _models,
    workflow: _workflow,
    summary: _summary,
    notes: _notes,
    recording: _recordingController,
    accounts: _googleMaintenance,
    answers: _answers,
  );
  late final MeetingOperations _meetingOperations = MeetingOperations(
    domain: domain,
    proactive: proactive,
    notes: _notes,
    summary: _summary,
    workflow: _workflow,
    recording: _recordingController,
    indexer: _meetingIndexer,
    questions: _questions,
    runtime: _runtime,
    changed: changed,
  );
  late final WorkspaceOperations _workspaceOperations = WorkspaceOperations(
    store: store,
    proactive: proactive,
    recording: _recordingController,
    notes: _notes,
    summary: _summary,
    workflow: _workflow,
    workspace: _workspace,
    accounts: _googleMaintenance,
  );
  late final OperationRegistry _registry =
      OperationRegistry(OperationScope.application, [
        ..._runtime.handlers,
        ..._workspaceOperations.handlers,
        ..._meetingOperations.handlers,
        ..._sources.handlers,
        ..._googleMaintenance.handlers,
        ..._models.handlers,
        ..._assetDownloads.handlers,
      ]);
  Set<Operation> get registeredOperations => _registry.operations;

  GoogleConnections get google => _googleMaintenance.connections;
  Map<String, Object?> get googleState => _googleMaintenance.state;

  void startBackground() {
    _googleMaintenance.start();
    proactive.restore();
  }

  Future<void> maintainGoogle() => _googleMaintenance.maintain();

  /// Test-only background-work observations, including orphaned producers.
  bool get queryAcquiring => _models.acquiring;
  bool get configuringModel => _generation.configuring;
  int get activeEnhancements => _notes.activeWork;
  int get proactiveWork => _automaticAnswers.activeWork;
  int get transcriptComputing => _notes.computing;
  bool get backgroundBusy =>
      _meetingIndexer.busy ||
      _generation.configuring ||
      domain.resumeInProgress ||
      domain.initializationPending ||
      generationReserved ||
      _notes.activeWork > 0 ||
      proactive.running ||
      _automaticAnswers.activeWork > 0 ||
      _notes.computing > 0 ||
      domain.mutating > 0 ||
      _models.acquiring ||
      _assetDownloads.busy ||
      (domain.generator?.generating ?? false);

  void changed() {
    if (!_closed) changes.add(null);
  }

  Map<String, Object?>? get generationState => _runtime.generationState;
  Map<String, Object?> get captureState => _runtime.captureState;

  Future<Object?> call(
    String method,
    Map<String, dynamic> args, {
    bool Function()? current,
  }) async {
    _checkOpen();
    return callRequest(
      decodeOperationRequest(Operation.parse(method), args),
      current: current,
    );
  }

  void _checkOpen() {
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    if (_clearingWorkspace) {
      throw RpcError(RpcErrorCode.busy, 'Workspace is being cleared');
    }
  }

  /// Typed envelope validation precedes dispatch, including retries prepared
  /// before a clear when an item ID may have been reused in the new workspace.
  void checkRequestWorkspaceEpoch(OperationRequest request) {
    try {
      final epoch = request.context.workspaceEpoch;
      if (epoch == null || epoch == store.workspaceEpoch) return;
      throw RpcError(
        RpcErrorCode.notFound,
        request.context.rawArguments['id'] == null
            ? workspaceClearedChangeMessage
            : workspaceClearedItemMessage,
      );
    } on IncompatibleReadSchema catch (error) {
      throw error.rpcError;
    }
  }

  Future<Object?> callRequest(
    OperationRequest request, {
    bool Function()? current,
  }) async {
    try {
      _checkOpen();
      final generation = domain.workspaceGeneration;
      final callerCurrent = current;
      bool active() =>
          generation == domain.workspaceGeneration &&
          (callerCurrent?.call() ?? true);
      if (!active()) {
        throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
      }
      checkRequestWorkspaceEpoch(request);
      final configuring =
          request.operation.descriptor.modelGate ==
          ModelGatePolicy.configuration;
      if (configuring && proactive.running) {
        await proactive.yieldToForeground();
        _checkOpen();
        if (!active()) {
          throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
        }
      }
      final reservation = configuring ? _generation.configure() : null;
      try {
        return await _registry.dispatch(request, current: active);
      } finally {
        reservation?.settle();
        if (request.operation.notifiesChanges) changed();
      }
    } on IncompatibleReadSchema catch (error) {
      throw error.rpcError;
    }
  }

  Stream<Object?> signIn(String owner, {bool addAccount = false}) =>
      _googleMaintenance.signIn(owner, addAccount: addAccount);

  void cancelSignIn(String owner) => _googleMaintenance.cancelSignIn(owner);

  Future<String> importFile(
    String path, {
    bool Function()? current,
    bool Function()? indexing,
  }) => _sources.importFile(path, current: current, indexing: indexing);

  Future<String> importUrl(
    String value, {
    bool Function()? current,
    bool allowPrivateNetwork = false,
    bool Function()? indexing,
  }) => _sources.importUrl(
    value,
    current: current,
    allowPrivateNetwork: allowPrivateNetwork,
    indexing: indexing,
  );

  Future<void> importDirectory(String path, {bool Function()? current}) =>
      _sources.importDirectory(path, current: current);

  Future<void> reimport({
    bool Function()? current,
    bool allowPrivateNetwork = false,
  }) => _sources.reimport(
    current: current,
    allowPrivateNetwork: allowPrivateNetwork,
  );

  Future<void> indexMeeting(int id, {bool Function()? current}) =>
      _meetingIndexer.indexMeeting(id, current: current);

  Future<void> generateMeeting(
    int id,
    String kind, {
    String? requestId,
    bool Function()? current,
  }) => _meetingOperations.generateMeeting(
    id,
    kind,
    requestId: requestId,
    current: current,
  );

  bool cancelSummaryRequest(String request) =>
      _summary.cancelSummaryRequest(request);
  Future<void> generateSummary(
    int id, {
    String? requestId,
    bool Function()? current,
    bool refresh = true,
  }) => _summary.generateSummary(
    id,
    requestId: requestId,
    current: current,
    refresh: refresh,
  );

  bool cancelMeetingWorkflowRequest(String parent) {
    final workflow = _workflow.cancelMeetingWorkflowRequest(parent);
    final notes = _notes.cancelRequest(parent);
    return workflow || notes;
  }

  Future<void> enhanceNotes(
    int id, {
    bool deferWhenBusy = false,
    bool isLive = false,
    bool forceRegenerate = false,
    Set<int>? targetBulletIndices,
    String? requestId,
    bool Function()? current,
  }) => _notes.enhanceNotes(
    id,
    deferWhenBusy: deferWhenBusy,
    isLive: isLive,
    forceRegenerate: forceRegenerate,
    targetBulletIndices: targetBulletIndices,
    requestId: requestId,
    current: current,
  );

  Future<void> generateActions(
    int id, {
    String? requestId,
    bool Function()? current,
  }) => _workflow.generateActions(id, requestId: requestId, current: current);
  Future<void> prepareMeeting(
    int id,
    List<String> sourceIds, {
    String? requestId,
    bool Function()? current,
  }) => _workflow.prepareMeeting(
    id,
    sourceIds,
    requestId: requestId,
    current: current,
  );

  Future<void> startRecording(int id) =>
      _recordingController.startRecording(id);
  Future<void> stopRecording() => _recordingController.stopRecording();
  void pauseRecording([int? id]) => _recordingController.pauseRecording(id);
  void resumeRecording([int? id]) => _recordingController.resumeRecording(id);

  Future<void> recoverMeetingIndexes() => _meetingIndexer.recover();
  @visibleForTesting
  Map<String, int> get meetingIndexWork => _meetingIndexer.workMetrics;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    Object? failure;
    StackTrace? failureStack;
    void attempt(void Function() operation) {
      try {
        operation();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    Future<void> join(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    attempt(_meetingIndexer.stop);
    attempt(_summary.stop);
    attempt(_workflow.stop);
    attempt(_googleMaintenance.stop);
    attempt(_models.stop);
    attempt(_assetDownloads.stop);
    attempt(_recordingController.stopScheduling);
    // Stop physical capture now. Canceled/paused index producers must already
    // know they are closing before the recording owner joins their Futures.
    final recordingClose = _recordingController.close();
    recordingClose.ignore();
    attempt(_notes.stop);
    await join(_models.cancelAcquisition);
    await join(_assetDownloads.close);
    await join(proactive.close);
    await join(_automaticAnswers.close);
    await join(_generation.close);
    await join(_summary.close);
    await join(_workflow.close);
    await join(_notes.close);
    await join(_models.close);
    await join(_googleMaintenance.close);
    await join(() => recordingClose);
    await join(_meetingIndexer.close);
    await join(captureLevelChanges.close);
    await join(changes.close);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }
}
