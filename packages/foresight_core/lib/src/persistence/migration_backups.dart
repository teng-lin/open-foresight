import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'backup_files.dart';
import 'sqlite_runtime.dart';

/// A candidate exists only after its bounded manifest was atomically published.
/// Its hash, schema, source identity and SQLite integrity are rechecked at use.
final class MigrationSnapshot {
  const MigrationSnapshot({
    required this.name,
    required this.schema,
    required this.created,
    required this.sha256,
    required this.sourceIdentity,
  });
  final String name;
  final int schema;
  final DateTime created;
  final String sha256;
  final String sourceIdentity;
}

/// Private snapshots are application content, not diagnostics. The service
/// holds its profile ownership before calling Store, and SQLite's exclusive
/// connection lock covers snapshot plus migration. This class never repairs
/// permissions on an untrusted entry or deletes content to make backup space.
final class MigrationBackups {
  MigrationBackups(this.databasePath, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final String databasePath;
  final DateTime Function() _now;
  static const maximumSnapshots = 2;
  static const maximumAge = Duration(days: 7);
  static final _namePattern = RegExp(
    r'^snapshot-[0-9]{1,16}-[a-f0-9]{32}\.db$',
  );
  static final _restorePattern = RegExp(r'^restore-[a-f0-9]{32}\.db$');
  String get directoryPath => '$databasePath.backups';

  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  BackupDirectory _directory({bool create = false}) =>
      BackupDirectory(directoryPath, create: create);

  bool get exists =>
      FileSystemEntity.typeSync(directoryPath, followLinks: false) !=
      FileSystemEntityType.notFound;

  MigrationSnapshot create(Database source, int schema) {
    if (!source.autocommit) {
      throw StateError('A migration backup requires an autocommit boundary.');
    }
    final parent = BackupDirectory(
      p.dirname(p.absolute(databasePath)),
      create: false,
      private: false,
    );
    late final BackupDirectory directory;
    try {
      directory = _directory(create: true);
    } catch (_) {
      parent.close();
      rethrow;
    }
    final name = 'snapshot-${_now().millisecondsSinceEpoch}-${_nonce()}.db';
    final temporary = '$name.partial';
    BackupFile? output;
    var published = false;
    try {
      // Opening the already-existing source without following links also rejects
      // device/hardlinked/public files before any backup operation begins.
      final original = parent.open(p.basename(databasePath), private: false);
      final sourceIdentity = original.identity;
      original.close();
      output = directory.open(temporary, create: true);
      source.execute('VACUUM INTO ?', [output.descriptorPath]);
      output.sync();
      _verifyDatabase(output, schema);
      final snapshot = MigrationSnapshot(
        name: name,
        schema: schema,
        created: _now().toUtc(),
        sha256: output.digest(),
        sourceIdentity: sourceIdentity,
      );
      output.close();
      output = null;
      directory.publish(temporary, name);
      published = true;
      final manifest = directory.open('$name.json.partial', create: true);
      try {
        manifest.write(
          utf8.encode(
            jsonEncode({
              'format': 1,
              'schema': schema,
              'created': snapshot.created.millisecondsSinceEpoch,
              'sha256': snapshot.sha256,
              'source': sourceIdentity,
            }),
          ),
        );
        manifest.sync();
      } finally {
        manifest.close();
      }
      directory.publish('$name.json.partial', '$name.json');
      directory.verifyAnchor();
      // Do not evict an existing good backup until its replacement is complete.
      _prune(directory, preserve: name);
      return snapshot;
    } catch (_) {
      output?.close();
      // An unpublished/partial file can never be offered as a restore candidate.
      // Keep it if cleanup fails; the next successful admission removes it.
      try {
        directory.remove(published ? name : temporary);
      } catch (_) {}
      rethrow;
    } finally {
      directory.close();
      parent.close();
    }
  }

  List<MigrationSnapshot> snapshots({required int supportedVersion}) {
    if (!exists) return [];
    final directory = _directory();
    try {
      return _snapshots(directory, supportedVersion: supportedVersion);
    } finally {
      directory.close();
    }
  }

  List<MigrationSnapshot> _snapshots(
    BackupDirectory directory, {
    required int supportedVersion,
  }) {
    final entries = directory.entries();
    _validateEntries(entries);
    final parent = BackupDirectory(
      p.dirname(p.absolute(databasePath)),
      create: false,
      private: false,
    );
    late final String sourceIdentity;
    try {
      final source = parent.open(p.basename(databasePath), private: false);
      try {
        sourceIdentity = source.identity;
      } finally {
        source.close();
      }
    } finally {
      parent.close();
    }
    final result = <MigrationSnapshot>[];
    for (final name in entries.where(_namePattern.hasMatch)) {
      if (!entries.contains('$name.json')) continue;
      final manifest = directory.open('$name.json');
      late final MigrationSnapshot snapshot;
      try {
        final value = jsonDecode(utf8.decode(manifest.readSmall(4096)));
        if (value is! Map ||
            value['format'] != 1 ||
            value['schema'] is! int ||
            value['created'] is! int ||
            value['source'] is! String ||
            value['source'] != sourceIdentity ||
            value['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'] as String)) {
          throw StateError('Invalid migration backup manifest.');
        }
        snapshot = MigrationSnapshot(
          name: name,
          schema: value['schema'] as int,
          created: DateTime.fromMillisecondsSinceEpoch(
            value['created'] as int,
            isUtc: true,
          ),
          sha256: value['sha256'] as String,
          sourceIdentity: value['source'] as String,
        );
      } finally {
        manifest.close();
      }
      if (snapshot.schema < 0 || snapshot.schema > supportedVersion) continue;
      if (_now().toUtc().difference(snapshot.created) > maximumAge) continue;
      final file = directory.open(name);
      try {
        if (file.digest() != snapshot.sha256) {
          throw StateError('Migration backup checksum verification failed.');
        }
        _verifyDatabase(file, snapshot.schema);
      } finally {
        file.close();
      }
      result.add(snapshot);
    }
    result.sort((a, b) => b.created.compareTo(a.created));
    return result;
  }

  static void _verifyDatabase(BackupFile file, int schema) {
    final db = openApplicationDatabase(
      file.descriptorPath,
      mode: OpenMode.readOnly,
    );
    try {
      if (db.select('PRAGMA user_version').single.values.single != schema ||
          db.select('PRAGMA integrity_check').single.values.single != 'ok') {
        throw StateError(
          'Migration backup integrity or schema verification failed.',
        );
      }
    } finally {
      db.dispose();
    }
  }

  static void _validateEntries(List<String> entries) {
    for (final entry in entries) {
      var name = entry;
      if (name.endsWith('.partial')) name = name.substring(0, name.length - 8);
      if (name.endsWith('.json')) name = name.substring(0, name.length - 5);
      if (!_namePattern.hasMatch(name) && !_restorePattern.hasMatch(name)) {
        throw StateError(
          'Unexpected entry in migration backup storage; cleanup remains pending.',
        );
      }
    }
  }

  void _prune(BackupDirectory directory, {String? preserve}) {
    final entries = directory.entries();
    _validateEntries(entries);
    final available = _snapshots(directory, supportedVersion: 0x7fffffff);
    final ordered = [
      ...available.where((snapshot) => snapshot.name == preserve),
      ...available.where((snapshot) => snapshot.name != preserve),
    ];
    final keep = ordered.take(maximumSnapshots).map((s) => s.name).toSet();
    for (final entry in entries) {
      // Restored copies are user-chosen rollback data, but remain covered by
      // privacy erasure. Do not discard a prepared restore during admission.
      if (_restorePattern.hasMatch(entry)) continue;
      if (!keep.contains(entry) && !keep.any((name) => entry == '$name.json')) {
        directory.remove(entry);
      }
    }
    directory.sync();
  }

  /// Builds a separate verified copy. It never swaps an application's live
  /// database. The offline activation owner must stop all service/read owners,
  /// check binary/helper compatibility, and retain the newer profile separately.
  /// The confirmation concerns the snapshot's explicit data-loss point.
  String restoreCopy(
    String name, {
    required int supportedVersion,
    required bool confirmDataLoss,
  }) {
    if (!confirmDataLoss) {
      throw StateError('Confirm the backup data-loss point before restoring.');
    }
    if (!_namePattern.hasMatch(name)) {
      throw ArgumentError('Invalid migration snapshot name.');
    }
    final directory = _directory();
    try {
      final snapshot = _snapshots(
        directory,
        supportedVersion: supportedVersion,
      ).where((s) => s.name == name).firstOrNull;
      if (snapshot == null) {
        throw StateError(
          'No verified schema-compatible migration snapshot is available.',
        );
      }
      final restored = 'restore-${_nonce()}.db';
      final temporary = '$restored.partial';
      final source = directory.open(name);
      BackupFile? destination;
      try {
        destination = directory.open(temporary, create: true);
        source.copyTo(destination);
        if (destination.digest() != snapshot.sha256) {
          throw StateError('Restored backup checksum verification failed.');
        }
        _verifyDatabase(destination, snapshot.schema);
      } catch (_) {
        if (destination != null) {
          destination.close();
          try {
            directory.remove(temporary);
          } catch (_) {}
        }
        rethrow;
      } finally {
        source.close();
        destination?.close();
      }
      directory.publish(temporary, restored);
      return p.join(directory.path, restored);
    } finally {
      directory.close();
    }
  }

  /// Opportunistic age/count cleanup while the application is running.
  void prune() {
    if (!exists) return;
    final directory = _directory();
    try {
      _prune(directory);
    } finally {
      directory.close();
    }
  }

  /// A clear or any content deletion invalidates every snapshot, because each
  /// SQLite snapshot may contain the deleted data. Failure leaves the caller's
  /// durable privacy marker in place; untrusted entries are never followed.
  void erase() {
    if (!exists) return;
    final directory = _directory();
    try {
      final entries = directory.entries();
      _validateEntries(entries);
      for (final entry in entries) {
        directory.remove(entry);
      }
      if (directory.entries().isNotEmpty) {
        throw StateError('Migration backup cleanup remains pending.');
      }
      directory.sync();
      directory.verifyAnchor();
    } finally {
      directory.close();
    }
  }
}
