import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:foresight_test_support/capture_poll.dart';
import 'package:open_foresight/main.dart' as app;
import 'package:open_foresight/store.dart';
import 'package:open_foresight/graph_layout.dart';
import 'package:open_foresight/graph_rendering.dart';
import 'package:open_foresight/cluster_rendering.dart';
import 'package:open_foresight/graph_persistence.dart';
import 'package:foresight_core/src/model_setup.dart';

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  int seconds = 60,
  String reason = 'Workflow timed out',
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (!ready()) {
    final report = Platform.environment['FORESIGHT_MEETING_REPORT'];
    if (report != null) {
      File(
        '$report.widget-tree.txt',
      ).writeAsStringSync(tester.allElements.first.toStringDeep());
    }
    final workspaces = find.byType(app.Workspace);
    if (workspaces.evaluate().isNotEmpty) {
      final dynamic workspace = tester.state(workspaces);
      final status = await workspace.d.command('status');
      fail(
        '$reason: busy=${workspace.busy}, error=${workspace.error}, '
        'status=$status',
      );
    }
    fail(reason);
  }
  final failure = tester.takeException();
  if (failure != null) {
    File(
      '/tmp/foresight-render-tree.txt',
    ).writeAsStringSync(tester.binding.renderViews.first.toStringDeep());
  }
  expect(failure, isNull);
}

/// Desktop startup connects the service before it mounts [app.Workspace].
/// One frame is still the "Starting…" screen, so a state lookup there throws
/// "Bad state: No element" and hides the real connection error.
Future<dynamic> startedWorkspace(WidgetTester tester) async {
  await app.main();
  String? startupFailure;
  await waitUntil(tester, () {
    if (find.text('Open Foresight could not start').evaluate().isNotEmpty) {
      final details = find.byType(SelectableText);
      startupFailure = details.evaluate().isEmpty
          ? 'unknown startup failure'
          : tester.widget<SelectableText>(details).data;
      return true;
    }
    return find.byType(app.Workspace).evaluate().isNotEmpty;
  });
  if (startupFailure != null) {
    throw StateError('Desktop did not start: $startupFailure');
  }
  return tester.state(find.byType(app.Workspace));
}

/// Recording starts only after the desktop confirms the service request.
/// Clicking Record alone leaves capture idle while this dialog is pending.
Future<void> allowRecording(WidgetTester tester) async {
  await waitUntil(
    tester,
    () => find
        .text('Allow microphone and system audio recording?')
        .evaluate()
        .isNotEmpty,
    reason: 'Recording approval dialog did not appear',
  );
  await tester.tap(find.text('Allow once'));
  await tester.pump();
}

Future<void> captureWindow(
  WidgetTester tester,
  String path, {
  List<int> expectedGutter = const [234, 238, 247],
  bool expectGraphSelection = false,
}) async {
  // The private PipeWire acceptance session has no Agent Desktop display.
  if (Platform.environment['FORESIGHT_PRIVATE_PIPEWIRE'] == '1') return;
  await tester.runAsync(() async {
    final target = File(path);
    target.parent.createSync(recursive: true);
    final session =
        Platform.environment['FORESIGHT_AGENT_DESKTOP_SESSION'] ?? '';
    final display = Platform.environment['WAYLAND_DISPLAY'] ?? '';
    if (!RegExp(r'^[a-f0-9]{12}$').hasMatch(session) ||
        !display.contains('/agent-desktop/$session/') ||
        Platform.environment.containsKey('HYPRLAND_INSTANCE_SIGNATURE')) {
      throw StateError(
        'Acceptance requires the explicitly owned private display',
      );
    }
    // A completed Flutter frame can precede its compositor presentation. Read
    // actual captures until their asserted pixels are visible, retaining the
    // latest image and measurements even when the monotonic deadline expires.
    final observation = await waitForCapture(
      () async {
        final screenshot = await Process.run('grim', [path]);
        if (screenshot.exitCode != 0) {
          throw StateError(
            'Cannot capture the test window: ${screenshot.stderr}',
          );
        }
        final codec = await ui.instantiateImageCodec(
          await target.readAsBytes(),
        );
        late ui.Image image;
        try {
          image = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
        try {
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (pixels == null) throw StateError('Cannot inspect capture pixels');
          var goldPixels = 0;
          if (expectGraphSelection) {
            for (var y = 400; y < image.height; y++) {
              for (var x = 128; x < image.width; x++) {
                final i = (y * image.width + x) * 4;
                if (pixels.getUint8(i) == 255 &&
                    pixels.getUint8(i + 1) == 213 &&
                    pixels.getUint8(i + 2) == 79) {
                  goldPixels++;
                }
              }
            }
          }
          // x=80 is the untouched gutter between the rail and the nearest card.
          final offset = (400 * image.width + 80) * 4;
          return (
            gutter: [
              pixels.getUint8(offset),
              pixels.getUint8(offset + 1),
              pixels.getUint8(offset + 2),
            ],
            goldPixels: goldPixels,
          );
        } finally {
          image.dispose();
        }
      },
      (snapshot) =>
          snapshot.gutter.length == expectedGutter.length &&
          List.generate(
            expectedGutter.length,
            (i) => i,
          ).every((i) => snapshot.gutter[i] == expectedGutter[i]) &&
          (!expectGraphSelection || snapshot.goldPixels > 0),
    );
    File('$path.diagnostics.json').writeAsStringSync(
      jsonEncode({
        'ready': observation.ready,
        'attempts': observation.attempts,
        'elapsed_ms': observation.elapsed.inMilliseconds,
        'gutter': observation.snapshot.gutter,
        'expected_gutter': expectedGutter,
        'gold_pixels': observation.snapshot.goldPixels,
        'graph_selection_required': expectGraphSelection,
      }),
    );
    if (expectGraphSelection) {
      expect(
        observation.snapshot.goldPixels,
        greaterThan(0),
        reason:
            'Selected graph screenshot must contain the rendered gold ring; widget state alone is insufficient. Capture: $path',
      );
    }
    expect(
      observation.snapshot.gutter,
      expectedGutter,
      reason:
          'Native capture is not opaque at the background gutter. Capture: $path',
    );
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  final originalErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    debugPrint(details.toString());
    originalErrorHandler?.call(details);
  };
  testWidgets(
    'new meeting records real PipeWire playback, transcribes, summarizes and survives restart',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final env = Platform.environment;
      if (env['FORESIGHT_PRIVATE_PIPEWIRE'] == '1') {
        // Widget tests default to 800x600; this workflow uses the wide desktop
        // panels from the native 1280x720 acceptance display.
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      final sink = env['FORESIGHT_PLAYBACK_TARGET']!;
      final fixture = env['FORESIGHT_AUDIO_FIXTURE']!;
      final dynamic workspace = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () =>
            workspace.d.generator?.effectiveState['state'] == 'ready' &&
            workspace.d.helper.snapshot?.pipeline == 'ready',
      );
      final embeddingIdentity = workspace.d.helper.snapshot.model;
      final embeddingBackend = embeddingIdentity.backend as String;
      final generationBackend =
          workspace.d.generator.effectiveState['backend'] as String;
      if (env['FORESIGHT_EXPECT_EMBEDDING_BACKEND'] != null)
        expect(embeddingBackend, env['FORESIGHT_EXPECT_EMBEDDING_BACKEND']);
      if (env['FORESIGHT_EXPECT_GENERATION_BACKEND'] != null)
        expect(generationBackend, env['FORESIGHT_EXPECT_GENERATION_BACKEND']);
      if (env['FORESIGHT_EXPECT_PREPROCESSING'] != null)
        expect(
          embeddingIdentity.preprocessing,
          env['FORESIGHT_EXPECT_PREPROCESSING'],
        );
      // The dedicated headless output has its own geometry; captures do not
      // overwrite the matched-size Mac/Linux comparison gallery.
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      final screenshotDirectory = env['FORESIGHT_REFERENCE_SCREENSHOTS']!;
      await tester.tap(find.text('Ask').first);
      await tester.pumpAndSettle();
      await waitUntil(tester, () => true);
      await captureWindow(tester, '$screenshotDirectory/06-ask.png');
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New meeting'));
      await tester.pumpAndSettle();
      final meeting = workspace.meetingFeature.meetingId as int;
      final title =
          workspace.d.store.rows('SELECT title FROM meetings WHERE id=?', [
                meeting,
              ]).single['title']
              as String;
      await waitUntil(
        tester,
        () => speechSetupProblem(workspace.d.store) == null,
        reason: 'Speech model and runner were not ready for recording',
      );
      await tester.tap(find.byTooltip('Meeting options'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(
                PopupMenuItem<String>,
                'Record microphone + playback',
              ),
            )
            .enabled,
        true,
        reason: 'Recording action is disabled: busy=${workspace.busy}',
      );
      await tester.tap(find.text('Record microphone + playback'));
      await allowRecording(tester);
      await waitUntil(
        tester,
        () =>
            workspace.meetingFeature.recording?.sampleCounts.length == 2 &&
            workspace.meetingFeature.recording.sampleCounts.every(
              (int n) => n > 0,
            ),
      );
      expect(
        workspace.d.store.rows('SELECT state FROM meetings WHERE id=?', [
          meeting,
        ]).single['state'],
        'recording',
      );
      final player = await Process.start('pw-play', [
        '--target',
        sink,
        fixture,
      ]);
      player.stdout.drain<void>();
      player.stderr.drain<void>();
      await waitUntil(
        tester,
        () => workspace.meetingFeature.recording.peakVolumes[1] > 0,
      );
      expect(await player.exitCode, 0);
      await waitUntil(
        tester,
        () =>
            workspace.meetingFeature.recording != null &&
            (workspace.meetingFeature.provisionalTranscript.values.any(
                  (text) => (text as String).toLowerCase().contains('country'),
                ) ||
                workspace.d.store
                    .rows(
                      'SELECT text FROM transcript WHERE meeting_id=? AND final=1',
                      [meeting],
                    )
                    .any(
                      (row) => (row['text'] as String).toLowerCase().contains(
                        'country',
                      ),
                    )),
      );
      final liveBeforeStop = Map<String, String>.from(
        workspace.meetingFeature.provisionalTranscript,
      );
      final finalizedBeforeStop = workspace.d.store.rows(
        'SELECT text,source,start_ms,end_ms FROM transcript WHERE meeting_id=? AND final=1',
        [meeting],
      );
      expect(workspace.meetingFeature.recording, isNotNull);
      await tester.pumpAndSettle();
      await captureWindow(
        tester,
        '$screenshotDirectory/09-live-transcription.png',
      );
      final counts = List<int>.from(
        workspace.meetingFeature.recording.sampleCounts,
      );
      final peaks = List<double>.from(
        workspace.meetingFeature.recording.peakVolumes,
      );
      expect(counts[0], greaterThan(0));
      expect(counts[1], greaterThan(48000));
      expect(peaks[1], greaterThan(0.01));
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pause source imports and indexing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop transcribing'));
      await waitUntil(
        tester,
        () =>
            workspace.meetingFeature.recording == null &&
            workspace.busy == false,
      );
      expect(workspace.error, isEmpty);
      expect(workspace.d.sourcesPaused, true);
      expect(
        workspace.d.store.rows('SELECT state FROM meetings WHERE id=?', [
          meeting,
        ]).single['state'],
        'completed',
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Resume source imports and indexing'));
      await waitUntil(
        tester,
        () =>
            workspace.d.store.rows('SELECT state FROM sources WHERE id=?', [
              'meeting-$meeting',
            ]).single['state'] ==
            'indexed',
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      final transcripts =
          workspace.d.store.rows(
                'SELECT * FROM transcript WHERE meeting_id=? AND final=1',
                [meeting],
              )
              as List;
      expect(transcripts, isNotEmpty);
      final text = transcripts.map((t) => t['text']).join('\n').toLowerCase();
      expect(text, contains('country'));
      expect(text, contains('ask not'));
      final source = workspace.d.store.rows(
        'SELECT * FROM sources WHERE id=?',
        ['meeting-$meeting'],
      ).single;
      expect(source['state'], 'indexed');
      await tester.tap(find.text('Summary').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Generate Summary'));
      await waitUntil(tester, () => workspace.busy == false);
      expect(workspace.error, isEmpty);
      final summary = workspace.d.store.rows(
        'SELECT * FROM artifacts WHERE meeting_id=?',
        [meeting],
      ).single;
      expect(
        (summary['generated'] as String).toLowerCase(),
        contains('country'),
      );
      await tester.ensureVisible(find.byTooltip('Edit Summary'));
      await tester.tap(find.byTooltip('Edit Summary'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'My meeting review: preserve this edit.',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Summary').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Generate Summary'));
      await waitUntil(tester, () => workspace.busy == false);
      expect(workspace.error, isEmpty);
      expect(
        workspace.d.store.rows('SELECT * FROM artifacts WHERE meeting_id=?', [
          meeting,
        ]).length,
        2,
      );
      expect(
        workspace.d.store.rows('SELECT edited FROM artifacts WHERE id=?', [
          summary['id'],
        ]).single['edited'],
        'My meeting review: preserve this edit.',
      );
      await workspace.d.command('preferences.set', {
        'key': 'liveEnhance',
        'value': 'false',
      });
      await tester.enterText(
        find.byKey(const ValueKey('meeting-notes-editor')),
        'Ask what you can do for your country.',
      );
      await tester.pumpAndSettle();
      final enhancedTab = find.widgetWithText(Tab, 'Enhanced');
      if (enhancedTab.evaluate().isNotEmpty) {
        await tester.tap(enhancedTab);
        await tester.pumpAndSettle();
      }
      await waitUntil(
        tester,
        () => find.text('Enhance notes').evaluate().isNotEmpty,
        reason: 'Enhanced notes did not refresh after editing the draft',
      );
      await tester.ensureVisible(find.text('Enhance notes'));
      await tester.tap(find.text('Enhance notes'));
      await waitUntil(
        tester,
        () =>
            workspace.meetingFeature.meetingEnhancing == false &&
            workspace.d.store
                .rows("SELECT * FROM artifacts WHERE kind='enhanced_notes'")
                .isNotEmpty,
      );
      expect(workspace.meetingFeature.meetingEnhanceStatus, isEmpty);
      final enhanced =
          workspace.d.store
                  .rows(
                    "SELECT generated FROM artifacts WHERE kind='enhanced_notes'",
                  )
                  .last['generated']
              as String;
      expect(enhanced.toLowerCase(), contains('country'));
      // Release the actual widget/domain and launch a fresh one against the saved profile.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      final dynamic reopened = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () =>
            reopened.d.generator?.effectiveState['state'] == 'ready' &&
            reopened.d.helper.snapshot?.pipeline == 'ready',
      );
      expect(
        reopened.d.store.rows(
          'SELECT * FROM transcript WHERE meeting_id=? AND final=1',
          [meeting],
        ).length,
        transcripts.length,
      );
      expect(
        reopened.d.store.rows('SELECT edited FROM artifacts WHERE id=?', [
          summary['id'],
        ]).single['edited'],
        'My meeting review: preserve this edit.',
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(title).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand meeting'));
      await tester.pumpAndSettle();
      expect(
        reopened.d.store.rows(
          'SELECT body FROM meeting_notes WHERE meeting_id=?',
          [meeting],
        ).single['body'],
        'Ask what you can do for your country.',
      );
      await tester.tap(find.text('Summary').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Previous versions'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('My meeting review: preserve this edit.'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await waitUntil(tester, () => true);
      await captureWindow(tester, env['FORESIGHT_MEETING_SCREENSHOT']!);
      await tester.tap(find.text('Ask').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'What does the speaker ask Americans to do? Cite [S1].',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ask'));
      await waitUntil(
        tester,
        () =>
            reopened.busy == false &&
            reopened.d.store.rows('SELECT * FROM answers').isNotEmpty,
      );
      expect(reopened.error, isEmpty);
      final answer = reopened.d.store
          .rows('SELECT * FROM answers ORDER BY id DESC')
          .first;
      expect(answer['status'], 'completed', reason: answer['body'] as String);
      expect((answer['body'] as String).toLowerCase(), contains('country'));
      expect((answer['body'] as String).toLowerCase(), isNot(contains('king')));
      await tester.pumpAndSettle();
      await waitUntil(tester, () => true);
      await captureWindow(tester, env['FORESIGHT_COPILOT_SCREENSHOT']!);
      final cited = jsonDecode(answer['citations'] as String) as List;
      expect(cited.single['document_id'], 'meeting-$meeting');
      final citedRevision = cited.single['revision'];
      await tester.tap(find.text('[S1] source revision $citedRevision'));
      await tester.pumpAndSettle();
      expect(
        find.text('${source['title']} · revision $citedRevision'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      // Close the desktop while a native speech result is pending.
      // The service must finish transcription and survive reconnection.
      final savedSpeech =
          reopened.d.store
                  .rows("SELECT runtime FROM models WHERE kind='speech'")
                  .single['runtime']
              as String;
      final slowSpeech = File(
        '${env['FORESIGHT_DATA']}/speech-cancellation-runner',
      )..writeAsStringSync('#!/bin/sh\nsleep 2\nexec "$savedSpeech" "\$@"\n');
      await Process.run('chmod', ['700', slowSpeech.path]);
      final speechAsset = reopened.d.store
          .rows("SELECT path FROM models WHERE kind='speech'")
          .single['path'];
      await reopened.d.command('models.register', {
        'kind': 'speech',
        'path': speechAsset,
        'runtime': slowSpeech.path,
      });
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Meeting options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record microphone + playback'));
      await allowRecording(tester);
      await waitUntil(
        tester,
        () =>
            reopened.meetingFeature.recording?.sampleCounts.length == 2 &&
            reopened.meetingFeature.recording.sampleCounts.every(
              (int n) => n > 0,
            ),
      );
      final secondPlayer = await Process.start('pw-play', [
        '--target',
        sink,
        fixture,
      ]);
      secondPlayer.stdout.drain<void>();
      secondPlayer.stderr.drain<void>();
      expect(await secondPlayer.exitCode, 0);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Stop transcribing'));
      await waitUntil(
        tester,
        () => reopened.meetingFeature.recording?.finishing == true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      dynamic afterCancellation = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () => afterCancellation.d.generator?.effectiveState['state'] == 'ready',
      );
      await waitUntil(
        tester,
        () => afterCancellation.meetingFeature.recording == null,
      );
      expect(
        afterCancellation.d.store.rows(
          'SELECT state FROM meetings WHERE id=?',
          [meeting],
        ).single['state'],
        'completed',
      );
      await afterCancellation.d.command('models.register', {
        'kind': 'speech',
        'path': speechAsset,
        'runtime': savedSpeech,
      });
      final realInactivity = env['FORESIGHT_REAL_INACTIVITY'] == '1';
      final inactivitySetting =
          afterCancellation.d.store.preference('inactivity', '15') as String;
      final inactivityObservations = <Map<String, Object?>>[];
      await afterCancellation.d.command('preferences.set', {
        'key': 'inactivity',
        'value': realInactivity ? '5' : '0.1',
      });
      // The opt-in path waits for production timekeeping on silent devices.
      await tester.tap(find.text('Start transcribing'));
      await allowRecording(tester);
      await waitUntil(
        tester,
        () =>
            afterCancellation.meetingFeature.recording?.sampleCounts.length ==
            2,
      );
      final silentMeeting = afterCancellation.meetingFeature.meetingId as int;
      final activityAtStart =
          afterCancellation.meetingFeature.recording.lastAudioActivity
              as DateTime;
      var nextCheckpoint = 60;
      await waitUntil(tester, () {
        final elapsed = DateTime.now().difference(activityAtStart).inSeconds;
        if (realInactivity &&
            elapsed >= nextCheckpoint &&
            elapsed < 300 &&
            afterCancellation.meetingFeature.recording != null) {
          expect(
            afterCancellation.meetingFeature.recording.lastAudioActivity,
            activityAtStart,
          );
          expect(afterCancellation.meetingFeature.recording.finishing, false);
          inactivityObservations.add({
            'elapsed_seconds': elapsed,
            'recording_active': true,
            'activity_timestamp_unchanged': true,
            'sample_counts': List<int>.from(
              afterCancellation.meetingFeature.recording.sampleCounts as List,
            ),
            'peak_volumes': List<double>.from(
              afterCancellation.meetingFeature.recording.peakVolumes as List,
            ),
          });
          debugPrint(
            'Real inactivity checkpoint: $elapsed seconds, still recording',
          );
          nextCheckpoint += 60;
        }
        return afterCancellation.meetingFeature.recording == null &&
            afterCancellation.busy == false;
      }, seconds: realInactivity ? 330 : 30);
      final inactivityElapsed = DateTime.now().difference(activityAtStart);
      if (realInactivity) {
        expect(inactivityElapsed.inSeconds, greaterThanOrEqualTo(300));
        expect(inactivityElapsed.inSeconds, lessThanOrEqualTo(330));
        expect(inactivityObservations.length, greaterThanOrEqualTo(4));
        debugPrint(
          'Real inactivity finalized: ${inactivityElapsed.inSeconds} seconds',
        );
      }
      expect(afterCancellation.error, isEmpty);
      expect(
        afterCancellation.d.store.rows(
          'SELECT state FROM meetings WHERE id=?',
          [silentMeeting],
        ).single['state'],
        'empty',
      );
      await afterCancellation.d.command('preferences.set', {
        'key': 'inactivity',
        'value': inactivitySetting,
      });
      // Test the source controls against actual extraction and helper indexing.
      // Imports intentionally reject files inside the application profile.
      final fixtures = Directory.systemTemp.createTempSync(
        'of-meeting-imports-',
      );
      addTearDown(() => fixtures.delete(recursive: true));
      for (final name in [
        'Apollo planning',
        'Borealis review',
        'Local AI notes',
        'Meeting agenda',
        'Product decisions',
      ]) {
        File('${fixtures.path}/$name.md').writeAsStringSync(
          '# $name\nAcceptance fixture: the team review is Friday.',
        );
      }
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pause source imports and indexing'));
      await tester.pumpAndSettle();
      expect(afterCancellation.d.sourcesPaused, true);
      final beforePauseImports = afterCancellation.d.store.sources.length;
      final pausedImport = afterCancellation.run(() async {
        await afterCancellation.sourceFeature.importFolderPath(fixtures.path);
      });
      await tester.pump();
      expect(afterCancellation.busy, true);
      expect(afterCancellation.d.store.sources.length, beforePauseImports);
      await captureWindow(
        tester,
        '$screenshotDirectory/10-source-import-paused.png',
      );
      await tester.tap(find.byTooltip('Resume source imports and indexing'));
      await pausedImport;
      await tester.pumpAndSettle();
      expect(afterCancellation.d.sourcesPaused, false);
      expect(afterCancellation.error, isEmpty);
      final firstImported = afterCancellation.d.store.sources
          .where((s) => s['title'] == 'Apollo planning.md')
          .single;
      expect(firstImported['state'], 'indexed');
      File(
        '${fixtures.path}/Apollo planning.md',
      ).writeAsStringSync('Updated acceptance fixture: the review is Monday.');
      await afterCancellation.run(
        afterCancellation.sourceFeature.refreshSources,
      );
      final revised = afterCancellation.d.store.sources
          .where((s) => s['id'] == firstImported['id'])
          .single;
      expect(revised['revision'], 2);
      expect(revised['content'], contains('Monday'));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var page = 'URL acceptance fixture: the review is Tuesday.';
      final subscription = server.listen((request) {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<html><script>hidden script</script><p>$page</p></html>',
        );
        request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}/notes';
      try {
        await afterCancellation.run(() async {
          await afterCancellation.d.command('sources.import_url', {
            'url': address,
            'allow_private_network': true,
          });
        });
        expect(afterCancellation.error, isEmpty);
        page = 'URL acceptance fixture: the review is Wednesday.';
        await afterCancellation.run(() async {
          await afterCancellation.d.command('sources.refresh', {
            'allow_private_network': true,
          });
        });
        final imported = afterCancellation.d.store.sources
            .where((s) => s['provenance'] == 'url:$address')
            .single;
        expect(imported['revision'], 2);
        expect(imported['content'], contains('Wednesday'));
        expect(imported['content'], isNot(contains('hidden script')));
        expect(imported['state'], 'indexed');
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
      // Discover names/metadata first, then import only the chosen file.
      final discovery = Directory('${fixtures.path}/discovery')..createSync();
      File(
        '${discovery.path}/Discovered review.md',
      ).writeAsStringSync('Discovered fixture: the review is Thursday.');
      File(
        '${discovery.path}/Unselected budget.txt',
      ).writeAsStringSync('Unselected fixture: the budget is 1500 dollars.');
      File(
        '${discovery.path}/unsupported.png',
      ).writeAsStringSync('Not a supported text import.');
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      final finding = afterCancellation.run(() async {
        await afterCancellation.sourceFeature.findLocalFiles(
          roots: [fixtures.path],
        );
      });
      await tester.pump();
      await waitUntil(
        tester,
        () => find.text('Discovered review.md').evaluate().isNotEmpty,
      );
      expect(find.text('2 files found · 5 already imported'), findsOneWidget);
      await tester.tap(find.text('Discovered review.md'));
      // The workspace's busy indicator keeps animating during this dialog.
      await tester.pump(const Duration(milliseconds: 250));
      await captureWindow(
        tester,
        '$screenshotDirectory/11-find-files-selection.png',
        expectedGutter: const [107, 109, 113],
      );
      await tester.tap(find.text('Import selected (1)'));
      await finding;
      await tester.pumpAndSettle();
      expect(afterCancellation.error, isEmpty);
      final discovered = afterCancellation.d.store.sources
          .where((source) => source['title'] == 'Discovered review.md')
          .single;
      expect(discovered['state'], 'indexed');
      expect(discovered['content'], contains('Thursday'));
      expect(
        afterCancellation.d.store.sources.where(
          (source) => source['title'] == 'Unselected budget.txt',
        ),
        isEmpty,
      );
      final exportedNotes =
          afterCancellation.d.store.meetingEnhancedNotes(meeting) as String;
      expect(exportedNotes, isNotEmpty);
      expect(
        afterCancellation.meetingFeature.exportMeetingMarkdown(),
        contains(exportedNotes.trim()),
      );
      for (final name in ['Stats', 'Sources']) {
        await tester.tap(find.text(name).first);
        await tester.pumpAndSettle();
        await waitUntil(tester, () => true);
        await captureWindow(
          tester,
          '$screenshotDirectory/${name == 'Stats' ? '01-stats' : '02-sources-list'}.png',
        );
      }
      final unindexedGraphSource = await afterCancellation.meetingFeature
          .importText(
            'Missing vector fixture',
            'Missing-vector text participates in the graph.',
            'text/plain',
            'fixture:missing-vector',
          );
      // A pending source is automatically indexed when the desktop reconnects.
      // Seed a failed source in this disposable fixture profile so the graph
      // restoration check retains a text node without an embedding.
      final fixtureStore = Store(afterCancellation.d.store.path as String);
      try {
        fixtureStore.state(
          unindexedGraphSource,
          'failed',
          'Missing-vector fixture',
        );
      } finally {
        fixtureStore.close();
      }
      final labelledSources = afterCancellation.d.store.sources;
      await afterCancellation.d.command('labels.set', {
        'id': labelledSources[0]['id'],
        'labels': ['Planning'],
      });
      await afterCancellation.d.command('labels.set', {
        'id': labelledSources[1]['id'],
        'labels': ['Planning', 'Local AI'],
      });
      afterCancellation.update(() {});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      await waitUntil(
        tester,
        () =>
            !afterCancellation.sourceFeature.graphOrganizing &&
            afterCancellation.sourceFeature.graphPoints.length >= 2,
      );
      expect(afterCancellation.sourceFeature.graphLayoutError, isEmpty);
      expect(
        afterCancellation.sourceFeature.graphPoints.containsKey(
          unindexedGraphSource,
        ),
        true,
      );
      expect(
        afterCancellation.sourceFeature.graphSceneVectors.containsKey(
          unindexedGraphSource,
        ),
        false,
      );
      final semanticGraphPointCount =
          afterCancellation.sourceFeature.graphPoints.length as int;
      final semanticGraphEdgeCount =
          afterCancellation.sourceFeature.graphEdges.length as int;
      expect(semanticGraphEdgeCount, greaterThan(0));
      final expectedGraphEdges = <String, double>{};
      for (final edge in afterCancellation.sourceFeature.graphEdges) {
        expect(edge.source.compareTo(edge.target), lessThan(0));
        expect(edge.similarity, greaterThanOrEqualTo(.2));
        expect(edge.similarity.isFinite, true);
        expectedGraphEdges[jsonEncode([edge.source, edge.target])] =
            edge.similarity as double;
      }
      expect(expectedGraphEdges.length, semanticGraphEdgeCount);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.minScale, .015);
      expect(viewer.maxScale, 5);
      expect(
        tester.getSize(find.byKey(const ValueKey('source-graph-links'))),
        const Size(3000, 3000),
      );
      final dynamic unselectedLinks = tester
          .widget<CustomPaint>(find.byKey(const ValueKey('source-graph-links')))
          .painter;
      expect(unselectedLinks.edges, isEmpty);
      final persistedLayoutIdentity =
          jsonDecode(
                afterCancellation.d.store
                        .rows('SELECT model_identity FROM graph_layouts')
                        .single['model_identity']
                    as String,
              )
              as List;
      expect(persistedLayoutIdentity.first, graphLayoutAlgorithmVersion);
      await captureWindow(tester, '$screenshotDirectory/03-sources-graph.png');
      final graphNodes = find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith('graph-node-') &&
            !(widget.key as ValueKey<String>).value.startsWith(
              'graph-node-opacity-',
            ),
      );
      final labelCounts = graphNodes.evaluate().map((element) {
        final id = (element.widget.key as ValueKey<String>).value.substring(
          'graph-node-'.length,
        );
        return (tester
                    .widget<CustomPaint>(
                      find.byKey(ValueKey('graph-node-paint-$id')),
                    )
                    .painter
                as GraphNodePainter)
            .labelColors
            .length;
      }).toSet();
      expect(labelCounts, containsAll([0, 1, 2]));
      final coloredNode = graphNodes
          .evaluate()
          .map((element) {
            final id = (element.widget.key as ValueKey<String>).value.substring(
              'graph-node-'.length,
            );
            return tester
                    .widget<CustomPaint>(
                      find.byKey(ValueKey('graph-node-paint-$id')),
                    )
                    .painter
                as GraphNodePainter;
          })
          .singleWhere((painter) => painter.labelColors.length == 2);
      expect(coloredNode.labelColors, [
        const Color(0xff0ebc5f),
        const Color(0xff60d5f3),
      ]);

      final graphBounds = tester.getRect(
        find.byKey(const ValueKey('source-graph-canvas')),
      );
      for (var i = 0; i < graphNodes.evaluate().length; i++) {
        expect(
          graphBounds.contains(tester.getCenter(graphNodes.at(i))),
          true,
          reason: 'Fit must place every fixture node inside the graph panel',
        );
      }
      String selectedUri = '';
      for (var i = 0; i < graphNodes.evaluate().length; i++) {
        await tester.tapAt(tester.getCenter(graphNodes.at(i)));
        await tester.pump();
        await waitUntil(
          tester,
          () => !afterCancellation.sourceFeature.graphRelatedLoading,
        );
        final id = afterCancellation.sourceFeature.graphSelectedDocument;
        if (id == null) continue;
        final rows = afterCancellation.d.store.sources as List;
        selectedUri =
            rows.singleWhere((row) => row['id'] == id)['source_uri'] as String;
        if (selectedUri.isNotEmpty &&
            (afterCancellation.sourceFeature.graphSelectionEdges as List)
                .isNotEmpty)
          break;
      }
      expect(
        selectedUri,
        isNotEmpty,
        reason: 'A real imported source must expose its original URI',
      );
      expect(afterCancellation.sourceFeature.graphSelectedDocument, isNotNull);
      expect(find.byKey(const ValueKey('graph-inspector')), findsOneWidget);
      final selectedDocument =
          afterCancellation.sourceFeature.graphSelectedDocument as String;
      final selectedNode =
          tester
                  .widget<CustomPaint>(
                    find.byKey(ValueKey('graph-node-paint-$selectedDocument')),
                  )
                  .painter
              as GraphNodePainter;
      expect(selectedNode.selected, true);
      expect(selectedNode.radius, greaterThan(0));
      expect(selectedNode.title, isNotEmpty);
      var originalLinkDispatched = false;
      {
        await tester.tap(find.byKey(const ValueKey('graph-inspector-link')));
        await tester.pump();
        final dispatch = File(
          Platform.environment['FORESIGHT_LINK_OPEN_REPORT']!,
        );
        await waitUntil(tester, () => dispatch.existsSync());
        expect(jsonDecode(dispatch.readAsStringSync()), [
          Uri.parse(selectedUri).toString(),
        ]);
        originalLinkDispatched = true;
      }
      final dynamic selectedLinks = tester
          .widget<CustomPaint>(find.byKey(const ValueKey('source-graph-links')))
          .painter;
      expect(selectedLinks.edges, isNotEmpty);
      for (final edge in selectedLinks.edges) {
        expect(
          edge.source == selectedDocument || edge.target == selectedDocument,
          true,
        );
      }
      await tester.pumpAndSettle();
      await captureWindow(
        tester,
        '$screenshotDirectory/13-selected-graph.png',
        expectGraphSelection: true,
      );
      final beforeInlineOrganization = {
        for (final entry
            in (afterCancellation.sourceFeature.graphPoints as Map).entries)
          entry.key: [entry.value.x, entry.value.y, entry.value.z],
      };
      await tester.tap(find.byKey(const ValueKey('inspector-add-label')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inspector-label-input')),
        'Inspector fixture',
      );
      await tester.pumpAndSettle();
      await captureWindow(
        tester,
        '$screenshotDirectory/14-inspector-label-editor.png',
        expectGraphSelection: true,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await waitUntil(
        tester,
        () =>
            !afterCancellation.busy &&
            afterCancellation.d.store.rows(
              "SELECT * FROM document_labels WHERE document_id=? AND label_name='Inspector fixture'",
              [selectedDocument],
            ).isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(afterCancellation.error, isEmpty);
      expect(afterCancellation.sourceFeature.graphLabelInput.text, isEmpty);
      expect(
        (afterCancellation.sourceFeature.graphPoints as Map).entries.any(
          (entry) =>
              (entry.value.x - beforeInlineOrganization[entry.key]![0]).abs() >
                  1e-6 ||
              (entry.value.y - beforeInlineOrganization[entry.key]![1]).abs() >
                  1e-6 ||
              (entry.value.z - beforeInlineOrganization[entry.key]![2]).abs() >
                  1e-6,
        ),
        true,
        reason:
            'Inline add must run force organization, not only recolor nodes',
      );
      final beforeLocalRemoval = afterCancellation.d.store.rows(
        'SELECT document_id,proj_x,proj_y,proj_z FROM graph_documents',
      );
      final propagatedInline = afterCancellation.d.store.rows(
        "SELECT * FROM document_labels WHERE label_name='Inspector fixture' AND document_id<>?",
        [selectedDocument],
      );
      expect(propagatedInline, isNotEmpty);
      await tester.tap(
        find.byKey(const ValueKey('inspector-remove-Inspector fixture')),
      );
      await tester.pumpAndSettle();
      expect(
        afterCancellation.d.store.rows(
          'SELECT document_id,proj_x,proj_y,proj_z FROM graph_documents',
        ),
        beforeLocalRemoval,
      );
      expect(
        afterCancellation.d.store.rows(
          "SELECT * FROM document_labels WHERE document_id=? AND label_name='Inspector fixture'",
          [selectedDocument],
        ),
        isEmpty,
      );
      expect(
        afterCancellation.d.store.rows(
          "SELECT * FROM document_labels WHERE label_name='Inspector fixture' AND document_id<>?",
          [selectedDocument],
        ),
        propagatedInline,
      );
      await tester.tap(find.byKey(const ValueKey('graph-inspector-close')));
      await tester.pumpAndSettle();
      expect(afterCancellation.sourceFeature.graphSelectedDocument, isNull);
      expect(find.byKey(const ValueKey('graph-inspector')), findsNothing);
      await waitUntil(tester, () => !afterCancellation.busy);
      final organizationButton = find.widgetWithText(ActionChip, 'Add label');
      expect(
        tester.widget<ActionChip>(organizationButton).onPressed,
        isNotNull,
      );
      await tester.ensureVisible(organizationButton);
      await tester.pumpAndSettle();
      await tester.tap(organizationButton);
      await tester.pumpAndSettle();
      expect(find.text('Create New Organization Label'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Apollo');
      await tester.tap(find.text('Create & Auto-Assign'));
      await waitUntil(
        tester,
        () =>
            !afterCancellation.busy &&
            afterCancellation.d.store
                .rows("SELECT * FROM document_clusters WHERE label='Apollo'")
                .isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(afterCancellation.error, isEmpty);
      final organizationRows =
          afterCancellation.d.store.rows(
                "SELECT * FROM document_labels WHERE label_name='Apollo'",
              )
              as List;
      expect(organizationRows, isNotEmpty);
      expect(
        organizationRows.any((row) => row['label_source'] == 'user_defined'),
        true,
      );
      expect(
        organizationRows.any(
          (row) =>
              row['label_source'] == 'propagated' ||
              row['label_source'] == 'propagated_community',
        ),
        true,
      );
      expect(
        afterCancellation.d.store
            .rows("SELECT * FROM document_clusters WHERE label='Apollo'")
            .single['radius'],
        greaterThanOrEqualTo(90),
      );
      await tester.tap(find.text('Add source'));
      await tester.pumpAndSettle();
      await waitUntil(tester, () => true);
      await captureWindow(
        tester,
        '$screenshotDirectory/04-add-source-menu.png',
      );
      await tester.tapAt(const Offset(200, 100));
      await tester.pumpAndSettle();
      final expectedClusters = afterCancellation.d.store.rows(
        'SELECT * FROM document_clusters',
      );
      final expectedLabels = afterCancellation.d.store.rows(
        'SELECT * FROM document_labels',
      );
      final savedGraphRows =
          afterCancellation.d.store.rows(
                'SELECT document_id,proj_x,proj_y,proj_z,length(embedding) AS bytes FROM graph_documents',
              )
              as List;
      expect(savedGraphRows.length, semanticGraphPointCount);
      expect(
        savedGraphRows.every(
          (row) =>
              row['bytes'] ==
              (row['document_id'] == unindexedGraphSource ? 0 : 768 * 4),
        ),
        true,
      );
      // Distinguish restoration from a coincidentally identical fresh PCA result.
      // This changes coordinates only inside the disposable acceptance profile.
      final snapshotStore = afterCancellation.d.store as Store;
      final snapshot = snapshotStore.loadRegisteredGraphLayout(
        snapshotStore.sources,
        labelSet: snapshotStore.graphLabelSet(),
      );
      final adjusted = snapshot.points.map(
        (k, v) => MapEntry(k, GraphPoint(v.x * .75, v.y, v.z)),
      );
      expect(
        await afterCancellation.d.command('graph.save', {
          'identity': snapshot.identity,
          'sources': graphSceneSources(snapshotStore.sources, snapshot.vectors),
          'vectors': snapshot.vectors,
          'points': adjusted.map((k, v) => MapEntry(k, [v.x, v.y, v.z])),
          'labelSet': snapshotStore.graphLabelSet(),
          'clusters': snapshotStore.rows('SELECT * FROM document_clusters'),
        }),
        true,
      );
      final expectedGraph = {
        for (final row in afterCancellation.d.store.rows(
          'SELECT document_id,proj_x,proj_y,proj_z FROM graph_documents',
        ))
          row['document_id']: [row['proj_x'], row['proj_y'], row['proj_z']],
      };
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      afterCancellation = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () =>
            afterCancellation.d.helper.snapshot?.pipeline == 'ready' &&
            afterCancellation.d.generator?.effectiveState['state'] == 'ready',
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      await waitUntil(
        tester,
        () =>
            !afterCancellation.sourceFeature.graphOrganizing &&
            afterCancellation.sourceFeature.graphPoints.length ==
                expectedGraph.length,
      );
      expect(afterCancellation.sourceFeature.graphLayoutError, isEmpty);
      expect(
        afterCancellation.d.store.rows('SELECT * FROM document_labels'),
        expectedLabels,
      );
      expect(
        afterCancellation.d.store.rows('SELECT * FROM document_clusters'),
        expectedClusters,
      );
      for (final entry in expectedGraph.entries) {
        final point = afterCancellation.sourceFeature.graphPoints[entry.key];
        expect([point.x, point.y, point.z], entry.value);
      }
      expect(
        afterCancellation.sourceFeature.graphVectorCache.length,
        savedGraphRows.where((row) => (row['bytes'] as int) > 0).length,
      );
      expect(
        afterCancellation.sourceFeature.graphSceneVectors.containsKey(
          unindexedGraphSource,
        ),
        false,
      );
      expect(
        afterCancellation.sourceFeature.graphEdges.length,
        semanticGraphEdgeCount,
      );
      for (final edge in afterCancellation.sourceFeature.graphEdges) {
        final key = jsonEncode([edge.source, edge.target]);
        expect(expectedGraphEdges.containsKey(key), true);
        expect(edge.similarity, closeTo(expectedGraphEdges[key]!, 1e-6));
      }
      final clusterPainter =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('source-graph-clusters')),
                  )
                  .painter
              as GraphClusterPainter;
      expect(clusterPainter.clusters.length, expectedClusters.length);
      expect(clusterPainter.clusters, isNotEmpty);
      await tester.pumpAndSettle();
      final fittedPainter =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('source-graph-clusters')),
                  )
                  .painter
              as GraphClusterPainter;
      final fittedViewport = afterCancellation.sourceFeature.graphViewportSize!;
      final fittedTransform =
          afterCancellation.sourceFeature.graphTransform.value;
      for (final rect in fittedPainter.paintedBounds()) {
        final topLeft = MatrixUtils.transformPoint(
          fittedTransform,
          rect.topLeft,
        );
        final bottomRight = MatrixUtils.transformPoint(
          fittedTransform,
          rect.bottomRight,
        );
        expect(topLeft.dx, greaterThanOrEqualTo(0));
        expect(topLeft.dy, greaterThanOrEqualTo(0));
        expect(bottomRight.dx, lessThanOrEqualTo(fittedViewport.width));
        expect(bottomRight.dy, lessThanOrEqualTo(fittedViewport.height));
      }
      await captureWindow(tester, '$screenshotDirectory/12-restored-graph.png');
      final organizationFilter = find.widgetWithText(FilterChip, 'Apollo');
      await tester.ensureVisible(organizationFilter);
      await tester.tap(organizationFilter);
      await tester.pumpAndSettle();
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('source-graph-clusters')),
                    )
                    .painter
                as GraphClusterPainter)
            .filter,
        'Apollo',
      );
      await captureWindow(
        tester,
        '$screenshotDirectory/15-highlighted-clusters.png',
      );
      await tester.tap(organizationFilter);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      if (afterCancellation.meetingFeature.meetingId != null) {
        await tester.tap(find.byTooltip('All meetings'));
        await tester.pumpAndSettle();
      }
      await waitUntil(tester, () => true);
      await captureWindow(tester, '$screenshotDirectory/05-meetings.png');
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await waitUntil(tester, () => true);
      await captureWindow(tester, '$screenshotDirectory/07-settings.png');
      await tester.ensureVisible(find.text('Version'));
      await tester.pumpAndSettle();
      await waitUntil(tester, () => true);
      await captureWindow(tester, '$screenshotDirectory/08-settings-lower.png');
      // The destructive action is exercised only in this disposable test profile.
      await tester.ensureVisible(find.text('Clear workspace data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear workspace data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(afterCancellation.d.store.sources, isNotEmpty);
      await tester.tap(find.text('Clear workspace data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete workspace'));
      await waitUntil(tester, () => afterCancellation.busy == false);
      expect(afterCancellation.error, isEmpty);
      expect(afterCancellation.d.store.sources, isEmpty);
      expect(
        afterCancellation.d.store.rows('SELECT * FROM graph_documents'),
        isEmpty,
      );
      expect(
        afterCancellation.d.store.rows('SELECT * FROM graph_layouts'),
        isEmpty,
      );
      expect(
        afterCancellation.d.store.rows('SELECT * FROM document_labels'),
        isEmpty,
      );
      expect(
        afterCancellation.d.store.rows('SELECT * FROM graph_force_state'),
        isEmpty,
      );
      expect(
        afterCancellation.d.store.rows('SELECT * FROM document_clusters'),
        isEmpty,
      );
      expect(afterCancellation.d.store.rows('SELECT * FROM meetings'), isEmpty);
      expect(afterCancellation.d.store.rows('SELECT * FROM answers'), isEmpty);
      expect(afterCancellation.d.store.rows('SELECT * FROM models').length, 3);
      final report = env['FORESIGHT_MEETING_REPORT'];
      if (report != null) {
        File(report).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'workflow':
                'Real Linux Flutter UI + real PipeWire loopback + Whisper + $embeddingBackend + $generationBackend',
            'embedding_dimensions': embeddingIdentity.dimensions,
            'embedding_model_digest': embeddingIdentity.modelDigest,
            'embedding_preprocessing': embeddingIdentity.preprocessing,
            'display': 'dedicated Agent Desktop headless display, 1280x720',
            'fixture': fixture,
            'sink': sink,
            'live_text_observed_before_stop': true,
            'provisional_before_stop': liveBeforeStop,
            'finalized_before_stop': finalizedBeforeStop,
            'microphone_samples': counts[0],
            'playback_samples': counts[1],
            'microphone_peak_rms': peaks[0],
            'playback_peak_rms': peaks[1],
            'transcripts': transcripts,
            'summary': summary,
            'cited_answer_after_restart': answer,
            'indexed_source': source['id'],
            'inactivity_timer_finalized_silent_capture': true,
            'inactivity_test_uses_backdated_activity_timestamp': false,
            if (realInactivity) ...{
              'inactivity_setting_minutes': 5,
              'inactivity_elapsed_seconds':
                  inactivityElapsed.inMilliseconds / 1000,
              'inactivity_checkpoints': inactivityObservations,
            },
            'clear_workspace_cancel_preserved_data_and_confirm_removed_data':
                true,
            'source_folder_import_and_indexing': true,
            'find_files_selected_import_and_gpu_indexing': true,
            'find_files_existing_paths_excluded': 5,
            'find_files_unselected_file_not_imported': true,
            'semantic_graph_layout_computed_from_real_embeddings': true,
            'graph_positions_and_float32_vectors_saved': true,
            'graph_saved_coordinates_restored_after_restart': true,
            'graph_restored_coordinate_fixture':
                'Saved X coordinates multiplied by 0.75 in the disposable profile to distinguish restore from fresh PCA',
            'graph_cache_removed_with_workspace': true,
            'graph_layout_algorithm': graphLayoutAlgorithmVersion,
            'missing_vector_text_source_force_position_restored_without_dummy_vector':
                true,
            'semantic_graph_point_count': semanticGraphPointCount,
            'semantic_graph_edge_count': semanticGraphEdgeCount,
            'semantic_graph_edges_from_real_gpu_embeddings': true,
            'semantic_graph_edges_recomputed_after_restart': true,
            'semantic_graph_edge_threshold': .2,
            'graph_default_edges_hidden': true,
            'graph_node_click_selected_without_opening_source': true,
            'graph_selection_draws_only_incident_edges': true,
            'graph_inspector_close_deselected': true,
            'graph_fit_keeps_fixture_node_centers_inside_panel': true,
            'graph_mac_world_canvas_3000': true,
            'graph_mac_zoom_limits': [.015, 5],
            'graph_mac_depth_node_style_rendered': true,
            'graph_labelled_style_and_selected_caption': true,
            'graph_selected_native_capture_has_gold_ring': true,
            'graph_label_color_method':
                'Persistent document associations; seven-color palette allocator',
            'graph_label_colors_survive_restart_and_clear': true,
            'organization_label_created_with_real_embeddings': true,
            'inspector_inline_add_propagates_and_remove_is_local': true,
            'cluster_envelopes_and_label_filter_rendered': true,
            'graph_fit_keeps_cluster_envelopes_wires_and_captions_inside_panel':
                true,
            'force_position_updates_integrated': true,
            'label_add_reorganized_and_local_remove_preserved_positions': true,
            'organization_label_semantic_assignments_and_cluster_persist': true,
            'graph_original_link_dispatched_to_system_opener_stub':
                originalLinkDispatched,
            'graph_link_test_method':
                'Owned xdg-open stub captures argv; no real browser or file manager is opened',
            'source_pause_retains_and_resumes_import_queue': true,
            'stop_recording_completes_while_source_indexing_paused': true,
            'source_reimport_preserved_id_and_advanced_revision': true,
            'url_import_and_refresh_against_loopback_server': true,
            'meeting_export_contains_enhanced_notes': true,
            'reference_screen_captures': screenshotDirectory,
            'user_edit_survived_regeneration_and_restart': true,
            'citation_navigated_to_saved_meeting_source': true,
            'close_during_transcription_reopened_without_native_or_database_error':
                true,
            'limitations': [
              'Known prerecorded speech routed through private playback and virtual microphone; physical spoken microphone acceptance is separate',
            ],
          }),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
    timeout: Timeout(
      Duration(
        minutes: Platform.environment['FORESIGHT_REAL_INACTIVITY'] == '1'
            ? 10
            : 5,
      ),
    ),
  );
}
