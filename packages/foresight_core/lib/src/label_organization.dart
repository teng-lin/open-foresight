import 'dart:convert';
import 'desktop_read_models.dart';
import 'graph_labels.dart';
import 'graph_layout.dart';
import 'label_propagation.dart';
import 'rpc_error.dart';

abstract interface class LabelOrganizationPersistence {
  T transaction<T>(T Function() work);
  List<SourceDocument> sources();
  List<DocumentLabel> get documentLabels;
  void put(DocumentLabel label);
  void saveLabelCluster(String name);
  void invalidateGraphOrganization();
}

/// Planning stays inside publication's transaction, using the vectors acquired
/// earlier only after their source revisions and states have been revalidated.
class LabelOrganizationService {
  final LabelOrganizationPersistence persistence;
  const LabelOrganizationService(this.persistence);
  int organize(
    String name,
    List<SourceDocument> expectedSources,
    Map<String, List<double>> vectors,
  ) => persistence.transaction(() {
    final current = persistence.sources();
    String revisions(List<SourceDocument> sources) => jsonEncode(
      sources
          .map((source) => [source.id, source.revision, source.state])
          .toList(),
    );
    if (revisions(current) != revisions(expectedSources)) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Sources changed while organizing labels; retry',
      );
    }
    final plan = planLabelPropagation(
      name,
      [
        for (final source in current)
          LabelDocument(source.id, source.content, title: source.title),
      ],
      persistence.documentLabels,
      vectors,
      semanticGraphEdges(vectors),
    );
    for (final label in plan.writes) {
      persistence.put(label);
    }
    persistence.saveLabelCluster(name);
    persistence.invalidateGraphOrganization();
    return plan.writes.length;
  });
}
