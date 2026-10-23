part of 'sources_controller.dart';

extension _GraphInteraction on SourcesController {
  void _featureScheduleGraphFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _navigation.selectedTab == WorkspaceTab.sources &&
          graphView)
        fitGraph();
    });
  }

  void _featureFitGraph() {
    // The Mac MediaQuery provider scope remains unresolved. Fit the measured
    // Linux graph panel so window headers cannot put sources below its bounds.
    final viewport = graphViewportSize ?? MediaQuery.sizeOf(context);
    // Use the current projection and include node extent, including collinear
    // layouts. The recovered Mac degenerate fallback at scale 1 can clip nodes
    // in Linux's smaller responsive panels.
    final projected = graphWorldPoints.values
        .map((point) {
          final rotated = rotateGraphPoint(
            point,
            yaw: graphYaw,
            pitch: graphPitch,
          );
          final perspective = graphPaintPerspective(rotated.z);
          final radius = 40 * perspective;
          final x = rotated.x * perspective;
          final y = rotated.y * perspective;
          return [
            GraphPoint(x - radius, y - radius, 0),
            GraphPoint(x + radius, y + radius, 0),
          ];
        })
        .expand((points) => points);
    var fit = fitGraphCamera(projected, viewport.width, viewport.height);
    // Captions scale inversely with zoom. Recompute their scene bounds at the
    // proposed zoom until the fit settles; circle/wire bounds use the same
    // projection as the painter. Include every cluster regardless of filter.
    for (var pass = 0; pass < 8; pass++) {
      final painter = GraphClusterPainter(
        clusters: graphSceneClusters,
        points: graphWorldPoints,
        labels: graphSceneLabels,
        yaw: graphYaw,
        pitch: graphPitch,
        zoom: fit.scale,
        fallback: Theme.of(context).colorScheme.primary,
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      );
      final bounds = painter.paintedBounds().expand(
        (rect) => [
          GraphPoint(
            rect.left - graphSceneOrigin,
            rect.top - graphSceneOrigin,
            0,
          ),
          GraphPoint(
            rect.right - graphSceneOrigin,
            rect.bottom - graphSceneOrigin,
            0,
          ),
        ],
      );
      final next = fitGraphCamera(
        [...projected, ...bounds],
        viewport.width,
        viewport.height,
      );
      final settled = (next.scale - fit.scale).abs() < 1e-6;
      fit = next;
      if (settled) break;
    }
    final target = Matrix4.identity()
      ..translateByDouble(fit.x, fit.y, 0, 1)
      ..scaleByDouble(fit.scale, fit.scale, fit.scale, 1);
    animateGraphCamera(target);
  }

  void _featureAnimateGraphCamera(Matrix4 target, {bool zoomButton = false}) {
    graphCameraController.stop();
    graphCameraTween = Matrix4Tween(
      begin: graphTransform.value.clone(),
      end: target,
    );
    graphCameraCurve = zoomButton
        ? const Cubic(.215, .61, .355, 1)
        : const Cubic(.645, .045, .355, 1);
    // Original _animateCameraTo / _zoomByFactor: 350ms / 250ms.
    graphCameraController.duration = Duration(
      milliseconds: zoomButton ? 250 : 350,
    );
    // The callback intentionally schedules work owned by its controller.
    // ignore: discarded_futures
    graphCameraController.forward(from: 0);
  }

  void _featureZoomGraph(double factor) {
    final scale = graphTransform.value.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(.015, 5.0);
    if ((next - scale).abs() < .001) return;
    final size = graphViewportSize ?? MediaQuery.sizeOf(context);
    final center = Offset(size.width / 2, size.height / 2);
    final scene = graphTransform.toScene(center);
    final target = Matrix4.identity()
      ..translateByDouble(
        center.dx - scene.dx * next,
        center.dy - scene.dy * next,
        0,
        1,
      )
      ..scaleByDouble(next, next, next, 1);
    animateGraphCamera(target, zoomButton: true);
  }

  void _featureStartGraphPointer(PointerDownEvent event) {
    if (graphMousePointer != null) return;
    graphDragMoved = false;
    if (event.kind != PointerDeviceKind.mouse) return;
    final modifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (event.buttons != kPrimaryMouseButton &&
        event.buttons != kSecondaryMouseButton &&
        event.buttons != kMiddleMouseButton)
      return;
    update(() {
      graphMousePointer = event.pointer;
      graphPointerStart = graphPointerLast = event.localPosition;
      graphPointerRotates = event.buttons == kPrimaryMouseButton || modifier;
      graphDragMoved = false;
    });
  }

  void _featureMoveGraphPointer(PointerMoveEvent event) {
    if (graphMousePointer != event.pointer || graphPointerLast == null) return;
    final delta = event.localPosition - graphPointerLast!;
    update(() {
      graphPointerLast = event.localPosition;
      graphDragMoved =
          graphDragMoved ||
          (event.localPosition - graphPointerStart!).distance > kTouchSlop;
      if (graphPointerRotates) {
        // Direction and clamp structure are recovered. Sensitivity and pitch
        // limits remain Linux choices pending Mac numeric-pool recovery.
        graphManualPitch = true;
        graphYaw += delta.dx * .005;
        graphPitch = (graphPitch + delta.dy * .005).clamp(
          -math.pi / 2,
          math.pi / 2,
        );
      } else {
        final matrix = graphTransform.value.clone();
        matrix.storage[12] += delta.dx;
        matrix.storage[13] += delta.dy;
        graphTransform.value = matrix;
      }
    });
  }

  void _featureEndGraphPointer(PointerEvent event) {
    if (graphMousePointer != event.pointer) return;
    update(() {
      graphMousePointer = null;
      graphPointerStart = graphPointerLast = null;
    });
  }

  void _featureSelectGraphDocument(String? document) {
    update(() {
      graphSelectedDocument = document;
      labelFilter = '';
    });
    refreshGraphSelection();
  }

  void _featureRefreshGraphSelection() {
    final document = graphSelectedDocument;
    final revision = ++graphSelectionRevision;
    final vectors = graphSceneVectors;
    final whole = graphEdges;
    update(() {
      graphSelectionEdges = document == null
          ? []
          : whole
                .where(
                  (edge) => edge.source == document || edge.target == document,
                )
                .toList();
      graphRelatedLoading = document != null;
      graphRelatedError = '';
    });
    if (document != null) {
      // The callback intentionally schedules work owned by its controller.
      // ignore: discarded_futures
      completeGraphSelection(document, revision, vectors, whole);
    }
  }

  Future<void> _featureCompleteGraphSelection(
    String document,
    int revision,
    Map<String, List<double>> vectors,
    List<GraphEdge> whole,
  ) async {
    try {
      final edges = await selectedGraphEdgesInBackground(
        document,
        vectors,
        whole,
      );
      if (!mounted ||
          revision != graphSelectionRevision ||
          graphSelectedDocument != document ||
          !identical(vectors, graphSceneVectors) ||
          !identical(whole, graphEdges))
        return;
      update(() {
        graphSelectionEdges = edges;
        graphRelatedLoading = false;
      });
    } catch (e) {
      if (!mounted || revision != graphSelectionRevision) return;
      update(() {
        graphRelatedLoading = false;
        graphRelatedError = e.toString();
      });
    }
  }
}
