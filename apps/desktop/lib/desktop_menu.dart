import 'dart:io';
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

  DesktopMenu(Future<void> Function(String) activated, {bool? macOS})
    : macOS = macOS ?? Platform.isMacOS {
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
