import 'note_widgets.dart';
import 'source_tiles.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:foresight_core/desktop.dart';
import 'read_model.dart';
import 'typed_graph.dart';
import '../../desktop_visuals.dart';
import '../../feature_request_identity.dart';
import '../../service_edit_dialog.dart';
import '../../presentation/workspace_presentation.dart';
import '../../shell/ports.dart';
import '../../shell/workspace_tab.dart';
import 'file_discovery_sheet.dart';
import 'graph_label_controls.dart';
import 'graph_rendering.dart';
import 'cluster_rendering.dart';
import 'source_painters.dart';

part 'source_actions.dart';
part 'source_labels.dart';
part 'source_collection.dart';
part 'graph_layout_owner.dart';
part 'graph_interaction.dart';
part 'graph_widgets.dart';

const _blue = workspaceBlue;
const _ink = workspaceInk;

// Each graph.embeddings reply must fit the service's 16 MiB frame limit.
const _graphEmbeddingBatch = 128;

class SourcesController implements SourceCommands {
  SourcesController({
    required FeatureHost host,
    required WorkspaceNavigation navigation,
    required OperationGate operations,
    required WorkspaceDialogs dialogs,
    required IntegrationsPort integrations,
  }) : _host = host,
       _navigation = navigation,
       _operations = operations,
       _dialogs = dialogs,
       integrationFeature = integrations;

  final FeatureHost _host;
  final WorkspaceNavigation _navigation;
  final OperationGate _operations;
  final WorkspaceDialogs _dialogs;
  final IntegrationsPort integrationFeature;
  bool _disposed = false;
  late final SourcesReadModel _reads = SourcesReadModel(
    connection: () => d,
    changed: () {
      if (!mounted) return;
      update(() {
        if (noteLoading &&
            !(_noteLoadOwner?.isCurrent(d, alive: mounted) ?? false)) {
          noteLoading = false;
        }
      });
    },
  );
  List<SourceSummary> _graphRows = const [];

  void _prepareGraphScene() {
    if (!graphView) return;
    final all = _reads.sources;
    graphSceneClusters = _reads.clusters
        .map((c) => GraphCluster(c.label, GraphPoint(c.x, c.y, 0), c.radius))
        .toList();
    graphSceneLabels = {};
    for (final label in _reads.labels) {
      graphSceneLabels.putIfAbsent(label.documentId, () => []).add(label);
    }
    scheduleGraphLayout(all);
    _graphRows = typedGraphSceneSources(all, graphSceneVectors);
    final ids = _graphRows.map((s) => s.id).toList()..sort();
    final fallback = uniformGraphLayout(ids);
    graphWorldPoints = {
      for (final id in ids)
        id: graphWorldPoint(
          graphPoints[id] ?? fallback[id]!,
          uniform: !graphPoints.containsKey(id),
        ),
    };
  }

  DesktopConnection get d => _host.connection;
  bool get mounted => !_disposed && _host.mounted;
  BuildContext get context => _host.context;
  void update(VoidCallback action) {
    if (mounted)
      _host.update(() {
        action();
        _prepareGraphScene();
      });
  }

  void setState(VoidCallback action) => update(action);
  Widget pill(
    String title,
    VoidCallback? action, {
    IconData? icon,
    bool selected = false,
  }) => workspacePill(title, action, icon: icon, selected: selected);
  Widget heading(String title, {List<Widget> actions = const []}) =>
      workspaceHeading(title, actions: actions);
  Widget searchBox(
    String hint,
    ValueChanged<String> onChanged, {
    TextEditingController? controller,
  }) => workspaceSearchBox(
    hint,
    (value) => update(() => onChanged(value)),
    controller: controller,
  );
  String timeLabel(Object? stamp) => workspaceTimeLabel(stamp);

  void initializeGraph() {
    _reads.start();
    _host.serviceUiRevision.addListener(_coarseServiceChanged);
    var lastNoteText = noteBody.text;
    noteBody.addListener(() {
      if (lastNoteText == noteBody.text) return;
      lastNoteText = noteBody.text;
      _noteDraftRevision++;
    });
    graphMotionTicker = _host.vsync.createTicker(tickGraphMotion);
    graphCameraController = AnimationController(vsync: _host.vsync);
    graphCameraController.addListener(() {
      final tween = graphCameraTween;
      if (mounted && tween != null) {
        graphTransform.value = tween.transform(
          graphCameraCurve.transform(graphCameraController.value),
        );
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_reads.dispose());
    _host.serviceUiRevision.removeListener(_coarseServiceChanged);
    graphMotionTicker.dispose();
    graphCameraController.dispose();
    graphMotionFrames.dispose();
    graphTransform.dispose();
    sourceSearchController.dispose();
    graphLabelInput.dispose();
    noteTitle.dispose();
    noteBody.dispose();
  }

  final noteTitle = TextEditingController();
  final noteBody = TextEditingController();
  int? noteId;
  int noteEditorGeneration = 0;

  /// A retry of an unconfirmed create reuses its key, so it creates once.
  final newNoteKey = PendingRequestKey();

  /// The note editor's text as last loaded or saved.
  (String, String) noteBaseline = ('', '');

  bool _graphView = false;
  bool get graphView => _graphView;
  set graphView(bool value) {
    _graphView = value;
    if (value) _queueGraphScene();
  }

  bool _sceneQueued = false;
  void _queueGraphScene() {
    if (_sceneQueued || _disposed) return;
    _sceneQueued = true;
    scheduleMicrotask(() {
      _sceneQueued = false;
      if (mounted) _prepareGraphScene();
    });
  }

  bool gridView = false;

  bool ascending = true;

  String _sourceQuery = '';
  String get sourceQuery => _sourceQuery;
  set sourceQuery(String value) {
    _sourceQuery = value;
    _reads.search(value);
  }

  String labelFilter = '';

  final sourceSearchController = TextEditingController();

  Set<String> get sourceSearchMatches => _reads.searchMatches ?? const {};

  SourceType? typeFilter;

  final graphTransform = TransformationController();

  final graphLabelInput = TextEditingController();

  Size? graphViewportSize;

  late final AnimationController graphCameraController;

  Matrix4Tween? graphCameraTween;

  Curve graphCameraCurve = const Cubic(.645, .045, .355, 1);

  Map<String, GraphPoint> graphPoints = {};

  Map<String, GraphPoint> graphWorldPoints = {};

  List<GraphCluster> graphSceneClusters = [];

  Map<String, List<DocumentLabel>> graphSceneLabels = {};

  List<GraphEdge> graphEdges = [];

  Map<String, List<double>> graphSceneVectors = {};

  String? graphSelectedDocument;

  int graphOrganizationRevision = 0;

  List<GraphEdge> graphSelectionEdges = [];

  int graphSelectionRevision = 0;

  bool graphRelatedLoading = false;

  String graphRelatedError = '';

  String graphLayoutKey = '';

  FeatureRequestIdentity? _graphLayoutOwner;

  bool graphOrganizing = false;

  String graphLayoutError = '';

  double graphYaw = 0;

  double graphPitch = 0;

  int? graphMousePointer;

  Offset? graphPointerStart;

  Offset? graphPointerLast;

  bool graphPointerRotates = false;

  bool graphDragMoved = false;

  final graphVectorCache = <String, List<double>>{};

  final graphMotionFrames = ValueNotifier<int>(0);

  late final Ticker graphMotionTicker;

  Duration? graphLastTick;

  bool graphAnimationPaused = false;

  bool graphManualPitch = false;

  bool graphModalOpen = false;

  void _coarseServiceChanged() {
    if (graphView) _queueGraphScene();
  }

  void syncGraphMotion() {
    final enabled =
        mounted &&
        _navigation.selectedTab == WorkspaceTab.sources &&
        graphView &&
        _reads.sources.isNotEmpty &&
        !graphAnimationPaused &&
        graphMousePointer == null &&
        !graphModalOpen &&
        !MediaQuery.disableAnimationsOf(context);
    if (enabled && !graphMotionTicker.isActive) {
      graphLastTick = null;
      // The callback intentionally schedules work owned by its controller.
      // ignore: discarded_futures
      graphMotionTicker.start();
    } else if (!enabled && graphMotionTicker.isActive) {
      graphMotionTicker.stop();
      graphLastTick = null;
    }
  }

  void tickGraphMotion(Duration elapsed) {
    final previous = graphLastTick;
    graphLastTick = elapsed;
    if (!mounted ||
        previous == null ||
        graphMousePointer != null ||
        graphAnimationPaused ||
        graphModalOpen ||
        _navigation.selectedTab != WorkspaceTab.sources ||
        !graphView)
      return;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    // Keep idle graph motion slow, with gentler motion while a source is selected.
    graphYaw += seconds * .025 * (graphSelectedDocument == null ? 1 : .05);
    if (!graphManualPitch) graphPitch = .4 + math.sin(graphYaw * .4) * .08;
    graphMotionFrames.value++;
  }

  Future<void> importFolderPath(String path) => _featureImportFolderPath(path);

  @override
  Future<void> findLocalFiles({List<String>? roots}) =>
      _featureFindLocalFiles(roots: roots);

  Future<void> refreshSources() => _featureRefreshSources();

  Future<void> importSourceUrl(String address) =>
      _featureImportSourceUrl(address);

  @override
  Future<void> import() => _featureImport();

  @override
  Future<void> source(Map<String, Object?> row) => _featureSource(row);

  @override
  Future<bool> sourceById(String id, {int? expectedRevision}) =>
      _featureSourceById(id, expectedRevision: expectedRevision);

  Future<void> editSource(Map<String, Object?> s) => _featureEditSource(s);

  FeatureRequestIdentity? _noteLoadOwner;
  int _noteDraftRevision = 0, _noteBodyLoadRevision = 0;
  (int, int)? _acceptedNoteBody;
  String _noteLoadError = '';
  bool noteLoading = false, _noteBodyNeedsReview = false;
  bool get _noteBodyAcceptedCurrent =>
      _acceptedNoteBody == (noteId, noteEditorGeneration) &&
      (_noteLoadOwner?.isCurrent(d, alive: mounted) ?? false);
  // Rendering consumes accepted body/session facts only. All edit/save/review
  // callbacks retain the authoritative durable-epoch check above.
  bool get _noteBodyPreparedCurrent =>
      _acceptedNoteBody == (noteId, noteEditorGeneration) &&
      (_noteLoadOwner?.matchesConnection(d, alive: mounted) ?? false);
  bool get _noteBodyPreparedReady =>
      noteId == null || (_noteBodyPreparedCurrent && !_noteBodyNeedsReview);
  bool get noteBodyReady =>
      noteId == null || (_noteBodyAcceptedCurrent && !_noteBodyNeedsReview);
  Future<void> openNote(NoteSummary note) => _featureOpenNote(note);

  void showSource(String id) => _featureShowSource(id);

  Widget notes() => _featureNotes();

  Future<void> importPath(String path) => _featureImportPath(path);

  Future<void> findFilesOnComputer({List<String>? roots}) =>
      _featureFindFilesOnComputer(roots: roots);

  Future<void> importSelectedPaths(List<String> selected) =>
      _featureImportSelectedPaths(selected);

  @override
  Future<void> importFolder() => _featureImportFolder();

  Future<void> reviewFolderImport(String path) =>
      _featureReviewFolderImport(path);

  Future<void> importDirectory(String path) => _featureImportDirectory(path);

  Future<void> reimport() => _featureReimport();

  @override
  Future<void> importUrl() => _featureImportUrl();

  Future<void> importAddress(
    String value, {
    bool allowPrivateNetwork = false,
  }) => _featureImportAddress(value, allowPrivateNetwork: allowPrivateNetwork);

  List<String> sourceLabels(SourceSummary s) => _featureSourceLabels(s);

  Future<void> putDocumentLabel(DocumentLabel label) =>
      _featurePutDocumentLabel(label);

  Future<bool> saveGraphLayout(
    String identity,
    List<SourceSummary> sources,
    Map<String, List<double>> vectors,
    Map<String, GraphPoint> points, {
    String? labelSet,
    List<GraphCluster> clusters = const [],
  }) => _featureSaveGraphLayout(
    identity,
    sources,
    vectors,
    points,
    labelSet: labelSet,
    clusters: clusters,
  );

  Future<void> addSelectedGraphLabel(String id, String value) =>
      _featureAddSelectedGraphLabel(id, value);

  Future<void> removeSelectedGraphLabel(String id, String name) =>
      _featureRemoveSelectedGraphLabel(id, name);

  Future<void> createOrganizationLabel() => _featureCreateOrganizationLabel();

  Future<void> autoAssignOrganizationLabel(String name) =>
      _featureAutoAssignOrganizationLabel(name);

  Future<void> deleteOrganizationLabel(String name) =>
      _featureDeleteOrganizationLabel(name);

  Future<void> editLabels(SourceSummary? s) => _featureEditLabels(s);

  Map<String, String> driveSourceMimes() => _featureDriveSourceMimes();

  SourceType typeOf(SourceSummary source, Map<String, String> originals) =>
      _featureTypeOf(source, originals);

  String typeName(SourceType type) => _featureTypeName(type);

  IconData typeIcon(SourceType type) => _featureTypeIcon(type);

  List<SourceSummary> filteredSources([
    List<SourceSummary>? collection,
    Map<String, String>? originalMimes,
  ]) => _featureFilteredSources(collection, originalMimes);

  Color sourceColor(SourceType type) => _featureSourceColor(type);

  IconData sourceIcon(SourceSummary source, {String? originalMime}) =>
      _featureSourceIcon(source, originalMime: originalMime);

  Widget sources() => _featureSources();

  String sourceTimeLabel(Object? stamp) =>
      stamp == null || stamp == 0 ? '--' : timeLabel(stamp);

  Widget sourceCells(SourceSummary? source, {String? originalMime}) =>
      SourceCells(
        source: source,
        icon: source == null
            ? null
            : sourceIcon(source, originalMime: originalMime),
        color: source == null
            ? null
            : sourceColor(typedSourceType(source, originalMime: originalMime)),
        imported: source == null ? '' : sourceTimeLabel(source.imported),
        changed: source == null ? '' : sourceTimeLabel(source.changed),
        labels: source == null ? '' : sourceLabels(source).join(', '),
        ascending: ascending,
        onSort: () => update(() => ascending = !ascending),
        onEditLabels: source == null || _operations.busy
            ? null
            : () => editLabels(source),
        onIndex: source == null || _operations.busy
            ? null
            : () => _operations.run(() => d.index(source.id)),
        onDelete: source == null || _operations.busy
            ? null
            : () => _operations.run(() => d.delete(source.id)),
      );

  Widget sourceTile(SourceSummary source, {String? originalMime}) => gridView
      ? sourceCardTile(source, originalMime: originalMime)
      : SourceRow(
          source: source,
          cells: sourceCells(source, originalMime: originalMime),
          onOpen: () => showSource(source.id),
        );

  Widget sourceCardTile(SourceSummary s, {String? originalMime}) => SourceCard(
    s: s,
    icon: sourceIcon(s, originalMime: originalMime),
    color: sourceColor(typedSourceType(s, originalMime: originalMime)),
    labels: sourceLabels(s).join(', '),
    onOpen: () => showSource(s.id),
    onEditLabels: _operations.busy ? null : () => editLabels(s),
    onIndex: _operations.busy
        ? null
        : () => _operations.run(() => d.index(s.id)),
    onDelete: _operations.busy
        ? null
        : () => _operations.run(() => d.delete(s.id)),
  );

  void scheduleGraphLayout(List<SourceSummary> all) =>
      _featureScheduleGraphLayout(all);

  void scheduleGraphFit() => _featureScheduleGraphFit();

  void fitGraph() => _featureFitGraph();

  void animateGraphCamera(Matrix4 target, {bool zoomButton = false}) =>
      _featureAnimateGraphCamera(target, zoomButton: zoomButton);

  void zoomGraph(double factor) => _featureZoomGraph(factor);

  void startGraphPointer(PointerDownEvent event) =>
      _featureStartGraphPointer(event);

  void moveGraphPointer(PointerMoveEvent event) =>
      _featureMoveGraphPointer(event);

  void endGraphPointer(PointerEvent event) => _featureEndGraphPointer(event);

  void selectGraphDocument(String? document) =>
      _featureSelectGraphDocument(document);

  void refreshGraphSelection() => _featureRefreshGraphSelection();

  Future<void> completeGraphSelection(
    String document,
    int revision,
    Map<String, List<double>> vectors,
    List<GraphEdge> whole,
  ) => _featureCompleteGraphSelection(document, revision, vectors, whole);

  Widget graphInspector(
    SourceSummary selected,
    List<SourceSummary> rows,
    List<GraphEdge> edges,
    List<DocumentLabel> labels,
  ) => _featureGraphInspector(selected, rows, edges, labels);

  Color fallbackGraphLabelColor() => _featureFallbackGraphLabelColor();

  Widget sourceGraph(
    List<SourceSummary> rows,
    Map<String, GraphPoint> worldPoints,
    List<SourceSummary> matches,
    Map<String, List<Color>> documentLabelColors,
    Map<String, Color> labelColorsByName,
    Map<String, List<DocumentLabel>> documentLabelRecords,
    List<GraphCluster> clusters,
  ) => _featureSourceGraph(
    rows,
    worldPoints,
    matches,
    documentLabelColors,
    labelColorsByName,
    documentLabelRecords,
    clusters,
  );
  Future<void> _featureOpenNote(NoteSummary note) => _loadNoteBody(
    note.id,
    note.title,
    resetEditor: noteId != note.id || noteBodyReady,
  );

  Future<void> _loadNoteBody(
    int id,
    String title, {
    required bool resetEditor,
  }) async {
    if (!mounted) return;
    final owner = _noteLoadOwner = FeatureRequestIdentity.capture(d);
    final generation = ++noteEditorGeneration;
    final preserveBody =
        !resetEditor && _noteDraftRevision != _noteBodyLoadRevision;
    setState(() {
      newNoteKey.reset();
      noteId = id;
      noteLoading = true;
      _acceptedNoteBody = null;
      _noteBodyNeedsReview = false;
      _noteLoadError = '';
      if (resetEditor) {
        noteTitle.text = title;
        noteBody.clear();
        noteBaseline = (title, '');
        _noteBodyLoadRevision = _noteDraftRevision;
      }
    });
    final draftRevision = _noteDraftRevision;
    bool current() =>
        owner.isCurrent(d, alive: mounted) &&
        generation == noteEditorGeneration &&
        noteId == id;
    try {
      final body = await d.store.read(StoreReadQueries.noteBody(id));
      if (!current()) return;
      if (body.error != null) throw body.error!;
      if (!body.current) {
        throw RpcError(
          RpcErrorCode.unavailable,
          'Note is refreshing; try again.',
        );
      }
      setState(() {
        final savedBody = body.value ?? '';
        _noteBodyNeedsReview =
            (preserveBody || _noteDraftRevision != draftRevision) &&
            noteBody.text != savedBody;
        if (!_noteBodyNeedsReview) {
          noteBody.text = savedBody;
          _noteBodyLoadRevision = _noteDraftRevision;
        }
        noteBaseline = (title, savedBody);
        _acceptedNoteBody = (id, generation);
      });
    } catch (failure) {
      if (current()) {
        setState(() => _noteLoadError = failure.toString());
        rethrow;
      }
    } finally {
      // Settlement releases this editor's loading state even if its owner was
      // retired. The body remains unaccepted; a newer selection/load owns its
      // own loading flag and is never cleared by this completion.
      if (mounted && generation == noteEditorGeneration && noteId == id)
        setState(() => noteLoading = false);
    }
  }

  void _featureShowSource(String id) {
    final owner = FeatureRequestIdentity.capture(d);
    unawaited(
      sourceById(id).catchError((Object error) {
        if (owner.isCurrent(d, alive: mounted))
          _operations.reportAsyncError(error);
        return false;
      }),
    );
  }

  Widget _featureNotes() => NoteEditor(
    notes: _reads.notes,
    noteTitle: noteTitle,
    noteBody: noteBody,
    canSave: !noteLoading && _noteBodyPreparedReady,
    status: _noteLoadStatus(),
    problem: _reads.problem,
    onNew: _newNoteDraft,
    onSave: _saveNote,
    onOpen: (note) =>
        unawaited(openNote(note).catchError(_operations.reportAsyncError)),
  );

  void _newNoteDraft() {
    setState(() {
      noteEditorGeneration++;
      noteId = null;
      noteLoading = false;
      _acceptedNoteBody = null;
      _noteBodyNeedsReview = false;
      _noteLoadError = '';
      noteBaseline = ('', '');
      newNoteKey.reset();
      noteTitle.clear();
      noteBody.clear();
    });
  }

  void _saveNote() {
    // A callback built before a session/epoch replacement must
    // not treat its accepted body as current after replacement.
    if (!mounted || noteLoading || !noteBodyReady) return;
    unawaited(
      _operations.run(() async {
        if (!mounted || noteLoading || !noteBodyReady) return;
        // Every send names the workspace this save began in, and a
        // reply that arrives after a reset is not shown: it names an
        // ID the views have dropped.
        final epoch = d.workspaceEpoch;
        final identity = FeatureRequestIdentity.capture(d);
        var originalId = noteId;
        final editorGeneration = noteEditorGeneration;
        bool current() =>
            identity.isCurrent(d, alive: mounted) &&
            noteId == originalId &&
            noteEditorGeneration == editorGeneration;
        Map<String, dynamic> scoped(Map<String, dynamic> args) => {
          ...args,
          if (epoch != null) 'workspace_epoch': epoch,
        };
        final note = {'title': noteTitle.text, 'body': noteBody.text};
        void saved(int id) => setState(() {
          noteId = id;
          noteBaseline = (note['title']!, note['body']!);
          _acceptedNoteBody = (id, noteEditorGeneration);
          _noteLoadOwner = identity;
          _noteBodyNeedsReview = false;
          _noteLoadError = '';
          if (noteBody.text == note['body'])
            _noteBodyLoadRevision = _noteDraftRevision;
        });
        final id = noteId;
        if (id != null) {
          await d.command(Operation.notesSave, scoped({...note, 'id': id}));
          if (current()) saved(id);
          return;
        }
        final created =
            await newNoteKey.run(
                  note,
                  (keyed) => d.command(Operation.notesSave, scoped(keyed)),
                  // Edited after an unconfirmed save: the first save
                  // is now known, so the edit updates that note.
                  amend: (first, edited) async {
                    final id = (first as Map)['id'] as int;
                    if (current()) {
                      setState(() {
                        originalId = id;
                        noteId = id;
                      });
                    }
                    return d.command(
                      Operation.notesSave,
                      scoped({...edited, 'id': id}),
                    );
                  },
                )
                as Map;
        if (current()) saved(created['id'] as int);
      }),
    );
  }

  Widget _noteLoadStatus() {
    final id = noteId;
    if (id == null || noteLoading || _noteBodyPreparedReady)
      return const SizedBox.shrink();
    if (_noteBodyPreparedCurrent && _noteBodyNeedsReview) {
      final accepted = _acceptedNoteBody!;
      return ListTile(
        title: const Text(
          'Review the saved note before replacing it with this draft.',
        ),
        trailing: TextButton(
          onPressed: () => unawaited(
            _reviewLoadedNote(
              accepted,
            ).catchError(_operations.reportAsyncError),
          ),
          child: const Text('Review saved note'),
        ),
      );
    }
    final current =
        _noteLoadOwner?.matchesConnection(d, alive: mounted) ?? false;
    return ListTile(
      title: Text(
        current && _noteLoadError.isNotEmpty
            ? _noteLoadError
            : 'Reload this note before saving.',
      ),
      trailing: TextButton(
        onPressed: () {
          if (!mounted || noteId != id || noteLoading || noteBodyReady) return;
          unawaited(
            _loadNoteBody(
              id,
              noteBaseline.$1,
              resetEditor: false,
            ).catchError(_operations.reportAsyncError),
          );
        },
        child: const Text('Retry loading note'),
      ),
    );
  }

  Future<void> _reviewLoadedNote((int, int) accepted) async {
    if (!mounted ||
        !_noteBodyAcceptedCurrent ||
        !_noteBodyNeedsReview ||
        accepted != _acceptedNoteBody)
      return;
    final owner = FeatureRequestIdentity.capture(d);
    final saved = noteBaseline;
    final useSaved = await showDialog<bool>(
      context: context,
      builder: (_) => SavedNoteReviewDialog(title: saved.$1, body: saved.$2),
    );
    if (useSaved == null ||
        !owner.isCurrent(d, alive: mounted) ||
        accepted != _acceptedNoteBody ||
        !_noteBodyNeedsReview)
      return;
    setState(() {
      if (useSaved) {
        noteTitle.text = saved.$1;
        noteBody.text = saved.$2;
        _noteBodyLoadRevision = _noteDraftRevision;
      }
      _noteBodyNeedsReview = false;
    });
  }
}

class SourcesView extends StatelessWidget {
  final SourcesController controller;
  const SourcesView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) => controller.sources();
}
