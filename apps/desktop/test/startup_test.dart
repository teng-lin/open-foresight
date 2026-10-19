import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'pump_until.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/commands.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/profile_paths.dart';

void main() {
  testWidgets(
    'real startup connection failures render guidance and release command ownership before retry',
    (tester) async {
      final root = createTestTempDirectorySync('of-start-');
      addTearDown(() => root.deleteSync(recursive: true));
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      Directory(profile.data).createSync();
      Process.runSync('/bin/chmod', ['755', profile.data]);
      final retained = File('${profile.data}/retained-model')
        ..writeAsStringSync('keep existing data');
      var attempts = 0;
      var quit = false;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          DesktopStartup(
            profile: profile,
            // Native inference configuration is outside this connection test.
            configureRuntime: (_) {},
            connect: (_) async {
              attempts++;
              expect(Directory(profile.data).statSync().mode & 0x1ff, 0x1c0);
              expect(retained.readAsStringSync(), 'keep existing data');
              // This runs after the actual AppCommands.bind used by production.
              expect(
                FileSystemEntity.typeSync('${profile.runtime}/commands.sock'),
                isNot(FileSystemEntityType.notFound),
              );
              throw StateError(
                'This profile is owned by a different installation (attempt $attempts). Stop its service explicitly.',
              );
            },
            quit: () => quit = true,
          ),
        );
      });
      // Rendering this failure follows actual socket and lock cleanup. A removed
      // socket alone is observable before AppCommands.close has completed.
      await pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  (widget.data ?? '').contains('attempt 1'),
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Open Foresight could not start'), findsOneWidget);
      expect(
        attempts,
        1,
        reason: tester.widget<SelectableText>(find.byType(SelectableText)).data,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? '').contains('attempt 1'),
        ),
        findsOneWidget,
      );
      expect(File('${profile.runtime}/commands.sock').existsSync(), false);
      // A separate launcher can immediately acquire the real OS lock/socket.
      await tester.runAsync(() async {
        final replacement = await AppCommands.bind(
          '${profile.runtime}/commands.sock',
        );
        await replacement.close();
      });
      await tester.runAsync(() async {
        await tester.tap(find.text('Retry'));
      });
      await pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  (widget.data ?? '').contains('attempt 2'),
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(attempts, 2);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? '').contains('attempt 2'),
        ),
        findsOneWidget,
      );
      expect(File('${profile.runtime}/commands.sock').existsSync(), false);
      await tester.tap(find.text('Quit'));
      expect(quit, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
