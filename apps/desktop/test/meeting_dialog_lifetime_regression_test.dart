import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets(
    'a Preparation picker opened before clear cannot write preferences for a reused meeting ID',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final original = f.store.meeting('Original meeting');
      f.store.importText(
        'Original document',
        'Original evidence',
        'text/plain',
        'fixture',
        id: 'original-document',
      );
      f.store.setPreference(
        'preparationSources.$original',
        '["original-document"]',
      );
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = original;
        f.shell.meetingFeature.meetingPanel = 'Preparation';
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Prepare from local documents'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.widgetWithText(CheckboxListTile, 'Original document'),
        findsOneWidget,
      );
      await tester.runAsync(
        () => f.connection.application.call(Operation.workspaceClear.wire, {}),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final replacement = f.store.meeting('Replacement meeting');
      expect(replacement, original);
      f.store.importText(
        'Replacement document',
        'Replacement evidence',
        'text/plain',
        'fixture',
        id: 'replacement-document',
      );
      f.store.setPreference(
        'preparationSources.$replacement',
        '["replacement-document"]',
      );
      await tester.tap(find.text('Use selected documents'));
      await pumpUntil(tester, () => !f.shell.busy);
      expect(
        f.store.preference('preparationSources.$replacement'),
        '["replacement-document"]',
      );
      expect(
        f.connection.calls.where(
          (call) =>
              call.$1 == Operation.preferencesSet &&
              call.$2['key'] == 'preparationSources.$replacement',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final boundary in ['session', 'clear']) {
    testWidgets('an open task editor cannot mutate a replacement after $boundary', (
      tester,
    ) async {
      final f = await ControllerFixture.mount(tester);
      final original = f.store.meeting('Original task owner');
      f.store.db.execute(
        "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,?,'Original task','open','[]',1)",
        [original, 'original'],
      );
      final task = f.store.rows('SELECT * FROM meeting_tasks').single;
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = original;
        f.shell.meetingFeature.meetingPanel = 'Action items';
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit task'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Retired editor overwrite',
      );
      if (boundary == 'session') {
        final epoch = f.connection.workspaceEpoch;
        final generation = f.connection.clientSessionGeneration;
        f.connection.replaceClientSessionForTesting();
        await tester.pump(const Duration(milliseconds: 100));
        expect(f.connection.workspaceEpoch, epoch);
        expect(f.connection.clientSessionGeneration, isNot(same(generation)));
      } else {
        await tester.runAsync(
          () =>
              f.connection.application.call(Operation.workspaceClear.wire, {}),
        );
        await tester.pumpAndSettle();
        final replacement = f.store.meeting('Replacement owner');
        expect(replacement, original);
        f.store.db.execute(
          "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,?,'Replacement task','completed','[]',1)",
          [replacement, 'replacement'],
        );
        expect(
          f.store.rows('SELECT id FROM meeting_tasks').single['id'],
          task['id'],
        );
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final expected = boundary == 'clear'
          ? 'Replacement task'
          : 'Original task';
      expect(
        f.store.rows('SELECT task FROM meeting_tasks').single['task'],
        expected,
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final boundary in ['clear', 'session']) {
    testWidgets('a retained task completion action cannot cross $boundary', (
      tester,
    ) async {
      final f = await ControllerFixture.mount(tester);
      final original = f.store.meeting('Task action owner');
      f.store.db.execute(
        "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,'action','Original task','open','[]',1)",
        [original],
      );
      final task = f.store.rows('SELECT * FROM meeting_tasks').single;
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = original;
        f.shell.meetingFeature.meetingPanel = 'Action items';
      });
      await tester.pumpAndSettle();
      final complete = tester
          .widget<Checkbox>(find.byType(Checkbox).first)
          .onChanged!;
      if (boundary == 'clear') {
        await tester.runAsync(
          () =>
              f.connection.application.call(Operation.workspaceClear.wire, {}),
        );
        await tester.pumpAndSettle();
        final replacement = f.store.meeting('Reused task owner');
        expect(replacement, original);
        f.store.db.execute(
          "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision,manual) VALUES(?,'replacement','Replacement task','open','[]',1,1)",
          [replacement],
        );
        expect(
          f.store.rows('SELECT id FROM meeting_tasks').single['id'],
          task['id'],
        );
      } else {
        final epoch = f.connection.workspaceEpoch;
        f.connection.replaceClientSessionForTesting();
        await tester.pump(const Duration(milliseconds: 100));
        expect(f.connection.workspaceEpoch, epoch);
      }
      f.connection.calls.clear();
      // Represents an input callback already queued by the retired view. Use
      // the real rendered Checkbox action, not a direct command shortcut.
      complete(true);
      await tester.pumpAndSettle();
      expect(
        f.store.rows('SELECT status FROM meeting_tasks').single['status'],
        'open',
      );
      expect(
        f.connection.calls.where(
          (call) => call.$1 == Operation.meetingsEditTask,
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final boundary in ['clear', 'session']) {
    testWidgets('a retained task editor action cannot cross $boundary', (
      tester,
    ) async {
      final f = await ControllerFixture.mount(tester);
      final original = f.store.meeting('Task editor owner');
      f.store.db.execute(
        "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,'original','Original task','open','[]',1)",
        [original],
      );
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = original;
        f.shell.meetingFeature.meetingPanel = 'Action items';
      });
      await tester.pumpAndSettle();
      final edit = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Edit task',
            ),
          )
          .onPressed!;
      if (boundary == 'clear') {
        await tester.runAsync(
          () =>
              f.connection.application.call(Operation.workspaceClear.wire, {}),
        );
        await tester.pumpAndSettle();
        expect(f.store.meeting('Replacement task owner'), original);
        f.store.db.execute(
          "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,'replacement','Replacement task','open','[]',1)",
          [original],
        );
      } else {
        final epoch = f.connection.workspaceEpoch;
        f.connection.replaceClientSessionForTesting();
        await tester.pump(const Duration(milliseconds: 100));
        expect(f.connection.workspaceEpoch, epoch);
      }
      f.connection.calls.clear();
      edit();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        f.connection.calls.where(
          (call) => call.$1 == Operation.meetingsEditTask,
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final kind in ['source picker', 'preparation']) {
    for (final boundary in ['clear', 'session']) {
      testWidgets('a retained $kind action cannot cross $boundary', (
        tester,
      ) async {
        final f = await ControllerFixture.mount(tester);
        final original = f.store.meeting('Original action owner');
        f.store.importText(
          'Original document',
          'Original evidence',
          'text/plain',
          'fixture',
          id: 'original-document',
        );
        f.shell.update(() {
          f.shell.meetingFeature.meetingId = original;
          f.shell.meetingFeature.meetingPanel = kind == 'preparation'
              ? 'Preparation'
              : 'Chat';
        });
        await tester.pumpAndSettle();
        late VoidCallback retained;
        if (kind == 'preparation') {
          retained = tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Prepare from local documents',
                ),
              )
              .onPressed!;
        } else {
          final row = find
              .ancestor(
                of: find.text('Answer sources: '),
                matching: find.byType(Row),
              )
              .first;
          final choose = tester
              .widget<DropdownButton<String>>(
                find.descendant(
                  of: row,
                  matching: find.byType(DropdownButton<String>),
                ),
              )
              .onChanged!;
          retained = () => choose('selected');
        }
        if (boundary == 'clear') {
          await tester.runAsync(
            () => f.connection.application.call(
              Operation.workspaceClear.wire,
              {},
            ),
          );
          await tester.pumpAndSettle();
          expect(f.store.meeting('Replacement action owner'), original);
          f.store.importText(
            'Replacement document',
            'Replacement evidence',
            'text/plain',
            'fixture',
            id: 'replacement-document',
          );
        } else {
          final epoch = f.connection.workspaceEpoch;
          f.connection.replaceClientSessionForTesting();
          await tester.pump(const Duration(milliseconds: 100));
          expect(f.connection.workspaceEpoch, epoch);
        }
        f.connection.calls.clear();
        retained();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(f.shell.busy, isFalse);
        expect(
          f.connection.calls.where(
            (call) =>
                call.$1 == Operation.preferencesSet ||
                call.$1 == Operation.meetingsPrepare,
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
