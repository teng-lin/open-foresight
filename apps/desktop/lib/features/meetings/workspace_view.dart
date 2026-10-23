part of 'meetings_controller.dart';

extension _WorkspaceView on MeetingsController {
  Widget _immersiveMeetingWorkspace() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          update(() => meetingImmersive = false),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => update(() => meetingImmersive = false),
                        icon: const Icon(Icons.fullscreen_exit),
                        label: const Text('Exit Immersive View'),
                      ),
                      if (recording != null) recordingHeader(),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: MeetingStyleScope(child: meetingWorkspace())),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget meetingWorkspace() {
    final id = meetingId!;
    final meeting = _reads.meeting(id);
    if (meeting == null)
      return Center(
        child: Text(
          _reads.meetingLoaded(id)
              ? 'Meeting no longer exists.'
              : 'Loading meeting…',
        ),
      );
    final start = (meeting.starts ?? meeting.created ?? 0);
    final end =
        (meeting.ends ?? start + const Duration(minutes: 30).inMilliseconds);
    final date = DateTime.fromMillisecondsSinceEpoch(start).toLocal();
    final dateText =
        '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1]}, ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]} ${date.day}, ${date.year}';
    return LayoutBuilder(
      builder: (workspaceContext, constraints) {
        final wide = constraints.maxWidth >= _meetingAssistantMinWidth;
        meetingAssistantWide = wide;
        final showAssistant =
            meetingSidecarVisible && (wide || meetingAssistantFallback);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _meetingWorkspaceHeader(meeting, dateText, start, end),
            if (preparedSpeechSetupProblem(_reads.speech) != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.info_outline),
                title: Text(preparedSpeechSetupProblem(_reads.speech)!),
                trailing: TextButton(
                  onPressed: () => _settings.showModelSetup('speech'),
                  child: const Text('Set up speech'),
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (_, size) {
                  final showSidecar = showAssistant && wide;
                  final sideWidth = meetingSidecarWidth
                      .clamp(280.0, math.max(280.0, size.maxWidth / 2))
                      .toDouble();
                  final notesWidth = showSidecar
                      ? size.maxWidth - sideWidth - 16
                      : size.maxWidth;
                  final editor = meetingNotesEditor(
                    id,
                    notesWidth >= 640,
                    assistantToggle: SizedBox(
                      width: 40,
                      child: IconButton(
                        key: const ValueKey('meeting-assistant-toggle'),
                        tooltip: showAssistant
                            ? 'Hide assistant'
                            : 'Open assistant',
                        isSelected: showAssistant,
                        style: IconButton.styleFrom(
                          backgroundColor: showAssistant ? workspaceBlue : null,
                          foregroundColor: workspaceInk,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: showAssistant
                            ? () => update(() => meetingSidecarVisible = false)
                            : () => openMeetingAssistant(workspaceContext),
                        icon: const Icon(Icons.view_sidebar_outlined),
                      ),
                    ),
                  );
                  if (showAssistant && !wide) return meetingAssistant(id);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 7, child: editor),
                      if (showSidecar) ...[
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            key: const ValueKey('meeting-sidecar-resize'),
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (drag) => update(
                              () => meetingSidecarWidth =
                                  (sideWidth - drag.delta.dx)
                                      .clamp(
                                        280.0,
                                        math.max(280.0, size.maxWidth / 2),
                                      )
                                      .toDouble(),
                            ),
                            child: SizedBox(
                              width: 16,
                              child: Center(
                                child: Container(
                                  width: 4,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: const Color(0xffd6dae1),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: sideWidth, child: meetingAssistant(id)),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _meetingWorkspaceHeader(
    MeetingDetails meeting,
    String dateText,
    int start,
    int end,
  ) => Row(
    children: [
      IconButton.filledTonal(
        tooltip: 'All meetings',
        onPressed: () async {
          try {
            await flushMeetingNotesDraft();
          } catch (_) {
            return;
          }
          if (mounted)
            update(() {
              meetingId = null;
              meetingImmersive = false;
            });
        },
        style: IconButton.styleFrom(backgroundColor: Colors.white),
        icon: const Icon(Icons.arrow_back),
      ),
      const SizedBox(width: 8),
      const CircleAvatar(
        backgroundColor: Color(0xffdce1ea),
        child: Icon(Icons.calendar_today, color: Color(0xff555b62)),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(meeting.title, style: MeetingVisuals.title),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                MeetingMetadataBadge(dateText),
                MeetingMetadataBadge(
                  '${meetingClock(start)} - ${meetingClock(end)}',
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}
