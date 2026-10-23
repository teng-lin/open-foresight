import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  for (final boundary in ['scope', 'session', 'clear', 'dispose']) {
    testWidgets(
      'a held answer cannot publish after $boundary retires its feature identity',
      (tester) async {
        final f = await ControllerFixture.mount(tester);
        final id = f.store.meeting('Original meeting');
        f.shell.update(() {
          f.shell.meetingFeature.meetingId = id;
          f.shell.meetingFeature.meetingPanel = 'Chat';
        });
        await tester.pumpAndSettle();
        final response = StreamController<String>(sync: true);
        f.connection.answerStream = (_, __, ___) => response.stream;
        f.shell.chatFeature.questionFor(id).text = 'Original question';
        final work = f.shell.chatFeature.askQuestion(meetingScope: id);
        var settled = false;
        unawaited(
          work.then<void>((_) {
            settled = true;
          }),
        );
        await pumpUntil(tester, () => response.hasListener);
        response.add('Original accepted preview');
        await tester.pump();
        expect(f.shell.chatFeature.answer, 'Original accepted preview');
        final epoch = f.connection.workspaceEpoch;
        if (boundary == 'scope') {
          // Another client changes sources in this same conversation.
          f.store.setPreference('answerScope.meeting:$id', 'selected');
          f.store.setPreference('answerSources.meeting:$id', '[]');
          f.connection.domain.helper.changed?.call();
          await tester.pump(const Duration(milliseconds: 100));
          expect(f.connection.workspaceEpoch, epoch);
        } else if (boundary == 'session') {
          final before = f.connection.clientSessionGeneration;
          f.connection.replaceClientSessionForTesting();
          await tester.pump(const Duration(milliseconds: 100));
          expect(f.connection.workspaceEpoch, epoch);
          expect(f.connection.clientSessionGeneration, isNot(same(before)));
        } else if (boundary == 'clear') {
          await tester.runAsync(
            () => f.connection.application.call(
              Operation.workspaceClear.wire,
              {},
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final replacement = f.store.meeting('Reused ID in new workspace');
          expect(replacement, id);
          expect(f.connection.workspaceEpoch, isNot(epoch));
          f.shell.update(() {
            f.shell.meetingFeature.meetingId = replacement;
            f.shell.meetingFeature.meetingPanel = 'Chat';
          });
          await tester.pump();
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
        // A reply already in flight can ignore cancellation. Presentation owns rejection.
        response.add('LATE TEXT FROM RETIRED IDENTITY');
        var producerClosed = false;
        unawaited(
          response.close().then<void>((_) {
            producerClosed = true;
          }),
        );
        await pumpUntil(tester, () => settled && producerClosed);
        await tester.pump();
        expect(f.shell.chatFeature.answer, isNot(contains('LATE TEXT')));
        expect(
          find.text('LATE TEXT FROM RETIRED IDENTITY', findRichText: true),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'same-conversation selected-empty scope hides earlier private history and citations',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Scoped history');
      final document = f.store.importText(
        'Old private source',
        'Secret',
        'text/plain',
        'fixture',
      );
      f.store.answer(
        'Earlier private question',
        'Earlier private answer',
        'completed',
        [
          {
            'citation': 'S1',
            'document_id': document,
            'revision': 1,
            'excerpt': 'Secret',
          },
        ],
        'fixture',
        conversation: 'meeting:$id',
      );
      final answer = f.store.db.lastInsertRowId;
      f.store.db.execute(
        'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
        [id, answer],
      );
      f.store.setPreference(
        'answerScope.v1.$answer',
        AnswerSourceScope('workspace', null).identity,
      );
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = id;
        f.shell.meetingFeature.meetingPanel = 'Chat';
      });
      await tester.pumpAndSettle();
      expect(find.text('Earlier private question'), findsOneWidget);
      f.store.setPreference('answerScope.meeting:$id', 'selected');
      f.store.setPreference(
        'answerSources.meeting:$id',
        jsonEncode(<String>[]),
      );
      f.connection.domain.helper.changed?.call();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('Earlier private question'), findsNothing);
      expect(
        find.text('Earlier private answer', findRichText: true),
        findsNothing,
      );
      expect(find.text('[S1] source revision 1'), findsNothing);
      expect(
        f.store.rows('SELECT body FROM answers').single['body'],
        'Earlier private answer',
      );
    },
  );
}
