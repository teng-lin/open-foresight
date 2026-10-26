import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/settings/diagnostic_support_view.dart';
import 'package:open_foresight/main.dart';

import '../test_support/core_fixture.dart';
import 'controller_fixture.dart';
import 'desktop_fixture_owner.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

final class _Port implements DiagnosticSupportPort {
  _Port(this.current);
  DiagnosticSupportSnapshot current;
  int snapshots = 0, opens = 0;
  Completer<DiagnosticFolderOpenResult>? pending;
  Object? failure;

  @override
  DiagnosticSupportSnapshot snapshot() {
    snapshots++;
    return current;
  }

  @override
  Future<DiagnosticFolderOpenResult> openLogsFolder() {
    opens++;
    final error = failure;
    if (error != null) return Future.error(error);
    return (pending = Completer()).future;
  }
}

DiagnosticSupportSnapshot _snapshot(
  DiagnosticSupportStatus status, {
  DiagnosticSupportReason reason = DiagnosticSupportReason.healthy,
  bool folder = true,
  bool storageConfigured = true,
  bool stale = false,
  DiagnosticSupportNativeReason native =
      DiagnosticSupportNativeReason.unconfigured,
  bool nativeDropsExact = true,
  int? slot,
  DiagnosticSupportLevel level = DiagnosticSupportLevel.info,
}) => DiagnosticSupportSnapshot(
  status: status,
  reason: reason,
  level: level,
  storageConfigured: storageConfigured,
  known: true,
  stale: stale,
  ageMs: stale ? 2500 : 0,
  nativeReason: native,
  nativeDropsExact: nativeDropsExact,
  slot: slot,
  logsFolderKnown: folder,
  admitted: 12,
  dropped: 1,
);

final _writing = _snapshot(DiagnosticSupportStatus.healthy, slot: 3);

Future<void> _mount(
  WidgetTester tester,
  DiagnosticSupportPort port, {
  Future<void> Function(String)? copy,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: DiagnosticSupportView(
        support: port,
        copyText: copy,
        version: '0.1.3',
        buildNumber: 4,
      ),
    ),
  ),
);

TextButton _button(WidgetTester tester, String key) =>
    tester.widget<TextButton>(find.byKey(Key(key)));

void main() {
  testWidgets('shows the actual snapshot and labels its host scope', (
    tester,
  ) async {
    final port = _Port(_writing);
    await _mount(tester, port);
    expect(
      find.textContaining('Writing to a log file · level info'),
      findsOneWidget,
    );
    expect(find.textContaining('Updated when this page opens'), findsOneWidget);
    expect(find.textContaining('never uploaded'), findsOneWidget);
    expect(find.textContaining('its health is not shown here'), findsOneWidget);
    expect(find.text('Recorded 12 · dropped 1 · rejected 0'), findsOneWidget);
    expect(port.opens, 0);
  });

  testWidgets('rebuilds read health once and never open the folder', (
    tester,
  ) async {
    final port = _Port(_writing);
    var color = Colors.white;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) {
            rebuild = update;
            return ColoredBox(
              color: color,
              child: Scaffold(body: DiagnosticSupportView(support: port)),
            );
          },
        ),
      ),
    );
    for (var i = 0; i < 20; ++i) {
      rebuild(() => color = i.isEven ? Colors.black : Colors.white);
      await tester.pump();
    }
    expect(port.snapshots, 1);
    expect(port.opens, 0);
    await tester.tap(find.byKey(const Key('refreshDiagnosticHealth')));
    await tester.pump();
    expect(port.snapshots, 2);
    expect(port.opens, 0);
  });

  testWidgets('refresh shows a changed session state', (tester) async {
    final port = _Port(_writing);
    await _mount(tester, port);
    port.current = _snapshot(
      DiagnosticSupportStatus.degraded,
      reason: DiagnosticSupportReason.sinkFailed,
    );
    expect(find.textContaining('Writing to a log file'), findsOneWidget);
    await tester.tap(find.byKey(const Key('refreshDiagnosticHealth')));
    await tester.pump();
    expect(
      find.textContaining(
        'Degraded: writing log files failed; the app continues',
      ),
      findsOneWidget,
    );
  });

  for (final (name, snapshot, label) in [
    (
      'no report',
      DiagnosticSupportSnapshot(
        status: DiagnosticSupportStatus.unknown,
        reason: DiagnosticSupportReason.storageWorkerUnknown,
        level: DiagnosticSupportLevel.info,
        logsFolderKnown: true,
      ),
      'Unknown: no report yet',
    ),
    (
      'a stale report',
      _snapshot(DiagnosticSupportStatus.unknown, stale: true, slot: 3),
      'Unknown: the last report is out of date',
    ),
    (
      'configured storage without a slot',
      _snapshot(DiagnosticSupportStatus.starting),
      'Starting: no log file has been admitted yet',
    ),
    (
      'unconfigured storage',
      _snapshot(DiagnosticSupportStatus.degraded, storageConfigured: false),
      'Degraded: log storage is not configured; the app continues',
    ),
    (
      'no admitted slot',
      _snapshot(
        DiagnosticSupportStatus.degraded,
        reason: DiagnosticSupportReason.storageUnavailable,
      ),
      'Degraded: no log file slot is available; the app continues',
    ),
    (
      'a failed storage worker',
      _snapshot(
        DiagnosticSupportStatus.degraded,
        reason: DiagnosticSupportReason.storageWorkerExited,
      ),
      'Degraded: the log storage worker stopped or did not start; '
          'the app continues',
    ),
    ('closing', _snapshot(DiagnosticSupportStatus.closing), 'Closing'),
    ('closed', _snapshot(DiagnosticSupportStatus.closed), 'Closed'),
    (
      'off',
      _snapshot(
        DiagnosticSupportStatus.off,
        reason: DiagnosticSupportReason.off,
        level: DiagnosticSupportLevel.off,
      ),
      'Off · level off',
    ),
  ]) {
    testWidgets('$name has its own status', (tester) async {
      await _mount(tester, _Port(snapshot));
      expect(find.textContaining(label), findsOneWidget);
      expect(find.textContaining('Writing to a log file'), findsNothing);
    });
  }

  testWidgets('native degradation is shown apart from session status', (
    tester,
  ) async {
    await _mount(
      tester,
      _Port(
        _snapshot(
          DiagnosticSupportStatus.healthy,
          slot: 3,
          native: DiagnosticSupportNativeReason.capacity,
          nativeDropsExact: false,
        ),
      ),
    );
    expect(find.textContaining('Writing to a log file'), findsOneWidget);
    expect(
      find.text('Native diagnostics: at capacity; drop counts are approximate'),
      findsOneWidget,
    );
    await _mount(tester, _Port(_writing));
    expect(find.byKey(const Key('nativeDiagnosticHealth')), findsNothing);
  });

  testWidgets(
    'an explicit click opens once and shows an accessible busy state',
    (tester) async {
      final port = _Port(_writing);
      await _mount(tester, port);
      await tester.tap(find.byKey(const Key('showLogsFolder')));
      await tester.pump();
      expect(port.opens, 1);
      expect(find.text('Showing…'), findsOneWidget);
      expect(_button(tester, 'showLogsFolder').onPressed, isNull);
      expect(_button(tester, 'refreshDiagnosticHealth').onPressed, isNull);
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byKey(const Key('showLogsFolder'))),
        matchesSemantics(
          label: 'Showing…',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          hasFocusAction: true,
        ),
      );
      semantics.dispose();
      await tester.tap(find.byKey(const Key('showLogsFolder')));
      await tester.pump();
      expect(port.opens, 1);
      port.pending!.complete(DiagnosticFolderOpenResult.opened);
      await tester.pump();
      expect(find.text('Show logs folder'), findsOneWidget);
      expect(_button(tester, 'showLogsFolder').onPressed, isNotNull);
      expect(port.snapshots, 2, reason: 'health is re-read after the attempt');
    },
  );

  for (final (result, message) in [
    (DiagnosticFolderOpenResult.missing, 'No log files have been written yet.'),
    (
      DiagnosticFolderOpenResult.unsafe,
      'The logs folder was not shown because it is not a private folder '
          'owned by you.',
    ),
    (
      DiagnosticFolderOpenResult.failed,
      'Could not show the logs folder. Try again.',
    ),
    (
      DiagnosticFolderOpenResult.unavailable,
      'The logs folder is unavailable in this session.',
    ),
  ]) {
    testWidgets('${result.name} shows a closed message', (tester) async {
      final port = _Port(_writing);
      await _mount(tester, port);
      await tester.tap(find.byKey(const Key('showLogsFolder')));
      await tester.pump();
      port.pending!.complete(result);
      await tester.pump();
      expect(find.text(message), findsOneWidget);
      final liveRegion = tester.widget<Semantics>(
        find
            .ancestor(of: find.text(message), matching: find.byType(Semantics))
            .first,
      );
      expect(liveRegion.properties.liveRegion, isTrue);
    });
  }

  testWidgets('a thrown port error never reaches the user', (tester) async {
    final port = _Port(_writing)
      ..failure = StateError('/home/fixture/secret: vendor stderr');
    await _mount(tester, port);
    await tester.tap(find.byKey(const Key('showLogsFolder')));
    await tester.pump();
    expect(
      find.text('Could not show the logs folder. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('/home'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposal during an open discards its late result', (
    tester,
  ) async {
    final port = _Port(_writing);
    await _mount(tester, port);
    await tester.tap(find.byKey(const Key('showLogsFolder')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    port.pending!.complete(DiagnosticFolderOpenResult.failed);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(port.snapshots, 1);
  });

  testWidgets('a replaced port invalidates the pending result', (tester) async {
    final first = _Port(_writing);
    final second = _Port(
      _snapshot(
        DiagnosticSupportStatus.off,
        reason: DiagnosticSupportReason.off,
        level: DiagnosticSupportLevel.off,
      ),
    );
    await _mount(tester, first);
    await tester.tap(find.byKey(const Key('showLogsFolder')));
    await tester.pump();
    await _mount(tester, second);
    expect(find.textContaining('Off'), findsOneWidget);
    expect(find.text('Show logs folder'), findsOneWidget);
    first.pending!.complete(DiagnosticFolderOpenResult.failed);
    await tester.pump();
    expect(
      find.text('Could not show the logs folder. Try again.'),
      findsNothing,
    );
    expect(first.snapshots, 1);
    expect(second.opens, 0);
  });

  testWidgets('the unavailable default disables show and copy', (tester) async {
    await _mount(tester, const UnavailableDiagnosticSupport());
    expect(find.textContaining('Unavailable in this session'), findsOneWidget);
    expect(
      find.text('The logs folder is unavailable in this session.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('diagnosticCounters')), findsNothing);
    expect(_button(tester, 'showLogsFolder').onPressed, isNull);
    expect(_button(tester, 'copyDiagnosticSummary').onPressed, isNull);
  });

  testWidgets('an unknown folder disables only the open action', (
    tester,
  ) async {
    final port = _Port(
      _snapshot(
        DiagnosticSupportStatus.degraded,
        reason: DiagnosticSupportReason.storageUnavailable,
        folder: false,
      ),
    );
    await _mount(tester, port);
    expect(
      find.text('The logs folder is unavailable in this session.'),
      findsOneWidget,
    );
    expect(_button(tester, 'showLogsFolder').onPressed, isNull);
    expect(_button(tester, 'copyDiagnosticSummary').onPressed, isNotNull);
  });

  testWidgets('an invalid configured level is explained', (tester) async {
    await _mount(
      tester,
      _Port(
        DiagnosticSupportSnapshot(
          status: DiagnosticSupportStatus.degraded,
          reason: DiagnosticSupportReason.healthy,
          level: DiagnosticSupportLevel.info,
          invalidLevel: true,
        ),
      ),
    );
    expect(
      find.textContaining('(FORESIGHT_LOG_LEVEL was invalid)'),
      findsOneWidget,
    );
  });

  testWidgets('copy hands only the closed summary to the clipboard', (
    tester,
  ) async {
    final copies = <String>[];
    final port = _Port(
      _snapshot(
        DiagnosticSupportStatus.starting,
        reason: DiagnosticSupportReason.bootstrapOnly,
      ),
    );
    await _mount(tester, port, copy: (text) async => copies.add(text));
    await tester.tap(find.byKey(const Key('copyDiagnosticSummary')));
    await tester.pump();
    expect(copies, [
      'Open Foresight 0.1.3 (build 4)\n${port.current.supportText}',
    ]);
    expect(copies.single, contains('status: starting'));
    expect(copies.single, contains('reason: bootstrapOnly'));
    expect(copies.single, contains('storage_configured: true'));
    expect(copies.single, isNot(contains('/')));
    expect(find.text('Copied the health summary.'), findsOneWidget);
    expect(port.opens, 0);
  });

  testWidgets('a copy result survives a concurrent show request', (
    tester,
  ) async {
    final copied = Completer<void>();
    final port = _Port(_writing);
    await _mount(tester, port, copy: (_) => copied.future);
    await tester.tap(find.byKey(const Key('copyDiagnosticSummary')));
    await tester.tap(find.byKey(const Key('showLogsFolder')));
    await tester.pump();
    copied.complete();
    await tester.pump();
    expect(find.text('Copied the health summary.'), findsOneWidget);
    port.pending!.complete(DiagnosticFolderOpenResult.opened);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replaced port discards a pending copy result', (tester) async {
    final copied = Completer<void>();
    await _mount(tester, _Port(_writing), copy: (_) => copied.future);
    await tester.tap(find.byKey(const Key('copyDiagnosticSummary')));
    await tester.pump();
    await _mount(tester, _Port(_writing), copy: (_) async {});
    copied.complete();
    await tester.pump();
    expect(find.text('Copied the health summary.'), findsNothing);
  });

  testWidgets('a clipboard failure shows a closed message', (tester) async {
    await _mount(
      tester,
      _Port(_writing),
      copy: (_) async => throw StateError('fixture clipboard'),
    );
    await tester.tap(find.byKey(const Key('copyDiagnosticSummary')));
    await tester.pump();
    expect(find.text('Could not copy the health summary.'), findsOneWidget);
    expect(find.textContaining('fixture'), findsNothing);
  });

  test('the environment defaults to the inert port and binds startup\'s', () {
    const environment = DesktopEnvironment(
      variables: {'HOME': '/fixture'},
      capabilities: PlatformCapabilities.macOS(),
      homeDirectory: '/account',
      configDirectory: '/fixture/config',
      dataDirectory: '/fixture/data',
      launcher: '/fixture/launcher',
    );
    expect(environment.diagnosticSupport, isA<UnavailableDiagnosticSupport>());
    final port = _Port(_writing);
    final bound = environment.withDiagnosticSupport(port);
    expect(bound.diagnosticSupport, same(port));
    expect(bound.variables, environment.variables);
    expect(bound.capabilities, same(environment.capabilities));
    expect(bound.homeDirectory, '/account');
    expect(bound.configDirectory, environment.configDirectory);
    expect(bound.dataDirectory, environment.dataDirectory);
    expect(bound.launcher, environment.launcher);
    expect(bound.run, same(environment.run));
    expect(bound.start, same(environment.start));
    expect(bound.openUri, same(environment.openUri));
    expect(bound.notify, same(environment.notify));
    expect(environment.diagnosticSupport, isA<UnavailableDiagnosticSupport>());
  });

  test('the view reaches no session, profile, host or network capability', () {
    final source = File(
      'lib/features/settings/diagnostic_support_view.dart',
    ).readAsStringSync();
    final imports = parseString(content: source).unit.directives
        .whereType<UriBasedDirective>()
        .map((directive) => directive.uri.stringValue)
        .toList();
    expect(imports, [
      'package:flutter/material.dart',
      'package:flutter/services.dart',
      'package:foresight_core/desktop.dart',
    ]);
    for (final token in [
      'LoggingSession',
      'ProfilePaths',
      'LocalDiagnosticSupport',
      'desktop_bootstrap',
      'openPlatformUri',
      'HttpClient',
      'Socket',
      'Process',
    ]) {
      expect(source, isNot(contains(token)), reason: token);
    }
    // Same host API pattern as the environment adapter guard.
    expect(RegExp(r'\bPlatform\s*\.').hasMatch(source), isFalse);
  });

  testWidgets(
    'settings shows the port supplied through the desktop environment',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('diagnostic-settings-');
      final port = _Port(_writing);
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
      });
      await tester.pumpWidget(
        Foresight(
          connection,
          environment: const DesktopEnvironment().withDiagnosticSupport(port),
          deviceLoader: () async => [],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      final view = find.byType(DiagnosticSupportView);
      await tester.scrollUntilVisible(
        view,
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DiagnosticSupportView>(view).support, same(port));
      expect(find.text('Diagnostics'), findsOneWidget);
      expect(port.opens, 0);
      await tester.tap(find.byKey(const Key('showLogsFolder')));
      await tester.pump();
      expect(port.opens, 1);
      port.pending!.complete(DiagnosticFolderOpenResult.opened);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }),
  );
}
