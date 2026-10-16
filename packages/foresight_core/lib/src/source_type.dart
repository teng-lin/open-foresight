/// Display categories preserve the original Drive MIME type after text export.
enum SourceType {
  pdf,
  document,
  spreadsheet,
  presentation,
  url,
  meeting,
  calendar,
  text,
  other,
}

SourceType sourceType(Map<String, Object?> source, {String? originalMime}) {
  final origins = (source['provenance'] as String? ?? '').split('; ');
  if (origins.any((origin) => origin.startsWith('url:'))) return SourceType.url;
  if (origins.any((origin) => origin.startsWith('meeting:')))
    return SourceType.meeting;
  if (origins.any((origin) => origin.startsWith('google-calendar:')))
    return SourceType.calendar;
  final mime = (originalMime ?? source['mime'] as String? ?? '').toLowerCase();
  if (mime == 'application/pdf') return SourceType.pdf;
  if (mime.contains('spreadsheet') ||
      mime == 'application/vnd.google-apps.spreadsheet' ||
      mime == 'text/csv' ||
      mime == 'text/tab-separated-values')
    return SourceType.spreadsheet;
  if (mime.contains('presentation') ||
      mime == 'application/vnd.google-apps.presentation')
    return SourceType.presentation;
  if (mime.contains('word') ||
      mime == 'application/vnd.google-apps.document' ||
      mime == 'application/rtf' ||
      mime == 'text/rtf')
    return SourceType.document;
  if (mime.startsWith('text/')) return SourceType.text;
  return SourceType.other;
}
