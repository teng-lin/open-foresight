import 'platform_capabilities.dart';
import 'package:flutter/services.dart';

/// Owns menu-bar commands independently of the optional global shortcut.
class DesktopMenu {
  static const channel = MethodChannel('foresight/menu');
  static const commands = {
    'activate',
    'quick-meeting',
    'meetings',
    'ask',
    'sources',
    'settings',
  };
  final bool macOS;
  bool _closed = false;

  DesktopMenu(
    Future<void> Function(String) activated, {
    bool? macOS,
    PlatformCapabilities capabilities = const PlatformCapabilities.linux(),
  }) : macOS = macOS ?? capabilities.usesNativeMenu {
    if (this.macOS) {
      channel.setMethodCallHandler((call) async {
        if (!_closed && commands.contains(call.method)) {
          await activated(call.method);
        }
      });
    }
  }

  void close() {
    _closed = true;
    if (macOS) channel.setMethodCallHandler(null);
  }
}
