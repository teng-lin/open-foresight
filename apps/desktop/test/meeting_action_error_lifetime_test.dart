import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/remote.dart'
    show RpcError, RpcErrorCode, RpcErrorReason;
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/failure_text.dart';
import '../test_support/meeting_panel.dart';
import 'controller_fixture.dart' show ControllerConnection;
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class _HeldMeetingError extends ControllerConnection {
  _HeldMeetingError(super.application, this.operation, {this.unknown = false});
  final Operation operation;
  final bool unknown;
  final entered = Completer<void>(), release = Completer<void>();
  final admitted = <Operation>[];

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) async {
    if (!current()) return null;
    admitted.add(operation);
    if (operation != this.operation) {
      return super.commandCurrent(operation, args, current);
    }
    entered.complete();
    await release.future;
    // A real request may settle with cancellation after its caller retires.
    // Deliberately deliver it even when current() is now false.
    throw RpcError(
      unknown ? RpcErrorCode.unavailable : RpcErrorCode.cancelled,
      'Held meeting request failed',
      reason: unknown ? RpcErrorReason.outcomeUnknown : null,
    );
  }
}

void main() {
  for (final action in ['scope', 'preparation', 'task edit', 'completion']) {
    for (final boundary in [
      'current',
      'session',
      'clear',
      'dispose',
      if (action == 'completion') 'outcome unknown',
    ]) {
      testWidgets('held $action error respects $boundary ownership', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1440, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final root = createTestTempDirectorySync('meeting-error-');
        final store = Store('${root.path}/app.db');
        final meeting = store.meeting('Meeting error owner');
        store.importText(
          'Local document',
          'Local evidence',
          'text/plain',
          'fixture',
          id: 'local-document',
        );
        store.setPreference(
          'preparationSources.$meeting',
          '["local-document"]',
        );
        store.db.execute(
          "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,'task','Original task','open','[]',1)",
          [meeting],
        );
        final connection = _HeldMeetingError(
          Application(
            Domain(
              store,
              OfflineHelper('${root.path}/socket', '${root.path}/helper'),
            ),
          ),
          action == 'scope' || action == 'preparation'
              ? Operation.preferencesSet
              : Operation.meetingsEditTask,
          unknown: boundary == 'outcome unknown',
        );
        await tester.pumpWidget(
          Foresight(connection, deviceLoader: () async => []),
        );
        final dynamic shell = tester.state(find.byType(Workspace));
        shell.update(() {
          shell.meetingFeature.meetingId = meeting;
          shell.meetingFeature.meetingPanel = action == 'scope'
              ? 'Chat'
              : action == 'preparation'
              ? 'Preparation'
              : 'Action items';
        });
        await tester.pumpAndSettle();
        if (action == 'scope') {
          await openMeetingAnswerSources(tester);
          await tester.tap(
            find.widgetWithText(CheckboxListTile, 'Local document'),
          );
          await tester.pump();
          await tester.tap(find.text('Use selected documents'));
        } else if (action == 'preparation') {
          await tester.tap(find.byTooltip('Prepare from local documents'));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(find.text('Use selected documents'));
        } else if (action == 'task edit') {
          await tester.tap(find.byTooltip('Edit task'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.byType(Checkbox).first);
        }
        await pumpUntil(tester, () => connection.entered.isCompleted);
        if (boundary == 'session') {
          final epoch = connection.workspaceEpoch;
          connection.replaceClientSessionForTesting();
          await tester.pump(const Duration(milliseconds: 100));
          expect(connection.workspaceEpoch, epoch);
        } else if (boundary == 'clear') {
          await tester.runAsync(
            () =>
                connection.application.call(Operation.workspaceClear.wire, {}),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(store.meeting('Replacement meeting'), meeting);
        } else if (boundary == 'dispose') {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        // A retired error must not replace the replacement owner's message.
        if (boundary == 'session' || boundary == 'clear') {
          shell.update(() => shell.error = 'Replacement owner message');
        }
        final int revision = shell.serviceUiRevision.value;
        connection.release.complete();
        await tester.pumpAndSettle();
        if (boundary != 'dispose') {
          expect(
            shell.error,
            boundary == 'outcome unknown'
                ? outcomeUnknownText
                : boundary == 'current'
                ? 'Held meeting request failed'
                : 'Replacement owner message',
          );
          expect(
            shell.serviceUiRevision.value,
            revision + (boundary == 'outcome unknown' ? 1 : 0),
          );
          expect(shell.busy, isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
        }
        var closed = false;
        unawaited(connection.closed.then<void>((_) => closed = true));
        await pumpUntil(tester, () => closed);
        expect(connection.admitted, [connection.operation]);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
