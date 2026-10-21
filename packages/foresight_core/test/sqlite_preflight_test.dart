import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/persistence/sqlite_preflight.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String path;
  setUp(() {
    root = createTestTempDirectorySync('sqlite-preflight-');
    path = '${root.path}/application.db';
    addTearDown(() => root.deleteSync(recursive: true));
  });
  String snapshot() => jsonEncode({
    for (final file in root.listSync().whereType<File>())
      file.path: [
        file.statSync().size,
        file.statSync().modified.toString(),
        sha256.convert(file.readAsBytesSync()).toString(),
      ],
  });
  Future<void> crash(String mode, int version) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'test/fixtures/sqlite_crash.dart',
      path,
      mode,
      '$version',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  void qualify({bool succeeds = true}) {
    final before = snapshot();
    final check = SqlitePreflight(path, supportedVersion: 15);
    if (succeeds) {
      check.qualify();
    } else {
      expect(check.qualify, throwsStateError);
    }
    expect(
      snapshot(),
      before,
      reason: 'live bytes and metadata must not change',
    );
  }

  test('missing and empty databases do not create sidecars', () {
    qualify();
    expect(root.listSync(), isEmpty);
    File(path).writeAsBytesSync([]);
    qualify();
  });
  test('healthy and future DELETE profiles do not mutate', () {
    final db = sqlite3.open(path);
    db.execute('PRAGMA user_version=15');
    db.dispose();
    qualify();
    final newer = sqlite3.open(path);
    newer.execute('PRAGMA user_version=16');
    newer.dispose();
    qualify(succeeds: false);
  });
  test(
    'committed WAL-only future version refuses with or without SHM',
    () async {
      await crash('wal', 15);
      expect(
        ByteData.sublistView(File(path).readAsBytesSync()).getUint32(60),
        15,
      );
      qualify(succeeds: false);
      File('$path-shm').deleteSync();
      qualify(succeeds: false);
      expect(File('$path-shm').existsSync(), isFalse);
    },
  );
  test('supported WAL is qualified privately then recoverable', () async {
    await crash('wal', 14);
    File('$path-shm').deleteSync();
    qualify();
    expect(File('$path-shm').existsSync(), isFalse);
    final db = sqlite3.open(path);
    expect(
      db.select('SELECT body FROM payload').single['body'],
      'committed WAL body',
    );
    db.dispose();
  });
  test(
    'real hot rollback journal qualifies and SQLite restores original',
    () async {
      await crash('hot', 15);
      qualify();
      final db = sqlite3.open(path);
      expect(db.select('PRAGMA user_version').single.values.single, 15);
      expect(db.select('SELECT * FROM payload'), isEmpty);
      db.dispose();
    },
  );
  for (final boundary in ['before', 'after']) {
    test('real $boundary-commit journal hides future original page-1', () {
      final corpus =
          jsonDecode(
                File('test/fixtures/sqlite-hot-future.json').readAsStringSync(),
              )
              as Map;
      final files = (corpus['fixtures'] as Map)[boundary] as Map;
      for (final entry in files.entries) {
        final metadata = entry.value as Map;
        final bytes = gzip.decode(
          base64Decode(metadata['gzip_base64'] as String),
        );
        expect(sha256.convert(bytes).toString(), metadata['sha256']);
        File(
          entry.key.toString().endsWith('-journal') ? '$path-journal' : path,
        ).writeAsBytesSync(bytes);
      }
      expect(
        ByteData.sublistView(File(path).readAsBytesSync()).getUint32(60),
        0,
      );
      final before = snapshot();
      expect(
        SqlitePreflight(path, supportedVersion: 1).qualify,
        throwsStateError,
      );
      expect(snapshot(), before);
    });
  }
  test('changed source after qualification rejects writable admission', () {
    final db = sqlite3.open(path);
    db.execute('PRAGMA user_version=15');
    final check = SqlitePreflight(path, supportedVersion: 15)..qualify();
    db.execute('PRAGMA user_version=16');
    expect(check.verifyUnchanged, throwsStateError);
    db.dispose();
  });
}
