import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/main.dart';
import 'controller_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  test('host effects occur only in the environment adapter', () {
    final forbidden = RegExp(
      r'Process\.\w+|Platform\.environment\b|\bopenPlatformUri\b|\bplatformNotification\b',
    );
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))) {
      if (file.path == 'lib/desktop_environment.dart') continue;
      expect(
        forbidden.allMatches(file.readAsStringSync()),
        isEmpty,
        reason: file.path,
      );
    }
  });

  test(
    'main supplies the production environment and production binds real effects',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(source, contains('environment: DesktopEnvironment.production()'));
      expect(source, contains('required this.environment'));
      expect(source, isNot(contains('this.deviceLoader = audioDevices')));
      final environment = DesktopEnvironment.production();
      expect(environment.run, Process.run);
      expect(environment.start, Process.start);
      expect(environment.openUri, openPlatformUri);
      expect(environment.notify, platformNotification);
      expect(environment.variables, Platform.environment);
      expect(
        environment.configDirectory,
        Platform.environment['XDG_CONFIG_HOME'] ??
            '${Platform.environment['HOME']}/.config',
      );
      expect(
        environment.dataDirectory,
        Platform.environment['XDG_DATA_HOME'] ??
            '${Platform.environment['HOME']}/.local/share',
      );
    },
  );

  test('widget environment defaults cannot spawn a process', () async {
    const environment = DesktopEnvironment();
    expect(environment.variables, isEmpty);
    await expectLater(
      environment.run('/usr/bin/hyprctl', []),
      throwsUnsupportedError,
    );
    await expectLater(
      environment.start('/usr/bin/true', []),
      throwsUnsupportedError,
    );
  });

  test('missing HOME preserves the recoverable startup profile error', () {
    final environment = DesktopEnvironment.production(
      variables: const {},
      macOS: false,
      runSync: (_, _) => throw StateError('No host probe on Linux'),
    );
    expect(environment.variables, isEmpty);
    expect(environment.configDirectory, '/dev/null/foresight-config');
    expect(environment.dataDirectory, '/dev/null/foresight-data');
  });

  test(
    'Finder without HOME uses the account directory through the adapter',
    () {
      final calls = <String>[];
      final environment = DesktopEnvironment.production(
        variables: const {},
        macOS: true,
        runSync: (executable, args) {
          calls.add(executable);
          return ProcessResult(
            1,
            0,
            executable == '/usr/bin/id'
                ? 'fixture\n'
                : 'NFSHomeDirectory: /Users/fixture\n',
            '',
          );
        },
      );
      expect(calls, ['/usr/bin/id', '/usr/bin/dscl']);
      expect(environment.configDirectory, '/Users/fixture/.config');
      expect(environment.dataDirectory, '/Users/fixture/.local/share');
    },
  );

  testWidgets('default device discovery uses the injected process runner', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('default-devices-');
    final connection = ControllerConnection(
      Application(
        Domain(
          Store('${root.path}/app.db'),
          OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        ),
      ),
    );
    final calls = <String>[];
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Foresight(
        connection,
        environment: DesktopEnvironment(
          run: (executable, arguments) async {
            calls.add(executable);
            return ProcessResult(1, 0, '[]', '');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!Platform.isMacOS) expect(calls, ['pw-dump']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'injected Hyprland activates and installs only through the fake host',
    (tester) async {
      final root = createTestTempDirectorySync('desktop-env-');
      final config = Directory('${root.path}/config')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final outside = File('${root.path}/unrelated')
        ..writeAsStringSync('Preserve this');
      final bindings = File('${config.path}/hypr/bindings.lua')
        ..createSync(recursive: true);
      bindings.writeAsStringSync('-- Existing user bindings\n');
      final launcher = File('${root.path}/open-foresight')
        ..writeAsStringSync('fixture');
      final calls = <(String, List<String>)>[];
      final environment = DesktopEnvironment(
        variables: {
          'HOME': root.path,
          'HYPRLAND_INSTANCE_SIGNATURE': 'fake-instance',
        },
        configDirectory: config.path,
        dataDirectory: data.path,
        launcher: launcher.path,
        run: (executable, arguments) async {
          calls.add((executable, List.of(arguments)));
          expect(executable, '/usr/bin/hyprctl');
          return ProcessResult(1, 0, switch (arguments.first) {
            'activewindow' => '{"pid":-1}',
            'binds' => '[]',
            _ => '',
          }, '');
        },
      );
      final store = Store('${root.path}/app.db');
      final connection = ControllerConnection(
        Application(
          Domain(
            store,
            OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          ),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        Foresight(
          connection,
          environment: environment,
          deviceLoader: () async => [],
        ),
      );
      await tester.pumpAndSettle();
      final dynamic shell = tester.state(find.byType(Workspace));
      await tester.runAsync(() async {
        await shell.integrationFeature.activateWindow(null);
        await shell.integrationFeature.enableGlobalShortcuts();
      });
      expect(
        bindings.readAsStringSync(),
        contains('FORESIGHT GLOBAL SHORTCUT'),
      );
      await tester.runAsync(
        () async => await shell.integrationFeature.disableGlobalShortcuts(),
      );
      expect(bindings.readAsStringSync(), '-- Existing user bindings\n');
      expect(calls.map((call) => call.$2.first), [
        'activewindow',
        'eval',
        'binds',
        'reload',
        'configerrors',
        'reload',
        'configerrors',
      ]);
      expect(outside.readAsStringSync(), 'Preserve this');
      expect(data.listSync(), isEmpty);
    },
    skip: Platform.isMacOS,
  );
}
