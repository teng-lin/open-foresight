import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../store.dart';
import 'audio_storage_binding.dart';
import 'audio_store.dart';
import 'backup_files.dart';
import 'recording_media.dart';
import 'snapshot_vfs.dart';
import 'sqlite_runtime.dart';

/// Explicit user-owned DB + current usable audio backup. Migration snapshots,
/// installed models/binaries and external export destinations are not included.
final class AudioProfileBackup {
  const AudioProfileBackup(this.path, this.manifest);
  final String path;
  final Map<String, Object?> manifest;
  int get representationCount => manifest['representations'] as int;
  int get mediaBytes => manifest['media_bytes'] as int;
  int get missingAudioChunks => manifest['missing_audio_chunks'] as int;
}

final class AudioProfileRestoreResult {
  const AudioProfileRestoreResult({
    required this.profilePath,
    required this.source,
  });
  final String profilePath;
  final AudioProfileBackup source;
}

/// A private external copy is preserved rather than recursively erasing an
/// uncertain staging tree. The CLI must report its concrete location.
final class AudioBackupIncomplete implements Exception {
  const AudioBackupIncomplete(this.stagingDirectory, this.cause);
  final String stagingDirectory;
  final Object cause;
  @override
  String toString() =>
      'Audio backup/restore did not publish. Its private partial copy remains at $stagingDirectory. $cause';
}

/// Initial backup creation requires a physical service quiescence barrier held
/// through publication. Restore publishes only into an authorized ABSENT profile;
/// it never replaces an active database or changes #180 activation semantics.
final class AudioProfileBackups {
  AudioProfileBackups({this.forbiddenRoots = const []});
  final List<String> forbiddenRoots;

  Future<AudioProfileBackup> create({
    required RecordingMedia media,
    required String authorizedDestination,
    required bool Function() quiesced,
    required bool Function() current,
  }) async {
    final store = media.store,
        audio = media.audio,
        generation = audio.storageGeneration,
        epoch = audio.workspaceEpoch(),
        backupId = AudioStore.newIdentity();
    void check() {
      if (!current() ||
          !quiesced() ||
          !audio.mediaAdmitted ||
          audio.storageGeneration != generation ||
          audio.workspaceEpoch() != epoch ||
          !media.binding.matches(generation)) {
        throw StateError(
          'Hold recording and worker quiescence through audio backup',
        );
      }
      media.ownerLockDescriptor;
      if (store.preference('internal.backupErasurePending') == '1' ||
          store.db
              .select(
                "SELECT 1 FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_sessions s ON s.id=c.session_id WHERE s.retain_lossless=1 AND r.state='superseded_pending_purge' LIMIT 1",
              )
              .isNotEmpty ||
          audio.pendingErasures(limit: 1).isNotEmpty ||
          store.db
              .select(
                "SELECT 1 FROM recording_sessions WHERE capture_state NOT IN ('stopped','interrupted') LIMIT 1",
              )
              .isNotEmpty ||
          store.db
              .select(
                "SELECT 1 FROM audio_asr_jobs WHERE state='running' UNION ALL SELECT 1 FROM audio_transform_jobs WHERE state='running' LIMIT 1",
              )
              .isNotEmpty ||
          store.db.select(
            'SELECT 1 FROM audio_media_references WHERE purpose!=? LIMIT 1',
            ['backup:$backupId'],
          ).isNotEmpty) {
        throw StateError(
          'Finish capture, readers, workers and pending privacy erasure before audio backup',
        );
      }
    }

    check();
    final destination = _Destination(authorizedDestination, [
      p.dirname(store.path),
      ...forbiddenRoots,
    ]);
    BackupDirectory? stage;
    BackupFile? database, inventory;
    final purpose = 'backup:$backupId';
    try {
      audio.transaction(
        () => store.db.execute(
          "INSERT INTO audio_media_references(id,representation_id,owner_generation,purpose) SELECT ?||':'||r.id,r.id,?,? FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_sessions s ON s.id=c.session_id WHERE r.state='published' AND r.validated=1 AND c.state='published' AND s.storage_generation=? AND s.workspace_epoch=?",
          [backupId, media.ownerGeneration, purpose, generation, epoch],
        ),
      );
      stage = destination.parent.child('.foresight-backup-$backupId');
      database = stage.open('application.db', create: true);
      final journal = stage.open('snapshot.journal', create: true);
      try {
        final vfs = SnapshotVfs(database, writable: true, journal: journal);
        vfs.registered(() => store.db.execute('VACUUM INTO ?', [vfs.uri]));
      } finally {
        journal.close();
      }
      stage.remove('snapshot.journal');
      database.sync();
      final metadata = _databaseMetadata(database);
      if (metadata.generation != generation || metadata.epoch != epoch) {
        throw StateError('Snapshot media authority changed');
      }
      inventory = stage.open('media-manifest.jsonl', create: true);
      var after = '', count = 0, total = 0;
      while (true) {
        check();
        final rows = _databasePage(database, generation, epoch, after);
        if (rows.isEmpty) break;
        // Recheck each frozen snapshot row still has its pin in the live DB.
        for (final row in rows) {
          if (store.db.select(
            'SELECT 1 FROM audio_media_references WHERE representation_id=? AND purpose=?',
            [row['id'], purpose],
          ).isEmpty) {
            throw StateError('Audio backup reader pin changed');
          }
        }
        await _copyRowsOffThread(p.dirname(store.path), stage.path, rows);
        check();
        for (final row in rows) {
          final encoded = utf8.encode('${jsonEncode(row)}\n');
          if (encoded.length > 2048) {
            throw StateError('Audio backup row exceeds format limit');
          }
          inventory.write(encoded);
          count++;
          total += row['bytes'] as int;
          after = row['id'] as String;
        }
      }
      inventory.sync();
      final manifest = <String, Object?>{
        'format': 1,
        'backup_id': backupId,
        'created_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
        'schema': Store.schemaVersion,
        'database_sha256': database.digest(),
        'generation': generation,
        'workspace_epoch': epoch,
        'inventory_sha256': inventory.digest(),
        'representations': count,
        'media_bytes': total,
        'missing_audio_chunks': metadata.missing,
        'scope': 'database_and_current_usable_audio',
        'external_exports': 'excluded',
      };
      final marker = stage.open('backup.json', create: true);
      try {
        marker.write(utf8.encode(jsonEncode(manifest)));
        marker.sync();
      } finally {
        marker.close();
      }
      stage.sync();
      check();
      destination.verify();
      final published = destination.parent.publishChild(
        stage,
        destination.name,
      );
      published.close();
      return AudioProfileBackup(destination.path, Map.unmodifiable(manifest));
    } catch (error, stack) {
      if (stage != null) {
        Error.throwWithStackTrace(
          AudioBackupIncomplete(stage.path, error),
          stack,
        );
      }
      rethrow;
    } finally {
      inventory?.close();
      database?.close();
      stage?.close();
      destination.close();
      // A failed copy leaves a private directory that is not advertised as the
      // selected backup. Pins end after every real copying isolate returned.
      store.db.execute(
        'DELETE FROM audio_media_references WHERE purpose=? AND owner_generation=?',
        [purpose, media.ownerGeneration],
      );
    }
  }

  Future<AudioProfileBackup> inspect(
    String directory, {
    required bool Function() current,
  }) async {
    final backup = BackupDirectory(directory, create: false);
    BackupFile? database, inventory;
    try {
      final header = backup.open('backup.json', readOnly: true);
      late final Map<String, Object?> manifest;
      try {
        manifest = Map<String, Object?>.from(
          jsonDecode(utf8.decode(header.readSmall(4096))) as Map,
        );
      } finally {
        header.close();
      }
      _validateHeader(manifest);
      database = backup.open('application.db', readOnly: true);
      inventory = backup.open('media-manifest.jsonl', readOnly: true);
      final path = backup.path,
          dbIdentity = database.identity,
          manifestIdentity = inventory.identity;
      await _verifyRootOffThread(path, dbIdentity, manifestIdentity, manifest);
      if (!current()) throw StateError('Audio backup inspection cancelled');
      backup.verifyAnchor();
      final metadata = _databaseMetadata(database);
      if (metadata.generation != manifest['generation'] ||
          metadata.epoch != manifest['workspace_epoch'] ||
          metadata.missing != manifest['missing_audio_chunks']) {
        throw const FormatException('Backup DB and root manifest disagree');
      }
      final reader = _InventoryReader(inventory);
      var after = '', count = 0, total = 0;
      while (true) {
        if (!current()) throw StateError('Audio backup inspection cancelled');
        final rows = _databasePage(
          database,
          metadata.generation,
          metadata.epoch,
          after,
        );
        if (rows.isEmpty) break;
        for (final expected in rows) {
          final row = reader.next();
          if (row == null || jsonEncode(row) != jsonEncode(expected)) {
            throw const FormatException(
              'Backup inventory does not match its database',
            );
          }
          count++;
          total += row['bytes'] as int;
          after = row['id'] as String;
        }
        await _verifyRowsOffThread(path, rows);
        if (!current()) throw StateError('Audio backup inspection cancelled');
        backup.verifyAnchor();
      }
      if (reader.next() != null ||
          count != manifest['representations'] ||
          total != manifest['media_bytes']) {
        throw const FormatException('Backup inventory extent mismatch');
      }
      return AudioProfileBackup(path, Map.unmodifiable(manifest));
    } finally {
      inventory?.close();
      database?.close();
      backup.close();
    }
  }

  Future<AudioProfileRestoreResult> restoreToNewProfile({
    required String backupDirectory,
    required String authorizedAbsentProfile,
    required bool Function() current,
  }) async {
    final verified = await inspect(backupDirectory, current: current);
    if (!current()) throw StateError('Audio restore cancelled');
    final destination = _Destination(authorizedAbsentProfile, [
      backupDirectory,
      ...forbiddenRoots,
    ]);
    BackupDirectory? stage, source;
    BackupFile? database, original;
    try {
      stage = destination.parent.child(
        '.foresight-audio-restore-${AudioStore.newIdentity()}',
      );
      source = BackupDirectory(verified.path, create: false);
      original = source.open('application.db', readOnly: true);
      database = stage.open('application.db', create: true);
      original.copyTo(database);
      database.sync();
      if (database.digest() != verified.manifest['database_sha256']) {
        throw const FormatException('Restored database bytes changed');
      }
      final metadata = _databaseMetadata(database);
      var after = '';
      while (true) {
        if (!current()) throw StateError('Audio restore cancelled');
        final rows = _databasePage(
          database,
          metadata.generation,
          metadata.epoch,
          after,
        );
        if (rows.isEmpty) break;
        await _copyRowsOffThread(source.path, stage.path, rows);
        if (!current()) throw StateError('Audio restore cancelled');
        stage.verifyAnchor();
        source.verifyAnchor();
        after = rows.last['id'] as String;
      }
      // Restored jobs cannot reuse an original profile's external destination.
      // Validate exact payload first; then make this explicit new copy safe.
      _blockRestoredExports(database, stage);
      database.sync();
      final binding = AudioStorageBinding(stage.path);
      try {
        binding.bind(
          generation: metadata.generation,
          expectedDatabaseIdentity: database.identity,
        );
      } finally {
        binding.close();
      }
      stage.sync();
      if (!current()) throw StateError('Audio restore cancelled');
      destination.verify();
      final published = destination.parent.publishChild(
        stage,
        destination.name,
      );
      published.close();
      return AudioProfileRestoreResult(
        profilePath: destination.path,
        source: verified,
      );
    } catch (error, stack) {
      if (stage != null) {
        Error.throwWithStackTrace(
          AudioBackupIncomplete(stage.path, error),
          stack,
        );
      }
      rethrow;
    } finally {
      database?.close();
      original?.close();
      source?.close();
      stage?.close();
      destination.close();
    }
  }
}

final class _Destination {
  _Destination(String selected, List<String> forbidden)
    : path = p.normalize(selected) {
    if (!p.isAbsolute(selected) ||
        selected != path ||
        selected.contains('\u0000') ||
        selected.length > 4096 ||
        p.basename(path) == '.' ||
        p.basename(path) == '..') {
      throw ArgumentError('Choose an absolute new directory');
    }
    for (final root in forbidden) {
      final normalized = p.normalize(p.absolute(root));
      if (path == normalized ||
          p.isWithin(normalized, path) ||
          p.isWithin(path, normalized)) {
        throw StateError('Choose a separate backup or new profile directory');
      }
    }
    parent = BackupDirectory(p.dirname(path), create: false, private: false);
    name = p.basename(path);
    try {
      verify();
    } catch (_) {
      parent.close();
      rethrow;
    }
  }
  final String path;
  late final String name;
  late final BackupDirectory parent;
  void verify() {
    parent.verifyAnchor();
    if (parent.entryExists(name)) {
      throw StateError('Backup/restore destination already exists');
    }
  }

  void close() => parent.close();
}

T _readDatabase<T>(BackupFile file, T Function(Database) use) {
  final vfs = SnapshotVfs(file, writable: false);
  return vfs.registered(() {
    final db = sqlite3.open(
      '/snapshot',
      vfs: vfs.name,
      mode: OpenMode.readOnly,
    );
    try {
      db.execute('PRAGMA trusted_schema=OFF');
      db.execute('PRAGMA query_only=ON');
      return use(db);
    } finally {
      db.dispose();
    }
  });
}

({String generation, String epoch, int missing}) _databaseMetadata(
  BackupFile file,
) => _readDatabase(file, (db) {
  if (db.select('PRAGMA user_version').single.values.single !=
          Store.schemaVersion ||
      db.select('PRAGMA integrity_check').single.values.single != 'ok') {
    throw const FormatException('Unsupported or damaged audio backup database');
  }
  return (
    generation:
        db
                .select(
                  'SELECT generation FROM audio_storage_generation WHERE singleton=1',
                )
                .single['generation']
            as String,
    epoch:
        db.select('SELECT value FROM preferences WHERE key=?', [
              Store.workspaceEpochKey,
            ]).single['value']
            as String,
    missing:
        db
                .select(
                  "SELECT COUNT(*) AS n FROM audio_chunks c WHERE c.state!='published' OR NOT EXISTS(SELECT 1 FROM audio_representations r WHERE r.chunk_id=c.id AND r.state='published' AND r.validated=1)",
                )
                .single['n']
            as int,
  );
});
List<Map<String, Object?>> _databasePage(
  BackupFile file,
  String generation,
  String epoch,
  String after,
) => _readDatabase(
  file,
  (db) => db
      .select(
        "SELECT r.id,r.chunk_id,c.session_id,r.relative_path,r.codec,r.container,r.sha256,r.byte_length,r.decoded_samples,r.pre_skip FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_sessions s ON s.id=c.session_id WHERE r.id>? AND r.state='published' AND r.validated=1 AND c.state='published' AND s.storage_generation=? AND s.workspace_epoch=? ORDER BY r.id LIMIT 64",
        [after, generation, epoch],
      )
      .map(
        (row) => _validateRow({
          'id': row['id'],
          'chunk': row['chunk_id'],
          'session': row['session_id'],
          'path': row['relative_path'],
          'codec': row['codec'],
          'container': row['container'],
          'sha256': row['sha256'],
          'bytes': row['byte_length'],
          'frames': row['decoded_samples'],
          'pre_skip': row['pre_skip'],
        }, generation),
      )
      .toList(),
);
Map<String, Object?> _validateRow(Map<String, Object?> row, String generation) {
  final uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  final session = row['session'],
      chunk = row['chunk'],
      name = (row['path'] as String).split('/').last;
  if (row.length != 10 ||
      session is! String ||
      chunk is! String ||
      !uuid.hasMatch(session) ||
      !uuid.hasMatch(chunk) ||
      row['path'] != 'recordings/$generation/$session/$name' ||
      row['bytes'] is! int ||
      (row['bytes'] as int) < 1 ||
      row['frames'] is! int ||
      (row['frames'] as int) < 1 ||
      (row['frames'] as int) > 240000 ||
      row['pre_skip'] is! int ||
      (row['pre_skip'] as int) < 0 ||
      (row['pre_skip'] as int) > 65535 ||
      row['sha256'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['sha256'] as String)) {
    throw const FormatException('Invalid backup audio inventory');
  }
  if (row['codec'] == 'pcm_s16le' && row['container'] == 'wav') {
    if (name != '$chunk.wav' ||
        row['id'] != '$chunk.raw' ||
        row['bytes'] != 196 + (row['frames'] as int) * 2 ||
        row['pre_skip'] != 0) {
      throw const FormatException('Invalid lossless backup representation');
    }
  } else if (row['codec'] == 'opus' && row['container'] == 'ogg') {
    if (!name.endsWith('.opus') ||
        !uuid.hasMatch(name.substring(0, name.length - 5)) ||
        row['id'] != name) {
      throw const FormatException('Invalid retained backup representation');
    }
  } else {
    throw const FormatException('Unsupported backup representation');
  }
  return row;
}

void _validateHeader(Map<String, Object?> m) {
  if (m.length != 13 ||
      m['format'] != 1 ||
      m['schema'] != Store.schemaVersion ||
      m['scope'] != 'database_and_current_usable_audio' ||
      m['external_exports'] != 'excluded' ||
      ![
        m['database_sha256'],
        m['inventory_sha256'],
      ].every((v) => v is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(v)) ||
      ![
        m['created_ms'],
        m['representations'],
        m['media_bytes'],
        m['missing_audio_chunks'],
      ].every((v) => v is int && v >= 0) ||
      ![m['backup_id'], m['generation']].every(
        (v) =>
            v is String &&
            RegExp(
              r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
            ).hasMatch(v),
      ) ||
      m['workspace_epoch'] is! String ||
      (m['workspace_epoch'] as String).length > 128) {
    throw const FormatException('Invalid complete audio backup manifest');
  }
}

Future<void> _copyRowsOffThread(
  String source,
  String target,
  List<Map<String, Object?>> rows,
) => Isolate.run(() => _copyRows(source, target, rows));
Future<void> _verifyRowsOffThread(
  String root,
  List<Map<String, Object?>> rows,
) => Isolate.run(() => _verifyRows(root, rows));
Future<void> _verifyRootOffThread(
  String root,
  String databaseIdentity,
  String inventoryIdentity,
  Map<String, Object?> manifest,
) => Isolate.run(
  () => _verifyRoot(root, databaseIdentity, inventoryIdentity, manifest),
);
BackupDirectory _mediaDirectory(
  BackupDirectory root,
  Map<String, Object?> row, {
  required bool create,
}) {
  final parts = (row['path'] as String).split('/');
  final recordings = root.child(parts[0], create: create);
  BackupDirectory? generation, session;
  try {
    generation = recordings.child(parts[1], create: create);
    session = generation.child(parts[2], create: create);
    if (create) {
      generation.sync();
      recordings.sync();
      root.sync();
    }
    final opened = session;
    session = null;
    return opened;
  } finally {
    session?.close();
    generation?.close();
    recordings.close();
  }
}

void _copyRows(
  String sourcePath,
  String targetPath,
  List<Map<String, Object?>> rows,
) {
  final source = BackupDirectory(sourcePath, create: false, private: false),
      target = BackupDirectory(targetPath, create: false);
  try {
    for (final row in rows) {
      final from = _mediaDirectory(source, row, create: false),
          to = _mediaDirectory(target, row, create: true);
      BackupFile? input, output;
      try {
        final name = (row['path'] as String).split('/').last;
        input = from.open(name, readOnly: true);
        output = to.open(name, create: true);
        if (input.size != row['bytes'] || input.digest() != row['sha256']) {
          throw const FormatException('Backup source audio checksum mismatch');
        }
        input.copyTo(output);
        output.sync();
        if (output.size != row['bytes'] ||
            output.digest() != row['sha256'] ||
            from.metadata(name).identity != input.identity) {
          throw const FormatException('Copied audio checksum mismatch');
        }
        from.verifyAnchor();
        to.sync();
        to.verifyAnchor();
      } finally {
        output?.close();
        input?.close();
        to.close();
        from.close();
      }
    }
    target.sync();
    source.verifyAnchor();
    target.verifyAnchor();
  } finally {
    target.close();
    source.close();
  }
}

void _verifyRows(String path, List<Map<String, Object?>> rows) {
  final root = BackupDirectory(path, create: false);
  try {
    for (final row in rows) {
      final directory = _mediaDirectory(root, row, create: false);
      BackupFile? file;
      try {
        file = directory.open(
          (row['path'] as String).split('/').last,
          readOnly: true,
        );
        if (file.size != row['bytes'] ||
            file.digest() != row['sha256'] ||
            directory
                    .metadata((row['path'] as String).split('/').last)
                    .identity !=
                file.identity) {
          throw const FormatException('Backup audio payload checksum mismatch');
        }
        directory.verifyAnchor();
      } finally {
        file?.close();
        directory.close();
      }
    }
    root.verifyAnchor();
  } finally {
    root.close();
  }
}

void _verifyRoot(
  String path,
  String dbIdentity,
  String inventoryIdentity,
  Map<String, Object?> manifest,
) {
  final root = BackupDirectory(path, create: false);
  BackupFile? db, inventory;
  try {
    db = root.open('application.db', readOnly: true);
    inventory = root.open('media-manifest.jsonl', readOnly: true);
    if (db.identity != dbIdentity ||
        inventory.identity != inventoryIdentity ||
        db.digest() != manifest['database_sha256'] ||
        inventory.digest() != manifest['inventory_sha256'] ||
        root.metadata('application.db').identity != dbIdentity ||
        root.metadata('media-manifest.jsonl').identity != inventoryIdentity) {
      throw const FormatException('Backup root payload checksum mismatch');
    }
    root.verifyAnchor();
  } finally {
    inventory?.close();
    db?.close();
    root.close();
  }
}

final class _InventoryReader {
  _InventoryReader(this.file);
  final BackupFile file;
  var offset = 0;
  var remaining = '';
  bool ended = false;
  Map<String, Object?>? next() {
    while (true) {
      final newline = remaining.indexOf('\n');
      if (newline >= 0) {
        final line = remaining.substring(0, newline);
        remaining = remaining.substring(newline + 1);
        if (line.isEmpty || line.length > 2048) {
          throw const FormatException('Invalid backup inventory row length');
        }
        return Map<String, Object?>.from(jsonDecode(line) as Map);
      }
      if (ended) {
        if (remaining.isNotEmpty) {
          throw const FormatException('Incomplete backup inventory row');
        }
        return null;
      }
      if (remaining.length > 2048) {
        throw const FormatException('Oversized backup inventory row');
      }
      final bytes = Uint8List(65536), read = file.readAt(bytes, offset);
      offset += read;
      if (read == 0) {
        ended = true;
      } else {
        remaining += ascii.decode(bytes.sublist(0, read));
      }
    }
  }
}

void _blockRestoredExports(BackupFile file, BackupDirectory directory) {
  final journal = directory.open('restore-safety.journal', create: true);
  // Use a real protected rollback journal for this intentional new-copy change.
  final writable = SnapshotVfs(file, writable: true, journal: journal);
  try {
    writable.registered(() {
      final db = sqlite3.open('/snapshot', vfs: writable.name);
      try {
        db.execute('PRAGMA journal_mode=DELETE');
        db.execute(
          "UPDATE audio_transform_jobs SET state='blocked',error='backup_restore_requires_new_destination',owner_generation=NULL,lease_generation=lease_generation+1 WHERE kind='export' AND state NOT IN ('completed','abandoned')",
        );
      } finally {
        db.dispose();
      }
    });
  } finally {
    journal.close();
  }
  directory.remove('restore-safety.journal');
  directory.sync();
}
