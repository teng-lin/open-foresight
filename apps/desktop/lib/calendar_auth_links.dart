import 'platform_capabilities.dart';
import 'package:flutter/services.dart';

/// Own-scheme delivery from Launch Services. Linux launchers use AppCommands.
class CalendarAuthLinks {
  static const channel = MethodChannel('foresight/calendar-auth');
  final PlatformCapabilities capabilities;
  CalendarAuthLinks({this.capabilities = const PlatformCapabilities.linux()});
  bool _closed = false;
  Future<void> start(Future<void> Function(String) receive) async {
    if (!capabilities.usesNativeCalendarLinks) return;
    channel.setMethodCallHandler((call) async {
      if (!_closed && call.method == 'open-url' && call.arguments is String) {
        await receive(call.arguments as String);
      }
    });
    try {
      final pending = await channel.invokeListMethod<String>('ready') ?? [];
      for (final url in pending) {
        if (!_closed) await receive(url);
      }
    } on MissingPluginException {
      // Widget tests and older development runners have no native receiver.
    }
  }

  void close() {
    _closed = true;
    if (capabilities.usesNativeCalendarLinks)
      channel.setMethodCallHandler(null);
  }
}
