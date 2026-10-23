part of 'sources_controller.dart';

extension _GraphWidgets on SourcesController {
  Widget _featureGraphInspector(
    SourceSummary selected,
    List<SourceSummary> rows,
    List<GraphEdge> edges,
    List<DocumentLabel> labels,
  ) {
    final id = selected.id;
    final sourceUri = selected.sourceUri ?? '';
    final byId = {for (final row in rows) row.id: row};
    final related =
        edges
            .map(
              (edge) => (
                row: byId[edge.source == id ? edge.target : edge.source],
                similarity: edge.similarity,
              ),
            )
            .where((item) => item.row != null)
            .toList()
          ..sort((a, b) => b.similarity.compareTo(a.similarity));
    return Material(
      key: const ValueKey('graph-inspector'),
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    selected.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (sourceUri.isNotEmpty)
                  IconButton(
                    key: const ValueKey('graph-inspector-link'),
                    tooltip: sourceUri,
                    onPressed: () async {
                      final uri = Uri.tryParse(sourceUri);
                      if (uri == null || !allowedSourceUri(uri)) return;
                      try {
                        await _host.sourceLinkOpener(uri);
                      } catch (_) {
                        if (context.mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Could not open the source link.'),
                            ),
                          );
                      }
                    },
                    icon: const Icon(Icons.link, size: 18),
                  ),
                IconButton(
                  key: const ValueKey('graph-inspector-close'),
                  tooltip: 'Close inspector',
                  onPressed: () => selectGraphDocument(null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            GraphLabelControls(
              labels: labels,
              controller: graphLabelInput,
              enabled: !_operations.busy,
              onAdd: (value) =>
                  _operations.run(() => addSelectedGraphLabel(id, value)),
              onRemove: (name) => removeSelectedGraphLabel(id, name),
            ),
            const SizedBox(height: 8),
            const Text(
              'Related documents:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (graphRelatedLoading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Finding Related Docs..',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else if (graphRelatedError.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Related documents unavailable.',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else if (related.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No direct high-similarity connections found.',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else
              for (final item in related)
                ListTile(
                  key: ValueKey('graph-related-${item.row!.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    item.row!.title,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(
                    '${(item.similarity * 100).round()}% Match',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => selectGraphDocument(item.row!.id),
                ),
          ],
        ),
      ),
    );
  }

  Color _featureFallbackGraphLabelColor() =>
      Theme.of(context).colorScheme.primary;

  _GraphViewSnapshot _projectGraph(
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
    return (
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
      return Stack(
        children: [
          if (graphOrganizing || graphLayoutError.isNotEmpty)
            Positioned(
              right: 16,
              bottom: 16,
              child: Tooltip(
                message: graphLayoutError.isEmpty
                    ? 'Organizing sources'
                    : graphLayoutError,
                child: Text(
                  graphLayoutError.isEmpty
                      ? 'Organizing sources…'
                      : 'Graph layout unavailable',
                ),
              ),
            ),
          _graphCanvas(view),
          if (view.selected != null) _graphSelection(view, view.selected!),
          _graphCameraControls(),
        ],
      );
    },
  );

  Widget _graphCanvas(_GraphViewSnapshot view) => Listener(
    key: const ValueKey('source-graph-canvas'),
    behavior: HitTestBehavior.opaque,
    onPointerDown: startGraphPointer,
    onPointerMove: moveGraphPointer,
    onPointerUp: endGraphPointer,
    onPointerCancel: endGraphPointer,
    child: GestureDetector(
      onTapDown: (details) {
        final scenePoint = graphTransform.toScene(details.localPosition);
        String? document;
        var depth = double.infinity;
        for (var i = 0; i < view.rows.length; i++) {
          final raw = graphPerspective(view.rotated[i].z);
          final center = Offset(
            graphSceneOrigin + view.rotated[i].x * raw,
            graphSceneOrigin + view.rotated[i].y * raw,
          );
          if ((scenePoint - center).distance <=
                  graphHitRadius(view.rotated[i].z, view.zoom) &&
              view.rotated[i].z < depth) {
            document = view.rows[i].id;
            depth = view.rotated[i].z;
          }
        }
        selectGraphDocument(document);
      },
      child: InteractiveViewer(
        transformationController: graphTransform,
        panEnabled: graphMousePointer == null,
        minScale: .015,
        maxScale: 5,
        constrained: false,
        child: SizedBox(
          width: graphSceneSize,
          height: graphSceneSize,
          child: Stack(
            children: [
              CustomPaint(
                key: const ValueKey('source-graph-clusters'),
                size: const Size(graphSceneSize, graphSceneSize),
                painter: GraphClusterPainter(
                  clusters: view.clusters,
                  points: view.worldPoints,
                  labels: view.documentLabelRecords,
                  yaw: graphYaw,
                  pitch: graphPitch,
                  zoom: view.zoom,
                  filter: labelFilter,
                  fallback: Theme.of(context).colorScheme.primary,
                  fontFamily: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.fontFamily,
                ),
              ),
              CustomPaint(
                key: const ValueKey('source-graph-links'),
                size: const Size(graphSceneSize, graphSceneSize),
                painter: SourceLinks(
                  view.rows,
                  view.positions,
                  view.selectionEdges,
                  view.rotated.map((p) => p.z).toList(),
                ),
              ),
              for (final i in view.paintOrder)
                Positioned(
                  left: view.positions[i].dx - view.painters[i].extent,
                  top: view.positions[i].dy - view.painters[i].extent,
                  child: Tooltip(
                    message: view.rows[i].title,
                    child: Semantics(
                      button: true,
                      label: view.rows[i].title,
                      onTap: () => selectGraphDocument(view.rows[i].id),
                      child: SizedBox(
                        key: ValueKey('graph-node-${view.rows[i].id}'),
                        width: view.painters[i].extent * 2,
                        height: view.painters[i].extent * 2,
                        child: CustomPaint(
                          key: ValueKey('graph-node-paint-${view.rows[i].id}'),
                          painter: view.painters[i],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _graphSelection(_GraphViewSnapshot view, SourceSummary selected) =>
      Positioned(
        right: 20,
        bottom: 20,
        child: SizedBox(
          width: math.min(360, math.max(0, view.size.width - 40)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(0, view.size.height - 40),
            ),
            child: graphInspector(
              selected,
              view.rows,
              view.selectionEdges,
              view.documentLabelRecords[selected.id] ?? const [],
            ),
          ),
        ),
      );

  Widget _graphCameraControls() => Positioned(
    left: 18,
    bottom: 16,
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => zoomGraph(0.7692307692307692),
            icon: const Icon(Icons.remove),
          ),
          ValueListenableBuilder<Matrix4>(
            valueListenable: graphTransform,
            builder: (_, value, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '${(value.getMaxScaleOnAxis() * 100).round()}%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => zoomGraph(1.3),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: 'Fit graph',
            onPressed: fitGraph,
            icon: const Icon(Icons.center_focus_strong),
          ),
          IconButton(
            tooltip: MediaQuery.disableAnimationsOf(context)
                ? 'Graph animation is disabled by reduced motion'
                : graphAnimationPaused
                ? 'Resume graph animation'
                : 'Pause graph animation',
            onPressed: MediaQuery.disableAnimationsOf(context)
                ? null
                : () => update(
                    () => graphAnimationPaused = !graphAnimationPaused,
                  ),
            icon: Icon(
              graphAnimationPaused || MediaQuery.disableAnimationsOf(context)
                  ? Icons.play_arrow
                  : Icons.pause,
            ),
          ),
        ],
      ),
    ),
  );
}

typedef _GraphViewSnapshot = ({
  Size size,
  List<SourceSummary> rows,
  Map<String, GraphPoint> worldPoints,
  Map<String, List<DocumentLabel>> documentLabelRecords,
  List<GraphCluster> clusters,
  List<GraphPoint> rotated,
  List<Offset> positions,
  List<int> paintOrder,
  double zoom,
  SourceSummary? selected,
  List<GraphEdge> selectionEdges,
  List<GraphNodePainter> painters,
});
