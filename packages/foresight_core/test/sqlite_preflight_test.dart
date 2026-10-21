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
  final python = Platform.environment['FORESIGHT_PYTHON'] ?? 'python3';
  String snapshot() {
    // Independent nanosecond metadata catches root-only SQLite fchown effects
    // that Dart FileStat's changed timestamp can round away.
    final result = Process.runSync(python, [
      '-c',
      '''
import hashlib, json, pathlib, sys
result = {}
for path in pathlib.Path(sys.argv[1]).iterdir():
    if not path.is_file():
        continue
    info = path.stat()
    result[path.name] = {
        'device': info.st_dev, 'inode': info.st_ino, 'size': info.st_size,
        'mode': info.st_mode, 'uid': info.st_uid, 'gid': info.st_gid,
        'mtime_ns': info.st_mtime_ns, 'ctime_ns': info.st_ctime_ns,
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
    }
print(json.dumps(result, sort_keys=True))
''',
      root.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'Metadata snapshot failed: ${result.stdout}\n${result.stderr}',
    );
    return result.stdout as String;
  }

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
  test('empty rollback journal preserves nanosecond source metadata', () {
    final db = sqlite3.open(path);
    db.execute('PRAGMA user_version=15');
    db.dispose();
    File('$path-journal').writeAsBytesSync([]);
    qualify();
    expect(File('$path-journal').existsSync(), isTrue);
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
  test('metadata-only source change still rejects writable admission', () {
    final db = sqlite3.open(path);
    db.execute('PRAGMA user_version=15');
    db.dispose();
    final check = SqlitePreflight(path, supportedVersion: 15)..qualify();
    final before = Map<String, dynamic>.from(
      (jsonDecode(snapshot()) as Map)['application.db'] as Map,
    );
    final changed = File(path).statSync().changed;
    final elapsed = Stopwatch()..start();
    while (true) {
      final result = Process.runSync(python, [
        '-c',
        'import os,sys; p=sys.argv[1]; s=os.stat(p); '
            'os.utime(p, ns=(s.st_atime_ns, s.st_mtime_ns))',
        path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      // Observe a timestamp change at the production API's resolution; do not
      // assume a fixed sleep or silently rewrite mtime through Dart FileStat.
      if (File(path).statSync().changed != changed) break;
      if (elapsed.elapsed > const Duration(seconds: 5)) {
        fail('Filesystem did not report a metadata rewrite');
      }
    }
    final after = Map<String, dynamic>.from(
      (jsonDecode(snapshot()) as Map)['application.db'] as Map,
    );
    expect(after.remove('ctime_ns'), isNot(before.remove('ctime_ns')));
    expect(after, before, reason: 'Mutation must affect only ctime');
    expect(check.verifyUnchanged, throwsStateError);
  });
}
