import 'desktop_connection_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class StreamingChatDomain extends Domain {
  StreamingChatDomain(super.store, super.helper);
  final response = StreamController<String>();
  final prompts = <String>[];
  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) {
    prompts.add('$conversation: $question');
    return response.stream;
  }
}

void main() {
  testWidgets(
    'drafts, saved answers and in-flight text stay in their conversation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('chat-navigation-');
      final store = Store('${root.path}/app.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final domain = StreamingChatDomain(store, helper);
      final alpha = store.meeting('Alpha');
      final beta = store.meeting('Beta');
      store.answer(
        'Saved Alpha question',
        'Private Alpha answer',
        'completed',
        [],
        'fixture',
        conversation: 'meeting:$alpha',
      );
      store.db.execute(
        'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
        [alpha, store.db.lastInsertRowId],
      );
      try {
        await tester.pumpWidget(
          Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
        );
        final dynamic state = tester.state(find.byType(Workspace));
        void navigate(int? id) => state.update(() {
          state.meetingId = id;
          state.tab = id == null ? 1 : 3;
          state.meetingPanel = 'Chat';
        });
        Finder composer() => find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText ?? '').startsWith('Ask Foresight'),
        );
        navigate(alpha);
        await tester.pumpAndSettle();
        await tester.enterText(composer(), 'Alpha draft');
        navigate(beta);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
        await tester.enterText(composer(), 'Beta draft');
        navigate(null);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
        expect(find.text('Saved Alpha question'), findsNothing);
        expect(
          find.text('Private Alpha answer', findRichText: true),
          findsNothing,
        );
        await tester.enterText(composer(), 'General draft');
        navigate(alpha);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          'Alpha draft',
        );
        await tester.tap(find.byTooltip('Ask'));
        await tester.pump();
        domain.response.add('Alpha streaming response');
        await tester.pump();
        expect(
          find.text('Alpha streaming response', findRichText: true),
          findsOneWidget,
        );
        navigate(beta);
        await tester.pump();
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          'Beta draft',
        );
        expect(
          find.text('Alpha streaming response', findRichText: true),
          findsNothing,
        );
        expect(find.byTooltip('Cancel answer'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'Ask',
                ),
              )
              .onPressed,
          isNull,
        );
        navigate(null);
        await tester.pump();
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          'General draft',
        );
        expect(
          find.text('Alpha streaming response', findRichText: true),
          findsNothing,
        );
        navigate(alpha);
        await tester.pump();
        expect(
          find.text('Alpha streaming response', findRichText: true),
          findsOneWidget,
        );
        expect(find.byTooltip('Cancel answer'), findsOneWidget);
        expect(domain.prompts, ['meeting:$alpha: Alpha draft']);
        await domain.response.close();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
