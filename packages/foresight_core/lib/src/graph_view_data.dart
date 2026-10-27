import 'dart:convert';
import 'graph_layout.dart';

const graphLayoutAlgorithmVersion = 'force-3d-mac45-pca-scene-v4';

class StoredGraphLayout {
  final Map<String, GraphPoint> points;
  final Map<String, List<double>> vectors;
  final bool complete;
  final String? identity;
  const StoredGraphLayout(
    this.points,
    this.vectors,
    this.complete, {
    this.identity,
  });
}

String graphDocumentSet(List<Map<String, Object?>> sources) {
  final revisions = sources.map((s) => [s['id'], s['revision']]).toList()
    ..sort((a, b) => (a[0] as String).compareTo(b[0] as String));
  return jsonEncode(revisions);
}

// Global Mac scene route: named sources with vectors or nonblank text.
List<Map<String, Object?>> graphSceneSources(
  List<Map<String, Object?>> sources,
  Map<String, List<double>> vectors,
) => sources
    .where(
      (source) =>
          (source['title'] as String? ?? '').trim().isNotEmpty &&
          ((vectors[source['id']]?.isNotEmpty ?? false) ||
              !source.containsKey('content') ||
              (source['content'] as String? ?? '').trim().isNotEmpty),
    )
    .toList();
