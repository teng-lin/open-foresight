import 'package:open_foresight/features/chat/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/meetings/meeting_visuals.dart';

/// Use the same visible tab or overflow menu as a desktop user.
Future<void> selectMeetingPanel(WidgetTester tester, String panel) async {
  final header = find.byType(MeetingAssistantHeader);
  expect(header, findsOneWidget);
  final tab = find.descendant(
    of: header,
    matching: find.widgetWithText(TextButton, panel),
  );
  if (tab.evaluate().isNotEmpty) {
    await tester.tap(tab);
  } else {
    await tester.tap(
      find.descendant(
        of: header,
        matching: find.byTooltip('More meeting panels'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, panel));
  }
  await tester.pumpAndSettle();
}

/// Open the real scope selector without submitting or settling a held command.
Future<void> openMeetingAnswerSources(WidgetTester tester) async {
  final scopeRow = find
      .ancestor(of: find.text('Answer sources: '), matching: find.byType(Row))
      .first;
  await tester.tap(
    find.descendant(
      of: scopeRow,
      matching: find.byType(DropdownButton<String>),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Selected local documents').last);
  // The scope command remains busy while this dialog is open, so its progress
  // indicator keeps animating. Advance the dialog transition without settling.
  await tester.pump(const Duration(milliseconds: 400));
}

/// Choose a document through the meeting Chat source selector.
Future<void> selectMeetingAnswerSource(
  WidgetTester tester,
  String title,
) async {
  await openMeetingAnswerSources(tester);
  final source = find.widgetWithText(CheckboxListTile, title);
  await tester.ensureVisible(source);
  if (!tester.widget<CheckboxListTile>(source).value!) {
    await tester.tap(source);
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.tap(find.text('Use selected documents'));
  await tester.pumpAndSettle();
}

/// History includes the prepared answer-source identity so a scope replacement
/// retires its scroll position. Select the typed conversation, not an old key.
Finder meetingChatHistory(int meeting) => find.byWidgetPredicate(
  (widget) =>
      widget is ChatHistory && widget.scope.startsWith('meeting:$meeting:'),
);

/// Reveal a citation in the answer history before opening its source.
Future<void> openMeetingCitation(
  WidgetTester tester,
  int meeting,
  Object revision, {
  String citationLabel = 'S1',
}) async {
  final history = meetingChatHistory(meeting);
  final citation = find.descendant(
    of: history,
    matching: find.widgetWithText(
      TextButton,
      '[$citationLabel] source revision $revision',
    ),
  );
  await tester.scrollUntilVisible(
    citation,
    200,
    scrollable: find.descendant(of: history, matching: find.byType(Scrollable)),
  );
  await tester.pumpAndSettle();
  expect(citation.hitTestable(), findsOneWidget);
  await tester.tap(citation);
  await tester.pumpAndSettle();
}
