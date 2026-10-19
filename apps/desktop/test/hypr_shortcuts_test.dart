import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/hypr_shortcuts.dart';

void main() {
  late Directory root;
  late File launcher;
  late HyprShortcuts shortcuts;
  late List<List<String>> calls;
  List<Map<String, Object?>> bindings = [];
  String errors = '';
  int inspectExit = 0, reloadExit = 0, errorsExit = 0;
  setUp(() {
    root = createTestTempDirectorySync('hypr-shortcut-fixture-');
    launcher = File("${root.path}/app 'quoted'/open foresight")
      ..createSync(recursive: true);
    calls = [];
    bindings = [];
    errors = '';
    inspectExit = reloadExit = errorsExit = 0;
    shortcuts = HyprShortcuts(
      root,
      launcher.path,
      run: (executable, args) async {
        expect(executable, '/usr/bin/hyprctl');
        calls.add(List.of(args));
        final action = args.first;
        return ProcessResult(
          1,
          action == 'binds'
              ? inspectExit
              : action == 'reload'
              ? reloadExit
              : errorsExit,
          action == 'binds'
              ? jsonEncode(bindings)
              : action == 'configerrors'
              ? errors
              : '',
          '',
        );
      },
    );
    shortcuts.bindings.createSync(recursive: true);
    shortcuts.bindings.writeAsStringSync(
      '-- user binding\no.bind("SUPER + X", "Other", "other")\n',
    );
  });
  test(
    'install is idempotent, quotes the launcher, backs up and removes only the owned block',
    () async {
      final original = shortcuts.bindings.readAsStringSync();
      expect(shortcuts.installed, false);
      await shortcuts.install('ctrl + shift + f');
      final installed = shortcuts.bindings.readAsStringSync();
      expect(installed, startsWith(original.trimRight()));
      expect(installed, contains('"CTRL + SHIFT + F"'));
      expect(installed, contains('--quick-meeting'));
      expect(
        installed,
        contains(
          jsonEncode(
            "'${launcher.path.replaceAll("'", "'\\''")}' --quick-meeting",
          ),
        ),
      );
      expect(shortcuts.installed, true);
      final backups = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('.foresight-backup-'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), original);
      await shortcuts.install('CTRL + SHIFT + F');
      expect(calls.where((c) => c.first == 'reload'), hasLength(1));
      await shortcuts.remove();
      expect(shortcuts.installed, false);
      expect(shortcuts.bindings.readAsStringSync().trim(), original.trim());
    },
  );
  test(
    'missing application, missing config and inspection failures do not mutate bindings',
    () async {
      final original = shortcuts.bindings.readAsStringSync();
      launcher.deleteSync();
      await expectLater(
        shortcuts.install('CTRL + SHIFT + F'),
        throwsStateError,
      );
      expect(calls, isEmpty);
      launcher.createSync();
      shortcuts.bindings.deleteSync();
      await expectLater(
        shortcuts.install('CTRL + SHIFT + F'),
        throwsStateError,
      );
      shortcuts.bindings.writeAsStringSync(original);
      inspectExit = 1;
      await expectLater(
        shortcuts.install('CTRL + SHIFT + F'),
        throwsStateError,
      );
      expect(shortcuts.bindings.readAsStringSync(), original);
    },
  );
  test(
    'conflicts are rejected while the previously owned binding can be replaced',
    () async {
      final original = shortcuts.bindings.readAsStringSync();
      bindings = [
        {'modmask': 5, 'key': 'f', 'description': 'Other action'},
      ];
      await expectLater(
        shortcuts.install('CTRL + SHIFT + F'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Other action'),
          ),
        ),
      );
      expect(shortcuts.bindings.readAsStringSync(), original);
      bindings = [
        {'modmask': 5, 'key': 'F', 'description': 'Foresight quick meeting'},
      ];
      await shortcuts.install('CTRL + SHIFT + F');
      expect(shortcuts.installed, true);
      await shortcuts.install('SUPER + ALT + 1');
      expect(
        shortcuts.bindings.readAsStringSync().split(HyprShortcuts.begin),
        hasLength(2),
      );
    },
  );
  for (final failure in ['reload', 'configerrors', 'diagnostic']) {
    test(
      '$failure restores exact previous bytes and reloads the restored config',
      () async {
        final original = shortcuts.bindings.readAsStringSync();
        if (failure == 'reload') reloadExit = 1;
        if (failure == 'configerrors') errorsExit = 1;
        if (failure == 'diagnostic') errors = 'invalid binding';
        await expectLater(
          shortcuts.install('CTRL + SHIFT + F'),
          throwsStateError,
        );
        expect(shortcuts.bindings.readAsStringSync(), original);
        expect(calls, [
          ['binds', '-j'],
          ['reload'],
          ['configerrors'],
          ['reload'],
        ]);
      },
    );
  }
}
