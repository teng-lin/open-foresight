import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/src/diagnostic_bootstrap.dart';
import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/startup.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Future<Map<String, Object?>> ownerScenario(
  DiagnosticHost host,
  String firstProfile,
  String otherProfile,
  bool transient,
) async {
  final prepared = ApplicationRuntimeBootstrap.prepare(host);
  final first = prepared.startDiagnostics(
    profilePath: firstProfile,
    transient: transient,
  );
  final second = prepared.startDiagnostics(profilePath: otherProfile);
  final session = await first;
  try {
    final health = session.healthSnapshot;
    final sameOwner = identical(session, await second);
    final closed = await session.close();
    final afterClose = await prepared.startDiagnostics(
      profilePath: otherProfile,
    );
    return {
      'host': prepared.host.name,
      'available': prepared.diagnostics.available,
      'sameFuture': identical(first, second),
      'sameOwner': sameOwner,
      'sameConfiguration': identical(
        session.configuration,
        prepared.diagnostics.configuration,
      ),
      'storageConfigured': health.storageConfigured,
      'known': health.known,
      'state': health.state.name,
      'level': health.level.name,
      'writerExited': closed.writerExited,
      'ownerSettled': closed.ownerSettled,
      'closedState': session.healthSnapshot.state.name,
      'closedOwnerReused': identical(afterClose, session),
      'activeAfterClose': afterClose.producer.active,
      'endpointsAfterClose': DiagnosticProducer.localEndpointCount,
      'timersAfterClose': DiagnosticProducer.localRegistrationTimerCount,
    };
  } finally {
    await session.close();
  }
}

void main() {
  test(
    'current context has runtime identity without borrowing runtime environment authority',
    () {
      final context = DiagnosticStartupContext.current(DiagnosticHost.mcp);
      expect(context.host, DiagnosticHost.mcp);
      expect(context.executable, Platform.resolvedExecutable);
      expect(context.script, isNotEmpty);
      // Normal core tests intentionally have no producer-selected build defines.
      expect(context.identitiesAvailable, isFalse);
      expect(context.sourceContext, isFalse);
      expect(context.nativeId, isEmpty);
      expect(context.dartId, isEmpty);
      expect(context.catalogId, isEmpty);
    },
  );

  for (final options in [
    (DiagnosticHost.mcp, false),
    (DiagnosticHost.mcp, true),
    (DiagnosticHost.standaloneWorker, false),
  ]) {
    test(
      'unavailable ${options.$1.name} owner remains singleton and closes (transient=${options.$2})',
      () async {
        final root = createTestTempDirectorySync('bootstrap-owner-');
        final first = '${root.path}/first';
        final other = '${root.path}/other';
        final result = await Isolate.run(
          () => ownerScenario(options.$1, first, other, options.$2),
        );
        expect(result['host'], options.$1.name);
        expect(result['available'], isFalse);
        expect(result['sameFuture'], isTrue);
        expect(result['sameOwner'], isTrue);
        expect(result['sameConfiguration'], isTrue);
        expect(result['storageConfigured'], isFalse);
        expect(result['known'], isTrue);
        final expected = DiagnosticConfiguration.fromEnvironment(
          Platform.environment,
        );
        expect(result['level'], expected.level.name);
        expect(result['state'], expected.enabled ? 'degraded' : 'off');
        expect(result['writerExited'], isTrue);
        expect(result['ownerSettled'], isTrue);
        expect(result['closedState'], 'closed');
        expect(result['closedOwnerReused'], isTrue);
        expect(result['activeAfterClose'], isFalse);
        expect(result['endpointsAfterClose'], 0);
        expect(result['timersAfterClose'], 0);
        expect(Directory(first).existsSync(), isFalse);
        expect(Directory(other).existsSync(), isFalse);
      },
    );
  }

  for (final host in [DiagnosticHost.service, DiagnosticHost.desktop]) {
    test(
      'mandatory ${host.name} SQL refusal leaves a later diagnostic-only owner usable',
      () async {
        final result = await Isolate.run(() async {
          String? refusal;
          try {
            ApplicationRuntimeBootstrap.prepare(host);
          } on DiagnosticStartupUnavailable catch (error) {
            refusal = error.toString();
          }
          final resources = [
            DiagnosticProducer.localEndpointCount,
            DiagnosticProducer.localRegistrationTimerCount,
          ];
          final prepared = ApplicationRuntimeBootstrap.prepare(
            DiagnosticHost.mcp,
          );
          final session = await prepared.startDiagnostics(transient: true);
          final closed = await session.close();
          return {
            'refusal': refusal,
            'resources': resources,
            'closed': closed.writerExited && closed.ownerSettled,
          };
        });
        expect(result['refusal'], 'Diagnostic startup is unavailable');
        expect(result['resources'], [0, 0]);
        expect(result['closed'], isTrue);
      },
    );
  }

  test(
    'bad source options degrade diagnostics without exposing or creating private candidates',
    () {
      final root = createTestTempDirectorySync('bootstrap-private-');
      final context = DiagnosticStartupContext(
        host: DiagnosticHost.mcp,
        executable: '${root.path}/source-host',
        script: '${root.path}/private-token.dart',
        nativeId: '0' * 64,
        dartId: '1' * 64,
        catalogId: '2' * 64,
        workerMode: 'kernel',
        sourceContext: true,
        sourceAnchor: root.path,
        dartSdkRoot: '${root.path}/untrusted-sdk',
        dartExecutable: '${root.path}/different/dart',
        packageConfig: '${root.path}/private-token.json',
      );
      final selected = DiagnosticStartup.beforeApplication(
        environment: {'FORESIGHT_LOG_LEVEL': 'trace'},
        context: context,
      );
      expect(selected.configuration.level, DiagnosticLevel.trace);
      expect(selected.available, isFalse);
      expect(selected.selection, isNull);
      expect(selected.functions, isNull);
      expect(root.listSync(), isEmpty);
      final invocation = DiagnosticWorkerInvocation.parse(['--status']);
      expect(
        () => loadDiagnosticChildStartup(invocation),
        throwsA(
          isA<DiagnosticStartupUnavailable>().having(
            (error) => error.toString(),
            'private failure',
            'Diagnostic startup is unavailable',
          ),
        ),
      );
    },
  );
}
