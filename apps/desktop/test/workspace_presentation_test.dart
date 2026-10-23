import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/desktop_visuals.dart';
import 'package:open_foresight/presentation/workspace_presentation.dart';

void main() {
  testWidgets('pills retain selected colors, icons and disabled actions', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              workspacePill(
                'Selected',
                () => presses++,
                icon: Icons.check,
                selected: true,
              ),
              workspacePill('Unavailable', null),
            ],
          ),
        ),
      ),
    );
    final selected = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton).at(0),
    );
    expect(selected.style!.backgroundColor!.resolve({}), workspaceBlue);
    expect(selected.style!.foregroundColor!.resolve({}), workspaceInk);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('Selected'));
    expect(presses, 1);
    final unavailable = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton).at(1),
    );
    expect(unavailable.onPressed, isNull);
    expect(unavailable.style!.backgroundColor!.resolve({}), Colors.white);
  });

  testWidgets('heading wraps actions below its title only below 700 pixels', (
    tester,
  ) async {
    for (final width in [699.0, 700.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: workspaceHeading(
                'Sources',
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Add')),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text('Sources')).style,
        DesktopVisuals.pageTitle,
      );
      final title = tester.getRect(find.text('Sources'));
      final action = tester.getRect(find.text('Add'));
      if (width < 700) {
        expect(action.top, greaterThan(title.bottom));
      } else {
        expect(action.center.dy, title.center.dy);
        expect(action.left, greaterThan(title.right));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('heading without actions stays a single row at narrow widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 300, child: workspaceHeading('Meetings')),
        ),
      ),
    );
    expect(
      find.ancestor(of: find.text('Meetings'), matching: find.byType(Row)),
      findsOneWidget,
    );
    expect(find.byType(Wrap), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search input retains caller ownership and delivers edits', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'initial');
    addTearDown(controller.dispose);
    final edits = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: workspaceSearchBox(
            'Find sources',
            edits.add,
            controller: controller,
          ),
        ),
      ),
    );
    expect(find.text('initial'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller, same(controller));
    expect(field.style, DesktopVisuals.field);
    expect(field.decoration!.hintText, 'Find sources');
    expect(field.decoration!.enabledBorder!.borderSide, BorderSide.none);
    await tester.enterText(find.byType(TextField), 'edited');
    expect(edits, ['edited']);
    expect(controller.text, 'edited');
    await tester.pumpWidget(const SizedBox());
    controller.text = 'still owned by caller';
    expect(controller.text, 'still owned by caller');
  });

  test('relative time retains unknown, future and unit boundary labels', () {
    final now = DateTime(2026, 10, 22, 12);
    String label(Duration age) =>
        workspaceTimeLabel(now.subtract(age).millisecondsSinceEpoch, now: now);
    expect(workspaceTimeLabel(null, now: now), 'Unknown');
    expect(workspaceTimeLabel(0, now: now), 'Unknown');
    expect(label(const Duration(minutes: -1)), 'Just now');
    expect(label(const Duration(seconds: 59)), 'Just now');
    expect(label(const Duration(minutes: 1)), '1 min ago');
    expect(label(const Duration(minutes: 59)), '59 mins ago');
    expect(label(const Duration(hours: 1)), '1 hour ago');
    expect(label(const Duration(hours: 23)), '23 hours ago');
    expect(label(const Duration(days: 1)), '1 day ago');
    expect(label(const Duration(days: 2)), '2 days ago');
  });

  test('relative time defaults to the current clock', () {
    expect(
      workspaceTimeLabel(DateTime.now().millisecondsSinceEpoch),
      'Just now',
    );
  });
}
