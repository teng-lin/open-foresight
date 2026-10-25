import 'package:foresight_core/desktop.dart'
    show SourceSummary, SourceType, sourceType;

SourceType typedSourceType(SourceSummary source, {String? originalMime}) =>
    sourceType({
      'mime': source.mime,
      'provenance': source.provenance,
    }, originalMime: originalMime);
