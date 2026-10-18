import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/app_theme.dart';
import 'package:open_foresight/meeting_visuals.dart';

void main() {
  setUp(() async {
    await (FontLoader(
      'GoogleSans',
    )..addFont(rootBundle.load('assets/fonts/GoogleSans-Medium.ttf'))).load();
  });

  testWidgets(
    'Transcript opens directly and overflow selection becomes a tab',
    (tester) async {
      var selected = 'Chat';
      var fontDelta = 0;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: foresightTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: StatefulBuilder(
                  builder: (context, setState) => MeetingAssistantHeader(
                    selectedPanel: selected,
                    onPanelSelected: (panel) =>
                        setState(() => selected = panel),
                    onFontSizeChanged: (delta) => fontDelta += delta,
                    onClose: () => closed = true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Transcript'));
      await tester.pumpAndSettle();
      expect(selected, 'Transcript');
      expect(
        tester.getSemantics(find.widgetWithText(TextButton, 'Transcript')),
        matchesSemantics(
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
          hasFocusAction: true,
          label: 'Transcript',
        ),
      );

      await tester.tap(find.byTooltip('More meeting panels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Action items'));
      await tester.pumpAndSettle();
      expect(selected, 'Action items');
      expect(find.widgetWithText(TextButton, 'Action items'), findsOneWidget);
      await tester.tap(find.text('A+'));
      expect(fontDelta, 1);
      await tester.tap(find.text('A−'));
      expect(fontDelta, 0);
      await tester.tap(find.byTooltip('Close assistant'));
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actions stay right aligned as panels, width and text scale change',
    (tester) async {
      for (final width in [280.0, 400.0, 700.0]) {
        for (final scale in [1.0, 1.4]) {
          for (final selected in MeetingAssistantHeader.panels) {
            await tester.pumpWidget(
              MaterialApp(
                theme: foresightTheme(),
                home: Scaffold(
                  body: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        child: MeetingAssistantHeader(
                          selectedPanel: selected,
                          onPanelSelected: (_) {},
                          onFontSizeChanged: (_) {},
                          onClose: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final close = tester.getRect(find.byTooltip('Close assistant'));
            expect(close.right, width - 8);
            for (final label in ['A−', 'A+', selected]) {
              final button = tester.getRect(
                find.widgetWithText(TextButton, label),
              );
              expect(button.center.dy, close.center.dy);
            }
            expect(
              tester.takeException(),
              isNull,
              reason: '$width wide, scale $scale, selected $selected',
            );
          }
        }
      }
      expect(find.byTooltip('More meeting panels'), findsNothing);
      for (final panel in MeetingAssistantHeader.panels) {
        expect(find.widgetWithText(TextButton, panel), findsOneWidget);
      }
    },
  );
}
