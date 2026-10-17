import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/chat_history_viewport.dart';

void main() {
  testWidgets(
    'chat follows output, respects reading older text and offers latest',
    (tester) async {
      Future<void> show(int revision, {bool answering = false}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 300,
                child: ChatHistoryViewport(
                  revision: revision,
                  answering: answering,
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(
                        height: 70.0 + i,
                        child: Text('Saved answer $i'),
                      ),
                    SizedBox(
                      height: 100.0 + revision * 20,
                      child: Text('Output $revision'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      double remaining() => tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .extentAfter;
      await show(1);
      expect(remaining(), lessThan(1));
      await show(2, answering: true);
      expect(remaining(), lessThan(1));
      await tester.drag(find.byType(ListView), const Offset(0, 250));
      await tester.pumpAndSettle();
      final readingPosition = offset();
      expect(remaining(), greaterThan(48));
      await show(3, answering: true);
      expect(offset(), closeTo(readingPosition, 1));
      expect(find.text('Show latest answer'), findsOneWidget);
      await tester.tap(find.text('Show latest answer'));
      await tester.pumpAndSettle();
      expect(remaining(), lessThan(1));
      expect(find.text('Show latest answer'), findsNothing);
      await show(4, answering: true);
      expect(remaining(), lessThan(1));
      expect(tester.takeException(), isNull);
    },
  );
}
