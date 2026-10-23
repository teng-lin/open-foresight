import 'package:open_foresight/features/meetings/capture_waveform.dart';
import '../test_support/reader_admissions.dart';
import 'store_reader_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'package:foresight_core/remote.dart' show CaptureLevelEvents;
import 'desktop_connection_fixture.dart';
import '../test_support/core_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

class _Recording implements Recording {
  @override
  bool paused = false;
  @override
  bool finishing = false;
  bool failResume = false;
  @override
  String lastError = '';
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

class _LevelConnection extends TestDesktopConnection
    implements CaptureLevelEvents {
  _LevelConnection(super.application);
  final levels = StreamController<List<double>>.broadcast();
  @override
  Stream<List<double>> get captureLevels => levels.stream;
  @override
  void close() {
    unawaited(levels.close());
    super.close();
  }
}

void main() {
  testWidgets(
    'audio levels repaint the waveform without rebuilding the recording header',
    (tester) async {
      final directory = createTestTempDirectorySync('recording-levels-');
      final store = Store('${directory.path}/app.db');
      final domain = Domain(
        store,
        OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
      );
      final admissions = ReaderAdmissions();
      fixtureReader(store, admissions: admissions);
      final app = Application(domain);
      final connection = _LevelConnection(app);
      final id = store.meeting('Meter fixture');
      app
        ..recording = _Recording()
        ..recordingMeeting = id
        ..recordingBegan = DateTime.now();
      try {
        await tester.pumpWidget(
          Foresight(connection, deviceLoader: () async => []),
        );
        await tester.pumpAndSettle();
        final header = tester.widget(
          find.byKey(const ValueKey('recording-pill')),
        );
        final oldMeter = tester.widget<CustomPaint>(
          find.byKey(const ValueKey('capture-waveform')),
        );
        final readsBeforeLevels = admissions.snapshot();
        for (var i = 0; i < 10; i++) {
          connection.levels.add([i / 10, 0.0]);
        }
        await tester.pump();
        await tester.pump();
        expect(
          admissions.snapshot(),
          readsBeforeLevels,
          reason:
              'Capture levels admit no typed reads, async reads, watches or worker projections',
        );
        final meter = tester.widget<CustomPaint>(
          find.byKey(const ValueKey('capture-waveform')),
        );
        expect(meter.painter, isNot(same(oldMeter.painter)));
        expect((meter.painter as CaptureWaveform).volumes, [0.9, 0.0]);
        expect(
          tester.widget(find.byKey(const ValueKey('recording-pill'))),
          same(header),
        );
        await app.stopRecording();
        await app.close();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await connection.levels.close();
      } finally {
        await app.close();
        await domain.helper.close();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'recording pill pauses/resumes through service and immersive view exits without stopping',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = createTestTempDirectorySync('recording-controls-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final domain = Domain(
        store,
        OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
      );
      final app = Application(domain);
      final recording = _Recording();
      final id = store.meeting('Control fixture');
      app
        ..recording = recording
        ..recordingMeeting = id
        ..recordingBegan = DateTime.now();
      try {
        await tester.pumpWidget(
          Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Microphone and system audio recording'),
          findsNothing,
        );
        expect(find.byTooltip('Stop transcribing'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause transcribing'));
        // The outer double-tap recognizer holds single control taps until its
        // standard double-tap window expires.
        await tester.pump(const Duration(milliseconds: 300));
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
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(recording.paused, true);
        expect(find.textContaining('Fixture device unavailable'), findsWidgets);
        recording.failResume = false;
        await tester.tap(find.byTooltip('Resume transcribing'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(recording.paused, false);
        final clock = find.byKey(const ValueKey('recording-clock'));
        await tester.tap(clock);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Exit Immersive View'), findsNothing);
        await tester.tap(clock);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Exit Immersive View'), findsNothing);
        // The original wraps the entire pill, including the timer, in its
        // standard double-tap recognizer rather than just the waveform.
        await tester.tap(clock);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(clock);
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsOneWidget);
        expect(find.byKey(const ValueKey('capture-waveform')), findsOneWidget);
        expect(find.byTooltip('Stop transcribing'), findsOneWidget);
        expect(find.text('Knowledge Sources'), findsNothing);
        for (final width in [640.0, 1280.0]) {
          tester.view.physicalSize = Size(width, 850);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('Exit Immersive View'));
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsNothing);
        expect(app.recording, same(recording));
        expect(find.byTooltip('Full screen'), findsNothing);
        await tester.tap(clock);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(clock);
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Exit Immersive View'), findsNothing);
        expect(app.recording, same(recording));
        await tester.tap(find.byTooltip('Stop transcribing'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(app.recording, isNull);
        expect(find.byKey(const ValueKey('recording-pill')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        app.recording = null;
        await tester.pumpWidget(const SizedBox.shrink());
        directory.deleteSync(recursive: true);
      }
    },
  );
}
