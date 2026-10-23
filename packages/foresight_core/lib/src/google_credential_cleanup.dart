import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'platform_services.dart';
import 'secret_store.dart';

/// Durable cleanup work contains only profile-scoped key names and provider
/// flags. It never restores an account or writes credential bytes to disk.
final class GoogleCredentialCleanup {
  GoogleCredentialCleanup(this.directory, this.secrets, this.prefix);

  final Directory directory;
  final SecretStore secrets;
  final String prefix;
  Map<String, bool>? _pending;
  File get _file => File('${directory.path}/credential-cleanup.json');

  Map<String, bool> get _keys {
    if (_pending case final loaded?) return loaded;
    final keys = <String, bool>{};
    if (_file.existsSync()) {
      privateDirectory(directory.path);
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          (_file.statSync().mode & 0x3f) != 0) {
        throw StateError('Credential cleanup journal must be a private file');
      }
      final value =
          jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      if (value['version'] != 1) {
        throw StateError('Unsupported credential cleanup journal');
      }
      for (final entry in (value['keys'] as Map).entries) {
        final key = entry.key as String;
        if (key != prefix && !RegExp('^$prefix-[a-f0-9]{64}\$').hasMatch(key)) {
          throw StateError('Credential cleanup key belongs to another profile');
        }
        keys[key] = entry.value as bool;
      }
    }
    return _pending = keys;
  }

  void add(Map<String, bool> keys) {
    for (final entry in keys.entries) {
      _keys[entry.key] = (_keys[entry.key] ?? false) || entry.value;
    }
    _save();
  }

  void _save() {
    if (_keys.isEmpty) {
      if (_file.existsSync()) _file.deleteSync();
      return;
    }
    privateDirectory(directory.path);
    final staging = File(
      '${_file.path}.${Random.secure().nextInt(1 << 32)}.next',
    );
    staging.createSync(exclusive: true);
    try {
      protectPrivateFile(staging.path);
      staging.writeAsStringSync(
        jsonEncode({'version': 1, 'keys': _keys}),
        flush: true,
      );
      staging.renameSync(_file.path);
    } finally {
      if (staging.existsSync()) staging.deleteSync();
    }
  }

  Future<void> retry({
    required Future<void> Function(String? token) revoke,
    required Set<String> activeKeys,
  }) async {
    var failed = false;
    for (final key in _keys.keys.toList()) {
      // A failed registry write or a newly authorized account must never have
      // its live credential deleted by old cleanup work.
      if (activeKeys.contains(key)) continue;
      String? token;
      if (_keys[key]!) {
        try {
          token = await secrets.read(key);
        } catch (_) {
          // Local erasure still proceeds if the store cannot read its value.
        }
      }
      try {
        await secrets.delete(key);
        final pending = _keys.remove(key)!;
        try {
          _save();
        } catch (_) {
          // A failed journal commit must remain retryable in this process too.
          _keys[key] = pending;
          rethrow;
        }
      } catch (_) {
        failed = true;
      }
      // A failed deletion must not prevent this account's revocation or the
      // cleanup of any other account. Offline revocation remains best effort.
      await revoke(token);
    }
    if (failed) {
      throw StateError('Google credential cleanup failed; will retry');
    }
  }
}
