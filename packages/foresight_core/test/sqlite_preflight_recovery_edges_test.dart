import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/persistence/sqlite_preflight.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

class _DatabaseFiles {
  final root = createTestTempDirectorySync('sqlite-qualification-contract-');
  late final path = '${root.path}/application.db';

  _DatabaseFiles() {
    addTearDown(() => root.deleteSync(recursive: true));
  }

  void healthy({int pageSize = 4096}) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA page_size=$pageSize');
      db.execute('CREATE TABLE payload(body TEXT)');
      db.execute('PRAGMA user_version=2');
    } finally {
      db.dispose();
    }
  }

  void frozenHotJournal() {
    final corpus =
        jsonDecode(
              File('test/fixtures/sqlite-hot-future.json').readAsStringSync(),
            )
            as Map;
    expect(corpus['generator'], contains('real SQLite VFS'));
    final files = (corpus['fixtures'] as Map)['before'] as Map;
    for (final row in files.entries) {
      final metadata = row.value as Map;
      final bytes = gzip.decode(
        base64Decode(metadata['gzip_base64'] as String),
      );
      expect(sha256.convert(bytes).toString(), metadata['sha256']);
      File(
        row.key.toString().endsWith('-journal') ? '$path-journal' : path,
      ).writeAsBytesSync(bytes);
    }
  }

  String snapshot() {
    final result =
        Process.runSync(Platform.environment['FORESIGHT_PYTHON'] ?? 'python3', [
          '-c',
          'import hashlib,json,pathlib,sys; result={}; '
              '\nfor p in pathlib.Path(sys.argv[1]).iterdir():'
              '\n if p.is_file():'
              '\n  s=p.stat(); result[p.name]={'
              '"sha256":hashlib.sha256(p.read_bytes()).hexdigest(),'
              '"mode":s.st_mode,"inode":s.st_ino,"device":s.st_dev,'
              '"mtime_ns":s.st_mtime_ns,"ctime_ns":s.st_ctime_ns}'
              '\nprint(json.dumps(result,sort_keys=True))',
          root.path,
        ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return result.stdout as String;
  }

  void qualify({String? refusal}) {
    final before = snapshot();
    final check = SqlitePreflight(path, supportedVersion: 15);
    if (refusal == null) {
      check.qualify();
    } else {
      expect(
        check.qualify,
        throwsA(
          isA<StateError>().having((e) => '$e', 'reason', contains(refusal)),
        ),
      );
    }
    expect(
      snapshot(),
      before,
      reason: 'Qualification must preserve live bytes and nanosecond identity',
    );
  }
}

void _uint32(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.big);

// Retain the checksum-verified real page records and vary only the trailing
// master-journal reference. A 492-byte valid path makes that footer one full
// sector, so the verifier must inspect it instead of stopping at a short tail.
Uint8List _sectorSizedFooter(Uint8List original) {
  final oldLength = ByteData.sublistView(
    original,
  ).getUint32(original.length - 16, Endian.big);
  final offset = original.length - oldLength - 20;
  expect(
    ByteData.sublistView(original).getUint32(offset, Endian.big),
    0x40000000 ~/ 4096 + 1,
  );
  final name = utf8.encode('/tmp/${List.filled(8, 's' * 60).join('/')}');
  expect(name.length, 492);
  final result = Uint8List(offset + name.length + 20);
  result.setRange(0, offset + 4, original);
  result.setRange(offset + 4, offset + 4 + name.length, name);
  _uint32(result, result.length - 16, name.length);
  _uint32(
    result,
    result.length - 12,
    name.fold<int>(0, (sum, byte) => sum + byte),
  );
  result.setRange(
    result.length - 8,
    result.length,
    original.sublist(original.length - 8),
  );
  return result;
}

void main() {
  bootstrapSqlSupportFixture();
  test(
    'valid maximum SQLite page size qualifies without rewriting its header',
    () {
      final files = _DatabaseFiles()..healthy(pageSize: 65536);
      final bytes = File(files.path).readAsBytesSync();
      expect(bytes.sublist(16, 18), [0, 1]);
      files.qualify();
    },
  );

  for (final variant in [
    'magic',
    'page size',
    'read/write versions',
    'truncated',
  ]) {
    test(
      'invalid database $variant refuses before writable admission and preserves bytes',
      () {
        final files = _DatabaseFiles()..healthy();
        var bytes = File(files.path).readAsBytesSync();
        switch (variant) {
          case 'magic':
            bytes[0] ^= 0x40;
          case 'page size':
            bytes[16] = 0;
            bytes[17] = 3;
          case 'read/write versions':
            bytes[18] = 1;
            bytes[19] = 2;
          case 'truncated':
            bytes = Uint8List.fromList(bytes.take(99).toList());
        }
        File(files.path).writeAsBytesSync(bytes);
        files.qualify(
          refusal: variant == 'magic'
              ? 'page-1 header'
              : variant == 'truncated'
              ? 'truncated database'
              : 'page geometry',
        );
      },
    );
  }

  test(
    'nonregular sidecar refuses before SQLite can interpret it as a WAL',
    () {
      final files = _DatabaseFiles()..healthy();
      Directory('${files.path}-wal').createSync();
      files.qualify(refusal: 'not a regular file');
      expect(Directory('${files.path}-wal').existsSync(), isTrue);
    },
  );

  test(
    'ambiguous WAL and rollback sidecars refuse without erasing either recovery source',
    () {
      final files = _DatabaseFiles()..frozenHotJournal();
      File('${files.path}-wal').writeAsBytesSync([1, 2, 3, 4]);
      files.qualify(refusal: 'ambiguous WAL and rollback journal');
    },
  );

  test(
    'superjournal additions and removals invalidate an otherwise qualified source identity',
    () {
      final files = _DatabaseFiles()..healthy();
      final old = File('${files.path}-mj-original')
        ..writeAsStringSync('owned recovery marker');
      final check = SqlitePreflight(files.path, supportedVersion: 15)
        ..qualify();
      old.deleteSync();
      expect(
        check.verifyUnchanged,
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'reason',
            contains('sidecar changed'),
          ),
        ),
      );
      final second = SqlitePreflight(files.path, supportedVersion: 15)
        ..qualify();
      File('${files.path}-mj-new').writeAsStringSync('new recovery marker');
      expect(second.verifyUnchanged, throwsStateError);
    },
  );

  test(
    'frozen real hot journal permits supported page-one and a valid superjournal footer',
    () {
      final files = _DatabaseFiles()..frozenHotJournal();
      files.qualify();
    },
  );

  test(
    'real hot journal validates a complete sector-sized superjournal reference',
    () {
      final files = _DatabaseFiles()..frozenHotJournal();
      final journal = File('${files.path}-journal');
      journal.writeAsBytesSync(_sectorSizedFooter(journal.readAsBytesSync()));
      files.qualify();
    },
  );

  test(
    'real hot journal sentinel page count preserves successful private qualification',
    () {
      final files = _DatabaseFiles()..frozenHotJournal();
      final journal = File('${files.path}-journal');
      final bytes = journal.readAsBytesSync();
      _uint32(bytes, 8, 0xffffffff);
      journal.writeAsBytesSync(bytes);
      files.qualify();
    },
  );

  for (final offset in [1, 12]) {
    test(
      'compatible short journal tail damage at $offset leaves original recovery files intact',
      () {
        final files = _DatabaseFiles()..frozenHotJournal();
        final journal = File('${files.path}-journal');
        final bytes = journal.readAsBytesSync();
        bytes[bytes.length - offset] ^= 1;
        journal.writeAsBytesSync(bytes);
        // Both current and retained page-one versions are supported. SQLite and
        // the qualifier may ignore this short tail; admission must stay read-only.
        files.qualify();
      },
    );
  }

  final mutations =
      <({String name, String refusal, void Function(Uint8List) change})>[
        (
          name: 'unsupported sector geometry',
          refusal: 'unsupported rollback journal geometry',
          change: (bytes) => _uint32(bytes, 20, 1000),
        ),
        (
          name: 'truncated record inventory',
          refusal: 'truncated journal page records',
          change: (bytes) => _uint32(bytes, 8, 999),
        ),
        (
          name: 'invalid page number',
          refusal: 'invalid rollback page number',
          change: (bytes) => _uint32(bytes, 512, 0),
        ),
        (
          name: 'invalid page checksum',
          refusal: 'invalid rollback page checksum',
          change: (bytes) => bytes[512 + 4096 + 4] ^= 1,
        ),
        (
          name: 'invalid footer magic',
          refusal: 'unrecognized superjournal footer',
          change: (bytes) => bytes[bytes.length - 1] ^= 1,
        ),
        (
          name: 'invalid footer checksum',
          refusal: 'invalid superjournal checksum',
          change: (bytes) => bytes[bytes.length - 12] ^= 1,
        ),
      ];
  for (final mutation in mutations) {
    test(
      'real hot journal ${mutation.name} refuses with original metadata intact',
      () {
        final files = _DatabaseFiles()..frozenHotJournal();
        final journal = File('${files.path}-journal');
        var bytes = journal.readAsBytesSync();
        if (mutation.name.contains('footer')) bytes = _sectorSizedFooter(bytes);
        mutation.change(bytes);
        journal.writeAsBytesSync(bytes);
        files.qualify(refusal: mutation.refusal);
      },
    );
  }
}
