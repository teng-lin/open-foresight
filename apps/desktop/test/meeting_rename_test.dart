import 'desktop_fixture_owner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/meetings/meeting_export.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  Future<(ControllerFixture, int)> open(WidgetTester tester) async {
    final f = await ControllerFixture.mount(tester);
    final id = f.store.meeting('Original meeting');
    f.store.saveMeetingNotes(id, 'Keep my notes');
    f.shell.update(() {
      f.shell.navigate(WorkspaceTab.meetings);
      f.shell.meetingFeature.meetingId = id;
    });
    await pumpUntil(
      tester,
      () => find.byTooltip('Rename meeting').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    return (f, id);
  }

  Finder nameField() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextField),
  );

  testWidgets(
    'rename saves through the service and updates header, list, search and export',
    (tester) async => withDesktopFixtures(tester, () async {
      final (f, id) = await open(tester);
      await tester.tap(find.byTooltip('Rename meeting'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(nameField()).controller!.text,
        'Original meeting',
      );
      await tester.enterText(nameField(), '  Planning 中文  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isEmpty,
      );
      await pumpUntil(
        tester,
        () => find.text('Planning 中文').evaluate().isNotEmpty,
      );
      expect(f.store.meetingQueries.workspace(id)!.title, 'Planning 中文');
      expect(f.store.meetingQueries.note(id)!.body, 'Keep my notes');
      final call = f.connection.calls.singleWhere(
        (call) => call.$1 == Operation.meetingsRename,
      );
      expect(call.$2, {
        'id': id,
        'title': 'Planning 中文',
        'workspace_epoch': f.store.workspaceEpoch,
      });
      expect(
        (await readMeetingExport(f.connection.store)).markdown,
        contains('## Planning 中文'),
      );
      await tester.tap(find.byTooltip('All meetings'));
      await tester.pumpAndSettle();
      expect(find.text('Planning 中文'), findsWidgets);
      final feature = f.shell.meetingFeature;
      f.shell.update(() {
        feature.meetingQuery = 'Planning';
        feature.meetingSearchController.text = 'Planning';
      });
      await tester.pumpAndSettle();
      expect(find.text('Planning 中文'), findsWidgets);
      f.shell.update(() => feature.meetingQuery = 'Original');
      await tester.pumpAndSettle();
      expect(find.text('Planning 中文'), findsNothing);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'cancel leaves the title unchanged; failed saves retain the draft for retry',
    (tester) async => withDesktopFixtures(tester, () async {
      final (f, id) = await open(tester);
      await tester.tap(find.byTooltip('Rename meeting'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), 'Discard this');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(f.store.meetingQueries.workspace(id)!.title, 'Original meeting');
      expect(
        f.connection.calls.where((call) => call.$1 == Operation.meetingsRename),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Rename meeting'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unable to save:'), findsOneWidget);
      expect(f.store.meetingQueries.workspace(id)!.title, 'Original meeting');
      f.connection.failures[Operation.meetingsRename] = StateError(
        'Service disconnected',
      );
      await tester.enterText(nameField(), 'Retry this name');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Service disconnected'), findsOneWidget);
      expect(
        tester.widget<TextField>(nameField()).controller!.text,
        'Retry this name',
      );
      f.connection.failures.remove(Operation.meetingsRename);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isEmpty,
      );
      await pumpUntil(
        tester,
        () => find.text('Retry this name').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    }),
  );
  testWidgets(
    'an open rename editor cannot save after client session replacement',
    (tester) async => withDesktopFixtures(tester, () async {
      final (f, id) = await open(tester);
      await tester.tap(find.byTooltip('Rename meeting'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), 'Retired editor overwrite');
      final originalEpoch = f.connection.workspaceEpoch;
      f.connection.replaceClientSessionForTesting();
      await tester.pumpAndSettle();
      expect(f.connection.workspaceEpoch, originalEpoch);
      f.store.meetingStore.renameMeeting(id, 'Current owner title');
      f.connection.calls.clear();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        f.store.meetingQueries.workspace(id)!.title,
        'Current owner title',
      );
      expect(
        f.connection.calls.where((call) => call.$1 == Operation.meetingsRename),
        isEmpty,
      );
      expect(find.textContaining('The meeting view changed.'), findsOneWidget);
      expect(
        tester.widget<TextField>(nameField()).controller!.text,
        'Retired editor overwrite',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'a queued rename action cannot edit a reused ID after workspace clear',
    (tester) async => withDesktopFixtures(tester, () async {
      final (f, id) = await open(tester);
      final rename = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Rename meeting',
            ),
          )
          .onPressed!;
      await tester.runAsync(
        () => f.connection.application.call(Operation.workspaceClear.wire, {}),
      );
      await tester.pumpAndSettle();
      final replacement = f.store.meeting('Replacement owner title');
      expect(replacement, id);
      f.connection.calls.clear();
      rename();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        f.store.meetingQueries.workspace(replacement)!.title,
        'Replacement owner title',
      );
      expect(
        f.connection.calls.where((call) => call.$1 == Operation.meetingsRename),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    }),
  );
}
