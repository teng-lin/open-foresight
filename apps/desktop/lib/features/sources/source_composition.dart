part of 'sources_controller.dart';

extension _SourceComposition on SourcesController {
  Widget _featureGraphInspector(
    SourceSummary selected,
    List<SourceSummary> rows,
    List<GraphEdge> edges,
    List<DocumentLabel> labels,
  ) => GraphInspector(
    selected: selected,
    rows: rows,
    edges: edges,
    labels: labels,
    labelInput: graphLabelInput,
    enabled: !_operations.busy,
    relatedLoading: graphRelatedLoading,
    relatedError: graphRelatedError.isNotEmpty,
    openLink: _host.sourceLinkOpener,
    onSelect: selectGraphDocument,
    onAddLabel: (value) =>
        _operations.run(() => addSelectedGraphLabel(selected.id, value)),
    onRemoveLabel: (name) => removeSelectedGraphLabel(selected.id, name),
  );

  Color _featureFallbackGraphLabelColor() =>
      Theme.of(context).colorScheme.primary;

  GraphViewSnapshot _projectGraph(
    List<SourceSummary> rows,
    Map<String, GraphPoint> worldPoints,
    List<SourceSummary> matches,
    Map<String, List<Color>> documentLabelColors,
    Map<String, Color> labelColorsByName,
    Map<String, List<DocumentLabel>> documentLabelRecords,
    List<GraphCluster> clusters,
    BoxConstraints constraints,
  ) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    if (graphViewportSize != size) {
      graphViewportSize = size;
      scheduleGraphFit();
    }
    final rotated = rows.map((row) {
      final id = row.id;
      return rotateGraphPoint(
        worldPoints[id] ?? const GraphPoint(0, 0, 0),
        yaw: graphYaw,
        pitch: graphPitch,
      );
    }).toList();
    final positions = rotated
        .map(
          (point) => Offset(
            graphSceneOrigin + point.x * graphPaintPerspective(point.z),
            graphSceneOrigin + point.y * graphPaintPerspective(point.z),
          ),
        )
        .toList();
    final paintOrder = List.generate(rows.length, (i) => i)
      ..sort((a, b) => rotated[b].z.compareTo(rotated[a].z));
    final zoom = graphTransform.value.getMaxScaleOnAxis();
    final selected = rows
        .where((row) => row.id == graphSelectedDocument)
        .firstOrNull;
    final selectedId = selected?.id;
    final selectionEdges = selectedId == null
        ? <GraphEdge>[]
        : graphSelectionEdges;
    final connected = <String>{
      if (selectedId != null) selectedId,
      for (final edge in selectionEdges) ...[edge.source, edge.target],
    };
    final matchingIds = matches.map((row) => row.id).toSet();
    final dimmed = <String>{
      for (final row in rows)
        if (labelFilter.isNotEmpty
            ? !sourceLabels(row).contains(labelFilter)
            : selectedId != null
            ? !connected.contains(row.id)
            : !matchingIds.contains(row.id))
          row.id,
    };
    final painters = [
      for (var i = 0; i < rows.length; i++)
        GraphNodePainter(
          depth: rotated[i].z,
          zoom: zoom,
          labelColors: documentLabelColors[rows[i].id] ?? const [],
          matchColor: labelFilter.isEmpty
              ? Colors.white
              : labelColorsByName[labelFilter] ?? fallbackGraphLabelColor(),
          title: rows[i].title,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          textDirection: Directionality.of(context),
          selected: selectedId == rows[i].id,
          dimmed: dimmed.contains(rows[i].id),
          activeMatch:
              (sourceQuery.isNotEmpty || labelFilter.isNotEmpty) &&
              !dimmed.contains(rows[i].id),
        ),
    ];
    return GraphViewSnapshot(
      size: size,
      rows: rows,
      worldPoints: worldPoints,
      documentLabelRecords: documentLabelRecords,
      clusters: clusters,
      rotated: rotated,
      positions: positions,
      paintOrder: paintOrder,
      zoom: zoom,
      selected: selected,
      selectionEdges: selectionEdges,
      painters: painters,
    );
  }

  Widget _featureSourceGraph(
    List<SourceSummary> rows,
    Map<String, GraphPoint> worldPoints,
    List<SourceSummary> matches,
    Map<String, List<Color>> documentLabelColors,
    Map<String, Color> labelColorsByName,
    Map<String, List<DocumentLabel>> documentLabelRecords,
    List<GraphCluster> clusters,
  ) => LayoutBuilder(
    builder: (_, constraints) {
      final view = _projectGraph(
        rows,
        worldPoints,
        matches,
        documentLabelColors,
        labelColorsByName,
        documentLabelRecords,
        clusters,
        constraints,
      );
      final selected = view.selected;
      return SourceGraphScene(
        view: view,
        transform: graphTransform,
        yaw: graphYaw,
        pitch: graphPitch,
        labelFilter: labelFilter,
        panEnabled: graphMousePointer == null,
        animationPaused: graphAnimationPaused,
        organizing: graphOrganizing,
        layoutError: graphLayoutError,
        inspector: selected == null
            ? null
            : graphInspector(
                selected,
                view.rows,
                view.selectionEdges,
                view.documentLabelRecords[selected.id] ?? const [],
              ),
        onSelect: selectGraphDocument,
        onPointerDown: startGraphPointer,
        onPointerMove: moveGraphPointer,
        onPointerEnd: endGraphPointer,
        onZoom: zoomGraph,
        onFit: fitGraph,
        onToggleAnimation: () =>
            update(() => graphAnimationPaused = !graphAnimationPaused),
      );
    },
  );
  Map<String, String> _featureDriveSourceMimes() => _reads.originalMimes;

  List<SourceSummary> _featureFilteredSources([
    List<SourceSummary>? collection,
    Map<String, String>? originalMimes,
  ]) {
    final originals = originalMimes ?? driveSourceMimes();
    final searchMatches = sourceQuery.isEmpty
        ? null
        : _reads.searchMatches ??
              {
                for (final source in collection ?? _reads.sources)
                  if (source.title.toLowerCase().contains(
                    sourceQuery.toLowerCase(),
                  ))
                    source.id,
              };
    final rows = (collection ?? _reads.sources)
        .where(
          (s) =>
              (searchMatches == null || searchMatches.contains(s.id)) &&
              (labelFilter.isEmpty || sourceLabels(s).contains(labelFilter)) &&
              (typeFilter == null || typeOf(s, originals) == typeFilter),
        )
        .toList();
    rows.sort(
      (a, b) =>
          (ascending ? 1 : -1) *
          (a.title).toLowerCase().compareTo((b.title).toLowerCase()),
    );
    return rows;
  }

  SourceCollectionSnapshot _collectionSnapshot() {
    final all = _reads.sources;
    final originals = driveSourceMimes();
    final rows = filteredSources(all, originals);
    final labelRecords = _reads.labels;
    final clusters = _reads.clusters
        .map((c) => GraphCluster(c.label, GraphPoint(c.x, c.y, 0), c.radius))
        .toList();
    final fallbackLabelColor = Theme.of(context).colorScheme.primary;
    final documentLabelRecords = <String, List<DocumentLabel>>{};
    final documentLabelColors = <String, List<Color>>{};
    final labelColorsByName = <String, Color>{};
    for (final record in labelRecords) {
      documentLabelRecords.putIfAbsent(record.documentId, () => []).add(record);
      final color = graphLabelColor(record.colorHex, fallbackLabelColor);
      documentLabelColors.putIfAbsent(record.documentId, () => []).add(color);
      labelColorsByName.putIfAbsent(record.name, () => color);
    }
    final graphRows = _graphRows;
    final counts = <SourceType, int>{};
    for (final source in all) {
      final type = typeOf(source, originals);
      counts[type] = (counts[type] ?? 0) + 1;
    }
    final labels = {
      ...all.expand(sourceLabels),
      ..._reads.clusterNames,
      if (labelFilter.isNotEmpty) labelFilter,
    }.toList()..sort();
    return SourceCollectionSnapshot(
      all: all,
      rows: rows,
      graphRows: graphRows,
      originals: originals,
      clusters: clusters,
      documentLabelRecords: documentLabelRecords,
      documentLabelColors: documentLabelColors,
      labelColorsByName: labelColorsByName,
      counts: counts,
      labels: labels,
    );
  }

  SourceType _featureTypeOf(
    SourceSummary source,
    Map<String, String> originals,
  ) => sourceCollectionType(source, originals);
  String _featureTypeName(SourceType type) => sourceCollectionTypeName(type);
  IconData _featureTypeIcon(SourceType type) => sourceCollectionTypeIcon(type);
  Color _featureSourceColor(SourceType type) => sourceCollectionColor(type);
  IconData _featureSourceIcon(SourceSummary source, {String? originalMime}) =>
      sourceCollectionIcon(source, originalMime: originalMime);
  Widget _featureSources() {
    final view = _collectionSnapshot();
    return SourceCollectionView(
      view: view,
      presentation: SourceCollectionPresentation(
        graphView: graphView,
        gridView: gridView,
        ascending: ascending,
        typeFilter: typeFilter,
        labelFilter: labelFilter,
        sourceQuery: sourceQuery,
        sourcesPaused: d.sourcesPaused,
        googleConnected: integrationFeature.googlePresentation.connected,
        googleSyncStatus: integrationFeature.googlePresentation.connected
            ? integrationFeature.googleSyncStatus()
            : '',
        busy: _operations.busy,
        driveAvailable: integrationFeature.driveAvailable,
        deviceName: _host.environment.capabilities.deviceName,
      ),
      problem: _reads.problem,
      searchController: sourceSearchController,
      graph: AnimatedBuilder(
        animation: Listenable.merge([graphMotionFrames, graphTransform]),
        builder: (_, __) => sourceGraph(
          view.graphRows,
          graphWorldPoints,
          view.rows,
          view.documentLabelColors,
          view.labelColorsByName,
          view.documentLabelRecords,
          view.clusters,
        ),
      ),
      onTogglePause: () => update(() {
        if (d.sourcesPaused) {
          d.resumeSources();
        } else {
          d.pauseSources();
        }
      }),
      onReimport: () => _operations.run(reimport),
      onGraphView: (value) => update(() => graphView = value),
      onSearch: (value) => update(() => sourceQuery = value),
      onCreateLabel: createOrganizationLabel,
      onDeleteLabel: (label) => deleteOrganizationLabel(label),
      onLabelSelected: (label) =>
          update(() => labelFilter = labelFilter == label ? '' : label),
      onTypeSelected: (type) => update(
        () => typeFilter = type == null || typeFilter == type ? null : type,
      ),
      onClearFilters: () => update(() {
        sourceQuery = '';
        sourceSearchController.clear();
        labelFilter = '';
        typeFilter = null;
      }),
      onToggleSort: () => update(() => ascending = !ascending),
      onGridView: (grid) => update(() => gridView = grid),
      onImport: _importCollectionChoice,
      onOpen: showSource,
      onEditLabels: (source) => editLabels(source),
      onIndex: (id) => _operations.run(() => d.index(id)),
      onDelete: (id) => _operations.run(() => d.delete(id)),
    );
  }

  void _importCollectionChoice(String choice) => _operations.run(() async {
    switch (choice) {
      case 'file':
        await import();
      case 'folder':
        await importFolder();
      case 'find-files':
        await findLocalFiles();
      case 'url':
        await importUrl();
      case 'drive-file':
        await integrationFeature.chooseDrive();
      case 'drive-folder':
        await integrationFeature.chooseDrive(folder: true);
      case 'drive-year':
        if (!integrationFeature.googlePresentation.connected)
          await integrationFeature.connectGoogle();
        if (mounted && integrationFeature.googlePresentation.connected) {
          await integrationFeature.importLastYear();
        }
    }
  });
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

  Widget _composeSourceTile(SourceSummary source, {String? originalMime}) =>
      gridView
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
  void _composeSyncGraphMotion() {
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

  void _composeTickGraphMotion(Duration elapsed) {
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
}
