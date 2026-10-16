import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/commands.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/profile_paths.dart';

void main() {
  testWidgets(
    'real startup connection failures render guidance and release command ownership before retry',
    (tester) async {
      final root = Directory('/tmp').createTempSync('of-start-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
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
        // Startup uses real Unix sockets and chmod subprocesses.
        for (var i = 0; i < 100 && attempts < 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
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
        for (var i = 0; i < 100 && attempts < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
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
      root.deleteSync(recursive: true);
    },
  );
}
