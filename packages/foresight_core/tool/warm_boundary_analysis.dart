import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';

import '../test/support/boundary_analysis.dart';

Future<void> main() async {
  final package = Directory.current.absolute;
  final contexts = desktopBoundaryContexts(package);
  try {
    for (final path in desktopBoundaryPaths(package)) {
      final session = contexts.contextFor(path).currentSession;
      final uri = session.uriConverter.pathToUri(path);
      if (uri == null) throw StateError('No exact library binding for $path');
      final result = await session.getLibraryByUri(uri.toString());
      if (result is! LibraryElementResult) {
        throw StateError('Cannot link boundary library $path: $result');
      }
    }
  } finally {
    await contexts.dispose();
  }
  // Exit naturally: FileByteStore finishes its pending asynchronous writes.
  // Only compiler bundles are reused; the test still inspects both namespaces.
}
