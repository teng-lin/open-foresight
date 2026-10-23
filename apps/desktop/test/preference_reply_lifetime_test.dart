import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import '../test_support/meeting_panel.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class _HeldPreferenceConnection extends TestDesktopConnection {
  _HeldPreferenceConnection(super.application, this.heldKey);
  final String heldKey;
  final entered = Completer<void>(), release = Completer<void>();
  final sent = <(Operation, Map<String, dynamic>)>[];
  Future<Object?> _reply(
    Operation operation,
    Map<String, dynamic> args,
    Object? result,
  ) async {
    if (operation == Operation.preferencesSet &&
        args['key'] == heldKey &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return result;
  }

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    sent.add((operation, Map.of(args)));
    return _reply(operation, args, await super.command(operation, args));
  }
}

void main() {
  for (final boundary in ['clear', 'session', 'dispose']) {
    testWidgets(
      'an accepted preference reply cannot continue stale source-picker writes after $boundary',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final root = createTestTempDirectorySync('preference-reply-');
        final path = '${root.path}/app.db';
        final store = Store(path);
        final meeting = store.meeting('Scoped picker');
        store.importText(
          'Original document',
          'Original evidence',
          'text/plain',
          'fixture',
          id: 'original-document',
        );
        store.setPreference(
          'answerSourcesSelection.$meeting',
          '["prior-selection"]',
        );
        final domain = Domain(
          store,
          OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        );
        final connection = _HeldPreferenceConnection(
          Application(domain),
          'answerSources.meeting:$meeting',
        );
        await tester.pumpWidget(
          Foresight(connection, deviceLoader: () async => []),
        );
        final shell =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        shell.update(() {
          shell.meetingFeature.meetingId = meeting;
          shell.meetingFeature.meetingPanel = 'Chat';
        });
        await tester.pumpAndSettle();
        await openMeetingAnswerSources(tester);
        await tester.tap(
          find.widgetWithText(CheckboxListTile, 'Original document'),
        );
        await tester.pump();
        await tester.tap(find.text('Use selected documents'));
        await pumpUntil(tester, () => connection.entered.isCompleted);
        expect(
          store.preference(connection.heldKey),
          '["original-document"]',
          reason: 'The first write committed before only its reply was held',
        );
        if (boundary == 'clear') {
          await tester.runAsync(
            () =>
                connection.application.call(Operation.workspaceClear.wire, {}),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final reused = store.meeting('New workspace picker');
          expect(reused, meeting);
          store.setPreference(connection.heldKey, '["replacement-document"]');
          store.setPreference(
            'answerSourcesSelection.$meeting',
            '["replacement-document"]',
          );
          store.setPreference('answerScope.meeting:$meeting', 'meeting');
        } else if (boundary == 'session') {
          final epoch = connection.workspaceEpoch;
          connection.replaceClientSessionForTesting();
          await tester.pump(const Duration(milliseconds: 100));
          expect(connection.workspaceEpoch, epoch);
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        connection.release.complete();
        if (boundary != 'dispose') await pumpUntil(tester, () => !shell.busy);
        await tester.pumpAndSettle();
        if (boundary != 'dispose')
          await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        unawaited(
          connection.closed.then<void>((_) {
            closed = true;
          }),
        );
        await pumpUntil(tester, () => closed);
        final reopened = Store(path);
        try {
          expect(
            reopened.preference(connection.heldKey),
            boundary == 'clear'
                ? '["replacement-document"]'
                : '["original-document"]',
          );
          expect(
            reopened.preference('answerSourcesSelection.$meeting'),
            boundary == 'clear'
                ? '["replacement-document"]'
                : '["prior-selection"]',
          );
          expect(
            reopened.preference('answerScope.meeting:$meeting', 'workspace'),
            boundary == 'clear' ? 'meeting' : 'workspace',
          );
        } finally {
          reopened.close();
        }
        expect(
          connection.sent.where((call) => call.$1 == Operation.preferencesSet),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
