// Recovered palette and allocation contract: case-insensitive name reuse,
// uppercase colour occupancy, then abs(Dart String.hashCode) modulo seven.
const graphLabelPalette = [
  '#0EBC5F',
  '#60D5F3',
  '#7372FE',
  '#FEC700',
  '#FF8D41',
  '#3186FF',
  '#FF69C3',
];

class DocumentLabel {
  final String documentId, name, source;
  final String? colorHex, rationale;
  const DocumentLabel(
    this.documentId,
    this.name,
    this.source,
    this.colorHex, [
    this.rationale,
  ]);
  factory DocumentLabel.fromRow(Map<String, Object?> row) => DocumentLabel(
    row['document_id'] as String,
    row['label_name'] as String,
    row['label_source'] as String,
    row['color_hex'] as String?,
    row['rationale'] as String?,
  );
}

String allocateGraphLabelColor(
  String name,
  Iterable<DocumentLabel> labels, {
  Iterable<String?> clusterColors = const [],
}) {
  final existing = labels.toList();
  for (final label in existing) {
    if (label.name.toLowerCase() == name.toLowerCase() &&
        label.colorHex != null) {
      return label.colorHex!;
    }
  }
  final used = {
    for (final label in existing)
      if (label.colorHex != null) label.colorHex!.toUpperCase(),
    for (final color in clusterColors)
      if (color != null) color.toUpperCase(),
  };
  for (final color in graphLabelPalette) {
    if (!used.contains(color.toUpperCase())) return color;
  }
  return graphLabelPalette[name.hashCode.abs() % graphLabelPalette.length];
}
