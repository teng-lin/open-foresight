import 'dart:math' as math;
import 'dart:isolate';

// Keep isolate closures outside widget state: they must capture only vectors.
Future<List<GraphEdge>> graphEdgesInBackground(
  Map<String, List<double>> vectors,
) => Isolate.run(() => semanticGraphEdges(vectors));

Future<List<GraphEdge>> selectedGraphEdgesInBackground(
  String document,
  Map<String, List<double>> vectors,
  List<GraphEdge> wholeEdges,
) => Isolate.run(() => selectedGraphEdges(document, vectors, wholeEdges));

Future<({Map<String, GraphPoint> points, List<GraphEdge> edges})>
organizeGraphSceneInBackground(Map<String, List<double>> vectors) =>
    Isolate.run(
      () => (
        points: semanticGraphLayout(vectors),
        edges: semanticGraphEdges(vectors),
      ),
    );

class GraphEdge {
  final String source, target;
  final double similarity;
  const GraphEdge(this.source, this.target, this.similarity);
}

class GraphNeighbor {
  final String document;
  final double similarity;
  const GraphNeighbor(this.document, this.similarity);
}

// The Mac view merges selected-document results first, then whole-graph edges.
// Its painter draws only incident edges while a document is selected.
List<GraphEdge> selectedGraphEdges(
  String document,
  Map<String, List<double>> vectors,
  List<GraphEdge> wholeEdges,
) {
  final seen = <(String, String)>{};
  final result = <GraphEdge>[];
  final selected = selectedGraphNeighbors(document, vectors).map(
    (neighbor) => GraphEdge(document, neighbor.document, neighbor.similarity),
  );
  for (final edge in [...selected, ...wholeEdges]) {
    final pair = edge.source.compareTo(edge.target) < 0
        ? (edge.source, edge.target)
        : (edge.target, edge.source);
    if (seen.add(pair) && (pair.$1 == document || pair.$2 == document)) {
      result.add(GraphEdge(pair.$1, pair.$2, edge.similarity));
    }
  }
  return result;
}

// Mac computeCosine: double accumulators, no clamp or epsilon. Empty,
// mismatched and zero-norm vectors return zero. NaN fails the positive cutoff.
double graphCosine(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) return 0;
  var dot = 0.0, normA = 0.0, normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}

List<GraphNeighbor> _graphNeighbors(
  String document,
  Map<String, List<double>> vectors,
  int limit,
) {
  final vector = vectors[document];
  if (vector == null || vector.isEmpty) return [];
  final candidates = <GraphNeighbor>[
    for (final other in vectors.entries)
      if (other.key != document && other.value.isNotEmpty)
        GraphNeighbor(other.key, graphCosine(vector, other.value)),
  ];
  // Both Mac closures share b.score.compareTo(a.score). No secondary ID key.
  // Input enumeration and large tied-list survivor order remain unverified.
  candidates.sort((a, b) => b.similarity.compareTo(a.similarity));
  return candidates.where((n) => n.similarity >= .2).take(limit).toList();
}

List<GraphNeighbor> selectedGraphNeighbors(
  String document,
  Map<String, List<double>> vectors,
) => _graphNeighbors(document, vectors, 6);

List<GraphEdge> semanticGraphEdges(Map<String, List<double>> vectors) {
  final seen = <(String, String)>{};
  final edges = <GraphEdge>[];
  for (final document in vectors.keys) {
    for (final neighbor in _graphNeighbors(document, vectors, 2)) {
      final other = neighbor.document;
      final pair = document.compareTo(other) < 0
          ? (document, other)
          : (other, document);
      if (seen.add(pair)) {
        edges.add(GraphEdge(pair.$1, pair.$2, neighbor.similarity));
      }
    }
  }
  return edges;
}

class GraphPoint {
  final double x, y, z;
  const GraphPoint(this.x, this.y, this.z);
}

// Derived from the checksum-matched Mac painter and canvas hit-test paths.
const graphCameraDistance = 1600.0;
const graphSceneSize = 3000.0;
const graphSceneOrigin = 1500.0;

// Linux's persisted PCA coordinates are normalized (Z has half extent).
// Convert at the rendering boundary to Mac's recovered world units. Keeping
// stored coordinates unchanged preserves existing saved layouts and vectors.
GraphPoint graphWorldPoint(GraphPoint point, {bool uniform = false}) =>
    GraphPoint(point.x * 240, point.y * 240, point.z * (uniform ? 240 : 432));

class GraphCameraFit {
  final double x, y, scale;
  const GraphCameraFit(this.x, this.y, this.scale);
}

GraphCameraFit fitGraphCamera(
  Iterable<GraphPoint> points,
  double width,
  double height,
) {
  var minX = double.infinity, maxX = double.negativeInfinity;
  var minY = double.infinity, maxY = double.negativeInfinity;
  for (final point in points) {
    minX = math.min(minX, point.x);
    maxX = math.max(maxX, point.x);
    minY = math.min(minY, point.y);
    maxY = math.max(maxY, point.y);
  }
  if (minX == double.infinity || minX >= maxX || minY >= maxY) {
    return GraphCameraFit(
      (width - graphSceneSize) / 2,
      (height - graphSceneSize) / 2,
      1,
    );
  }
  final scale = math
      .min(width / (1.25 * (maxX - minX)), height / (1.25 * (maxY - minY)))
      .clamp(.015, 5.0);
  return GraphCameraFit(
    width / 2 - (graphSceneOrigin + (minX + maxX) / 2) * scale,
    height / 2 - (graphSceneOrigin + (minY + maxY) / 2) * scale,
    scale,
  );
}

GraphPoint rotateGraphPoint(
  GraphPoint point, {
  double yaw = 0,
  double pitch = 0,
}) {
  final u = point.x * math.cos(yaw) - point.z * math.sin(yaw);
  final w = point.x * math.sin(yaw) + point.z * math.cos(yaw);
  return GraphPoint(
    u,
    point.y * math.cos(pitch) - w * math.sin(pitch),
    point.y * math.sin(pitch) + w * math.cos(pitch),
  );
}

double graphPerspective(double depth) =>
    graphCameraDistance / (graphCameraDistance + depth);
double graphPaintPerspective(double depth) =>
    graphPerspective(depth).clamp(.05, 6.0);
double graphDepthFade(double depth) =>
    1 - .45 * ((depth + 600) / 1200).clamp(0.0, 1.0);
double graphBaseRadius(double zoom) =>
    (10 + 13 * (zoom - .4)).clamp(10.0, 22.0);

double graphNodeRadius(
  double depth,
  double zoom, {
  bool selected = false,
  bool activeMatch = false,
}) =>
    graphBaseRadius(zoom) *
    graphPaintPerspective(depth) *
    (selected
        ? 1.45
        : activeMatch
        ? 1.25
        : 1);

double graphHitRadius(double depth, double zoom) =>
    math.max(1.5 * graphBaseRadius(zoom) * graphPerspective(depth), 34 / zoom);

double graphNodeFillOpacity(double depth, {bool dimmed = false}) =>
    graphDepthFade(depth) * (dimmed ? .28 : .85);

double graphNodeOutlineOpacity(double depth, {bool dimmed = false}) =>
    graphDepthFade(depth) * (dimmed ? .35 : .92);

// Recovered finite-domain Mac PCA, in world units. Document order is supplied
// separately because missing vectors and repeated IDs affect initialization.
Map<String, GraphPoint> pcaGraphLayout(
  List<String> documents,
  Map<String, List<double>> vectors,
) {
  final eligible = documents
      .where((id) => vectors[id]?.isNotEmpty ?? false)
      .toList();
  if (eligible.length < 2) return {};
  final dimensions = vectors[eligible.first]!.length;
  // Nonfinite inputs are a Linux safety boundary; the reference does not
  // establish finite output for malformed vectors. Mixed lengths are valid.
  if (dimensions < 3 ||
      eligible.any((id) => vectors[id]!.any((x) => !x.isFinite))) {
    return {};
  }
  final mean = List<double>.filled(dimensions, 0);
  for (final id in eligible) {
    final vector = vectors[id]!;
    for (var j = 0; j < math.min(dimensions, vector.length); j++) {
      mean[j] += vector[j];
    }
  }
  for (var j = 0; j < dimensions; j++) {
    mean[j] /= eligible.length;
  }
  final centered = <String, List<double>>{};
  for (final id in eligible) {
    final vector = vectors[id]!;
    final row = List<double>.filled(dimensions, 0);
    for (var j = 0; j < math.min(dimensions, vector.length); j++) {
      row[j] = vector[j] - mean[j];
    }
    centered[id] = row;
  }
  double dot(List<double> a, List<double> b) {
    var result = 0.0;
    for (var j = 0; j < dimensions; j++) {
      result += a[j] * b[j];
    }
    return result;
  }

  final axes = <List<double>>[];
  void deflate(List<double> v) {
    // All coefficients precede component updates, including the third axis.
    final coefficients = axes.map((axis) => dot(v, axis)).toList();
    for (var j = 0; j < dimensions; j++) {
      var projection = 0.0;
      for (var a = 0; a < axes.length; a++) {
        projection += coefficients[a] * axes[a][j];
      }
      v[j] -= projection;
    }
  }

  for (var component = 0; component < 3; component++) {
    var axis = List.generate(
      dimensions,
      (j) => switch (component) {
        0 => math.sin(j + 1),
        1 => math.cos(j + 1),
        _ => math.sin(2 * j + .5),
      },
    );
    deflate(axis);
    final seedNorm = math.sqrt(dot(axis, axis));
    if (seedNorm > 1e-12) axis = axis.map((x) => x / seedNorm).toList();
    for (var step = 0; step < 30; step++) {
      final next = List<double>.filled(dimensions, 0);
      for (final id in eligible) {
        final row = centered[id]!;
        final projection = dot(row, axis);
        for (var j = 0; j < dimensions; j++) {
          next[j] += row[j] * projection;
        }
      }
      deflate(next);
      final norm = math.sqrt(dot(next, next));
      if (norm < 1e-12) break; // Retain the preceding axis, including its seed.
      axis = next.map((x) => x / norm).toList();
    }
    axes.add(axis);
  }
  final projected = <String, List<double>>{
    for (final id in eligible)
      id: axes.map((axis) => dot(centered[id]!, axis)).toList(),
  };
  final maxima = List.generate(
    3,
    (j) => projected.values.fold(0.0, (m, row) => math.max(m, row[j].abs())),
  );
  final scales = List.generate(
    3,
    (j) => maxima[j] > 1e-6 ? (j == 2 ? 216 : 240) / maxima[j] : 1.0,
  );
  final result = <String, GraphPoint>{
    for (final entry in projected.entries)
      entry.key: GraphPoint(
        entry.value[0] * scales[0],
        entry.value[1] * scales[1],
        entry.value[2] * scales[2],
      ),
  };
  final missing = documents.where((id) => !result.containsKey(id)).toList();
  for (var i = 0; i < missing.length; i++) {
    final angle = (2 * math.pi / math.max(missing.length, 1)) * i;
    result[missing[i]] = GraphPoint(
      276 * math.cos(angle),
      276 * math.sin(angle),
      0,
    );
  }
  return result;
}

Map<String, GraphPoint> initialGraphLayout(
  List<String> documents,
  Map<String, List<double>> vectors,
) {
  final pca = pcaGraphLayout(documents, vectors);
  if (pca.isNotEmpty || documents.isEmpty) return pca;
  return uniformGraphLayout(
    documents,
  ).map((id, point) => MapEntry(id, graphWorldPoint(point, uniform: true)));
}

// Compatibility boundary for callers storing normalized Linux coordinates.
Map<String, GraphPoint> semanticGraphLayout(
  Map<String, List<double>> vectors,
) => pcaGraphLayout(vectors.keys.toList(), vectors).map(
  (id, point) =>
      MapEntry(id, GraphPoint(point.x / 240, point.y / 240, point.z / 432)),
);

Map<String, GraphPoint> uniformGraphLayout(List<String> ids) {
  return {
    for (var i = 0; i < ids.length; i++)
      ids[i]: (() {
        final y = 1 - 2 * i / math.max(ids.length - 1, 1);
        final radius = math.sqrt(math.max(0, 1 - y * y));
        // Exact increment recovered from the Mac object pool.
        final angle = i * 2.399963229728653;
        return GraphPoint(
          math.cos(angle) * radius,
          y,
          math.sin(angle) * radius,
        );
      })(),
  };
}

GraphPoint projectGraphPoint(
  GraphPoint point, {
  double yaw = 0,
  double pitch = 0,
  double distance = 3,
}) {
  if (!distance.isFinite || distance <= 0) {
    throw ArgumentError.value(distance, 'distance');
  }
  final u = point.x * math.cos(yaw) - point.z * math.sin(yaw);
  final w = point.x * math.sin(yaw) + point.z * math.cos(yaw);
  final v = point.y * math.cos(pitch) - w * math.sin(pitch);
  final depth = point.y * math.sin(pitch) + w * math.cos(pitch);
  final denominator = distance + depth;
  if (denominator <= 1e-10) throw ArgumentError('Point lies behind the camera');
  final scale = distance / denominator;
  return GraphPoint(u * scale, v * scale, depth);
}
