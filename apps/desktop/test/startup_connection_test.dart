import 'desktop_fixture_owner.dart';
import '../test_support/core_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/commands.dart';

import 'package:open_foresight/main.dart';
import 'package:open_foresight/desktop_environment.dart';

import 'controller_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

void main() {
  late Directory root;
  late ProfilePaths profile;
  setUp(() {
    root = createTestTempDirectorySync('startup-owner-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
  });
  ControllerConnection connection() {
    Directory(profile.data).createSync(recursive: true);
    final store = Store('${profile.data}/app.db');
    store.setPreference('onboarding.complete', 'true');
    return ControllerConnection(
      Application(
        Domain(
          store,
          OfflineHelper('${root.path}/helper.sock', '${root.path}/helper'),
        ),
      ),
    );
  }

  testWidgets(
    'successful startup transfers connection and command ownership to workspace',
    (tester) async => withDesktopFixtures(tester, () async {
      final connected = connection();
      var attempts = 0;
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => tester.pumpWidget(
          DesktopStartup(
            environment: DesktopEnvironment(
              run: DesktopEnvironment.production().run,
            ),
            profile: profile,
            deviceLoader: () async => [],
            configureRuntime: (_) {},
            quit: () => fail('Must launch the workspace'),
            connect: (_) async {
              attempts++;
              return connected;
            },
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => find.byType(Workspace).evaluate().isNotEmpty,
      );
      expect(attempts, 1);
      expect(connected.closes, 0);
      final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(shell.integrationFeature.commands, isNotNull);
      await tester.runAsync(
        () => AppCommands.forward(
          '${profile.runtime}/commands.sock',
          command: 'activate',
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await pumpUntil(tester, () => connected.closes == 1);
      expect(find.byType(Workspace), findsNothing);
    }),
  );
  testWidgets(
    'late connection is released if startup unmounts before connecting',
    (tester) async => withDesktopFixtures(tester, () async {
      final connected = connection();
      final ready = Completer<ControllerConnection>();
      var connecting = false;
      await tester.runAsync(
        () => tester.pumpWidget(
          DesktopStartup(
            environment: DesktopEnvironment(
              run: DesktopEnvironment.production().run,
            ),
            profile: profile,
            configureRuntime: (_) {},
            connect: (_) {
              connecting = true;
              return ready.future;
            },
          ),
        ),
      );
      await pumpUntil(tester, () => connecting);
      await tester.pumpWidget(const SizedBox());
      ready.complete(connected);
      await pumpUntil(tester, () => connected.closes == 1);
      final rebound = await tester.runAsync(
        () => AppCommands.bind(
          '${profile.runtime}/commands.sock',
          environment: DesktopEnvironment.production(),
        ),
      );
      await tester.runAsync(() => rebound!.close());
      expect(tester.takeException(), isNull);
    }),
  );
  testWidgets(
    'stop-only launch without an owner exits without connecting or retaining commands',
    (tester) async => withDesktopFixtures(tester, () async {
      var exits = 0;
      await tester.runAsync(
        () => tester.pumpWidget(
          DesktopStartup(
            environment: DesktopEnvironment(
              run: DesktopEnvironment.production().run,
            ),
            profile: profile,
            arguments: const ['--stop-meeting'],
            configureRuntime: (_) {},
            connect: (_) async => throw StateError('Must not connect'),
            quit: () => exits++,
          ),
        ),
      );
      await pumpUntil(tester, () => exits == 1);
      expect(File('${profile.runtime}/commands.sock').existsSync(), false);
      await tester.pumpWidget(const SizedBox());
    }),
  );
}
