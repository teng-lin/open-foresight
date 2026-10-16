/// Explicit overrides support isolated sessions. Legacy profiles are migrated
/// offline with tools/migrate_profile.py, never adopted while they may be live.
class ProfilePaths {
  final String data, runtime;
  const ProfilePaths(this.data, this.runtime);
  factory ProfilePaths.resolve(Map<String, String> environment) {
    final home = environment['HOME']!;
    final base = environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    final data = environment['FORESIGHT_DATA'] ?? '$base/open-foresight';
    final runtime =
        environment['FORESIGHT_RUNTIME'] ??
        '${environment['XDG_RUNTIME_DIR'] ?? '$data/runtime'}/open-foresight';
    return ProfilePaths(data, runtime);
  }
}
