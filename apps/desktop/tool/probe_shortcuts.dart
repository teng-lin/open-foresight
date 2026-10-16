import 'dart:convert';
import 'dart:io';
import 'package:foresight_linux/global_shortcuts.dart';

Future<void> main() async {
  final shortcuts = GlobalShortcuts((id, token) {
    stdout.writeln('Activated: $id');
  });
  try {
    await shortcuts.enable();
    stdout.writeln(
      jsonEncode({
        'state': shortcuts.state,
        'trigger': shortcuts.trigger,
        'session': shortcuts.session?.value,
      }),
    );
    await Future<void>.delayed(const Duration(seconds: 15));
  } finally {
    await shortcuts.close();
  }
}
