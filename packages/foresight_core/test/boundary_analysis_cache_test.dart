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
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _ObservedStore implements ByteStore {
  final FileByteStore delegate;
  final writtenKeys = <String>{};
  final _pendingKeys = <String>{};
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
    _pendingKeys.add(key);
    return delegate.putGet(key, bytes);
  }

  @override
  void release(Iterable<String> keys) => delegate.release(keys);

  Future<void> awaitDiskWrites(String cache) async {
    if (_pendingKeys.isEmpty) return;
    // Use another store so an in-progress write cannot masquerade as disk reuse.
    final reader = FileByteStore(cache);
    final clock = Stopwatch()..start();
    while (!_pendingKeys.every((key) => reader.get(key) != null)) {
      if (clock.elapsed > const Duration(seconds: 5)) {
        fail('Analyzer compiler bundles did not finish writing to $cache');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // These writes stay complete when a test later damages their cache entries.
    _pendingKeys.clear();
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

const _original = {'ConditionalDefault', 'OnlyShown', 'TransitAllowed'};
const _conditional = {
  'ConditionalSelected',
  'OnlyShown',
  'TransitAllowed',
  'Store',
};

class _BoundaryFixture {
  final Directory root = createTestTempDirectorySync('boundary-analysis-test-');
  late final Directory cache = Directory('${root.path}/cache')..createSync();
  late final File entry = File('${root.path}/entry.dart');
  late final File leaf = File('${root.path}/leaf.dart');
  final _stores = <_ObservedStore>[];

  _BoundaryFixture({bool includeStore = false}) {
    addTearDown(_dispose);
    entry.writeAsStringSync(
      "export 'middle.dart' hide HiddenAtEntry;\n"
      "export 'shown.dart' show OnlyShown;\n"
      "export 'default.dart' if (diagnostic.selected) 'selected.dart';\n",
    );
    File(
      '${root.path}/middle.dart',
    ).writeAsStringSync("export 'leaf.dart' hide TransitHidden;\n");
    leaf.writeAsStringSync(
      'class TransitAllowed {}\n'
      'class TransitHidden {}\n'
      'class HiddenAtEntry {}\n'
      '${includeStore ? 'class Store {}\n' : ''}',
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
  }

  _ObservedStore store() {
    final store = _ObservedStore(cache.path);
    _stores.add(store);
    return store;
  }

  Future<void> _dispose() async {
    for (final store in _stores) {
      await store.awaitDiskWrites(cache.path);
    }
    root.deleteSync(recursive: true);
  }
}

void main() {
  test('warm compiler bundles preserve transitive show/hide exports', () async {
    final fixture = _BoundaryFixture();
    final cold = fixture.store();
    expect(await _namespace(fixture.entry, cold), _original);
    expect(cold.writtenKeys, isNotEmpty);
    await cold.awaitDiskWrites(fixture.cache.path);

    final warm = fixture.store();
    expect(await _namespace(fixture.entry, warm), _original);
    expect(warm.hits, greaterThan(0));
    expect(warm.writtenKeys, isEmpty);
    await warm.awaitDiskWrites(fixture.cache.path);
  });

  test('transitive source changes invalidate compiler bundles', () async {
    final fixture = _BoundaryFixture();
    final cold = fixture.store();
    expect(await _namespace(fixture.entry, cold), _original);
    expect(cold.writtenKeys, isNotEmpty);
    await cold.awaitDiskWrites(fixture.cache.path);

    fixture.leaf.writeAsStringSync('class Store {}\n', mode: FileMode.append);
    final changed = fixture.store();
    expect(await _namespace(fixture.entry, changed), {..._original, 'Store'});
    expect(changed.hits, greaterThan(0));
    expect(changed.writtenKeys, isNotEmpty);
    await changed.awaitDiskWrites(fixture.cache.path);
  });

  test('conditional variables invalidate compiler bundles', () async {
    final fixture = _BoundaryFixture(includeStore: true);
    final cold = fixture.store();
    expect(await _namespace(fixture.entry, cold), {..._original, 'Store'});
    expect(cold.writtenKeys, isNotEmpty);
    await cold.awaitDiskWrites(fixture.cache.path);

    final selected = fixture.store();
    expect(
      await _namespace(fixture.entry, selected, selected: true),
      _conditional,
    );
    expect(selected.writtenKeys, isNotEmpty);
    await selected.awaitDiskWrites(fixture.cache.path);
  });

  test('damaged compiler bundles miss and rebuild semantic exports', () async {
    final fixture = _BoundaryFixture(includeStore: true);
    final cold = fixture.store();
    expect(await _namespace(fixture.entry, cold, selected: true), _conditional);
    expect(cold.writtenKeys, isNotEmpty);
    await cold.awaitDiskWrites(fixture.cache.path);

    // Truncation, wrong version and checksum damage must all become misses.
    var index = 0;
    for (final file
        in fixture.cache.listSync(recursive: true).whereType<File>()) {
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
    final damaged = fixture.store();
    expect(
      await _namespace(fixture.entry, damaged, selected: true),
      _conditional,
    );
    expect(damaged.hits, 0);
    expect(damaged.misses, greaterThan(0));
    expect(damaged.writtenKeys, isNotEmpty);
    await damaged.awaitDiskWrites(fixture.cache.path);
  });
}
