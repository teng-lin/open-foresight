import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'meeting Chat saves separate conversation histories through the service operation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('meeting-chat-ui-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final alpha = store.meeting('Alpha');
      final beta = store.meeting('Beta');
      try {
        await tester.pumpWidget(
          Foresight(
            Domain(
              store,
              OfflineHelper(
                '${directory.path}/socket',
                '${directory.path}/helper',
              ),
            ),
            deviceLoader: () async => [],
          ),
        );
        final dynamic state = tester.state(find.byType(Workspace));
        for (final id in [alpha, beta]) {
          state.update(() {
            state.meetingId = id;
            state.meetingPanel = 'Chat';
          });
          await tester.pumpAndSettle();
          if (id == beta) {
            expect(
              find.byWidgetPredicate(
                (widget) => widget is Text && widget.data == 'Alpha question',
              ),
              findsNothing,
            );
          }
          await tester.enterText(
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText == 'Ask Foresight AI...',
            ),
            id == alpha ? 'Alpha question' : 'Beta question',
          );
          await tester.pump();
          await tester.tap(find.byTooltip('Ask'));
          await tester.pumpAndSettle();
        }
        state.update(() {
          state.meetingId = null;
          state.tab = 1;
        });
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.hintText ==
                    'Ask Foresight about your meetings',
          ),
          'General question',
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Ask'));
        await tester.pumpAndSettle();
        expect(
          store.rows(
            'SELECT question,conversation,meeting_id FROM answers LEFT JOIN meeting_answers ON answers.id=answer_id ORDER BY answers.id',
          ),
          [
            {
              'question': 'Alpha question',
              'conversation': 'meeting:$alpha',
              'meeting_id': alpha,
            },
            {
              'question': 'Beta question',
              'conversation': 'meeting:$beta',
              'meeting_id': beta,
            },
            {
              'question': 'General question',
              'conversation': 'desktop',
              'meeting_id': null,
            },
          ],
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        directory.deleteSync(recursive: true);
      }
    },
  );
}
