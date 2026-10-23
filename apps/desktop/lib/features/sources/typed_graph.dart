import 'dart:convert';
import 'package:foresight_core/desktop.dart';

SourceType typedSourceType(SourceSummary source, {String? originalMime}) =>
    sourceType({
      'mime': source.mime,
      'provenance': source.provenance,
    }, originalMime: originalMime);

/// Only command inputs are serialized; persistence projections remain typed.
List<Map<String, Object?>> graphSourceArguments(List<SourceSummary> sources) =>
    [
      for (final source in sources)
        {
          'id': source.id,
          'revision': source.revision,
          'title': source.title,
          'state': source.state,
        },
    ];

String typedGraphDocumentSet(List<SourceSummary> sources) {
  final revisions = sources.map((s) => (s.id, s.revision)).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  return jsonEncode([
    for (final row in revisions) [row.$1, row.$2],
  ]);
}

List<SourceSummary> typedGraphSceneSources(
  List<SourceSummary> sources,
  Map<String, List<double>> vectors,
) => sources
    .where(
      (source) =>
          source.title.trim().isNotEmpty &&
          ((vectors[source.id]?.isNotEmpty ?? false) ||
              source is! SourceDocument ||
              source.content.trim().isNotEmpty),
    )
    .toList();

Future<StoredGraphLayout> readGraphLayout(
  StoreReader reader,
  List<SourceSummary> sources, {
  String? identity,
  int? dimensions,
  String? labelSet,
}) async {
  final result = await reader.read(
    StoreReadQueries.graphLayout(
      sources: sources,
      identity: identity,
      dimensions: dimensions,
      labelSet: labelSet,
      helperIdentity: identity ?? 'registered',
    ),
  );
  if (result.error != null) throw result.error!;
  if (!result.current || result.value == null) {
    throw RpcError(RpcErrorCode.unavailable, 'Graph snapshot unavailable');
  }
  return result.value!;
}
