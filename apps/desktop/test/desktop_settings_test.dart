import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/desktop_settings.dart';

void main() {
  test(
    'autostart uses quoted packaged launcher and removes only its own entry',
    () async {
      final tmp = Directory.systemTemp.createTempSync('foresight-autostart-');
      final launcher = File('${tmp.path}/app with spaces/foresight-linux');
      launcher.parent.createSync(recursive: true);
      launcher.writeAsStringSync('fixture');
      final settings = DesktopSettings(
        Directory('${tmp.path}/config'),
        launcher.path,
      );
      await settings.setOpenAtLogin(true);
      expect(
        settings.entry.readAsStringSync(),
        contains('Exec="${launcher.path}"'),
      );
      final other = File('${settings.entry.parent.path}/another.desktop')
        ..writeAsStringSync('preserve');
      await settings.setOpenAtLogin(false);
      expect(settings.openAtLogin, false);
      expect(other.existsSync(), true);
      tmp.deleteSync(recursive: true);
    },
  );
}
