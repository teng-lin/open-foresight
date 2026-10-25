part of 'meetings_controller.dart';

extension _NotesView on MeetingsController {
  Widget meetingNotesEditor(
    int id,
    bool wide, {
    bool preview = false,
    Widget? assistantToggle,
  }) {
    if (loadedMeetingNotes != id) return const MeetingNotesLoading();
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
    return MeetingEnhancedPane(
      preview: preview,
      enhancedText: enhancedText,
      hasArtifact: enhanced != null,
      hasProgress: progress != null,
      active: progress?.active == true,
      cancelRequested: progress?.cancelRequested == true,
      degraded: enhanced?.manifest['degraded'] == true,
      status: progress?.status ?? '',
      hasNotes: meetingNotesController.text.isNotEmpty,
      body: _meetingEnhancedBody(
        enhancedText,
        preview: preview,
        hasProgress: progress != null,
      ),
      onCopy: () => Clipboard.setData(ClipboardData(text: enhancedText)),
      onEdit: enhanced == null
          ? null
          : () => unawaited(
              editArtifact(
                enhanced,
                initialText: enhancedText,
              ).catchError(_operations.reportAsyncError),
            ),
      onHide: () => update(() => meetingEnhancedVisible = false),
      onCancel: () async {
        await meetingsCancelEnhanceDescriptor.send(
          d,
          MeetingsCancelEnhanceInput(
            id: id,
            requestId: WireField(
              progress?.requestId.isNotEmpty == true
                  ? progress!.requestId
                  : null,
            ),
          ),
        );
      },
      onEnhance: meetingEnhancing || _operations.busy || _chat.asking
          ? null
          : () => enhanceMeetingNotes(id),
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
