import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'backup_files.dart';

final class AudioStorageIdentity {
  const AudioStorageIdentity(this.databaseIdentity, this.generation);
  final String databaseIdentity, generation;
}

/// Independent media authority outside SQLite and its migration snapshots.
///
/// Offline restore stages a copy while the live database exists, then swaps
/// the names. The live device/inode changes even if a restored generation token
/// equals the previous token. Ordinary WAL writes keep that identity. Service
/// startup must compare this binding before admitting ANY media read/job/adopt.
/// A verified profile move needs explicit rebinding after manifest validation.
///
/// The caller holds exclusive profile ownership. On mismatch it first fences
/// media jobs and rotates the DB generation (preserving missing-audio history),
/// then replaces this binding. An absent binding with existing audio metadata
/// is a mismatch, never permission to adopt files by name.
final class AudioStorageBinding {
  AudioStorageBinding(
    String profileDirectory, {
    this.databaseName = 'application.db',
  }) : _profile = BackupDirectory(
         profileDirectory,
         create: false,
         private: false,
       ) {
    try {
      if (p.basename(databaseName) != databaseName ||
          databaseName == '.' ||
          databaseName == '..') {
        throw ArgumentError.value(databaseName, 'databaseName');
      }
      // Keep control files separate from unbounded meeting/chunk directories.
      _control = _profile.child('recording-control');
    } catch (_) {
      _profile.close();
      rethrow;
    }
  }

  static const _name = 'storage-binding.json';
  final String databaseName;
  final BackupDirectory _profile;
  late final BackupDirectory _control;
  bool _closed = false;

  String get databaseIdentity {
    _checkOpen();
    return _profile.metadata(databaseName, private: false).identity;
  }

  AudioStorageIdentity? read() {
    _checkOpen();
    if (!_control.containsEntry(_name)) return null;
    final file = _control.open(_name);
    try {
      final decoded = jsonDecode(utf8.decode(file.readSmall(4096)));
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 3 ||
          decoded['format'] != 1 ||
          decoded['database_identity'] is! String ||
          decoded['generation'] is! String) {
        throw const FormatException('Invalid audio storage binding');
      }
      final database = decoded['database_identity'] as String;
      final generation = decoded['generation'] as String;
      if (!RegExp(r'^\d+:\d+(?::\d+)?$').hasMatch(database) ||
          !_validGeneration(generation)) {
        throw const FormatException('Invalid audio storage binding identity');
      }
      return AudioStorageIdentity(database, generation);
    } finally {
      file.close();
    }
  }

  bool matches(String generation) {
    final binding = read();
    return binding != null &&
        binding.generation == generation &&
        binding.databaseIdentity == databaseIdentity;
  }

  /// Atomic process-crash-safe publication using descriptor-relative protected
  /// files. This does not independently certify physical power-loss durability.
  /// Expected identity fences a restore/replacement between inspection and use.
  void bind({
    required String generation,
    required String expectedDatabaseIdentity,
    bool replace = false,
  }) {
    _checkOpen();
    if (!_validGeneration(generation)) {
      throw ArgumentError.value(generation, 'generation');
    }
    if (databaseIdentity != expectedDatabaseIdentity) {
      throw StateError('The database changed before audio storage binding');
    }
    final previous = read();
    if (previous != null) {
      if (previous.databaseIdentity == expectedDatabaseIdentity &&
          previous.generation == generation) {
        return;
      }
      if (!replace) throw StateError('Audio storage requires reconciliation');
    }
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final temporary = 'binding-$nonce.partial';
    final file = _control.open(temporary, create: true);
    try {
      file.write(
        utf8.encode(
          jsonEncode({
            'format': 1,
            'database_identity': expectedDatabaseIdentity,
            'generation': generation,
          }),
        ),
      );
      file.sync();
    } finally {
      file.close();
    }
    if (databaseIdentity != expectedDatabaseIdentity) {
      _control.remove(temporary);
      _control.sync();
      throw StateError('The database changed during audio storage binding');
    }
    if (previous == null) {
      _control.publish(temporary, _name);
    } else {
      _control.replace(temporary, _name);
      _control.sync();
    }
  }

  static bool _validGeneration(String value) => RegExp(
    r'^(?:[a-f0-9]{32}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$',
  ).hasMatch(value);

  void _checkOpen() {
    if (_closed) throw StateError('Audio storage binding is closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _control.close();
    _profile.close();
  }
}
