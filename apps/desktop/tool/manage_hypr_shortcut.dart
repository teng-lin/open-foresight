import 'dart:io';
import 'package:foresight/hypr_shortcuts.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) throw ArgumentError('install|remove launcher');
  final shortcut = HyprShortcuts(
    Directory(
      Platform.environment['XDG_CONFIG_HOME'] ??
          '${Platform.environment['HOME']}/.config',
    ),
    arguments[1],
  );
  if (arguments[0] == 'install') {
    await shortcut.install('CTRL + SHIFT + F');
  } else if (arguments[0] == 'remove') {
    await shortcut.remove();
  } else {
    throw ArgumentError('Unknown action');
  }
}
