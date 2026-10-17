import 'dart:io';

import 'package:foresight_core/src/file_discovery.dart';
import 'package:test/test.dart';

void main() {
  test(
    'discovery scans chosen roots, excludes imports, skips links and hidden/build folders',
    () async {
      final root = Directory.systemTemp.createTempSync('foresight-discovery-');
      addTearDown(() => root.deleteSync(recursive: true));
      final nested = Directory('${root.path}/nested')..createSync();
      for (final path in [
        'note.TXT',
        'already; imported.md',
        'ignore.png',
        '.hidden.md',
        'nested/plan.pdf',
        '.private/secret.txt',
        'build/generated.txt',
      ]) {
        final file = File('${root.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('fixture');
      }
      Link('${root.path}/loop').createSync(root.path);
      Link('${root.path}/linked.txt').createSync('${root.path}/note.TXT');
      final result = await LocalFileDiscovery().scan(
        [root.path, nested.path, '${root.path}/.'],
        excludedPaths: {'${root.path}/already; imported.md'},
      );
      expect(result.files.map((f) => f.name).toSet(), {'note.TXT', 'plan.pdf'});
      expect(result.alreadyImported, 1);
      expect(result.truncated, false);
      expect(result.files.every((f) => f.bytes == 7), true);
    },
  );
  test(
    'unavailable folders do not prevent discovery in readable roots',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'foresight-discovery-unavailable-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/note.md').writeAsStringSync('fixture');
      final result = await LocalFileDiscovery().scan([
        '${root.path}/missing',
        root.path,
      ]);
      expect(result.files.single.name, 'note.md');
      expect(result.unavailableFolders.length, 1);
    },
  );
  test('scan limits and cancellation bound work', () async {
    final root = Directory.systemTemp.createTempSync(
      'foresight-discovery-limits-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    for (var i = 0; i < 150; i++) {
      File('${root.path}/note-$i.txt').writeAsStringSync('fixture');
    }
    final bounded = await LocalFileDiscovery().scan([root.path], maxFiles: 3);
    expect(bounded.files.length, 3);
    expect(bounded.truncated, true);
    final entries = await LocalFileDiscovery().scan([root.path], maxEntries: 2);
    expect(entries.examined, 2);
    expect(entries.truncated, true);
    final scanner = LocalFileDiscovery();
    final cancelled = await scanner.scan(
      [root.path],
      progress: (count, _) {
        if (count >= 100) scanner.cancel();
      },
    );
    expect(cancelled.examined, 100);
    final stopped = LocalFileDiscovery()..cancel();
    expect((await stopped.scan([root.path])).examined, 0);
  });

  test('invalid scan limits fail before progress or filesystem work', () async {
    for (final limits in [(0, 1), (1, 0), (-1, 1), (1, -1)]) {
      var progressCalled = false;
      await expectLater(
        LocalFileDiscovery().scan(
          ['/missing'],
          maxFiles: limits.$1,
          maxEntries: limits.$2,
          progress: (_, _) => progressCalled = true,
        ),
        throwsArgumentError,
      );
      expect(progressCalled, isFalse);
    }
  });

  test('default folders include only existing directories', () {
    final root = Directory.systemTemp.createTempSync('discovery-defaults-');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(LocalFileDiscovery.defaultFolders(root.path), isEmpty);
    Directory('${root.path}/Downloads').createSync();
    Directory('${root.path}/Desktop').createSync();
    File('${root.path}/Documents').writeAsStringSync('not a directory');
    expect(LocalFileDiscovery.defaultFolders(root.path), [
      '${root.path}/Downloads',
      '${root.path}/Desktop',
    ]);
  });

  test(
    'results sort newest first with a stable path tie break and byte sizes',
    () async {
      final root = Directory.systemTemp.createTempSync('discovery-order-');
      addTearDown(() => root.deleteSync(recursive: true));
      final old = DateTime.utc(2020), recent = DateTime.utc(2021);
      for (final name in ['b.txt', 'a.RTF', 'c.md']) {
        File('${root.path}/$name')
          ..writeAsStringSync('café 日本語')
          ..setLastModifiedSync(name == 'c.md' ? recent : old);
      }
      final result = await LocalFileDiscovery().scan([root.path]);
      expect(result.files.map((file) => file.name), ['c.md', 'a.RTF', 'b.txt']);
      expect(result.files.map((file) => file.modified.toUtc()), [
        recent,
        old,
        old,
      ]);
      expect(result.files.every((file) => file.bytes == 15), isTrue);
    },
  );

  test(
    'canonical roots deduplicate aliases and excluded symlinks resolve to their targets',
    () async {
      final root = Directory.systemTemp.createTempSync('discovery-alias-');
      addTearDown(() => root.deleteSync(recursive: true));
      final folder = Directory('${root.path}/documents')..createSync();
      final file = File('${folder.path}/saved.md')
        ..writeAsStringSync('existing');
      final alias = Link('${root.path}/alias')..createSync(folder.path);
      final excludedAlias = Link('${root.path}/already.md')
        ..createSync(file.path);
      final result = await LocalFileDiscovery().scan(
        [folder.path, alias.path, '${folder.path}/.'],
        excludedPaths: {excludedAlias.path},
      );
      expect(result.files, isEmpty);
      expect(result.examined, 1);
      expect(result.alreadyImported, 1);
      expect(result.unavailableFolders, isEmpty);
    },
  );

  test(
    'missing excluded files and non-directory roots do not block readable roots',
    () async {
      final root = Directory.systemTemp.createTempSync('discovery-missing-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/note.txt')
        ..writeAsStringSync('available');
      final result = await LocalFileDiscovery().scan(
        [file.path, root.path],
        excludedPaths: {'${root.path}/deleted.txt'},
      );
      expect(result.files.single.path, file.resolveSymbolicLinksSync());
      expect(result.unavailableFolders, [file.resolveSymbolicLinksSync()]);
      expect(result.alreadyImported, 0);
    },
  );

  test(
    'progress remains monotonic and ends with the exact completed count',
    () async {
      final root = Directory.systemTemp.createTempSync('discovery-progress-');
      addTearDown(() => root.deleteSync(recursive: true));
      for (var i = 0; i < 105; i++) {
        File('${root.path}/$i.txt').writeAsStringSync('fixture');
      }
      final updates = <(int, int)>[];
      final result = await LocalFileDiscovery().scan([
        root.path,
      ], progress: (examined, found) => updates.add((examined, found)));
      expect(updates, [(100, 100), (105, 105)]);
      expect(result.files, hasLength(105));
      expect(result.truncated, isFalse);
    },
  );

  test(
    'cancellation before scanning also skips excluded path resolution',
    () async {
      final scanner = LocalFileDiscovery()..cancel();
      final updates = <(int, int)>[];
      final result = await scanner.scan(
        ['/missing'],
        excludedPaths: {'/missing/file'},
        progress: (examined, found) => updates.add((examined, found)),
      );
      expect(result.examined, 0);
      expect(result.files, isEmpty);
      expect(result.unavailableFolders, isEmpty);
      expect(result.truncated, isFalse);
      expect(updates, [(0, 0)]);
    },
  );
}
