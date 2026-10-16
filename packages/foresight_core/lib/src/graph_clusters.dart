import 'graph_layout.dart';

class GraphCluster {
  final String label;
  final GraphPoint center;
  final double radius;
  const GraphCluster(this.label, this.center, this.radius);
  factory GraphCluster.fromRow(Map<String, Object?> row) => GraphCluster(
    row['label'] as String,
    GraphPoint(
      (row['center_proj_x'] as num).toDouble(),
      (row['center_proj_y'] as num).toDouble(),
      0,
    ),
    (row['radius'] as num).toDouble(),
  );
}
