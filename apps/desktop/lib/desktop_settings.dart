import 'dart:io';

/// Freedesktop autostart entry; invoked only when the user changes the switch.
class DesktopSettings {
  final Directory config;
  final String launcher;
  DesktopSettings(this.config, this.launcher);
  File get entry => File('${config.path}/autostart/open-foresight.desktop');
  File get legacyEntry =>
      File('${config.path}/autostart/foresight-linux.desktop');
  File get previousEntry => File('${config.path}/autostart/foresight.desktop');
  bool get openAtLogin =>
      entry.existsSync() ||
      legacyEntry.existsSync() ||
      previousEntry.existsSync();
  Future<void> ensureApplicationEntry() async {
    if (!File(launcher).existsSync())
      throw StateError('Enable global shortcuts from the packaged Linux app.');
    final home = Platform.environment['HOME']!;
    final data = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    final application = File('$data/applications/io.openforesight.App.desktop');
    await application.parent.create(recursive: true);
    await application.writeAsString(
      '[Desktop Entry]\nType=Application\nName=Open Foresight\nExec="${_escapedLauncher()}"\nTerminal=false\nStartupWMClass=io.openforesight.App\nCategories=Office;\n',
    );
  }

  String _escapedLauncher() => launcher
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('`', '\\`')
      .replaceAll(r'$', r'\$')
      .replaceAll('%', '%%');
  Future<void> setOpenAtLogin(bool value) async {
    if (!value) {
      if (entry.existsSync()) await entry.delete();
      if (legacyEntry.existsSync()) await legacyEntry.delete();
      if (previousEntry.existsSync()) await previousEntry.delete();
      return;
    }
    if (!File(launcher).existsSync()) {
      throw StateError('Enable open at login from the packaged Linux app.');
    }
    final escaped = _escapedLauncher();
    await entry.parent.create(recursive: true);
    await entry.writeAsString(
      '[Desktop Entry]\nType=Application\nName=Open Foresight\nExec="$escaped"\nTerminal=false\n',
    );
    if (legacyEntry.existsSync()) await legacyEntry.delete();
    if (previousEntry.existsSync()) await previousEntry.delete();
  }
}
