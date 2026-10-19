import 'dart:convert';
import 'dart:io';

/// Managed Omarchy user-config block; never replaces an unrelated binding.
class HyprShortcuts {
  final Directory config;
  final String launcher;
  final Future<ProcessResult> Function(String, List<String>) run;
  static const begin = '-- BEGIN FORESIGHT GLOBAL SHORTCUT';
  static const end = '-- END FORESIGHT GLOBAL SHORTCUT';
  HyprShortcuts(this.config, this.launcher, {this.run = Process.run});
  File get bindings => File('${config.path}/hypr/bindings.lua');
  bool get installed =>
      bindings.existsSync() && bindings.readAsStringSync().contains(begin);
  static String normalize(String shortcut) {
    final parts = shortcut
        .toUpperCase()
        .split('+')
        .map((s) => s.trim())
        .toList();
    const modifiers = {'CTRL', 'SHIFT', 'ALT', 'SUPER'};
    if (parts.length < 3 ||
        parts.toSet().length != parts.length ||
        !parts.take(parts.length - 1).every(modifiers.contains) ||
        !RegExp(r'^[A-Z0-9]$').hasMatch(parts.last))
      throw StateError('Use at least two modifiers and one letter or digit.');
    return parts.join(' + ');
  }

  Future<void> install(String shortcut) async {
    final normalized = normalize(shortcut);
    if (!File(launcher).existsSync())
      throw StateError('Install shortcuts from the packaged app.');
    if (!bindings.existsSync())
      throw StateError('Omarchy user bindings.lua is unavailable.');
    final live = await run('/usr/bin/hyprctl', ['binds', '-j']);
    if (live.exitCode != 0)
      throw StateError('Cannot inspect existing desktop shortcuts.');
    final parts = normalized.split(' + ');
    final mask = parts
        .take(parts.length - 1)
        .fold<int>(
          0,
          (mask, key) =>
              mask | {'SHIFT': 1, 'CTRL': 4, 'ALT': 8, 'SUPER': 64}[key]!,
        );
    for (final bind in jsonDecode(live.stdout as String) as List) {
      if (bind['modmask'] == mask &&
          (bind['key'] as String).toUpperCase() == parts.last &&
          bind['description'] != 'Foresight quick meeting')
        throw StateError(
          'That shortcut is already used by ${bind['description'] ?? bind['dispatcher']}. Choose another combination.',
        );
    }
    final quoted = "'${launcher.replaceAll("'", "'\\''")}' --quick-meeting";
    final command = jsonEncode(quoted);
    final block =
        '$begin\no.bind(${jsonEncode(normalized)}, "Foresight quick meeting", $command)\n$end';
    if (bindings.readAsStringSync().contains(block)) return;
    await _replace(block);
  }

  Future<void> remove() => _replace('');
  Future<void> _replace(String block) async {
    final original = bindings.readAsStringSync();
    final managed = RegExp(
      '${RegExp.escape(begin)}[\\s\\S]*?${RegExp.escape(end)}\\n?',
    );
    final cleaned = original.replaceAll(managed, '').trimRight();
    final updated = '$cleaned\n${block.isEmpty ? '' : '\n$block\n'}';
    final backup = File(
      '${bindings.path}.foresight-backup-${DateTime.now().microsecondsSinceEpoch}',
    );
    await backup.writeAsString(original);
    await bindings.writeAsString(updated);
    final reload = await run('/usr/bin/hyprctl', ['reload']);
    final errors = await run('/usr/bin/hyprctl', ['configerrors']);
    if (reload.exitCode != 0 ||
        errors.exitCode != 0 ||
        errors.stdout.toString().trim().isNotEmpty) {
      await bindings.writeAsString(original);
      await run('/usr/bin/hyprctl', ['reload']);
      throw StateError(
        'Desktop rejected the shortcut configuration; previous bindings restored.',
      );
    }
  }
}
