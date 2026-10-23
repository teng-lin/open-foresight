import 'dart:io';
import '../../desktop_environment.dart';
import 'package:flutter/services.dart';

/// Native macOS login items or a managed Freedesktop autostart entry.
class DesktopSettings {
  final Directory config;
  final DesktopEnvironment environment;
  final String launcher;
  final bool macOS;
  static const channel = MethodChannel('foresight/desktop');
  bool _macOpenAtLogin = false;
  DesktopSettings(
    this.config,
    this.launcher, {
    bool? macOS,
    this.environment = const DesktopEnvironment(),
  }) : macOS = macOS ?? environment.capabilities.usesNativeLoginItems;
  Future<void> refresh() async {
    if (macOS)
      _macOpenAtLogin = await channel.invokeMethod<bool>('login.get') ?? false;
  }

  File get entry => File('${config.path}/autostart/open-foresight.desktop');
  File get legacyEntry =>
      File('${config.path}/autostart/foresight-linux.desktop');
  File get previousEntry => File('${config.path}/autostart/foresight.desktop');
  bool get openAtLogin => macOS
      ? _macOpenAtLogin
      : entry.existsSync() ||
            legacyEntry.existsSync() ||
            previousEntry.existsSync();
  Future<void> ensureApplicationEntry() async {
    if (macOS) return;
    if (!File(launcher).existsSync())
      throw StateError('Enable global shortcuts from the packaged Linux app.');
    final data = environment.dataDirectory;
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
    if (macOS) {
      await channel.invokeMethod<void>('login.set', {'enabled': value});
      await refresh();
      return;
    }
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
