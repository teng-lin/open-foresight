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
  DiagnosticSupportReason reason, {
  bool folder = true,
  DiagnosticSupportLevel level = DiagnosticSupportLevel.info,
  int admitted = 12,
}) => DiagnosticSupportSnapshot(
  reason: reason,
  level: level,
  logsFolderKnown: folder,
  admitted: admitted,
  dropped: 1,
);

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
    final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
    await _mount(tester, port);
    expect(find.textContaining('Recording · level info'), findsOneWidget);
    expect(find.textContaining('never uploaded'), findsOneWidget);
    expect(find.textContaining('its health is not shown here'), findsOneWidget);
    expect(find.text('Recorded 12 · dropped 1 · rejected 0'), findsOneWidget);
    expect(port.opens, 0);
  });

  testWidgets('rebuilds read health once and never open the folder', (
    tester,
  ) async {
    final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
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
    final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
    await _mount(tester, port);
    port.current = _snapshot(DiagnosticSupportReason.sinkFailed);
    expect(find.textContaining('Recording'), findsOneWidget);
    await tester.tap(find.byKey(const Key('refreshDiagnosticHealth')));
    await tester.pump();
    expect(
      find.textContaining('Log writing stopped after a failure'),
      findsOneWidget,
    );
  });

  testWidgets(
    'an explicit click opens once and shows an accessible busy state',
    (tester) async {
      final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
      await _mount(tester, port);
      await tester.tap(find.byKey(const Key('openLogsFolder')));
      await tester.pump();
      expect(port.opens, 1);
      expect(find.text('Opening…'), findsOneWidget);
      expect(_button(tester, 'openLogsFolder').onPressed, isNull);
      expect(_button(tester, 'refreshDiagnosticHealth').onPressed, isNull);
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byKey(const Key('openLogsFolder'))),
        matchesSemantics(
          label: 'Opening…',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          hasFocusAction: true,
        ),
      );
      semantics.dispose();
      await tester.tap(find.byKey(const Key('openLogsFolder')));
      await tester.pump();
      expect(port.opens, 1);
      port.pending!.complete(DiagnosticFolderOpenResult.opened);
      await tester.pump();
      expect(find.text('Open logs folder'), findsOneWidget);
      expect(_button(tester, 'openLogsFolder').onPressed, isNotNull);
      expect(port.snapshots, 2, reason: 'health is re-read after the attempt');
    },
  );

  for (final (result, message) in [
    (DiagnosticFolderOpenResult.missing, 'No log files have been written yet.'),
    (
      DiagnosticFolderOpenResult.unsafe,
      'The logs folder was not opened because it is not a private folder.',
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
      final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
      await _mount(tester, port);
      await tester.tap(find.byKey(const Key('openLogsFolder')));
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
    final port = _Port(_snapshot(DiagnosticSupportReason.healthy))
      ..failure = StateError('/home/fixture/secret: vendor stderr');
    await _mount(tester, port);
    await tester.tap(find.byKey(const Key('openLogsFolder')));
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
    final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
    await _mount(tester, port);
    await tester.tap(find.byKey(const Key('openLogsFolder')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    port.pending!.complete(DiagnosticFolderOpenResult.failed);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(port.snapshots, 1);
  });

  testWidgets('a replaced port invalidates the pending result', (tester) async {
    final first = _Port(_snapshot(DiagnosticSupportReason.healthy));
    final second = _Port(_snapshot(DiagnosticSupportReason.off));
    await _mount(tester, first);
    await tester.tap(find.byKey(const Key('openLogsFolder')));
    await tester.pump();
    await _mount(tester, second);
    expect(find.textContaining('Off'), findsOneWidget);
    expect(find.text('Open logs folder'), findsOneWidget);
    first.pending!.complete(DiagnosticFolderOpenResult.failed);
    await tester.pump();
    expect(
      find.text('Could not show the logs folder. Try again.'),
      findsNothing,
    );
    expect(first.snapshots, 1);
    expect(second.opens, 0);
  });

  testWidgets('the unavailable default disables every action', (tester) async {
    await _mount(tester, const UnavailableDiagnosticSupport());
    expect(find.textContaining('Unavailable in this session'), findsOneWidget);
    expect(
      find.text('The logs folder is unavailable in this session.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('diagnosticCounters')), findsNothing);
    expect(_button(tester, 'openLogsFolder').onPressed, isNull);
    expect(_button(tester, 'copyDiagnosticSummary').onPressed, isNull);
  });

  testWidgets('an unknown folder disables only the open action', (
    tester,
  ) async {
    final port = _Port(
      _snapshot(DiagnosticSupportReason.storageUnavailable, folder: false),
    );
    await _mount(tester, port);
    expect(
      find.textContaining('Not writing log files; the app continues'),
      findsOneWidget,
    );
    expect(_button(tester, 'openLogsFolder').onPressed, isNull);
    expect(_button(tester, 'copyDiagnosticSummary').onPressed, isNotNull);
  });

  testWidgets('an invalid configured level is explained', (tester) async {
    await _mount(
      tester,
      _Port(
        DiagnosticSupportSnapshot(
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
    final port = _Port(_snapshot(DiagnosticSupportReason.bootstrapOnly));
    await _mount(tester, port, copy: (text) async => copies.add(text));
    await tester.tap(find.byKey(const Key('copyDiagnosticSummary')));
    await tester.pump();
    expect(copies, [
      'Open Foresight 0.1.3 (build 4)\n${port.current.supportText}',
    ]);
    expect(copies.single, contains('status: memoryOnly'));
    expect(copies.single, isNot(contains('/')));
    expect(find.text('Copied the health summary.'), findsOneWidget);
    expect(port.opens, 0);
  });

  testWidgets('a clipboard failure shows a closed message', (tester) async {
    await _mount(
      tester,
      _Port(_snapshot(DiagnosticSupportReason.healthy)),
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
    final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
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
      'Platform',
    ]) {
      expect(source, isNot(contains(token)), reason: token);
    }
  });

  testWidgets(
    'settings shows the port supplied through the desktop environment',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('diagnostic-settings-');
      final port = _Port(_snapshot(DiagnosticSupportReason.healthy));
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
      await tester.tap(find.byKey(const Key('openLogsFolder')));
      await tester.pump();
      expect(port.opens, 1);
      port.pending!.complete(DiagnosticFolderOpenResult.opened);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }),
  );
}
