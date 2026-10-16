import 'dart:io';

/// Retain the visible desktop's existing profile and socket ownership. Never
/// select the separate legacy virtual-display profile implicitly.
class ProfilePaths {
  final String data, runtime;
  const ProfilePaths(this.data, this.runtime);
  factory ProfilePaths.resolve(Map<String, String> environment) {
    final home = environment['HOME']!;
    final base = environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    final legacy = '$base/foresight-linux-desktop';
    final modern = '$base/foresight';
    final data =
        environment['FORESIGHT_DATA'] ??
        (File('$modern/application.db').existsSync() ||
                !File('$legacy/application.db').existsSync()
            ? modern
            : legacy);
    final name = data == legacy
        ? 'foresight-linux-desktop'
        : data == '$base/foresight-linux'
        ? 'foresight-linux'
        : 'foresight';
    final runtime =
        environment['FORESIGHT_RUNTIME'] ??
        '${environment['XDG_RUNTIME_DIR'] ?? '$data/runtime'}/$name';
    return ProfilePaths(data, runtime);
  }
}
