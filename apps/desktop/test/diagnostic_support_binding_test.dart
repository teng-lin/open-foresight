import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop_bootstrap.dart'
    show LocalDiagnosticSupport;
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/settings/diagnostic_support_view.dart';
import 'package:open_foresight/main.dart';

import '../test_support/core_fixture.dart';
import 'controller_fixture.dart';
import 'desktop_fixture_owner.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

final class _Sink implements DiagnosticSink {
  @override
  int get slot => 3;
  @override
  bool get failed => false;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) => true;
  @override
  bool append(Uint8List bytes) => true;
  @override
  void close() {}
}

DiagnosticSink? _sink(
  String profile,
  DiagnosticIdentity session,
  DiagnosticRole role,
) => _Sink();

void _chmod(String mode, String path) =>
    expect(Process.runSync('/bin/chmod', [mode, path]).exitCode, 0);

/// Real LoggingSession, real LocalDiagnosticSupport and the real Settings
/// feature, bound through DesktopEnvironment.withDiagnosticSupport exactly as
/// startup binds it. Only the URI opener is injected.
void main() {
  testWidgets(
    'settings shows a real session through the real adapter after binding',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('diagnostic-real-host-');
      final profile = Directory('${root.path}/profile')..createSync();
      _chmod('700', profile.path);
      final logs = Directory('${profile.path}/logs')..createSync();
      _chmod('700', logs.path);
      final revealed = <Uri>[];
      final session = (await tester.runAsync(
        () => LoggingSession.startForTesting(
          configuration: const DiagnosticConfiguration(),
          profilePath: profile.path,
          sinkFactory: _sink,
        ),
      ))!;
      final support =
          LocalDiagnosticSupport(openUri: (uri) async => revealed.add(uri))
            ..attachSession(session)
            ..selectProfile(ProfilePaths(profile.path, '${root.path}/run'));
      final connection = ControllerConnection(
        Application(
          Domain(
            Store('${root.path}/app.db'),
            OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          ),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(session.close);
      });
      await tester.pumpWidget(
        Foresight(
          connection,
          environment: const DesktopEnvironment().withDiagnosticSupport(
            support,
          ),
          deviceLoader: () async => [],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(DiagnosticSupportView),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Starting: no log file has been admitted yet'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        expect(
          session.producer.emit(
            DiagnosticEvent.runtimeFailed,
            DiagnosticComponent.logging,
          ),
          isTrue,
        );
        await eventually(
          () => session.healthSnapshot.state == DiagnosticHealthState.healthy,
        );
      });
      expect(find.textContaining('Starting'), findsOneWidget);
      await tester.tap(find.byKey(const Key('refreshDiagnosticHealth')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Writing to a log file'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('showLogsFolder')));
        await eventually(() => revealed.isNotEmpty);
      });
      await tester.pumpAndSettle();
      expect(revealed, [Uri.file(logs.resolveSymbolicLinksSync())]);
      expect(tester.takeException(), isNull);
    }),
  );
}
