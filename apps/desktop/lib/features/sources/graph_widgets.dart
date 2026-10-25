import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import 'cluster_rendering.dart';
import 'graph_rendering.dart';
import 'graph_label_controls.dart';
import 'source_painters.dart';

final class GraphViewSnapshot {
  GraphViewSnapshot({
    required this.size,
    required List<SourceSummary> rows,
    required Map<String, GraphPoint> worldPoints,
    required Map<String, List<DocumentLabel>> documentLabelRecords,
    required List<GraphCluster> clusters,
    required List<GraphPoint> rotated,
    required List<Offset> positions,
    required List<int> paintOrder,
    required this.zoom,
    required this.selected,
    required List<GraphEdge> selectionEdges,
    required List<GraphNodePainter> painters,
  }) : rows = List.unmodifiable(rows),
       worldPoints = Map.unmodifiable(worldPoints),
       documentLabelRecords = Map.unmodifiable(
         documentLabelRecords.map(
           (key, value) =>
               MapEntry(key, List<DocumentLabel>.unmodifiable(value)),
         ),
       ),
       clusters = List.unmodifiable(clusters),
       rotated = List.unmodifiable(rotated),
       positions = List.unmodifiable(positions),
       paintOrder = List.unmodifiable(paintOrder),
       selectionEdges = List.unmodifiable(selectionEdges),
       painters = List.unmodifiable(painters);
  final Size size;
  final List<SourceSummary> rows;
  final Map<String, GraphPoint> worldPoints;
  final Map<String, List<DocumentLabel>> documentLabelRecords;
  final List<GraphCluster> clusters;
  final List<GraphPoint> rotated;
  final List<Offset> positions;
  final List<int> paintOrder;
  final double zoom;
  final SourceSummary? selected;
  final List<GraphEdge> selectionEdges;
  final List<GraphNodePainter> painters;
}

class GraphInspector extends StatelessWidget {
  GraphInspector({
    super.key,
    required this.selected,
    required List<SourceSummary> rows,
    required List<GraphEdge> edges,
    required List<DocumentLabel> labels,
    required this.labelInput,
    required this.enabled,
    required this.relatedLoading,
    required this.relatedError,
    required this.openLink,
    required this.onSelect,
    required this.onAddLabel,
    required this.onRemoveLabel,
  }) : rows = List.unmodifiable(rows),
       edges = List.unmodifiable(edges),
       labels = List.unmodifiable(labels);
  final SourceSummary selected;
  final List<SourceSummary> rows;
  final List<GraphEdge> edges;
  final List<DocumentLabel> labels;
  final TextEditingController labelInput;
  final bool enabled, relatedLoading, relatedError;
  final Future<void> Function(Uri) openLink;
  final ValueChanged<String?> onSelect;
  final Future<void> Function(String) onAddLabel;
  final ValueChanged<String> onRemoveLabel;
  @override
  Widget build(BuildContext context) {
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
                        await openLink(uri);
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
                  onPressed: () => onSelect(null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            GraphLabelControls(
              labels: labels,
              controller: labelInput,
              enabled: enabled,
              onAdd: onAddLabel,
              onRemove: onRemoveLabel,
            ),
            const SizedBox(height: 8),
            const Text(
              'Related documents:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (relatedLoading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Finding Related Docs..',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else if (relatedError)
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
                  onTap: () => onSelect(item.row!.id),
                ),
          ],
        ),
      ),
    );
  }
}

class SourceGraphScene extends StatelessWidget {
  const SourceGraphScene({
    super.key,
    required this.view,
    required this.transform,
    required this.yaw,
    required this.pitch,
    required this.labelFilter,
    required this.panEnabled,
    required this.animationPaused,
    required this.organizing,
    required this.layoutError,
    required this.inspector,
    required this.onSelect,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerEnd,
    required this.onZoom,
    required this.onFit,
    required this.onToggleAnimation,
  });
  final GraphViewSnapshot view;
  final TransformationController transform;
  final double yaw, pitch;
  final String labelFilter, layoutError;
  final bool panEnabled, animationPaused, organizing;
  final Widget? inspector;
  final ValueChanged<String?> onSelect;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerEvent> onPointerEnd;
  final ValueChanged<double> onZoom;
  final VoidCallback onFit, onToggleAnimation;
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (organizing || layoutError.isNotEmpty)
          Positioned(
            right: 16,
            bottom: 16,
            child: Tooltip(
              message: layoutError.isEmpty ? 'Organizing sources' : layoutError,
              child: Text(
                layoutError.isEmpty
                    ? 'Organizing sources…'
                    : 'Graph layout unavailable',
              ),
            ),
          ),
        _graphCanvas(context, view),
        if (view.selected != null) _graphSelection(view, view.selected!),
        _graphCameraControls(context),
      ],
    );
  }

  Widget _graphCanvas(BuildContext context, GraphViewSnapshot view) => Listener(
    key: const ValueKey('source-graph-canvas'),
    behavior: HitTestBehavior.opaque,
    onPointerDown: onPointerDown,
    onPointerMove: onPointerMove,
    onPointerUp: onPointerEnd,
    onPointerCancel: onPointerEnd,
    child: GestureDetector(
      onTapDown: (details) {
        final scenePoint = transform.toScene(details.localPosition);
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
        onSelect(document);
      },
      child: InteractiveViewer(
        transformationController: transform,
        panEnabled: panEnabled,
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
                  yaw: yaw,
                  pitch: pitch,
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
                      onTap: () => onSelect(view.rows[i].id),
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

  Widget _graphSelection(GraphViewSnapshot view, SourceSummary selected) =>
      Positioned(
        right: 20,
        bottom: 20,
        child: SizedBox(
          width: math.min(360, math.max(0, view.size.width - 40)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(0, view.size.height - 40),
            ),
            child: inspector,
          ),
        ),
      );

  Widget _graphCameraControls(BuildContext context) => Positioned(
    left: 18,
    bottom: 16,
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => onZoom(0.7692307692307692),
            icon: const Icon(Icons.remove),
          ),
          ValueListenableBuilder<Matrix4>(
            valueListenable: transform,
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
            onPressed: () => onZoom(1.3),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: 'Fit graph',
            onPressed: onFit,
            icon: const Icon(Icons.center_focus_strong),
          ),
          IconButton(
            tooltip: MediaQuery.disableAnimationsOf(context)
                ? 'Graph animation is disabled by reduced motion'
                : animationPaused
                ? 'Resume graph animation'
                : 'Pause graph animation',
            onPressed: MediaQuery.disableAnimationsOf(context)
                ? null
                : onToggleAnimation,
            icon: Icon(
              animationPaused || MediaQuery.disableAnimationsOf(context)
                  ? Icons.play_arrow
                  : Icons.pause,
            ),
          ),
        ],
      ),
    ),
  );
}
