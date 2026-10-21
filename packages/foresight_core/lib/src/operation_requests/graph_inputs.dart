import '../graph_clusters.dart';
import '../graph_layout.dart';
import '../rpc_error.dart';

Never _invalid(String field) => throw RpcError(
  RpcErrorCode.invalidArgument,
  '$field has an invalid graph input',
);

/// A validated source projection. Extra read-model fields are retained for
/// current persistence adapters; callers cannot mutate a decoded projection.
class GraphSourceInput {
  GraphSourceInput({
    required this.id,
    required this.revision,
    required this.title,
    required this.content,
    required Map<String, Object?> projection,
  }) : projection = Map.unmodifiable(projection);
  final String id;
  final int? revision;
  final String? title, content;
  final Map<String, Object?> projection;
}

List<GraphSourceInput> decodeGraphSources(Object? value, String field) {
  if (value is! List) _invalid(field);
  return List.unmodifiable(
    value.map((item) {
      if (item is! Map || item.keys.any((key) => key is! String)) {
        _invalid(field);
      }
      final id = item['id'], revision = item['revision'];
      final title = item['title'], content = item['content'];
      if (id is! String ||
          (revision != null && revision is! int) ||
          (title != null && title is! String) ||
          (content != null && content is! String)) {
        _invalid(field);
      }
      return GraphSourceInput(
        id: id,
        revision: revision as int?,
        title: title as String?,
        content: content as String?,
        projection: Map<String, Object?>.from(item),
      );
    }),
  );
}

Map<String, List<double>> decodeGraphVectors(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid(field);
  return Map.unmodifiable(
    value.map((key, vector) {
      if (vector is! List || vector.any((v) => v is! num || !v.isFinite)) {
        _invalid(field);
      }
      return MapEntry(
        key as String,
        List<double>.unmodifiable(vector.map((v) => (v as num).toDouble())),
      );
    }),
  );
}

Map<String, GraphPoint> decodeGraphPoints(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid(field);
  return Map.unmodifiable(
    value.map((key, point) {
      if (point is! List ||
          point.length < 3 ||
          point.take(3).any((v) => v is! num || !v.isFinite)) {
        _invalid(field);
      }
      return MapEntry(
        key as String,
        GraphPoint(
          (point[0] as num).toDouble(),
          (point[1] as num).toDouble(),
          (point[2] as num).toDouble(),
        ),
      );
    }),
  );
}

List<GraphCluster> decodeGraphClusters(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List) _invalid(field);
  return List.unmodifiable(
    value.map((item) {
      if (item is! Map ||
          item['label'] is! String ||
          item['center_proj_x'] is! num ||
          item['center_proj_y'] is! num ||
          item['radius'] is! num) {
        _invalid(field);
      }
      return GraphCluster(
        item['label'] as String,
        GraphPoint(
          (item['center_proj_x'] as num).toDouble(),
          (item['center_proj_y'] as num).toDouble(),
          0,
        ),
        (item['radius'] as num).toDouble(),
      );
    }),
  );
}
