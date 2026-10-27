import 'dart:io';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import '../sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'real frontend owns and retires its diagnostic producer with the application VM',
    () async {
      final root = createTestTempDirectorySync('diag-domain-owner-');
      final saved = Map.of(runtimeConfiguration.environment);
      runtimeConfiguration.environment.removeWhere(
        (key, _) =>
            key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
      );
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: profile.data,
      );
      IsolatedApplicationService? host;
      ServiceClient? client;
      addTearDown(() async {
        await client?.close();
        await host?.close();
        await session.close();
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      });
      host = await IsolatedApplicationService.start(
        profile,
        diagnostics: session,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      client = await ServiceClient.connect(serviceEndpoint(profile));
      final state = await client
          .call('status', {})
          .timeout(const Duration(seconds: 3));
      expect(state, isA<Map>());
      expect(session.retainedSlotCount, 2); // Entrypoint plus real Domain VM.
      await client.close();
      client = null;
      await host.close();
      final clock = Stopwatch()..start();
      while (session.retainedSlotCount != 1 &&
          clock.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(session.retainedSlotCount, 1);
      expect(
        File('${profile.data}/.application-endpoint.json').existsSync(),
        isFalse,
      );
      final closed = await session.close();
      expect(closed.writerExited, isTrue);
      expect(closed.ownerSettled, isTrue);
    },
  );
}
