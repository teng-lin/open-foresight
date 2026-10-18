import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/meeting_visuals.dart';

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
