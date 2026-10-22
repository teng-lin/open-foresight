import 'package:open_foresight/desktop_environment.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/commands.dart';

void main() {
  test(
    'calendar return forwards to the owner and foreign schemes are rejected',
    () async {
      final directory = createTestTempDirectorySync('calendar-command-');
      final received = Completer<String>();
      final commands = await AppCommands.bind(
        '${directory.path}/commands.sock',
        environment: DesktopEnvironment.production(),
        action: (command, url) async {
          expect(command, 'calendar-auth');
          received.complete(url!);
        },
      );
      try {
        expect(
          await AppCommands.forward(
            commands.path,
            command: 'calendar-auth',
            authUrl: 'granola://login-complete?code=foreign',
          ),
          false,
        );
        const callback =
            'open-foresight://login-in-progress?foresight_state=fixture&open-url=fixture';
        expect(
          await AppCommands.forward(
            commands.path,
            command: 'calendar-auth',
            authUrl: callback,
          ),
          true,
        );
        expect(
          await received.future.timeout(const Duration(seconds: 2)),
          callback,
        );
      } finally {
        await commands.close();
      }
    },
  );

  test(
    'shortcut failures reach the owning UI error handler after queued acknowledgement',
    () async {
      final directory = createTestTempDirectorySync('foresight-command-error-');
      final failed = Completer<Object>();
      final commands = await AppCommands.bind(
        '${directory.path}/commands.sock',
        environment: DesktopEnvironment.production(),
        action: (_, _) async {
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
      final directory = createTestTempDirectorySync('foresight-commands-');
      final path = '${directory.path}/commands.sock';
      final received = <String>[];
      final observed = StreamController<String>.broadcast();
      addTearDown(observed.close);
      var owner = await AppCommands.bind(
        path,
        environment: DesktopEnvironment.production(),
        action: (command, token) async {
          received.add('$command:$token');
          observed.add(received.last);
        },
      );
      final quickMeeting = observed.stream.first;
      expect(
        await AppCommands.forward(path, activationToken: 'test-token'),
        true,
      );
      expect(
        await quickMeeting.timeout(const Duration(seconds: 2)),
        'quick-meeting:test-token',
      );
      expect(received, ['quick-meeting:test-token']);
      final activation = observed.stream.first;
      expect(await AppCommands.forward(path, quick: false), true);
      await activation.timeout(const Duration(seconds: 2));
      expect(received.last, 'activate:null');
      final stopped = observed.stream.first;
      expect(await AppCommands.forward(path, command: 'stop-meeting'), true);
      await stopped.timeout(const Duration(seconds: 2));
      expect(received.last, 'stop-meeting:null');
      expect(owner.isClosed, false);
      await owner.close();
      expect(owner.isClosed, true);
      expect(await AppCommands.forward(path), false);
      owner = await AppCommands.bind(
        path,
        environment: DesktopEnvironment.production(),
        action: (_, _) async {},
      );
      expect(await AppCommands.forward(path), true);
      await owner.close();
      directory.deleteSync(recursive: true);
    },
  );

  test(
    'forwarding to a desktop that closes its listener during the connect '
    'reports it was not forwarded',
    () async {
      final directory = createTestTempDirectorySync('forward-reset-');
      final path = '${directory.path}/commands.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      try {
        listener.listen((socket) => socket.destroy());
        final forwarding = AppCommands.forward(path);
        // Let the connect reach the backlog before the listener closes.
        for (var hop = 0; hop < 20; hop++) {
          await Future<void>.microtask(() {});
        }
        final closed = listener.close();
        // Hold this isolate while the closed listener resets that connect.
        sleep(const Duration(milliseconds: 50));
        expect(await forwarding, isFalse);
        await closed;
      } finally {
        await listener.close();
        directory.deleteSync(recursive: true);
      }
    },
    // Linux resets a connect waiting in a closed AF_UNIX backlog with
    // ECONNRESET; the order this test forces relies on that.
    testOn: 'linux',
  );
}
