import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/results.dart';
// Analyzer 12.1.0 is pinned; exercise its actual compiler-bundle store and linker.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/byte_store.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:test/test.dart';

class _ObservedStore implements ByteStore {
  final FileByteStore delegate;
  final writtenKeys = <String>{};
  int hits = 0;
  int misses = 0;

  _ObservedStore(String path) : delegate = FileByteStore(path);

  @override
  Uint8List? get(String key) {
    final bytes = delegate.get(key);
    if (bytes == null) {
      misses++;
    } else {
      hits++;
    }
    return bytes;
  }

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    writtenKeys.add(key);
    return delegate.putGet(key, bytes);
  }

  @override
  void release(Iterable<String> keys) => delegate.release(keys);

  Future<void> awaitDiskWrites(String cache) async {
    // Use another store so an in-progress write cannot masquerade as disk reuse.
    final reader = FileByteStore(cache);
    final clock = Stopwatch()..start();
    while (!writtenKeys.every((key) => reader.get(key) != null)) {
      if (clock.elapsed > const Duration(seconds: 5)) {
        fail('Analyzer compiler bundles did not finish writing to $cache');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

Future<Set<String>> _namespace(
  File entry,
  _ObservedStore store, {
  bool selected = false,
}) async {
  final contexts = AnalysisContextCollectionImpl(
    includedPaths: [entry.path],
    byteStore: store,
    declaredVariables: {'diagnostic.selected': '$selected'},
  );
  try {
    final session = contexts.contextFor(entry.path).currentSession;
    final uri = session.uriConverter.pathToUri(entry.path);
    expect(uri, isNotNull);
    final result = await session.getLibraryByUri(uri!.toString());
    expect(result, isA<LibraryElementResult>());
    return (result as LibraryElementResult)
        .element
        .exportNamespace
        .definedNames2
        .keys
        .toSet();
  } finally {
    await contexts.dispose();
  }
}

void main() {
  test(
    'compiler bundles preserve semantic exports and reject damaged cache',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'boundary-analysis-test-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final cache = Directory('${root.path}/cache')..createSync();
      final entry = File('${root.path}/entry.dart')
        ..writeAsStringSync(
          "export 'middle.dart' hide HiddenAtEntry;\n"
          "export 'shown.dart' show OnlyShown;\n"
          "export 'default.dart' if (diagnostic.selected) 'selected.dart';\n",
        );
      File(
        '${root.path}/middle.dart',
      ).writeAsStringSync("export 'leaf.dart' hide TransitHidden;\n");
      final leaf = File('${root.path}/leaf.dart')
        ..writeAsStringSync(
          'class TransitAllowed {}\n'
          'class TransitHidden {}\n'
          'class HiddenAtEntry {}\n',
        );
      File(
        '${root.path}/shown.dart',
      ).writeAsStringSync('class OnlyShown {}\nclass HiddenByShow {}\n');
      File(
        '${root.path}/default.dart',
      ).writeAsStringSync('class ConditionalDefault {}\n');
      File(
        '${root.path}/selected.dart',
      ).writeAsStringSync('class ConditionalSelected {}\n');
      const original = {'ConditionalDefault', 'OnlyShown', 'TransitAllowed'};
      final cold = _ObservedStore(cache.path);
      expect(await _namespace(entry, cold), original);
      expect(cold.writtenKeys, isNotEmpty);
      await cold.awaitDiskWrites(cache.path);

      final warm = _ObservedStore(cache.path);
      expect(await _namespace(entry, warm), original);
      expect(warm.hits, greaterThan(0));
      expect(warm.writtenKeys, isEmpty);

      leaf.writeAsStringSync('class Store {}\n', mode: FileMode.append);
      final changed = _ObservedStore(cache.path);
      expect(await _namespace(entry, changed), {...original, 'Store'});
      expect(changed.hits, greaterThan(0));
      expect(changed.writtenKeys, isNotEmpty);
      await changed.awaitDiskWrites(cache.path);

      const conditional = {
        'ConditionalSelected',
        'OnlyShown',
        'TransitAllowed',
        'Store',
      };
      final selected = _ObservedStore(cache.path);
      expect(await _namespace(entry, selected, selected: true), conditional);
      expect(selected.writtenKeys, isNotEmpty);
      await selected.awaitDiskWrites(cache.path);

      // Truncation, wrong version and checksum damage must all become misses.
      var index = 0;
      for (final file in cache.listSync(recursive: true).whereType<File>()) {
        final bytes = file.readAsBytesSync();
        switch (index++ % 3) {
          case 0:
            file.writeAsBytesSync(bytes.take(2).toList());
          case 1:
            bytes[bytes.length - 4] ^= 0x80;
            file.writeAsBytesSync(bytes);
          case 2:
            bytes[0] ^= 0x80;
            file.writeAsBytesSync(bytes);
        }
      }
      final damaged = _ObservedStore(cache.path);
      expect(await _namespace(entry, damaged, selected: true), conditional);
      expect(damaged.misses, greaterThan(0));
      expect(damaged.writtenKeys, isNotEmpty);
      await damaged.awaitDiskWrites(cache.path);
    },
  );
}
