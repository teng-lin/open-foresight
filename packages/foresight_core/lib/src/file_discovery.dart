import 'dart:io';

class DiscoveredLocalFile {
  final String path;
  final int bytes;
  final DateTime modified;
  const DiscoveredLocalFile(this.path, this.bytes, this.modified);
  String get name => path.split(Platform.pathSeparator).last;
}

class LocalFileScan {
  final List<DiscoveredLocalFile> files;
  final List<String> unavailableFolders;
  final int examined, alreadyImported;
  final bool truncated;
  const LocalFileScan(
    this.files,
    this.unavailableFolders,
    this.examined,
    this.alreadyImported,
    this.truncated,
  );
}

class LocalFileDiscovery {
  bool cancelled = false;
  void cancel() => cancelled = true;
  static List<String> defaultFolders(String home) => [
    for (final name in ['Documents', 'Downloads', 'Desktop'])
      if (Directory('$home/$name').existsSync()) '$home/$name',
  ];

  Future<LocalFileScan> scan(
    List<String> roots, {
    Set<String> excludedPaths = const {},
    int maxFiles = 2000,
    int maxEntries = 50000,
    void Function(int examined, int found)? progress,
  }) async {
    if (maxFiles < 1 || maxEntries < 1) {
      throw ArgumentError('Positive scan limits required');
    }
    final files = <String, DiscoveredLocalFile>{};
    final unavailable = <String>{};
    final visited = <String>{};
    final excluded = <String>{};
    for (final path in excludedPaths) {
      if (cancelled) break;
      try {
        excluded.add(await File(path).resolveSymbolicLinks());
      } on FileSystemException {
        excluded.add(File(path).absolute.path);
      }
    }
    var examined = 0, imported = 0, truncated = false;
    final pending = roots
        .map((p) => Directory(p).absolute.path)
        .toList()
        .reversed
        .toList();
    while (pending.isNotEmpty && !cancelled && !truncated) {
      var path = pending.removeLast();
      try {
        path = await Directory(path).resolveSymbolicLinks();
        if (!visited.add(path)) continue;
        await for (final entry in Directory(path).list(followLinks: false)) {
          if (cancelled) break;
          if (examined >= maxEntries || files.length >= maxFiles) {
            truncated = true;
            break;
          }
          examined++;
          final name = entry.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;
          if (entry is Directory) {
            if (!['node_modules', 'build', 'target'].contains(name)) {
              pending.add(entry.absolute.path);
            }
          } else if (entry is File &&
              RegExp(
                r'\.(txt|md|pdf|rtf)$',
                caseSensitive: false,
              ).hasMatch(name)) {
            final absolute = entry.absolute.path;
            if (excluded.contains(absolute)) {
              imported++;
              continue;
            }
            try {
              final stat = await entry.stat();
              if (stat.type == FileSystemEntityType.file) {
                files[absolute] = DiscoveredLocalFile(
                  absolute,
                  stat.size,
                  stat.modified,
                );
              }
            } on FileSystemException {
              unavailable.add(path);
            }
          }
          if (examined % 100 == 0) progress?.call(examined, files.length);
        }
      } on FileSystemException {
        unavailable.add(path);
      }
    }
    final ordered = files.values.toList()
      ..sort((a, b) {
        final age = b.modified.compareTo(a.modified);
        return age != 0 ? age : a.path.compareTo(b.path);
      });
    progress?.call(examined, ordered.length);
    return LocalFileScan(
      ordered,
      unavailable.toList(),
      examined,
      imported,
      truncated,
    );
  }
}
