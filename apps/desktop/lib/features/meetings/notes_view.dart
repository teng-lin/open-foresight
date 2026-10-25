part of 'meetings_controller.dart';

extension _NotesView on MeetingsController {
  Widget meetingNotesEditor(
    int id,
    bool wide, {
    bool preview = false,
    Widget? assistantToggle,
  }) {
    if (loadedMeetingNotes != id)
      return const Center(child: Text('Loading meeting notes…'));
    final live = _reads.preference('liveEnhance', 'true') == 'true';
    return MeetingNotesLayout(
      wide: wide,
      preview: preview,
      enhancedVisible: meetingEnhancedVisible,
      toolbar: _meetingNotesToolbar(
        id,
        preview: preview,
        live: live,
        assistantToggle: assistantToggle,
      ),
      editor: _meetingNotesInput(),
      enhancedPane: _meetingEnhancedPane(id, preview: preview),
    );
  }

  Widget _meetingNotesInput() => MeetingNotesInput(
    controller: meetingNotesController,
    onChanged: scheduleMeetingNotesSave,
  );

  Widget _meetingEnhancedPane(int id, {required bool preview}) {
    final enhanced = _reads.artifacts(id, 'enhanced_notes').firstOrNull;
    final progress = meetingEnhancements['$id'];
    final enhancedText = progress?.bodyProvided == true
        ? progress!.body
        : _reads.enhanced(id);
    return Container(
      margin: EdgeInsets.fromLTRB(preview ? 24 : 0, 24, 24, 24),
      decoration: BoxDecoration(
        color: MeetingVisuals.enhancedSurface,
        borderRadius: MeetingVisuals.previewRadius,
      ),
      child: LayoutBuilder(
        builder: (_, bounds) => SingleChildScrollView(
          child: SizedBox(
            height: math.max(preview ? 160 : 260, bounds.maxHeight),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: MeetingPanelHeading(
                    title: preview ? 'Enhanced notes' : 'Live enhanced notes',
                    actions: [
                      IconButton(
                        tooltip: 'Copy enhanced notes',
                        onPressed:
                            enhanced == null &&
                                progress == null &&
                                enhancedText.isEmpty
                            ? null
                            : () => Clipboard.setData(
                                ClipboardData(text: enhancedText),
                              ),
                        icon: const Icon(Icons.copy_outlined, size: 19),
                      ),
                      if (enhanced != null)
                        IconButton(
                          tooltip: 'Edit enhanced notes',
                          onPressed: () => unawaited(
                            editArtifact(
                              enhanced,
                              initialText: enhancedText,
                            ).catchError(_operations.reportAsyncError),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                      IconButton(
                        tooltip: 'Hide enhanced notes',
                        onPressed: () =>
                            update(() => meetingEnhancedVisible = false),
                        icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                      ),
                    ],
                  ),
                ),
                if (enhanced?.manifest['degraded'] == true)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Some notes were preserved without successful enhancement. Review or regenerate these notes.',
                    ),
                  ),
                if (progress?.active == true) ...[
                  const LinearProgressIndicator(),
                  TextButton(
                    key: const ValueKey('cancel-note-enhancement'),
                    onPressed: progress?.cancelRequested == true
                        ? null
                        : () async {
                            await d.command(Operation.meetingsCancelEnhance, {
                              'id': id,
                              'request_id':
                                  progress?.requestId.isNotEmpty == true
                                  ? progress!.requestId
                                  : null,
                            });
                          },
                    child: Text(
                      progress?.cancelRequested == true
                          ? 'Cancelling…'
                          : 'Cancel enhancement',
                    ),
                  ),
                ],
                if ((progress?.status ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(progress!.status),
                  ),
                Expanded(
                  child: _meetingEnhancedBody(
                    enhancedText,
                    preview: preview,
                    hasProgress: progress != null,
                  ),
                ),
                if (meetingNotesController.text.isNotEmpty)
                  TextButton.icon(
                    onPressed:
                        meetingEnhancing || _operations.busy || _chat.asking
                        ? null
                        : () => enhanceMeetingNotes(id),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('Enhance notes'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _meetingEnhancedBody(
    String enhancedText, {
    required bool preview,
    required bool hasProgress,
  }) => MeetingEnhancedBody(
    enhancedText: enhancedText,
    preview: preview,
    hasProgress: hasProgress,
    status: meetingEnhanceStatus,
    openLink: _host.environment.openUri,
  );

  Widget _meetingNotesToolbar(
    int id, {
    required bool preview,
    required bool live,
    Widget? assistantToggle,
  }) => MeetingNotesToolbar(
    preview: preview,
    live: live,
    enhancing: meetingEnhancing,
    enhancedVisible: meetingEnhancedVisible,
    noteStyle: _reads.preference('noteStyle', 'Standard'),
    onFormat: (before, after) => formatMeetingNotes(before, after),
    onStyle: (style) =>
        runAction(() => _settings.preference('noteStyle', style)),
    onEnhance:
        meetingEnhancing ||
            _operations.busy ||
            _chat.asking ||
            meetingNotesController.text.trim().isEmpty
        ? null
        : () => enhanceMeetingNotes(id),
    onToggleLive: () => update(() {
      unawaited(
        runAction(
          () => _settings.preference('liveEnhance', (!live).toString()),
        ),
      );
      meetingEnhancedVisible = !live;
      if (!live) unawaited(runAction(saveMeetingNotes));
    }),
    onShowEnhanced: () => update(() => meetingEnhancedVisible = true),
    assistantToggle: assistantToggle,
  );
}
