import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/audio_presentation.dart';
import 'package:open_foresight/app_theme.dart';
import 'package:open_foresight/features/meetings/audio_player.dart';
import 'package:open_foresight/features/meetings/meeting_visuals.dart';
import 'package:open_foresight/features/meetings/notes_widgets.dart';
import 'package:open_foresight/features/meetings/workspace_view.dart';

import 'meeting_audio_player_test.dart' as audio_fixture show Actions, clip;

void main() {
  for (final scale in [1.0, 1.5]) {
    for (final size in [const Size(900, 500), const Size(600, 320)]) {
      testWidgets(
        'saved audio leaves usable notes at $size, text scale $scale',
        (tester) async {
          await (FontLoader(
                'GoogleSans',
              )..addFont(rootBundle.load('assets/fonts/GoogleSans-Medium.ttf')))
              .load();
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final errors = <FlutterErrorDetails>[];
          final reportError = FlutterError.onError!;
          FlutterError.onError = (details) {
            errors.add(details);
            reportError(details);
          };
          addTearDown(() => FlutterError.onError = reportError);
          final controller = TextEditingController(text: 'Saved meeting notes');
          addTearDown(controller.dispose);
          final actions = audio_fixture.Actions();
          await tester.pumpWidget(
            MaterialApp(
              theme: foresightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: MeetingStyleScope(
                  child: MeetingWorkspacePanel(
                    header: MeetingWorkspaceHeader(
                      title: 'Saved meeting',
                      dateText: 'Tue, Oct 27, 2026',
                      timeText: '10:00 - 10:30',
                      onBack: () {},
                      onRename: () {},
                    ),
                    audio: MeetingAudioPlayer(
                      session: audio_fixture.clip(
                        canChangeRetention: true,
                        canDeleteRecording: true,
                      ),
                      playback: const AudioPlaybackPresentation(),
                      actions: actions,
                    ),
                    sidecarVisible: true,
                    assistantFallback: false,
                    sidecarWidth: 320,
                    assistantMinWidth: 900,
                    onAssistantWidth: (_) {},
                    onSidecarWidth: (_) {},
                    onSetupSpeech: () {},
                    onHideAssistant: () {},
                    onOpenAssistant: (_) {},
                    notesBuilder: (wide, toggle) => MeetingNotesLayout(
                      wide: wide,
                      preview: false,
                      enhancedVisible: true,
                      toolbar: MeetingNotesToolbar(
                        preview: false,
                        live: true,
                        enhancing: false,
                        enhancedVisible: true,
                        noteStyle: 'Standard',
                        onFormat: (_, _) {},
                        onStyle: (_) {},
                        onEnhance: () {},
                        onToggleLive: () {},
                        onShowEnhanced: () {},
                        assistantToggle: toggle,
                      ),
                      editor: MeetingNotesInput(
                        controller: controller,
                        onChanged: () {},
                      ),
                      enhancedPane: const Text('Saved enhanced notes'),
                    ),
                    assistantBuilder: () => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: errors.map((error) => error.toString()).join("\n"),
          );
          expect(find.byTooltip('Rename meeting'), findsOneWidget);
          final viewport = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(MeetingWorkspacePanel),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          final notes = find.byType(MeetingNotesLayout);
          final notesHeight = tester.getSize(notes).height;
          final maxScroll = viewport.position.maxScrollExtent;
          viewport.position.jumpTo(maxScroll + 40);
          await tester.pump();
          expect(tester.getSize(notes).height, closeTo(notesHeight, .01));
          expect(viewport.position.maxScrollExtent, closeTo(maxScroll, .01));
          viewport.position.jumpTo(0);
          await tester.pumpAndSettle();
          final editor = find.byKey(const ValueKey('meeting-notes-editor'));
          expect(tester.getSize(editor).height, greaterThanOrEqualTo(80));
          await tester.ensureVisible(find.byTooltip('Play audio'));
          await tester.tap(find.byTooltip('Play audio'));
          await tester.pumpAndSettle();
          expect(actions.calls, [
            ['play', 'session'],
          ]);
          await tester.ensureVisible(editor);
          await tester.enterText(editor, 'Edited notes');
          expect(controller.text, 'Edited notes');
          expect(
            tester.takeException(),
            isNull,
            reason: errors.map((error) => error.toString()).join("\n"),
          );
        },
      );
    }
  }
}
