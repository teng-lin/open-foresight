import 'package:open_foresight/features/sources/source_painters.dart';
import 'package:foresight_test_support/macos_integration_runtime.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/remote.dart' show RemoteDomain;
import 'dart:convert';
import 'dart:async';
import '../test_support/current_read.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:foresight_test_support/capture_poll.dart';
import 'package:foresight_test_support/capture_process.dart';
import 'package:open_foresight/main.dart' as app;
import 'package:open_foresight/features/onboarding/onboarding_view.dart';
import 'package:foresight_core/desktop.dart';
import '../test_support/integration_persistence.dart';
import 'package:open_foresight/features/sources/graph_rendering.dart';
import 'package:open_foresight/features/sources/cluster_rendering.dart';

import '../test_support/meeting_panel.dart';
import '../test_support/file_manager_fixture.dart';
import '../test_support/onboarding.dart';

StoreReader readerFor(app.WorkspaceTestAccess workspace) => (workspace.d).store;
Future<List<Map<String, Object?>>> sourceRows(StoreReader reader) async {
  final sources = await currentRead(reader, StoreReadQueries.sources());
  final rows = <Map<String, Object?>>[];
  for (final source in sources) {
    final document = await currentRead(
      reader,
      StoreReadQueries.source(source.id),
    );
    if (document == null || document.revision != source.revision) {
      throw const IntegrationReadPending('source selection changed');
    }
    rows.add({...source.toRow(), ...document.toRow()});
  }
  return rows;
}

Future<void> waitUntil(
  WidgetTester tester,
  FutureOr<bool> Function() ready, {
  int seconds = 60,
  String reason = 'Workflow timed out',
}) async {
  final elapsed = Stopwatch()..start();
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  var settled = await currentReadCondition(ready, deadline: deadline);
  while (!settled && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    settled = await currentReadCondition(ready, deadline: deadline);
  }
  if (!settled) {
    final report = Platform.environment['FORESIGHT_MEETING_REPORT'];
    if (report != null) {
      File(
        '$report.widget-tree.txt',
      ).writeAsStringSync(tester.allElements.first.toStringDeep());
    }
    final workspaces = find.byType(app.Workspace);
    if (workspaces.evaluate().isNotEmpty) {
      final workspace = tester.state(workspaces) as app.WorkspaceTestAccess;
      // Capture before the status RPC: pending work can finish while that
      // request runs, making a post-failure database artifact look successful.
      final observedAt = DateTime.now().toUtc().toIso8601String();
      final waitedMs = elapsed.elapsedMilliseconds;
      final sourceResult = await readerFor(
        workspace,
      ).read(StoreReadQueries.sources());
      final sources = (sourceResult.value?.toList() ?? <SourceSummary>[])
        ..sort((a, b) => a.id.compareTo(b.id));
      final observedSources = [
        for (final source in sources)
          {
            'id': source.id,
            'state': source.state,
            'error': source.error,
            'revision': source.revision,
          },
      ];
      final status = await workspace.d.command(Operation.status);
      fail(
        '$reason: busy=${workspace.busy}, error=${workspace.error}, '
        'waited_ms=$waitedMs, observed_at=$observedAt, sources=$observedSources, '
        'sources_freshness=${sourceResult.freshness.name}, source_error=${sourceResult.error}, '
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

/// Observe readiness under one existing workflow deadline. Retry only the
/// fixture's noncurrent read signal; operation and query errors still fail.
Future<T> observeCurrent<T>(
  WidgetTester tester,
  Future<T> Function() read,
) async {
  late T value;
  await waitUntil(tester, () async {
    value = await read();
    return true;
  }, reason: 'Current integration read did not settle');
  return value;
}

/// Desktop startup connects the service before it mounts [app.Workspace].
/// One frame is still the "Starting…" screen, so a state lookup there throws
/// "Bad state: No element" and hides the real connection error.
Future<app.WorkspaceTestAccess> startedWorkspace(WidgetTester tester) async {
  await app.main();
  String? startupFailure;
  await waitUntil(tester, () async {
    if (find.text('Open Foresight could not start').evaluate().isNotEmpty) {
      final details = find.byType(SelectableText);
      startupFailure = details.evaluate().isEmpty
          ? 'unknown startup failure'
          : tester.widget<SelectableText>(details).data;
      return true;
    }
    // Workspace mounts before its asynchronous onboarding preferences load.
    // Keep the same startup deadline while waiting for the actual first screen.
    return find.byType(app.Workspace).evaluate().isNotEmpty &&
        (find.byType(OnboardingView).evaluate().isNotEmpty ||
            find.text('Meetings').evaluate().isNotEmpty);
  });
  if (startupFailure != null) {
    throw StateError('Desktop did not start: $startupFailure');
  }
  await finishOnboarding(tester);
  return tester.state(find.byType(app.Workspace)) as app.WorkspaceTestAccess;
}

/// Unmount first so disposal owns the pending note save and recording stop.
/// Join its existing cleanup work instead of guessing when the next launch is safe.
Future<void> closeWorkspace(
  WidgetTester tester,
  app.WorkspaceTestAccess workspace,
) async {
  final saves = workspace.meetingFeature.meetingNoteSaves;
  final connection = workspace.d as RemoteDomain;
  final client = connection.client;
  final commands = workspace.integrationFeature.commands;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() async {
    try {
      await saves.close().timeout(const Duration(seconds: 30));
    } finally {
      connection.close();
      await connection.closed.timeout(const Duration(seconds: 30));
    }
  });
  await waitUntil(
    tester,
    () async =>
        client.isClosed && (commands == null || commands.isClosed == true),
    reason: 'Desktop disposal did not release the client and activation lock',
  );
}

/// External recording requests still require a desktop approval decision.
Future<void> allowRecording(WidgetTester tester) async {
  await waitUntil(
    tester,
    () async => find
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
  final env = Platform.environment;
  final privateX11 = env['FORESIGHT_PRIVATE_X11'];
  // Older widget-only invocations still have no native display to capture.
  if (env['FORESIGHT_PRIVATE_PIPEWIRE'] == '1' && privateX11 == null) return;
  await tester.runAsync(() async {
    final target = File(path);
    final pending = File('$path.capture.png');
    target.parent.createSync(recursive: true);
    final session =
        Platform.environment['FORESIGHT_AGENT_DESKTOP_SESSION'] ?? '';
    final display = Platform.environment['WAYLAND_DISPLAY'] ?? '';
    final ownedX11 =
        privateX11 != null &&
        RegExp(r'^:\d+$').hasMatch(privateX11) &&
        env['DISPLAY'] == privateX11 &&
        env['GDK_BACKEND'] == 'x11' &&
        env['FORESIGHT_PRIVATE_PIPEWIRE'] == '1';
    final ownedWayland =
        RegExp(r'^[a-f0-9]{12}$').hasMatch(session) &&
        display.contains('/agent-desktop/$session/');
    if ((!ownedX11 && !ownedWayland) ||
        env.containsKey('HYPRLAND_INSTANCE_SIGNATURE')) {
      throw StateError(
        'Acceptance requires the explicitly owned private display',
      );
    }
    // A completed Flutter frame can precede its compositor presentation. Read
    // actual captures until their asserted pixels are visible, retaining the
    // latest image and measurements even when the monotonic deadline expires.
    ({List<int> gutter, int goldPixels})? lastSnapshot;
    var attempts = 0;
    try {
      final observation = await waitForCapture(
        () async {
          attempts++;
          final screenshot = ownedX11
              ? await runCaptureProcess('import', [
                  '-window',
                  'root',
                  pending.path,
                ])
              : await runCaptureProcess('grim', [pending.path]);
          if (screenshot.exitCode != 0) {
            throw StateError(
              'Cannot capture the test window: ${screenshot.stderr}',
            );
          }
          final codec = await ui.instantiateImageCodec(
            await pending.readAsBytes(),
          );
          late ui.Image image;
          try {
            image = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
          try {
            expect(image.width, 1280);
            expect(image.height, 720);
            final pixels = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            if (pixels == null)
              throw StateError('Cannot inspect capture pixels');
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
            final snapshot = (
              gutter: [
                pixels.getUint8(offset),
                pixels.getUint8(offset + 1),
                pixels.getUint8(offset + 2),
              ],
              goldPixels: goldPixels,
            );
            // A stalled or corrupt next capture must not replace the last PNG.
            await pending.rename(path);
            lastSnapshot = snapshot;
            return snapshot;
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
    } catch (error) {
      File('$path.diagnostics.json').writeAsStringSync(
        jsonEncode({
          'capture_error': error.toString(),
          'attempts': attempts,
          'last_image': target.existsSync() ? path : null,
          'pending_image': pending.existsSync() ? pending.path : null,
          'gutter': lastSnapshot?.gutter,
          'expected_gutter': expectedGutter,
          'gold_pixels': lastSnapshot?.goldPixels,
          'graph_selection_required': expectGraphSelection,
        }),
      );
      rethrow;
    }
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    prepareMacosIntegrationRuntime(registerTearDown: addTearDown);
  });
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
      final workspace = await startedWorkspace(tester);
      final receipts = IntegrationPersistenceReceipts(env['FORESIGHT_DATA']!);
      addTearDown(receipts.close);
      await waitUntil(
        tester,
        () async =>
            workspace.d.generator?.effectiveState['state'] == 'ready' &&
            workspace.d.helper.snapshot?.pipeline == 'ready',
      );
      final embeddingIdentity = workspace.d.helper.snapshot!.model;
      final embeddingBackend = embeddingIdentity.backend;
      final generationBackend =
          workspace.d.generator!.effectiveState['backend'] as String;
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
      await waitUntil(tester, () async => true);
      await captureWindow(tester, '$screenshotDirectory/06-ask.png');
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New meeting'));
      await tester.pumpAndSettle();
      final meeting = workspace.meetingFeature.meetingId as int;
      final title =
          [
                if ((await observeCurrent(
                      tester,
                      () => currentRead(
                        readerFor(workspace),
                        StoreReadQueries.meeting(meeting),
                      ),
                    ))
                    case final value?)
                  value.toRow(),
              ].single['title']
              as String;
      await waitUntil(
        tester,
        () async =>
            preparedSpeechSetupProblem(
              await currentRead(
                readerFor(workspace),
                StoreReadQueries.model('speech'),
              ),
            ) ==
            null,
        reason: 'Speech model and runner were not ready for recording',
      );
      await tester.tap(find.text('Start transcribing'));
      await tester.pump();
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsNothing,
      );
      await waitUntil(
        tester,
        () async =>
            workspace.meetingFeature.recording?.sampleCounts.length == 2 &&
            workspace.meetingFeature.recording!.sampleCounts.every(
              (int n) => n > 0,
            ),
      );
      expect(
        [
          if ((await observeCurrent(
                tester,
                () => currentRead(
                  readerFor(workspace),
                  StoreReadQueries.meeting(meeting),
                ),
              ))
              case final value?)
            value.toRow(),
        ].single['state'],
        'recording',
      );
      final player = await Process.start('pw-play', [
        '--target',
        sink,
        fixture,
      ]);
      // Completion is observed by the owning lifecycle or test fixture.
      // ignore: unawaited_futures
      player.stdout.drain<void>();
      // Completion is observed by the owning lifecycle or test fixture.
      // ignore: unawaited_futures
      player.stderr.drain<void>();
      await waitUntil(
        tester,
        () async => workspace.meetingFeature.recording!.peakVolumes[1] > 0,
      );
      expect(await player.exitCode, 0);
      await waitUntil(
        tester,
        () async =>
            workspace.meetingFeature.recording != null &&
            (workspace.meetingFeature.provisionalTranscript.values.any(
                  (text) => (text).toLowerCase().contains('country'),
                ) ||
                (await currentRead(
                      readerFor(workspace),
                      StoreReadQueries.transcript(meeting, finalOnly: true),
                    ))
                    .map((row) => row.toRow())
                    .toList()
                    .any(
                      (row) => (row['text'] as String).toLowerCase().contains(
                        'country',
                      ),
                    )),
      );
      final liveBeforeStop = Map<String, String>.from(
        workspace.meetingFeature.provisionalTranscript,
      );
      final finalizedBeforeStop =
          (await observeCurrent(
                tester,
                () => currentRead(
                  readerFor(workspace),
                  StoreReadQueries.transcript(meeting, finalOnly: true),
                ),
              ))
              .map(
                (row) => <String, Object?>{
                  'text': row.text,
                  'source': row.source,
                  'start_ms': row.startMs,
                  'end_ms': row.endMs,
                },
              )
              .toList();
      expect(workspace.meetingFeature.recording, isNotNull);
      await tester.pumpAndSettle();
      await captureWindow(
        tester,
        '$screenshotDirectory/09-live-transcription.png',
      );
      final counts = List<int>.from(
        workspace.meetingFeature.recording!.sampleCounts,
      );
      final peaks = List<double>.from(
        workspace.meetingFeature.recording!.peakVolumes,
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
      await tester.tap(find.byTooltip('Stop recording'));
      await waitUntil(
        tester,
        () async =>
            workspace.meetingFeature.recording == null &&
            workspace.busy == false,
      );
      expect(workspace.error, isEmpty);
      expect(workspace.d.sourcesPaused, true);
      expect(
        [
          if ((await observeCurrent(
                tester,
                () => currentRead(
                  readerFor(workspace),
                  StoreReadQueries.meeting(meeting),
                ),
              ))
              case final value?)
            value.toRow(),
        ].single['state'],
        'completed',
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Resume source imports and indexing'));
      await waitUntil(
        tester,
        () async =>
            [
              if ((await currentRead(
                    readerFor(workspace),
                    StoreReadQueries.source('meeting-$meeting'),
                  ))
                  case final value?)
                value.toRow(),
            ].single['state'] ==
            'indexed',
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      final transcripts = (await observeCurrent(
        tester,
        () => currentRead(
          readerFor(workspace),
          StoreReadQueries.transcript(meeting, finalOnly: true),
        ),
      )).map((row) => row.toRow()).toList();
      expect(transcripts, isNotEmpty);
      final text = transcripts.map((t) => t['text']).join('\n').toLowerCase();
      expect(text, contains('country'));
      expect(text, contains('ask not'));
      final source = [
        if ((await observeCurrent(
              tester,
              () => currentRead(
                readerFor(workspace),
                StoreReadQueries.source('meeting-$meeting'),
              ),
            ))
            case final value?)
          value.toRow(),
      ].single;
      expect(source['state'], 'indexed');
      await selectMeetingPanel(tester, 'Summary');
      await tester.tap(find.byTooltip('Generate Summary'));
      await waitUntil(tester, () async => workspace.busy == false);
      expect(workspace.error, isEmpty);
      final summary = receipts
          .artifacts(meeting: meeting)
          .map((row) => row.toRow())
          .toList()
          .single;
      expect(
        (summary['generated'] as String).toLowerCase(),
        contains('country'),
      );
      final editSummary = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == 'Edit Summary' &&
            widget.onPressed != null,
      );
      await waitUntil(
        tester,
        () => editSummary.evaluate().length == 1,
        reason: 'Generated summary did not reach the editable UI projection',
      );
      await tester.ensureVisible(editSummary);
      await tester.pumpAndSettle();
      expect(editSummary.hitTestable(), findsOneWidget);
      await tester.tap(editSummary);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'My meeting review: preserve this edit.',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();
      await selectMeetingPanel(tester, 'Summary');
      await tester.tap(find.byTooltip('Generate Summary'));
      await waitUntil(tester, () async => workspace.busy == false);
      expect(workspace.error, isEmpty);
      expect(
        receipts
            .artifacts(meeting: meeting)
            .map((row) => row.toRow())
            .toList()
            .length,
        2,
      );
      expect(
        receipts
            .artifactById(summary['id'] as int)
            .map((row) => row.toRow())
            .toList()
            .single['edited'],
        'My meeting review: preserve this edit.',
      );
      await workspace.d.command(Operation.preferencesSet, {
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
        () async => find.text('Enhance notes').evaluate().isNotEmpty,
        reason: 'Enhanced notes did not refresh after editing the draft',
      );
      await tester.ensureVisible(find.text('Enhance notes'));
      await tester.tap(find.text('Enhance notes'));
      await waitUntil(
        tester,
        () async =>
            workspace.meetingFeature.meetingEnhancing == false &&
            receipts
                .artifacts(kind: 'enhanced_notes')
                .map((row) => row.toRow())
                .toList()
                .isNotEmpty,
      );
      expect(workspace.meetingFeature.meetingEnhanceStatus, isEmpty);
      final enhanced =
          receipts
                  .artifacts(kind: 'enhanced_notes')
                  .map((row) => row.toRow())
                  .toList()
                  .last['generated']
              as String;
      expect(enhanced.toLowerCase(), contains('country'));
      // Release the actual widget/domain and launch a fresh one against the saved profile.
      await closeWorkspace(tester, workspace);
      final reopened = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () async =>
            reopened.d.generator?.effectiveState['state'] == 'ready' &&
            reopened.d.helper.snapshot?.pipeline == 'ready',
      );
      expect(
        (await observeCurrent(
          tester,
          () => currentRead(
            readerFor(reopened),
            StoreReadQueries.transcript(meeting, finalOnly: true),
          ),
        )).map((row) => row.toRow()).toList().length,
        transcripts.length,
      );
      expect(
        receipts
            .artifactById(summary['id'] as int)
            .map((row) => row.toRow())
            .toList()
            .single['edited'],
        'My meeting review: preserve this edit.',
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(title).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand meeting'));
      await tester.pumpAndSettle();
      expect(
        [
          if ((await observeCurrent(
                tester,
                () => currentRead(
                  readerFor(reopened),
                  StoreReadQueries.meetingNote(meeting),
                ),
              ))
              case final value?)
            value.toRow(),
        ].single['body'],
        'Ask what you can do for your country.',
      );
      await selectMeetingPanel(tester, 'Summary');
      final previousVersions = find.text('Previous versions');
      await waitUntil(
        tester,
        () => previousVersions.evaluate().length == 1,
        reason:
            'Saved summary versions did not reach the reopened UI projection',
      );
      await tester.ensureVisible(previousVersions);
      await tester.pumpAndSettle();
      expect(previousVersions.hitTestable(), findsOneWidget);
      await tester.tap(previousVersions);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('My meeting review: preserve this edit.'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await waitUntil(tester, () async => true);
      await captureWindow(tester, env['FORESIGHT_MEETING_SCREENSHOT']!);
      await selectMeetingPanel(tester, 'Chat');
      // This acceptance checks the recorded transcript's exact revision. Other
      // meeting outputs are valid Chat sources, so select the transcript through
      // the same source controls a user would use before asking about it.
      await selectMeetingAnswerSource(tester, source['title'] as String);
      await waitUntil(
        tester,
        () async =>
            reopened.busy == false &&
            (await currentRead(
                  readerFor(reopened),
                  StoreReadQueries.preference('answerScope.meeting:$meeting'),
                )) ==
                'selected',
      );
      expect(
        jsonDecode(
          (await observeCurrent(
            tester,
            () => currentRead(
              readerFor(reopened),
              StoreReadQueries.preference('answerSources.meeting:$meeting'),
            ),
          )),
        ),
        ['meeting-$meeting'],
      );
      await tester.enterText(
        find.byKey(ValueKey('chat-input:meeting:$meeting')),
        'What does the speaker ask Americans to do? Cite [S1].',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ask'));
      await waitUntil(
        tester,
        () async =>
            reopened.busy == false &&
            receipts.answers.map((row) => row.toRow()).toList().isNotEmpty,
      );
      expect(reopened.error, isEmpty);
      final answer = receipts.answers.map((row) => row.toRow()).toList().first;
      expect(answer['status'], 'completed', reason: answer['body'] as String);
      expect((answer['body'] as String).toLowerCase(), contains('country'));
      expect((answer['body'] as String).toLowerCase(), isNot(contains('king')));
      await tester.pumpAndSettle();
      await waitUntil(tester, () async => true);
      await captureWindow(tester, env['FORESIGHT_COPILOT_SCREENSHOT']!);
      final cited = (jsonDecode(answer['citations'] as String) as List)
          .cast<Map>();
      final transcriptCitation = cited.firstWhere(
        (citation) => citation['document_id'] == 'meeting-$meeting',
      );
      final citedRevision = transcriptCitation['revision'] as int;
      await openMeetingCitation(
        tester,
        meeting,
        citedRevision,
        citationLabel: transcriptCitation['citation'] as String,
      );
      expect(
        find.text('${source['title']} · revision $citedRevision'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      // Close the desktop while a native speech result is pending.
      // The service must finish transcription and survive reconnection.
      final savedSpeech =
          [
                if ((await observeCurrent(
                      tester,
                      () => currentRead(
                        readerFor(reopened),
                        StoreReadQueries.model('speech'),
                      ),
                    ))
                    case final value?)
                  value.toRow(),
              ].single['runtime']
              as String;
      final slowSpeech = File(
        '${env['FORESIGHT_DATA']}/speech-cancellation-runner',
      )..writeAsStringSync('#!/bin/sh\nsleep 2\nexec "$savedSpeech" "\$@"\n');
      await Process.run('chmod', ['700', slowSpeech.path]);
      final speechAsset = [
        if ((await observeCurrent(
              tester,
              () => currentRead(
                readerFor(reopened),
                StoreReadQueries.model('speech'),
              ),
            ))
            case final value?)
          value.toRow(),
      ].single['path'];
      await reopened.d.command(Operation.modelsRegister, {
        'kind': 'speech',
        'path': speechAsset,
        'runtime': slowSpeech.path,
      });
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start transcribing'));
      await tester.pump();
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsNothing,
      );
      await waitUntil(
        tester,
        () async =>
            reopened.meetingFeature.recording?.sampleCounts.length == 2 &&
            reopened.meetingFeature.recording!.sampleCounts.every(
              (int n) => n > 0,
            ),
      );
      final secondPlayer = await Process.start('pw-play', [
        '--target',
        sink,
        fixture,
      ]);
      // Completion is observed by the owning lifecycle or test fixture.
      // ignore: unawaited_futures
      secondPlayer.stdout.drain<void>();
      // Completion is observed by the owning lifecycle or test fixture.
      // ignore: unawaited_futures
      secondPlayer.stderr.drain<void>();
      expect(await secondPlayer.exitCode, 0);
      await tester.tap(find.byTooltip('Stop recording'));
      await waitUntil(
        tester,
        () async => reopened.meetingFeature.recording?.finishing == true,
      );
      await closeWorkspace(tester, reopened);
      expect(tester.takeException(), isNull);
      var afterCancellation = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () async =>
            afterCancellation.d.generator?.effectiveState['state'] == 'ready',
      );
      await waitUntil(
        tester,
        () async => afterCancellation.meetingFeature.recording == null,
      );
      expect(
        [
          if ((await observeCurrent(
                tester,
                () => currentRead(
                  readerFor(afterCancellation),
                  StoreReadQueries.meeting(meeting),
                ),
              ))
              case final value?)
            value.toRow(),
        ].single['state'],
        'completed',
      );
      await afterCancellation.d.command(Operation.modelsRegister, {
        'kind': 'speech',
        'path': speechAsset,
        'runtime': savedSpeech,
      });
      final realInactivity = env['FORESIGHT_REAL_INACTIVITY'] == '1';
      final inactivitySetting = (await observeCurrent(
        tester,
        () => currentRead(
          readerFor(afterCancellation),
          StoreReadQueries.preference('inactivity', '15'),
        ),
      ));
      final inactivityObservations = <Map<String, Object?>>[];
      await afterCancellation.d.command(Operation.preferencesSet, {
        'key': 'inactivity',
        'value': realInactivity ? '5' : '0.1',
      });
      // The opt-in path waits for production timekeeping on silent devices.
      await tester.tap(find.text('Start transcribing'));
      await tester.pump();
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsNothing,
      );
      await waitUntil(
        tester,
        () async =>
            afterCancellation.meetingFeature.recording?.sampleCounts.length ==
            2,
      );
      final silentMeeting = afterCancellation.meetingFeature.meetingId as int;
      final activityAtStart =
          afterCancellation.meetingFeature.recording!.lastAudioActivity;
      var nextCheckpoint = 60;
      await waitUntil(tester, () async {
        final elapsed = DateTime.now().difference(activityAtStart).inSeconds;
        if (realInactivity &&
            elapsed >= nextCheckpoint &&
            elapsed < 300 &&
            afterCancellation.meetingFeature.recording != null) {
          expect(
            afterCancellation.meetingFeature.recording!.lastAudioActivity,
            activityAtStart,
          );
          expect(afterCancellation.meetingFeature.recording!.finishing, false);
          inactivityObservations.add({
            'elapsed_seconds': elapsed,
            'recording_active': true,
            'activity_timestamp_unchanged': true,
            'sample_counts': List<int>.from(
              afterCancellation.meetingFeature.recording!.sampleCounts as List,
            ),
            'peak_volumes': List<double>.from(
              afterCancellation.meetingFeature.recording!.peakVolumes as List,
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
        [
          if ((await observeCurrent(
                tester,
                () => currentRead(
                  readerFor(afterCancellation),
                  StoreReadQueries.meeting(silentMeeting),
                ),
              ))
              case final value?)
            value.toRow(),
        ].single['state'],
        'empty',
      );
      await afterCancellation.d.command(Operation.preferencesSet, {
        'key': 'inactivity',
        'value': inactivitySetting,
      });
      // Test the source controls against actual extraction and helper indexing.
      // Imports intentionally reject files inside the application profile.
      final fixtures = createTestTempDirectorySync('of-meeting-imports-');
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
      final beforePauseImports = (await observeCurrent(
        tester,
        () => sourceRows(readerFor(afterCancellation)),
      )).length;
      final pausedImport = afterCancellation.run(() async {
        await afterCancellation.sourceFeature.importFolderPath(fixtures.path);
      });
      await tester.pump();
      expect(afterCancellation.busy, true);
      expect(
        (await observeCurrent(
          tester,
          () => sourceRows(readerFor(afterCancellation)),
        )).length,
        beforePauseImports,
      );
      await captureWindow(
        tester,
        '$screenshotDirectory/10-source-import-paused.png',
      );
      await tester.tap(find.byTooltip('Resume source imports and indexing'));
      await pausedImport;
      await tester.pumpAndSettle();
      expect(afterCancellation.d.sourcesPaused, false);
      expect(afterCancellation.error, isEmpty);
      final firstImported = (await observeCurrent(
        tester,
        () => sourceRows(readerFor(afterCancellation)),
      )).where((s) => s['title'] == 'Apollo planning.md').single;
      expect(firstImported['state'], 'indexed');
      File(
        '${fixtures.path}/Apollo planning.md',
      ).writeAsStringSync('Updated acceptance fixture: the review is Monday.');
      await afterCancellation.run(
        afterCancellation.sourceFeature.refreshSources,
      );
      final revised = (await observeCurrent(
        tester,
        () => sourceRows(readerFor(afterCancellation)),
      )).where((s) => s['id'] == firstImported['id']).single;
      expect(revised['revision'], 2);
      expect(revised['content'], contains('Monday'));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var page = 'URL acceptance fixture: the review is Tuesday.';
      final subscription = server.listen((request) {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<html><script>hidden script</script><p>$page</p></html>',
        );
        // The callback intentionally schedules work owned by its controller.
        // ignore: discarded_futures
        request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}/notes';
      try {
        await afterCancellation.run(() async {
          await afterCancellation.d.command(Operation.sourcesImportUrl, {
            'url': address,
            'allow_private_network': true,
          });
        });
        expect(afterCancellation.error, isEmpty);
        page = 'URL acceptance fixture: the review is Wednesday.';
        await afterCancellation.run(() async {
          await afterCancellation.d.command(Operation.sourcesRefresh, {
            'allow_private_network': true,
          });
        });
        final imported = (await observeCurrent(
          tester,
          () => sourceRows(readerFor(afterCancellation)),
        )).where((s) => s['provenance'] == 'url:$address').single;
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
        () async => find.text('Discovered review.md').evaluate().isNotEmpty,
      );
      expect(find.text('2 files found · 5 already imported'), findsOneWidget);
      await tester.tap(find.text('Discovered review.md'));
      // The busy indicator keeps animating; render one frame and let the
      // screenshot pixel deadline observe compositor presentation.
      await tester.pump();
      await captureWindow(
        tester,
        '$screenshotDirectory/11-find-files-selection.png',
        expectedGutter: const [107, 109, 113],
      );
      await tester.tap(find.text('Import selected (1)'));
      await finding;
      await tester.pumpAndSettle();
      expect(afterCancellation.error, isEmpty);
      final discovered = (await observeCurrent(
        tester,
        () => sourceRows(readerFor(afterCancellation)),
      )).where((source) => source['title'] == 'Discovered review.md').single;
      expect(discovered['state'], 'indexed');
      expect(discovered['content'], contains('Thursday'));
      expect(
        (await observeCurrent(
          tester,
          () => sourceRows(readerFor(afterCancellation)),
        )).where((source) => source['title'] == 'Unselected budget.txt'),
        isEmpty,
      );
      final exportedNotes = (await observeCurrent(
        tester,
        () => currentRead(
          readerFor(afterCancellation),
          StoreReadQueries.enhancedNotes(meeting),
        ),
      ));
      expect(exportedNotes, isNotEmpty);
      expect(
        await afterCancellation.meetingFeature.exportMeetingMarkdown(),
        contains(exportedNotes.trim()),
      );
      for (final name in ['Stats', 'Sources']) {
        await tester.tap(find.text(name).first);
        await tester.pumpAndSettle();
        await waitUntil(tester, () async => true);
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
      seedMissingGraphVector(env['FORESIGHT_DATA']!, unindexedGraphSource);
      final labelledSources = (await observeCurrent(
        tester,
        () => sourceRows(readerFor(afterCancellation)),
      ));
      await afterCancellation.d.command(Operation.labelsSet, {
        'id': labelledSources[0]['id'],
        'labels': ['Planning'],
      });
      await afterCancellation.d.command(Operation.labelsSet, {
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
        () async =>
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
          afterCancellation.sourceFeature.graphPoints.length;
      final semanticGraphEdgeCount =
          afterCancellation.sourceFeature.graphEdges.length;
      expect(semanticGraphEdgeCount, greaterThan(0));
      final expectedGraphEdges = <String, double>{};
      for (final edge in afterCancellation.sourceFeature.graphEdges) {
        expect(edge.source.compareTo(edge.target), lessThan(0));
        expect(edge.similarity, greaterThanOrEqualTo(.2));
        expect(edge.similarity.isFinite, true);
        expectedGraphEdges[jsonEncode([edge.source, edge.target])] =
            edge.similarity;
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
      final unselectedLinks =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('source-graph-links')),
                  )
                  .painter
              as SourceLinks;
      expect(unselectedLinks.edges, isEmpty);
      final persistedLayoutIdentity =
          (jsonDecode(
                receipts.graphModelIdentities
                        .map(
                          (identity) => <String, Object?>{
                            'model_identity': identity,
                          },
                        )
                        .toList()
                        .single['model_identity']
                    as String,
              )
              as List);
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
          () async => !afterCancellation.sourceFeature.graphRelatedLoading,
        );
        final id = afterCancellation.sourceFeature.graphSelectedDocument;
        if (id == null) continue;
        final rows = (await observeCurrent(
          tester,
          () => sourceRows(readerFor(afterCancellation)),
        ));
        selectedUri =
            rows.singleWhere((row) => row['id'] == id)['source_uri'] as String;
        if (Uri.tryParse(selectedUri)?.scheme == 'file' &&
            (afterCancellation.sourceFeature.graphSelectionEdges as List)
                .isNotEmpty)
          break;
      }
      expect(
        selectedUri,
        isNotEmpty,
        reason: 'A real imported source must expose its original URI',
      );
      expect(Uri.parse(selectedUri).scheme, 'file');
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
        final dispatch = File(env['FORESIGHT_LINK_OPEN_REPORT']!);
        if (dispatch.existsSync()) dispatch.deleteSync();
        final fileManager = FileManagerRevealSpy(dispatch);
        await fileManager.start(
          isolated:
              env['FORESIGHT_PRIVATE_PIPEWIRE'] == '1' ||
              env['FORESIGHT_AGENT_DESKTOP_SESSION'] != null,
        );
        try {
          await tester.tap(find.byKey(const ValueKey('graph-inspector-link')));
          await tester.pump();
          await waitUntil(
            tester,
            () async => dispatch.existsSync(),
            reason:
                'Original source was not revealed through FileManager1.ShowItems',
          );
          final observed = jsonDecode(dispatch.readAsStringSync()) as Map;
          final revealed = List<String>.from(observed.remove('uris') as List);
          expect(revealed, hasLength(1));
          expect(
            Uri.parse(revealed.single).toFilePath(),
            Uri.parse(selectedUri).toFilePath(),
          );
          expect(observed, {
            'interface': 'org.freedesktop.FileManager1',
            'path': '/org/freedesktop/FileManager1',
            'method': 'ShowItems',
            'startup_id': '',
          });
          originalLinkDispatched = true;
        } finally {
          await fileManager.close();
        }
      }
      final selectedLinks =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('source-graph-links')),
                  )
                  .painter
              as SourceLinks;
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
        for (final entry in afterCancellation.sourceFeature.graphPoints.entries)
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
        () async =>
            !afterCancellation.busy &&
            receipts
                .labels(document: selectedDocument, name: 'Inspector fixture')
                .isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(afterCancellation.error, isEmpty);
      expect(afterCancellation.sourceFeature.graphLabelInput.text, isEmpty);
      expect(
        afterCancellation.sourceFeature.graphPoints.entries.any(
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
      final beforeLocalRemoval = receipts.graphPositions;
      final propagatedInline = receipts.labels(
        excludingDocument: selectedDocument,
        name: 'Inspector fixture',
      );
      expect(propagatedInline, isNotEmpty);
      await tester.tap(
        find.byKey(const ValueKey('inspector-remove-Inspector fixture')),
      );
      await tester.pumpAndSettle();
      expect(receipts.graphPositions, beforeLocalRemoval);
      expect(
        receipts.labels(document: selectedDocument, name: 'Inspector fixture'),
        isEmpty,
      );
      expect(
        receipts.labels(
          excludingDocument: selectedDocument,
          name: 'Inspector fixture',
        ),
        propagatedInline,
      );
      await tester.tap(find.byKey(const ValueKey('graph-inspector-close')));
      await tester.pumpAndSettle();
      expect(afterCancellation.sourceFeature.graphSelectedDocument, isNull);
      expect(find.byKey(const ValueKey('graph-inspector')), findsNothing);
      await waitUntil(tester, () async => !afterCancellation.busy);
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
        () async =>
            !afterCancellation.busy && receipts.clusters('Apollo').isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(afterCancellation.error, isEmpty);
      final organizationRows = receipts.labels(name: 'Apollo');
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
        receipts.clusters('Apollo').single['radius'],
        greaterThanOrEqualTo(90),
      );
      await tester.tap(find.text('Add source'));
      await tester.pumpAndSettle();
      await waitUntil(tester, () async => true);
      await captureWindow(
        tester,
        '$screenshotDirectory/04-add-source-menu.png',
      );
      await tester.tapAt(const Offset(200, 100));
      await tester.pumpAndSettle();
      final expectedClusters = receipts.clusters();
      final expectedLabels = receipts.labels();
      final savedGraphRows = receipts.graphEmbeddingReceipts;
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
      final snapshotReader = readerFor(afterCancellation);
      final graphObservation = await observeCurrent(tester, () async {
        final sources = await sourceRows(snapshotReader);
        final summaries = await currentRead(
          snapshotReader,
          StoreReadQueries.sources(),
        );
        final labels = await currentRead(
          snapshotReader,
          StoreReadQueries.graphLabelSet(),
        );
        final result = await snapshotReader.read(
          StoreReadQueries.graphLayout(
            sources: summaries,
            labelSet: labels,
            helperIdentity: 'integration-registered-receipt',
          ),
        );
        if (result.error != null) throw result.error!;
        if (!result.current) {
          throw const IntegrationReadPending('graph layout');
        }
        return (sources: sources, labels: labels, result: result);
      });
      final snapshotSources = graphObservation.sources;
      final snapshotResult = graphObservation.result;
      expect(snapshotResult.error, isNull);
      final snapshot = snapshotResult.value!;
      final adjusted = snapshot.points.map(
        (k, v) => MapEntry(k, GraphPoint(v.x * .75, v.y, v.z)),
      );
      expect(
        await afterCancellation.d.command(Operation.graphSave, {
          'identity': snapshot.identity,
          'sources': graphSceneSources(snapshotSources, snapshot.vectors),
          'vectors': snapshot.vectors,
          'points': adjusted.map((k, v) => MapEntry(k, [v.x, v.y, v.z])),
          'labelSet': graphObservation.labels,
          'clusters': receipts.clusters(),
        }),
        true,
      );
      final expectedGraph = {
        for (final row in receipts.graphPositions)
          row['document_id']: [row['proj_x'], row['proj_y'], row['proj_z']],
      };
      await closeWorkspace(tester, afterCancellation);
      afterCancellation = await startedWorkspace(tester);
      await waitUntil(
        tester,
        () async =>
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
        () async =>
            !afterCancellation.sourceFeature.graphOrganizing &&
            afterCancellation.sourceFeature.graphPoints.length ==
                expectedGraph.length,
      );
      expect(afterCancellation.sourceFeature.graphLayoutError, isEmpty);
      expect(receipts.labels(), expectedLabels);
      expect(receipts.clusters(), expectedClusters);
      for (final entry in expectedGraph.entries) {
        final point = afterCancellation.sourceFeature.graphPoints[entry.key]!;
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
      await waitUntil(tester, () async => true);
      await captureWindow(tester, '$screenshotDirectory/05-meetings.png');
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await waitUntil(tester, () async => true);
      await captureWindow(tester, '$screenshotDirectory/07-settings.png');
      await tester.ensureVisible(find.text('Version'));
      await tester.pumpAndSettle();
      await waitUntil(tester, () async => true);
      await captureWindow(tester, '$screenshotDirectory/08-settings-lower.png');
      // The destructive action is exercised only in this disposable test profile.
      await tester.ensureVisible(find.text('Clear workspace data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear workspace data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        (await observeCurrent(
          tester,
          () => sourceRows(readerFor(afterCancellation)),
        )),
        isNotEmpty,
      );
      await tester.tap(find.text('Clear workspace data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete workspace'));
      await waitUntil(tester, () async => afterCancellation.busy == false);
      expect(afterCancellation.error, isEmpty);
      expect(
        (await observeCurrent(
          tester,
          () => sourceRows(readerFor(afterCancellation)),
        )),
        isEmpty,
      );
      expect(receipts.graphDocuments, isEmpty);
      expect(receipts.graphLayouts, isEmpty);
      expect(receipts.labels(), isEmpty);
      expect(receipts.graphForceState, isEmpty);
      expect(receipts.clusters(), isEmpty);
      expect(
        (await observeCurrent(
          tester,
          () => currentRead(
            readerFor(afterCancellation),
            StoreReadQueries.meetings(),
          ),
        )),
        isEmpty,
      );
      expect(receipts.answers.map((row) => row.toRow()).toList(), isEmpty);
      expect(
        (await observeCurrent(
          tester,
          () => currentRead(
            readerFor(afterCancellation),
            StoreReadQueries.models(),
          ),
        )).length,
        3,
      );
      final report = env['FORESIGHT_MEETING_REPORT'];
      if (report != null) {
        File(report).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'workflow':
                'Real Linux Flutter UI + real PipeWire loopback + Whisper + $embeddingBackend + $generationBackend',
            'embedding_dimensions': embeddingIdentity.dimensions,
            'embedding_model_digest': embeddingIdentity.modelDigest,
            'embedding_preprocessing': embeddingIdentity.preprocessing,
            'display': env['FORESIGHT_PRIVATE_X11'] != null
                ? 'owned Xvfb display, 1280x720; compiled Linux desktop'
                : 'dedicated Agent Desktop headless display, 1280x720',
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
            'graph_selected_native_capture_has_gold_ring':
                env['FORESIGHT_PRIVATE_X11'] != null ||
                env['FORESIGHT_PRIVATE_PIPEWIRE'] != '1',
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
            'graph_original_link_revealed_through_file_manager':
                originalLinkDispatched,
            'graph_link_test_method':
                'Real absolute dbus-send dispatch to an owned FileManager1.ShowItems receiver on the private session bus',
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
      await closeWorkspace(tester, afterCancellation);
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
