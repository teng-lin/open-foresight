import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import '../test_support/core_fixture.dart';

import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class _DiagnosticGeneration implements GenerationStatus {
  _DiagnosticGeneration(this.effectiveState);
  @override
  final Map<String, dynamic> effectiveState;
  @override
  bool get generating => true;
  @override
  bool cancel({String? requestId}) => false;
  @override
  void close() {}
}

class _DiagnosticConnection extends TestDesktopConnection {
  _DiagnosticConnection(super.application, this.generator);
  @override
  final GenerationStatus? generator;
}

void main() {
  for (final state in <Map<String, dynamic>?>[
    null,
    {
      'state': 'failed',
      'error': 'Fixture load failure',
      'backend': 'litert-lm-cpu-native',
      'load_policy': 'verified',
      'context_length': 2048,
      'temperature': 0.25,
      'future_diagnostic': {'detail': 'preserved'},
    },
  ]) {
    testWidgets(
      'typed Settings diagnostics retain ${state == null ? 'absent defaults' : 'nondefault and unknown fields'}',
      (tester) async {
        final root = createTestTempDirectorySync('settings-status-');
        final store = Store('${root.path}/app.db');
        final connection = _DiagnosticConnection(
          Application(
            Domain(
              store,
              OfflineHelper('${root.path}/socket', '${root.path}/helper'),
            ),
          ),
          state == null ? null : _DiagnosticGeneration(state),
        );
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(
          Foresight(connection, deviceLoader: () async => []),
        );
        await tester.pumpAndSettle();
        final shell =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        shell.update(() => shell.navigate(WorkspaceTab.models));
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                widget.data ==
                    'Generator: ${state ?? {'state': 'unconfigured'}}',
          ),
          findsOneWidget,
        );
        shell.settingsFeature.showHelperMonitor();
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(
            of: dialog,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  widget.data!.contains('Generation: $state\nSpeech:'),
            ),
          ),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
