import '../client_contract.dart';

import '../operation_requests/graph_inputs.dart';

import '../graph_layout.dart';

import '../graph_clusters.dart';

final class GraphEmbeddingsInput extends ClientArguments {
  GraphEmbeddingsInput({
    super.envelope,
    required List<GraphSourceInput> sources,
  }) : sources = List.unmodifiable(sources);
  final List<GraphSourceInput> sources;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'sources': [for (final source in sources) source.projection],
  });
}

final class GraphInvalidateInput extends ClientArguments {
  const GraphInvalidateInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GraphAcknowledgeInput extends ClientArguments {
  const GraphAcknowledgeInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class GraphSaveInput extends ClientArguments {
  GraphSaveInput({
    super.envelope,
    required this.identity,
    required List<GraphSourceInput> sources,
    required Map<String, List<double>> vectors,
    required Map<String, GraphPoint> points,
    this.labelSet = const WireField.absent(),
    WireField<List<GraphCluster>?> clusters = const WireField.absent(),
  }) : sources = List.unmodifiable(sources),
       vectors = Map.unmodifiable(
         vectors.map(
           (key, value) => MapEntry(key, List<double>.unmodifiable(value)),
         ),
       ),
       points = Map.unmodifiable(points),
       clusters = clusters.present
           ? WireField(
               clusters.value == null
                   ? null
                   : List.unmodifiable(clusters.value!),
             )
           : const WireField.absent();
  final String identity;
  final List<GraphSourceInput> sources;
  final Map<String, List<double>> vectors;
  final Map<String, GraphPoint> points;
  final WireField<String?> labelSet;
  final WireField<List<GraphCluster>?> clusters;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'identity': identity,
    'sources': [for (final source in sources) source.projection],
    'vectors': vectors,
    'points': points.map(
      (key, point) => MapEntry(key, [point.x, point.y, point.z]),
    ),
    if (labelSet.present) 'labelSet': labelSet.value,
    if (clusters.present)
      'clusters': clusters.value == null
          ? null
          : [
              for (final cluster in clusters.value!)
                {
                  'label': cluster.label,
                  'center_proj_x': cluster.center.x,
                  'center_proj_y': cluster.center.y,
                  'radius': cluster.radius,
                },
            ],
  });
}
