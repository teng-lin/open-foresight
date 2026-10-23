import 'dart:io';
import 'dart:typed_data';

import 'sqlite_runtime.dart';

import '../platform_file_metadata.dart' show fileMetadataSync;
import '../platform_services.dart' show protectPrivateFile;

/// Qualifies existing bytes before any live writable connection is opened.
/// SQLite owns recovery; this verifier never repairs or rewrites a journal.
/// See SQLite fileformat.html (database header / rollback journal) and pager.c
/// readJournalHdr, pager_cksum, pager_playback_one_page.
class SqlitePreflight {
  final String path;
  final int supportedVersion;
  late final Map<String, Object?> _originals = _identities();

  SqlitePreflight(String path, {required this.supportedVersion})
    : path = File(path).absolute.path;

  Never _refuse(String why) => throw StateError(
    'Cannot qualify application database: $why; no migration was started',
  );

  Object? _identity(String path) {
    final metadata = fileMetadataSync(path);
    if (metadata == null) return null;
    if (metadata.mode & 0xf000 != 0x8000) {
      _refuse('database or sidecar is not a regular file');
    }
    return metadata;
  }

  Map<String, Object?> _identities() {
    final result = <String, Object?>{
      for (final suffix in ['', '-wal', '-shm', '-journal'])
        '$path$suffix': _identity('$path$suffix'),
    };
    final file = File(path);
    if (file.parent.existsSync()) {
      final prefix = '${file.uri.pathSegments.last}-mj';
      for (final entry in file.parent.listSync(followLinks: false)) {
        if (entry.uri.pathSegments.last.startsWith(prefix)) {
          result[entry.path] = _identity(entry.path);
        }
      }
    }
    return result;
  }

  void verifyUnchanged() {
    final now = _identities();
    if (now.length != _originals.length ||
        now.entries.any((entry) => _originals[entry.key] != entry.value)) {
      _refuse(
        'database or sidecar changed during qualification; retry offline',
      );
    }
  }

  void _supported(int version) {
    if (version < 0 || version > supportedVersion) {
      throw StateError(
        'Unsupported newer application database version $version '
        '(maximum $supportedVersion)',
      );
    }
  }

  Uint8List _read(RandomAccessFile file, int offset, int size) {
    file.setPositionSync(offset);
    final bytes = file.readSync(size);
    if (bytes.length != size) _refuse('truncated database or journal');
    return bytes;
  }

  int _be(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes).getUint32(offset, Endian.big);

  bool _pageOne(Uint8List bytes) {
    const magic = [
      83,
      81,
      76,
      105,
      116,
      101,
      32,
      102,
      111,
      114,
      109,
      97,
      116,
      32,
      51,
      0,
    ];
    if (bytes.length < 100 ||
        Iterable<int>.generate(16).any((i) => bytes[i] != magic[i])) {
      _refuse('unrecognized database page-1 header');
    }
    var size = bytes[16] * 256 + bytes[17];
    if (size == 1) size = 65536;
    if (size < 512 ||
        size > 65536 ||
        (size & (size - 1)) != 0 ||
        bytes[18] != bytes[19] ||
        ![1, 2].contains(bytes[18])) {
      _refuse('unrecognized database page geometry');
    }
    _supported(_be(bytes, 60));
    return bytes[18] == 2;
  }

  void _journalVersions() {
    final journal = File('$path-journal');
    if (!journal.existsSync() || journal.lengthSync() == 0) {
      _refuse('SQLite requires recovery but no rollback journal is available');
    }
    const magic = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];
    final file = journal.openSync();
    try {
      final length = file.lengthSync();
      if (length < 512) _refuse('truncated rollback journal header');
      var offset = 0, sector = 512, pageSize = 0;
      while (offset + sector <= length) {
        final header = _read(file, offset, 28);
        if (header.take(12).every((byte) => byte == 0)) return;
        if (pageSize != 0 && _be(header, 0) == 0x40000000 ~/ pageSize + 1) {
          final tail = _read(file, length - 16, 16);
          final nameLength = _be(tail, 0);
          if (nameLength + 20 != length - offset ||
              Iterable<int>.generate(8).any((i) => tail[i + 8] != magic[i])) {
            _refuse('unrecognized superjournal footer');
          }
          final name = _read(file, offset + 4, nameLength);
          final checksum = name.fold<int>(
            0,
            (sum, value) =>
                (sum + (value < 128 ? value : value - 256)) & 0xffffffff,
          );
          if (checksum != _be(tail, 4)) {
            _refuse('invalid superjournal checksum');
          }
          return;
        }
        if (Iterable<int>.generate(8).any((i) => header[i] != magic[i])) {
          _refuse('unrecognized rollback journal header');
        }
        var count = _be(header, 8);
        final nonce = _be(header, 12), pages = _be(header, 16);
        final nextSector = _be(header, 20), nextPage = _be(header, 24);
        if (nextSector < 32 ||
            nextSector > 65536 ||
            (nextSector & (nextSector - 1)) != 0 ||
            nextPage < 512 ||
            nextPage > 65536 ||
            (nextPage & (nextPage - 1)) != 0 ||
            (pageSize != 0 && (pageSize != nextPage || sector != nextSector))) {
          _refuse('unsupported rollback journal geometry');
        }
        sector = nextSector;
        pageSize = nextPage;
        if (sector > length - offset) _refuse('truncated journal segment');
        offset += sector;
        if (count == 0xffffffff) count = (length - offset) ~/ (pageSize + 8);
        if (count > (length - offset) ~/ (pageSize + 8)) {
          _refuse('truncated journal page records');
        }
        for (var i = 0; i < count; i++) {
          final record = _read(file, offset, pageSize + 8);
          final page = _be(record, 0);
          if (page == 0 || page == 0x40000000 ~/ pageSize + 1) {
            _refuse('invalid rollback page number');
          }
          if (page <= pages) {
            var checksum = nonce;
            for (var at = pageSize - 200; at > 0; at -= 200) {
              checksum = (checksum + record[4 + at]) & 0xffffffff;
            }
            if (checksum != _be(record, pageSize + 4)) {
              _refuse('invalid rollback page checksum');
            }
            if (page == 1) _pageOne(Uint8List.sublistView(record, 4));
          }
          offset += pageSize + 8;
        }
        offset = ((offset + sector - 1) ~/ sector) * sector;
      }
    } finally {
      file.closeSync();
    }
  }

  int _readonlyVersion(String candidate) {
    final db = sqlite3.open(candidate, mode: OpenMode.readOnly);
    try {
      return db.select('PRAGMA user_version').single.values.single as int;
    } finally {
      db.dispose();
    }
  }

  void qualify() {
    // Evaluate the lazy snapshot before the first probe/copy.
    _originals;
    final original = File(path);
    if (!original.existsSync() || original.lengthSync() == 0) {
      verifyUnchanged();
      return;
    }
    final file = original.openSync();
    late final bool walMode;
    try {
      walMode = _pageOne(_read(file, 0, 100));
    } finally {
      file.closeSync();
    }
    final wal = File('$path-wal'), journal = File('$path-journal');
    if (walMode || wal.existsSync()) {
      if (journal.existsSync() && journal.lengthSync() != 0) {
        _refuse(
          'ambiguous WAL and rollback journal; recover with compatible SQLite',
        );
      }
      final scratch = Directory.systemTemp.createTempSync('of-schema-');
      try {
        final copy = '${scratch.path}/qualification.db';
        original.copySync(copy);
        protectPrivateFile(copy);
        if (wal.existsSync()) {
          wal.copySync('$copy-wal');
          protectPrivateFile('$copy-wal');
        }
        verifyUnchanged();
        try {
          _supported(_readonlyVersion(copy));
        } on SqliteException catch (error) {
          _refuse(
            'private SQLite snapshot is unreadable (${error.extendedResultCode}); retry offline or recover with compatible SQLite',
          );
        }
      } finally {
        scratch.deleteSync(recursive: true);
      }
    } else {
      Directory? scratch;
      try {
        var candidate = path;
        if (journal.existsSync()) {
          // SQLite can fchown even an empty journal during a read-only open
          // when running as root. Keep that metadata write on private copies.
          // READONLY_ROLLBACK precedes playback/superjournal lookup; never
          // recover the copy or rewrite its original absolute master footer.
          final before = _identity(path);
          final beforeJournal = _identity(journal.path);
          scratch = Directory.systemTemp.createTempSync('of-schema-');
          candidate = '${scratch.path}/qualification.db';
          original.copySync(candidate);
          protectPrivateFile(candidate);
          journal.copySync('$candidate-journal');
          protectPrivateFile('$candidate-journal');
          if (before != _identity(path) ||
              beforeJournal != _identity(journal.path)) {
            _refuse('rollback source changed while copying; retry offline');
          }
        }
        _supported(_readonlyVersion(candidate));
      } on SqliteException catch (error) {
        // SQLITE_READONLY_ROLLBACK: inspect recognized original page-1 states,
        // then let SQLite perform its real recovery on the original files.
        if (error.extendedResultCode != 776) {
          _refuse(
            'SQLite read-only qualification failed (${error.extendedResultCode}); recover with compatible SQLite first',
          );
        }
        _journalVersions();
      } finally {
        scratch?.deleteSync(recursive: true);
      }
    }
    verifyUnchanged();
  }
}
