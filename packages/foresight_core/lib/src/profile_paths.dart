import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Canonicalize existing ancestors as well as profiles not yet created.
String canonicalProfilePath(String path) {
  var directory = Directory.fromUri(
    Directory(path).absolute.uri.normalizePath(),
  );
  final suffix = <String>[];
  while (!directory.existsSync()) {
    suffix.insert(
      0,
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
    );
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return [
    directory.resolveSymbolicLinksSync(),
    ...suffix,
  ].join('/').replaceAll(RegExp('/+'), '/');
}

String? _macHomeDirectory() {
  final user = Process.runSync('/usr/bin/id', ['-un']);
  if (user.exitCode != 0) return null;
  final result = Process.runSync('/usr/bin/dscl', [
    '.',
    '-read',
    '/Users/${user.stdout.toString().trim()}',
    'NFSHomeDirectory',
  ]);
  if (result.exitCode != 0) return null;
  final value = result.stdout.toString().trim();
  const prefix = 'NFSHomeDirectory: ';
  return value.startsWith(prefix) ? value.substring(prefix.length) : null;
}

class ProfilePaths {
  final String data, runtime;
  const ProfilePaths(this.data, this.runtime);
  factory ProfilePaths.resolve(Map<String, String> environment, {bool? macOS}) {
    final mac = macOS ?? Platform.isMacOS;
    final home =
        environment['HOME'] ?? (Platform.isMacOS ? _macHomeDirectory() : null);
    if (home == null || home.isEmpty) {
      throw StateError('HOME must identify the user profile');
    }
    final base = environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    final data = canonicalProfilePath(
      environment['FORESIGHT_DATA'] ??
          (mac
              ? '$home/Library/Application Support/Open Foresight'
              : '$base/open-foresight'),
    );
    final temporary = mac
        ? (environment['TMPDIR'] ??
              (Platform.isMacOS ? Directory.systemTemp.path : '/tmp'))
        : '';
    if (mac && Platform.isMacOS && environment['FORESIGHT_RUNTIME'] == null) {
      final parent = Directory(temporary);
      final owner = Process.runSync('/usr/bin/stat', ['-f', '%u', parent.path]);
      final user = Process.runSync('/usr/bin/id', ['-u']);
      if (!parent.existsSync() ||
          owner.exitCode != 0 ||
          user.exitCode != 0 ||
          owner.stdout.toString().trim() != user.stdout.toString().trim() ||
          (parent.statSync().mode & 0x3f) != 0) {
        throw StateError('macOS TMPDIR must be a private user-owned directory');
      }
    }
    final identity = sha256
        .convert(utf8.encode(data))
        .toString()
        .substring(0, 24);
    final runtime = canonicalProfilePath(
      environment['FORESIGHT_RUNTIME'] ??
          (mac
              ? '$temporary/of-${identity.substring(0, 12)}'
              : '${environment['XDG_RUNTIME_DIR'] ?? '$data/runtime'}/open-foresight'),
    );
    if (mac && utf8.encode('$runtime/application.sock').length >= 104) {
      throw StateError(
        'FORESIGHT_RUNTIME is too long for macOS Unix sockets; choose a short private directory (under 80 bytes).',
      );
    }
    return ProfilePaths(data, runtime);
  }
}
