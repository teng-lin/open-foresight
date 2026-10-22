import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
// Analyzer 12.1.0 is pinned: its public factory cannot accept a ByteStore.
// Keep this internal API confined to test tooling and revisit it on upgrades.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';

const desktopBoundaryEntries = ['desktop.dart', 'desktop_bootstrap.dart'];

List<String> desktopBoundaryPaths(Directory package) => [
  for (final entry in desktopBoundaryEntries) '${package.path}/lib/$entry',
];

AnalysisContextCollection desktopBoundaryContexts(Directory package) {
  final paths = desktopBoundaryPaths(package);
  final cache = Platform.environment['FORESIGHT_BOUNDARY_ANALYSIS_CACHE'];
  if (cache == null) {
    return AnalysisContextCollection(includedPaths: paths);
  }
  return AnalysisContextCollectionImpl(
    includedPaths: paths,
    byteStore: FileByteStore(cache),
  );
}
