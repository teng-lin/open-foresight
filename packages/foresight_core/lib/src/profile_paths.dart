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

/// The 24-hex identity of the profile whose canonical data path is [data].
String _profileIdentity(String data) =>
    sha256.convert(utf8.encode(data)).toString().substring(0, 24);

class ProfilePaths {
  final String data, runtime;
  const ProfilePaths(this.data, this.runtime);

  /// Which profile this is: 24 hex digits of the SHA-256 of its canonical
  /// data path. An owner reports it in status, so a client never attaches to,
  /// stops or replaces another profile's owner (SL-7). Aliases of one data
  /// directory share an identity.
  String get identity => _profileIdentity(canonicalProfilePath(data));

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
    final profile = _profileIdentity(data).substring(0, 12);
    // Each profile has its own default runtime, so two profiles share
    // sockets only when FORESIGHT_RUNTIME says so (D5). An owner started with
    // the earlier shared Linux default stays reachable through its endpoint
    // record.
    final xdgRuntime = environment['XDG_RUNTIME_DIR'];
    final runtime = canonicalProfilePath(
      environment['FORESIGHT_RUNTIME'] ??
          (mac
              ? '$temporary/of-$profile'
              : xdgRuntime != null
              ? '$xdgRuntime/open-foresight/$profile'
              : '$data/runtime/$profile'),
    );
    if (mac && utf8.encode('$runtime/application.sock').length >= 104) {
      throw StateError(
        'FORESIGHT_RUNTIME is too long for macOS Unix sockets; choose a short private directory (under 80 bytes).',
      );
    }
    return ProfilePaths(data, runtime);
  }
}
