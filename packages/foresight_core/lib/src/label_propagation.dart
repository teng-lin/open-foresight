import 'dart:math' as math;
import 'dart:isolate';
import 'graph_labels.dart';
import 'graph_layout.dart';

class LabelDocument {
  final String id, body;
  final String? title;
  const LabelDocument(this.id, this.body, {this.title});
}

class LabelPropagationPlan {
  final List<DocumentLabel> writes;
  final Set<String> assigned;
  const LabelPropagationPlan(this.writes, this.assigned);
}

Future<LabelPropagationPlan> planLabelPropagationInBackground(
  String name,
  List<LabelDocument> documents,
  List<DocumentLabel> labels,
  Map<String, List<double>> vectors,
  List<GraphEdge> edges,
) => Isolate.run(
  () => planLabelPropagation(name, documents, labels, vectors, edges),
);

// Bounded Mac static contract: lexical anchors, fixed centroid/anchor edge
// pass, then edge-adjacent fallback to five total assignments. No model call.
LabelPropagationPlan planLabelPropagation(
  String name,
  List<LabelDocument> documents,
  List<DocumentLabel> labels,
  Map<String, List<double>> vectors,
  List<GraphEdge> edges,
) {
  final color = allocateGraphLabelColor(name, labels);
  final normalized = name.toLowerCase();
  final whitespace = RegExp(r'\s+');
  int length(String body) => math.max(1, body.split(whitespace).length);
  final average = documents.isEmpty
      ? 500.0
      : documents.fold<int>(0, (sum, d) => sum + length(d.body)) /
            documents.length;
  final frequency = documents
      .where(
        (d) =>
            d.body.toLowerCase().contains(normalized) ||
            (d.title ?? '').toLowerCase().contains(normalized),
      )
      .length;
  final idf = 1 + math.log((documents.length + 1) / (frequency + 1));
  final occurrences = RegExp(RegExp.escape(normalized));
  final heading = RegExp(r'(^|\n)#+\s+.*' + RegExp.escape(normalized));
  final writes = <DocumentLabel>[];
  final anchors = <String>{}, assigned = <String>{};
  for (final doc in documents) {
    final title = (doc.title ?? '').toLowerCase().contains(normalized);
    final markdown = heading.hasMatch(doc.body);
    final tf = normalized.isEmpty ? 0 : occurrences.allMatches(doc.body).length;
    final relevance =
        2.5 * tf / (tf + 1.5 * (.25 + .75 * length(doc.body) / average)) * idf;
    final body = doc.body.toLowerCase();
    final prefix = body
        .substring(0, math.min(300, body.length))
        .contains(normalized);
    if (title ||
        markdown ||
        (tf >= 4 && relevance >= 3.2) ||
        (tf >= 4 && prefix && relevance >= 2)) {
      final reason = title
          ? 'Title exact match'
          : markdown
          ? 'Heading exact match'
          : 'High keyword relevance';
      writes.add(
        DocumentLabel(
          doc.id,
          name,
          'user_defined',
          color,
          '$reason for "$name"',
        ),
      );
      anchors.add(doc.id);
      assigned.add(doc.id);
    }
  }
  final loaded = documents.map((d) => d.id).toSet();
  for (final label in labels.where((l) => l.name == name)) {
    assigned.add(label.documentId);
    if (loaded.contains(label.documentId) ||
        label.source == 'user_defined' ||
        label.source == 'user_attached')
      anchors.add(label.documentId);
  }
  List<double>? centroid;
  var contributors = 0;
  for (final id in anchors) {
    final vector = vectors[id];
    if (vector == null || vector.isEmpty) continue;
    centroid ??= List.filled(vector.length, 0.0);
    for (var i = 0; i < math.min(centroid.length, vector.length); i++)
      centroid[i] += vector[i];
    contributors++;
  }
  if (centroid != null) {
    for (var i = 0; i < centroid.length; i++) centroid[i] /= contributors;
    final norm = math.sqrt(centroid.fold<double>(0, (sum, v) => sum + v * v));
    if (norm > 0) for (var i = 0; i < centroid.length; i++) centroid[i] /= norm;
  }
  final unique = <GraphEdge>[];
  final pairs = <String>{};
  for (final edge in edges) {
    final a = edge.source.compareTo(edge.target) <= 0
        ? edge.source
        : edge.target;
    final b = a == edge.source ? edge.target : edge.source;
    if (pairs.add('$a|$b')) unique.add(edge);
  }
  double score(String id, double fallback) {
    final vector = vectors[id];
    return centroid != null && vector != null && vector.isNotEmpty
        ? graphCosine(centroid, vector)
        : fallback;
  }

  if (assigned.isNotEmpty && anchors.isNotEmpty) {
    final titles = {for (final d in documents) d.id: d.title};
    for (final edge in unique) {
      if (!(anchors.contains(edge.source) || anchors.contains(edge.target)) ||
          edge.similarity < .65)
        continue;
      final anchor = anchors.contains(edge.source) ? edge.source : edge.target;
      final candidate = anchor == edge.source ? edge.target : edge.source;
      if (assigned.contains(candidate)) continue;
      final cosine = score(candidate, edge.similarity);
      final mixed = .65 * cosine + .35 * edge.similarity;
      if (mixed >= .66 && cosine >= .58) {
        writes.add(
          DocumentLabel(
            candidate,
            name,
            'propagated',
            color,
            'Similar to "${titles[anchor] ?? 'core seed'}" (${(mixed * 100).toStringAsFixed(0)}% match)',
          ),
        );
        assigned.add(candidate);
      }
    }
    if (assigned.length < 5) {
      final candidates = <String, double>{};
      for (final edge in unique) {
        final left = assigned.contains(edge.source),
            right = assigned.contains(edge.target);
        if (left == right) continue;
        final candidate = left ? edge.target : edge.source;
        final value = score(candidate, edge.similarity);
        if (value > (candidates[candidate] ?? -1))
          candidates[candidate] = value;
      }
      final ranked = candidates.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final candidate in ranked) {
        if (assigned.length >= 5 || candidate.value < .58) break;
        if (assigned.contains(candidate.key)) continue;
        writes.add(
          DocumentLabel(
            candidate.key,
            name,
            'propagated_community',
            color,
            'Clustered with "$name" community (${(candidate.value * 100).toStringAsFixed(0)}% match)',
          ),
        );
        assigned.add(candidate.key);
      }
    }
  }
  return LabelPropagationPlan(writes, assigned);
}
