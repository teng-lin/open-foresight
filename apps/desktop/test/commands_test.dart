import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/commands.dart';

void main() {
  test(
    'activation forwards to the existing owner and socket can reopen after close',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'foresight-commands-',
      );
      final path = '${directory.path}/commands.sock';
      final received = <String>[];
      var owner = await AppCommands.bind(path, (command, token) async {
        received.add('$command:$token');
      });
      expect(
        await AppCommands.forward(path, activationToken: 'test-token'),
        true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, ['quick-meeting:test-token']);
      expect(await AppCommands.forward(path, quick: false), true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received.last, 'activate:null');
      expect(await AppCommands.forward(path, command: 'stop-meeting'), true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received.last, 'stop-meeting:null');
      await owner.close();
      expect(await AppCommands.forward(path), false);
      owner = await AppCommands.bind(path, (_, _) async {});
      expect(await AppCommands.forward(path), true);
      await owner.close();
      directory.deleteSync(recursive: true);
    },
  );
}
