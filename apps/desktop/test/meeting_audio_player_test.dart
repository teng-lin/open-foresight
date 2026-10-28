import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/audio_presentation.dart';
import 'package:open_foresight/features/meetings/audio_player.dart';

final class Actions implements MeetingAudioPlayerActions {
  @override
  Future<void> retryTranscription(String id) =>
      call(['retry_transcription', id]);
  @override
  Future<void> retryCompression(String id) => call(['retry_compression', id]);
  @override
  Future<void> deleteRecording(String id) async {
    calls.add(['delete', id]);
  }

  @override
  Future<void> setRetainLossless(String id, bool value) async {
    calls.add(['retain', id, value]);
  }

  final calls = <Object>[];
  Completer<void>? pending;
  bool fail = false;
  Future<void> call(Object value) async {
    calls.add(value);
    if (pending case final wait?) await wait.future;
    if (fail) throw StateError('/private/secret/audio.opus');
  }

  @override
  Future<void> play(String id) => call(['play', id]);
  @override
  Future<void> pause(String id) => call(['pause', id]);
  @override
  Future<void> seek(String id, int us) => call(['seek', id, us]);
  @override
  Future<void> seekTranscript(AudioTranscriptSeekTarget target) =>
      call(['transcript', target.transcriptId, target.playbackUs]);
  @override
  Future<void> export(
    String id,
    MeetingAudioExportFormat format, {
    required bool allowIncomplete,
  }) => call(['export', id, format, allowIncomplete]);
  @override
  Future<void> cancelExport(String id) => call(['cancel', id]);
}

AudioSessionPresentation clip({
  String id = 'session',
  MeetingAudioAvailability availability = MeetingAudioAvailability.available,
  MeetingAudioPhysicalState physical = MeetingAudioPhysicalState.idle,
  bool canExport = true,
  bool playbackSupported = true,
  bool canDeleteRecording = false,
  bool canChangeRetention = false,
  bool retainLossless = false,
  int retainedBytes = 100,
  int stagingBytes = 0,
  bool canRetryTranscription = false,
  bool canRetryCompression = false,
  List<MeetingAudioExportFormat> exportFormats = const [
    MeetingAudioExportFormat.opus,
    MeetingAudioExportFormat.mp3,
  ],
  AudioWorkPresentation compression = const AudioWorkPresentation(),
  AudioWorkPresentation export = const AudioWorkPresentation(),
  List<AudioSourceProcessingPresentation> sources = const [],
  String captureError = '',
  int durationUs = 65000000,
}) => AudioSessionPresentation(
  id: id,
  startedWallMs: 0,
  durationUs: durationUs,
  availability: availability,
  retainedBytes: retainedBytes,
  stagingBytes: stagingBytes,
  hasGaps: availability == MeetingAudioAvailability.partial,
  sources: sources,
  compression: compression,
  export: export,
  physicalState: physical,
  captureError: captureError,
  canExport: canExport,
  playbackSupported: playbackSupported,
  canDeleteRecording: canDeleteRecording,
  canChangeRetention: canChangeRetention,
  retainLossless: retainLossless,
  canRetryTranscription: canRetryTranscription,
  canRetryCompression: canRetryCompression,
  exportFormats: exportFormats,
);

Future<void> show(
  WidgetTester tester,
  Actions actions, {
  AudioSessionPresentation? session,
  AudioPlaybackPresentation playback = const AudioPlaybackPresentation(),
  AudioTranscriptSeekTarget? target,
  double scale = 1,
  bool scrollable = false,
  bool playbackOnly = false,
}) {
  final player = SizedBox(
    width: 500,
    child: MeetingAudioPlayer(
      session: session ?? clip(),
      playback: playback,
      actions: actions,
      transcriptTarget: target,
      playbackOnly: playbackOnly,
    ),
  );
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          // Production hosts the player in the meeting's sliver scroll view.
          child: scrollable ? SingleChildScrollView(child: player) : player,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('live chunk processing does not shift the recording player', (
    tester,
  ) async {
    final actions = Actions();
    await show(
      tester,
      actions,
      session: clip(physical: MeetingAudioPhysicalState.recording),
    );
    final height = tester.getSize(find.byType(MeetingAudioPlayer)).height;
    await show(
      tester,
      actions,
      session: clip(
        physical: MeetingAudioPhysicalState.recording,
        sources: const [
          AudioSourceProcessingPresentation(
            source: MeetingAudioSource.microphone,
            pendingDurationUs: 5000000,
            pendingJobs: 1,
          ),
        ],
        compression: const AudioWorkPresentation(pending: 1),
      ),
    );
    expect(find.text('Saving space in the background…'), findsNothing);
    expect(find.textContaining('transcription is catching up'), findsNothing);
    expect(tester.getSize(find.byType(MeetingAudioPlayer)).height, height);
    await show(
      tester,
      actions,
      session: clip(
        physical: MeetingAudioPhysicalState.recording,
        compression: const AudioWorkPresentation(
          state: MeetingAudioWorkState.failed,
        ),
        captureError: 'fixture capture failure',
      ),
    );
    expect(
      find.text('Audio compression needs attention. Available audio is kept.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Recording stopped unexpectedly'),
      findsOneWidget,
    );
  });

  testWidgets('storage distinguishes saved audio from additional copies', (
    tester,
  ) async {
    await show(
      tester,
      Actions(),
      session: clip(retainedBytes: 12500000, stagingBytes: 2500000),
    );
    expect(find.text('Recording storage: 15 MB'), findsOneWidget);
    expect(
      find.text('12.5 MB saved audio · 2.5 MB additional copies'),
      findsOneWidget,
    );
  });

  testWidgets('save menu discloses re-encoding and keeps format admission', (
    tester,
  ) async {
    final actions = Actions();
    await show(tester, actions);
    await tester.tap(find.text('Save audio'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Saving re-encodes audio. Already compressed audio may lose some quality.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Opus · smaller file'));
    await tester.pumpAndSettle();
    expect(actions.calls, [
      ['export', 'session', MeetingAudioExportFormat.opus, false],
    ]);
  });

  testWidgets(
    'storage and save disclosure stay accessible at narrow large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        final actions = Actions();
        await show(
          tester,
          actions,
          session: clip(
            retainedBytes: 1000000000000,
            stagingBytes: 500000000000,
            canChangeRetention: true,
            retainLossless: true,
          ),
          scale: 2,
          scrollable: true,
        );
        expect(find.text('Recording storage: 1.5 TB'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('Recording storage: 1.5 TB')),
          findsOneWidget,
        );
        expect(find.text('Keep remaining originals'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Save audio'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save audio'));
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp('Saving re-encodes audio')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('MP3'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(actions.calls, [
          ['export', 'session', MeetingAudioExportFormat.mp3, false],
        ]);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'one retry action per failed processing group and service authority',
    (tester) async {
      final actions = Actions();
      await show(
        tester,
        actions,
        session: clip(
          canRetryTranscription: true,
          canRetryCompression: true,
          sources: const [
            AudioSourceProcessingPresentation(
              source: MeetingAudioSource.microphone,
              pendingDurationUs: 1000000,
              pendingJobs: 1,
              failedJobs: 1,
              error: 'missing_model',
            ),
            AudioSourceProcessingPresentation(
              source: MeetingAudioSource.playback,
              pendingDurationUs: 1000000,
              pendingJobs: 1,
              failedJobs: 1,
              error: 'worker_exit',
            ),
          ],
          compression: const AudioWorkPresentation(
            state: MeetingAudioWorkState.failed,
            failed: 2,
          ),
        ),
      );
      expect(find.text('Retry transcription'), findsOneWidget);
      expect(find.text('Retry compression'), findsOneWidget);
      await tester.tap(find.text('Retry transcription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry compression'));
      await tester.pumpAndSettle();
      expect(actions.calls, [
        ['retry_transcription', 'session'],
        ['retry_compression', 'session'],
      ]);
      await show(
        tester,
        actions,
        session: clip(
          compression: const AudioWorkPresentation(
            state: MeetingAudioWorkState.failed,
            failed: 1,
          ),
        ),
      );
      expect(find.text('Retry transcription'), findsNothing);
      expect(find.text('Retry compression'), findsNothing);
    },
  );
  testWidgets(
    'retry failure is visible without replacing processing status or leaking paths',
    (tester) async {
      final actions = Actions()..fail = true;
      await show(tester, actions, session: clip(canRetryTranscription: true));
      await tester.tap(find.text('Retry transcription'));
      await tester.pumpAndSettle();
      expect(
        find.text('Couldn’t retry transcription. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('/private/secret'), findsNothing);
      expect(find.text('Retry transcription'), findsOneWidget);
    },
  );

  testWidgets(
    'preparing, unavailable and background states retain distinct labels',
    (tester) async {
      final actions = Actions();
      await show(
        tester,
        actions,
        session: clip(
          availability: MeetingAudioAvailability.pending,
          physical: MeetingAudioPhysicalState.starting,
          canExport: false,
        ),
      );
      expect(find.text('Starting recording…'), findsOneWidget);
      expect(find.text('Preparing your recording…'), findsOneWidget);
      await show(
        tester,
        actions,
        session: clip(
          availability: MeetingAudioAvailability.none,
          physical: MeetingAudioPhysicalState.pausing,
        ),
      );
      expect(find.text('Pausing recording…'), findsOneWidget);
      expect(find.text('No saved audio yet.'), findsOneWidget);
      await show(
        tester,
        actions,
        session: clip(
          physical: MeetingAudioPhysicalState.stopping,
          captureError: 'restored_without_audio',
          sources: const [
            AudioSourceProcessingPresentation(
              source: MeetingAudioSource.playback,
              pendingDurationUs: 0,
              pendingJobs: 1,
              error: 'internal path',
            ),
          ],
          compression: const AudioWorkPresentation(pending: 1),
          export: const AudioWorkPresentation(
            state: MeetingAudioWorkState.complete,
          ),
        ),
        playback: const AudioPlaybackPresentation(
          state: MeetingAudioPlaybackState.failed,
          error: 'internal path',
        ),
      );
      expect(find.text('Finishing recording…'), findsOneWidget);
      expect(
        find.text('Audio is unavailable after restoring this meeting.'),
        findsOneWidget,
      );
      expect(
        find.text('System audio transcription needs attention.'),
        findsOneWidget,
      );
      expect(find.text('Saving space in the background…'), findsOneWidget);
      expect(find.text('Audio file saved.'), findsOneWidget);
      expect(find.textContaining('internal path'), findsNothing);
      await show(
        tester,
        actions,
        session: clip(
          export: const AudioWorkPresentation(
            state: MeetingAudioWorkState.failed,
          ),
        ),
      );
      expect(
        find.text('Couldn’t save the audio file. Try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('disposing during a command safely ignores its completion', (
    tester,
  ) async {
    final actions = Actions()..pending = Completer<void>();
    await show(tester, actions);
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    actions.pending!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved silence offers accessible playback without transcript', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final actions = Actions();
    await show(tester, actions);
    expect(find.text('Saved recording'), findsOneWidget);
    expect(find.byTooltip('Play audio'), findsOneWidget);
    expect(find.text('0:00 / 1:05'), findsOneWidget);
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    expect(actions.calls, [
      ['play', 'session'],
    ]);
    expect(
      tester.getSemantics(find.byType(Slider)),
      matchesSemantics(
        hasEnabledState: true,
        isEnabled: true,
        isSlider: true,
        isFocusable: true,
        hasFocusAction: true,
        label: '0:00',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
        value: '0:00 of 1:05',
        increasedValue: '0:03 of 1:05',
        decreasedValue: '0:00 of 1:05',
        textDirection: TextDirection.ltr,
      ),
    );
    semantics.dispose();
  });

  testWidgets(
    'pause and drag-to-seek use source-independent playback offsets',
    (tester) async {
      final actions = Actions();
      await show(
        tester,
        actions,
        playback: const AudioPlaybackPresentation(
          state: MeetingAudioPlaybackState.playing,
          positionUs: 1000000,
        ),
      );
      await tester.tap(find.byTooltip('Pause audio'));
      await tester.pump();
      expect(actions.calls.single, ['pause', 'session']);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(32000000);
      await tester.pump();
      expect(find.text('0:32 / 1:05'), findsOneWidget);
      slider.onChangeEnd!(32000000);
      await tester.pump();
      expect(actions.calls.last, ['seek', 'session', 32000000]);
    },
  );

  testWidgets('missing audio disables playback, seeking and export', (
    tester,
  ) async {
    final actions = Actions();
    await show(
      tester,
      actions,
      session: clip(
        availability: MeetingAudioAvailability.missing,
        canExport: false,
      ),
    );
    expect(find.text('This recording’s audio is unavailable.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(
      tester
          .widget<PopupMenuButton<MeetingAudioExportFormat>>(
            find.byType(PopupMenuButton<MeetingAudioExportFormat>),
          )
          .enabled,
      false,
    );
    expect(actions.calls, isEmpty);
  });

  testWidgets(
    'partial export is visibly explicit and carries incomplete consent',
    (tester) async {
      final actions = Actions();
      await show(
        tester,
        actions,
        session: clip(availability: MeetingAudioAvailability.partial),
      );
      expect(
        find.text(
          'Some audio is unavailable. You can listen to the available parts.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Save available audio'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Saving re-encodes audio. Already compressed audio may lose some quality.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Available audio · MP3'));
      await tester.pumpAndSettle();
      expect(actions.calls, [
        ['export', 'session', MeetingAudioExportFormat.mp3, true],
      ]);
    },
  );

  testWidgets(
    'unverified playback hides player controls while verified export stays usable',
    (tester) async {
      final actions = Actions();
      await show(tester, actions, session: clip(playbackSupported: false));
      expect(
        find.text('Audio playback is unavailable in this app session.'),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.byTooltip('Play audio'), findsNothing);
      await tester.tap(find.text('Save audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MP3'));
      await tester.pumpAndSettle();
      expect(actions.calls, [
        ['export', 'session', MeetingAudioExportFormat.mp3, false],
      ]);
    },
  );
  testWidgets('absent verified format capabilities hide saving', (
    tester,
  ) async {
    final actions = Actions();
    await show(tester, actions, session: clip(exportFormats: const []));
    expect(
      find.byType(PopupMenuButton<MeetingAudioExportFormat>),
      findsNothing,
    );
    expect(find.text('Save audio'), findsNothing);
    expect(actions.calls, isEmpty);
    expect(find.text('Delete recording'), findsNothing);
    expect(find.text('Keep remaining originals'), findsNothing);
  });

  testWidgets(
    'deletion requires confirmation and preserves transcript explanation',
    (tester) async {
      final actions = Actions();
      await show(tester, actions, session: clip(canDeleteRecording: true));
      await tester.tap(find.text('Delete recording'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This recording’s audio will be removed. Your transcript will stay available.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(actions.calls, isEmpty);
      await tester.tap(find.text('Delete recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete recording'));
      await tester.pumpAndSettle();
      expect(actions.calls, [
        ['delete', 'session'],
      ]);
    },
  );
  testWidgets(
    'confirmation for an old selection cannot delete the new recording',
    (tester) async {
      final actions = Actions();
      await show(tester, actions, session: clip(canDeleteRecording: true));
      await tester.tap(find.text('Delete recording'));
      await tester.pumpAndSettle();
      await show(
        tester,
        actions,
        session: clip(id: 'new-session', canDeleteRecording: true),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete recording'));
      await tester.pumpAndSettle();
      expect(actions.calls, isEmpty);
    },
  );
  testWidgets('live playback bar omits activity and retains command errors', (
    tester,
  ) async {
    final actions = Actions()..fail = true;
    await show(
      tester,
      actions,
      playbackOnly: true,
      session: clip(
        canChangeRetention: true,
        compression: const AudioWorkPresentation(pending: 1),
      ),
    );
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Saved recording'), findsNothing);
    expect(find.text('Saving space in the background…'), findsNothing);
    expect(find.textContaining('Recording storage'), findsNothing);
    expect(find.text('Keep remaining originals'), findsNothing);
    expect(find.text('Save audio'), findsNothing);
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    expect(
      find.text('Couldn’t play this recording. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'remaining-originals switch is hidden for every saved preference',
    (tester) async {
      final actions = Actions();
      for (final retain in [false, true]) {
        await show(
          tester,
          actions,
          session: clip(canChangeRetention: true, retainLossless: retain),
        );
        expect(find.text('Keep remaining originals'), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
        expect(find.byTooltip('Play audio'), findsOneWidget);
        expect(actions.calls, isEmpty);
      }
    },
  );
  testWidgets('whole export keeps incomplete admission false', (tester) async {
    final actions = Actions();
    await show(tester, actions);
    await tester.tap(find.text('Save audio'));
    await tester.pumpAndSettle();
    expect(find.text('WAV'), findsNothing);
    await tester.tap(find.text('Opus · smaller file'));
    await tester.pumpAndSettle();
    expect(actions.calls, [
      ['export', 'session', MeetingAudioExportFormat.opus, false],
    ]);
  });

  testWidgets(
    'only matching validated transcript targets enable listen action',
    (tester) async {
      final actions = Actions();
      const target = AudioTranscriptSeekTarget(
        transcriptId: 1,
        sessionId: 'session',
        playbackUs: 500000,
      );
      await show(tester, actions, target: target);
      await tester.tap(find.text('Listen to selected text'));
      await tester.pump();
      expect(actions.calls.single, ['transcript', 1, 500000]);
      await show(
        tester,
        actions,
        target: const AudioTranscriptSeekTarget(
          transcriptId: 1,
          sessionId: 'old',
          playbackUs: 500000,
        ),
      );
      expect(
        tester
            .widget<TextButton>(
              find
                  .ancestor(
                    of: find.text('Listen to selected text'),
                    matching: find.byWidgetPredicate((w) => w is TextButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'old transcription backlog stays saved while failure states remain separate',
    (tester) async {
      final actions = Actions();
      await show(
        tester,
        actions,
        session: clip(
          captureError: 'capture stopped',
          sources: const [
            AudioSourceProcessingPresentation(
              source: MeetingAudioSource.microphone,
              pendingDurationUs: 120000000,
              pendingJobs: 9,
            ),
          ],
          compression: const AudioWorkPresentation(
            state: MeetingAudioWorkState.failed,
            failed: 1,
          ),
          export: const AudioWorkPresentation(
            state: MeetingAudioWorkState.running,
            running: 1,
          ),
        ),
      );
      expect(find.text('Saved recording'), findsOneWidget);
      expect(
        find.text('Microphone transcription is catching up: 2:00.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Recording stopped unexpectedly. Your saved audio is still shown here.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Audio compression needs attention. Available audio is kept.',
        ),
        findsOneWidget,
      );
      expect(find.text('Saving audio…'), findsOneWidget);
      await tester.tap(find.text('Cancel save'));
      await tester.pump();
      expect(actions.calls.single, ['cancel', 'session']);
    },
  );

  testWidgets('async errors are user-safe and old clip completion is fenced', (
    tester,
  ) async {
    final actions = Actions()
      ..pending = Completer<void>()
      ..fail = true;
    await show(tester, actions);
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await show(tester, actions, session: clip(id: 'new'));
    actions.pending!.complete();
    await tester.pump();
    expect(find.textContaining('Couldn’t'), findsNothing);
    actions.pending = null;
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    expect(
      find.text('Couldn’t play this recording. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('/private'), findsNothing);
  });

  testWidgets(
    'compact controls tolerate larger text and long recording clocks',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(
        tester,
        Actions(),
        session: clip(
          durationUs: 10800000000,
          physical: MeetingAudioPhysicalState.paused,
        ),
        playback: const AudioPlaybackPresentation(positionUs: 99999999999),
        scale: 1.5,
      );
      expect(find.text('Recording paused'), findsOneWidget);
      expect(find.text('3:00:00 / 3:00:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
