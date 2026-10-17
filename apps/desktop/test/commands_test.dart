import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/commands.dart';

void main() {
  test(
    'shortcut failures reach the owning UI error handler after queued acknowledgement',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'foresight-command-error-',
      );
      final failed = Completer<Object>();
      final commands = await AppCommands.bind(
        '${directory.path}/commands.sock',
        (_, _) async {
          throw StateError('Microphone unavailable');
        },
      );
      commands.onError = failed.complete;
      try {
        expect(await AppCommands.forward(commands.path), true);
        expect(
          (await failed.future.timeout(const Duration(seconds: 2))).toString(),
          contains('Microphone unavailable'),
        );
      } finally {
        await commands.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

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
