import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/helper.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/model_setup.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/speech_setup_view.dart';

class OfflineHelper extends Helper {
  OfflineHelper(super.socket, super.storage);
  @override
  Future<void> start() async {
    state = 'disconnected';
  }
}

void main() {
  testWidgets(
    'meeting recording requires setup and opens speech setup instead of throwing',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('meeting-setup-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final helper = OfflineHelper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      );
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Domain(store, helper)),
          deviceLoader: () async => [],
        ),
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New meeting'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Meeting options'), findsNothing);
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechSetupDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.text('Set up a speech model and runner before recording.'),
        findsOneWidget,
      );
      expect(find.textContaining('Bad state'), findsNothing);
      await tester.tap(find.text('Set up speech'));
      await tester.pumpAndSettle();
      final choice = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(choice.value, 'speech');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      directory.deleteSync(recursive: true);
    },
  );

  test(
    'registered missing runner is reported as incomplete speech setup',
    () async {
      final directory = Directory.systemTemp.createTempSync('meeting-model-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final model = File('${directory.path}/speech.model')
        ..writeAsStringSync('control flow fixture');
      await store.register(
        'speech',
        model.path,
        '${directory.path}/missing-runner',
      );
      expect(speechSetupProblem(store), contains('runner is missing'));
      store.close();
      directory.deleteSync(recursive: true);
    },
  );
}
