import 'dart:convert';
import 'dart:io';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import '../tool/migration_guard.dart';

const commit = 'c28a1561b5091645718462169bc6c0cfd0040943';
void main() {
  late Directory temp, trusted, candidate;
  final repo = Directory.current.parent.parent;
  final module = File('${repo.path}/$migrationPath').readAsStringSync();
  void write(Directory root, String path, String text) {
    final file = File('${root.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  void fixtures(Directory root) {
    for (final file in Directory(
      '${repo.path}/$fixturePath',
    ).listSync().whereType<File>()) {
      write(
        root,
        '$fixturePath/${file.uri.pathSegments.last}',
        file.readAsStringSync(),
      );
    }
  }

  Map<String, Object?> check({bool create = false, bool bootstrap = true}) =>
      verifyMigrations(
        candidate: candidate,
        trusted: trusted,
        trustedCommit: commit,
        bootstrap: bootstrap,
        createManifest: create,
      );
  void change(String from, String to) {
    expect(module, contains(from), reason: 'fixture must mutate real code');
    write(candidate, migrationPath, module.replaceFirst(from, to));
  }

  setUp(() {
    temp = createTestTempDirectorySync('migration-guard-');
    addTearDown(() => temp.deleteSync(recursive: true));
    trusted = Directory('${temp.path}/trusted')..createSync();
    candidate = Directory('${temp.path}/candidate')..createSync();
    for (final name in ['store.dart', 'graph_labels.dart']) {
      write(
        trusted,
        'packages/foresight_core/lib/src/$name',
        File('test/fixtures/persistence-c28a1561/$name.txt').readAsStringSync(),
      );
    }
    write(candidate, migrationPath, module);
    fixtures(candidate);
    check(create: true);
  });
  test('frozen complete definitions match independently supplied schema15', () {
    expect(check()['checked_versions'], 15);
    final entries = MigrationSource.read(
      candidate,
      requireFrozen: true,
    ).entries;
    expect(entries[1], entries[2]);
    expect(
      entries[9]!['symbols'],
      containsAll([
        'DocumentLabel',
        'allocateGraphLabelColor',
        'graphLabelPalette',
        'rows',
      ]),
    );
    expect(Directory('${temp.path}/.git').existsSync(), isFalse);
  });
  test(
    'actual main unrelated Store movement retains frozen origin provenance',
    () {
      final main = Directory('${temp.path}/actual-main')..createSync();
      for (final name in ['store.dart', 'graph_labels.dart']) {
        write(
          main,
          'packages/foresight_core/lib/src/$name',
          File(
            '${trusted.path}/packages/foresight_core/lib/src/$name',
          ).readAsStringSync().replaceFirst(
            'class Store {',
            'class Store {\n  int unrelated() => 42;',
          ),
        );
      }
      final result = verifyMigrations(
        candidate: candidate,
        trusted: main,
        trustedCommit: '3fb259243a99137e3cba1d5e795c44100f42e688',
        bootstrapRoot: trusted,
        bootstrapCommit: commit,
        bootstrap: true,
      );
      expect(result['checked_versions'], 15);
      final store = File(
        '${main.path}/packages/foresight_core/lib/src/store.dart',
      );
      final original = store.readAsStringSync();
      store.writeAsStringSync(
        original.replaceFirst("kind='action_items'", "kind='changed'"),
      );
      expect(
        () => verifyMigrations(
          candidate: candidate,
          trusted: main,
          trustedCommit: '3fb259243a99137e3cba1d5e795c44100f42e688',
          bootstrapRoot: trusted,
          bootstrapCommit: commit,
          bootstrap: true,
        ),
        throwsStateError,
      );
      store.writeAsStringSync(
        original.replaceFirst(
          'case 15:',
          "case 16:\n        db.execute('SELECT 1');\n      case 15:",
        ),
      );
      expect(
        () => verifyMigrations(
          candidate: candidate,
          trusted: main,
          trustedCommit: '3fb259243a99137e3cba1d5e795c44100f42e688',
          bootstrapRoot: trusted,
          bootstrapCommit: commit,
          bootstrap: true,
        ),
        throwsStateError,
      );
    },
  );
  test('formatting comments and verified private bindings preserve bodies', () {
    write(
      candidate,
      migrationPath,
      module.replaceAll('db.execute(', 'db /* same binding */ . execute ('),
    );
    expect(check()['checked_versions'], 15);
  });
  for (final edit in [
    ('runtime default', "DEFAULT 'llama_cpp'", "DEFAULT 'different_runtime'"),
    (
      'source URI closure',
      'provenance.substring(4)',
      'provenance.substring(3)',
    ),
    ('palette closure', "'#0EBC5F'", "'#000000'"),
    (
      'label factory closure',
      "row['document_id'] as String,\n        row['label_name'] as String",
      "row['document_id'] as String,\n        row['label_source'] as String",
    ),
    (
      'inline schema14',
      'input_length INTEGER NOT NULL',
      'input_length INTEGER',
    ),
    ('inline schema15', "kind='action_items'", "kind='old_actions'"),
  ]) {
    test('rejects ${edit.$1} even when local hashes regenerated', () {
      change(edit.$2, edit.$3);
      expect(() => check(create: true), throwsStateError);
    });
  }
  test('rejects live helper redirection', () {
    change(
      '_writeLabelRecords(id, names);',
      'LiveStore(db).writeLabelRecords(id, names);',
    );
    expect(() => check(create: true), throwsStateError);
  });
  test('rejects live import despite identical method tokens', () {
    write(candidate, migrationPath, "import '../store.dart';\n$module");
    expect(() => check(create: true), throwsStateError);
  });
  test('rejects constructor side effects', () {
    change(
      'ApplicationMigrations(this.db);',
      'ApplicationMigrations(this.db) { db.execute("DELETE FROM sources"); }',
    );
    expect(() => check(create: true), throwsStateError);
  });
  test(
    'changed source fixture cannot replace independently supplied source',
    () {
      final file = File('${candidate.path}/$fixturePath/store.dart.txt');
      file.writeAsStringSync('${file.readAsStringSync()}\n// changed\n');
      expect(() => check(create: true), throwsStateError);
    },
  );
  test('missing main manifest never silently enables bootstrap', () {
    expect(() => check(bootstrap: false), throwsStateError);
  });
  test(
    'subsequent main prefix freezes fixtures and rejects another bootstrap',
    () {
      write(trusted, migrationPath, module);
      fixtures(trusted);
      write(
        trusted,
        manifestPath,
        File('${candidate.path}/$manifestPath').readAsStringSync(),
      );
      expect(check(bootstrap: false)['mode'], 'reviewed-main-prefix');
      expect(() => check(create: true), throwsStateError);
      final file = File('${candidate.path}/$fixturePath/schema15.sql');
      file.writeAsStringSync('${file.readAsStringSync()}\n-- rebaseline\n');
      expect(() => check(bootstrap: false, create: true), throwsStateError);
    },
  );
  test('committed local digest cannot override independent comparison', () {
    final file = File('${candidate.path}/$manifestPath');
    final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    (value['migrations'] as Map)['5']['sha256'] = '0' * 64;
    file.writeAsStringSync(jsonEncode(value));
    expect(() => check(), throwsStateError);
  });
  for (final ref in ['refs/pull/998/merge', 'refs/heads/main', null]) {
    test('real guard works without git under ref $ref', () async {
      final env = Map<String, String>.from(Platform.environment)
        ..remove('GITHUB_REF');
      if (ref != null) env['GITHUB_REF'] = ref;
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          '${repo.path}/packages/foresight_core/tool/migration_guard.dart',
          'check',
          '--candidate-root',
          candidate.path,
          '--trusted-root',
          trusted.path,
          '--trusted-commit',
          commit,
          '--bootstrap',
        ],
        environment: env,
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 45));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        (jsonDecode(result.stdout as String) as Map)['checked_versions'],
        15,
      );
    });
  }
}
