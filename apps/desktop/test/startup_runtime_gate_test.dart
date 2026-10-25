import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/main.dart';

void main() {
  testWidgets(
    'early runtime failure stays visible and retries before profile authority',
    (tester) async {
      final root = createTestTempDirectorySync('startup-runtime-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      var preparations = 0, connections = 0, configured = 0, quits = 0;
      await tester.pumpWidget(
        DesktopStartup(
          environment: DesktopEnvironment(
            run: DesktopEnvironment.production().run,
          ),
          profile: profile,
          bootstrapFailure: StateError('runtime_support_unavailable'),
          prepareRuntime: () async {
            preparations++;
            throw StateError('runtime_support_unavailable');
          },
          configureRuntime: (_) => configured++,
          connect: (_) async {
            connections++;
            throw StateError('connection reached');
          },
          quit: () => quits++,
        ),
      );
      expect(find.text('Open Foresight could not start'), findsOneWidget);
      expect(preparations, 0);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(preparations, 1);
      expect(configured, 0);
      expect(connections, 0);
      expect(Directory(profile.data).existsSync(), isFalse);
      expect(Directory(profile.runtime).existsSync(), isFalse);
      expect(find.text('Open Foresight could not start'), findsOneWidget);
      await tester.tap(find.text('Quit'));
      expect(quits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
