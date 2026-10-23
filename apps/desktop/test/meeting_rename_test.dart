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
    (tester) async {
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
    },
  );

  testWidgets(
    'cancel leaves the title unchanged; failed saves retain the draft for retry',
    (tester) async {
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
    },
  );
}
