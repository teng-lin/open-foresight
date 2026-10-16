import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/recording.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class _Recording implements Recording {
  @override
  bool paused = false;
  @override
  bool finishing = false;
  bool failResume = false;
  @override
  Map<String, dynamic> get echoCancellationState => {
    'requested': false,
    'active': false,
  };
  @override
  List<int> get sampleCounts => [0, 0];
  @override
  List<double> get peakVolumes => [0, 0];
  @override
  List<double> get currentVolumes => [0, 0];
  @override
  DateTime get lastAudioActivity => DateTime.now();
  @override
  void pause() {
    paused = true;
  }

  @override
  void resume() {
    if (failResume) throw StateError('Fixture device unavailable');
    paused = false;
  }

  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'recording pill pauses/resumes through service and immersive view exits without stopping',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'recording-controls-',
      );
      final store = Store('${directory.path}/app.db');
      final domain = Domain(
        store,
        OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
      );
      final recording = _Recording();
      final id = store.meeting('Control fixture');
      domain.application
        ..recording = recording
        ..recordingMeeting = id
        ..recordingBegan = DateTime.now();
      try {
        await tester.pumpWidget(
          Foresight(domain, deviceLoader: () async => []),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Pause transcribing'));
        await tester.pumpAndSettle();
        expect(recording.paused, true);
        expect(
          store.rows('SELECT state FROM meetings WHERE id=?', [
            id,
          ]).single['state'],
          'paused',
        );
        expect(find.byTooltip('Resume transcribing'), findsOneWidget);
        recording.failResume = true;
        await tester.tap(find.byTooltip('Resume transcribing'));
        await tester.pumpAndSettle();
        expect(recording.paused, true);
        expect(find.textContaining('Fixture device unavailable'), findsWidgets);
        recording.failResume = false;
        await tester.tap(find.byTooltip('Resume transcribing'));
        await tester.pumpAndSettle();
        expect(recording.paused, false);
        await tester.tap(find.byKey(const ValueKey('recording-pill')));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byKey(const ValueKey('recording-pill')));
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsOneWidget);
        expect(find.text('Knowledge Sources'), findsNothing);
        for (final width in [640.0, 1280.0]) {
          tester.view.physicalSize = Size(width, 850);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('Exit Immersive View'));
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsNothing);
        expect(domain.application.recording, same(recording));
        await tester.tap(find.byTooltip('Full screen'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsNothing);
        expect(domain.application.recording, same(recording));
        expect(tester.takeException(), isNull);
      } finally {
        domain.application.recording = null;
        await tester.pumpWidget(const SizedBox.shrink());
        directory.deleteSync(recursive: true);
      }
    },
  );
}
