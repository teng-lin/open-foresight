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
  }) => enhancedText.isEmpty && !hasProgress
      ? Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!preview) ...[
                  const Icon(
                    Icons.auto_awesome,
                    color: Color(0xffb8bec8),
                    size: 32,
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  meetingEnhanceStatus.isEmpty
                      ? 'Live enhanced notes will appear here as shorthand notes are written.'
                      : meetingEnhanceStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xff959ba5),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        )
      : SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: GeneratedContent(
            enhancedText,
            openLink: _host.environment.openUri,
          ),
        );

  Widget _meetingNotesToolbar(
    int id, {
    required bool preview,
    required bool live,
    Widget? assistantToggle,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        _meetingNotesFormatting(preview),
        _meetingNotesActions(
          id,
          preview: preview,
          live: live,
          assistantToggle: assistantToggle,
        ),
      ],
    ),
  );

  Widget _meetingNotesFormatting(bool preview) => preview
      ? PopupMenuButton<String>(
          tooltip: 'Format notes',
          icon: const Icon(Icons.text_format),
          onSelected: (format) {
            switch (format) {
              case 'Bold':
                formatMeetingNotes('**', '**');
              case 'Italic':
                formatMeetingNotes('*', '*');
              case 'Bullet list':
                formatMeetingNotes('\n- ');
              case 'Numbered list':
                formatMeetingNotes('\n1. ');
              case 'Heading':
                formatMeetingNotes('\n# ');
            }
          },
          itemBuilder: (_) => [
            for (final format in [
              'Bold',
              'Italic',
              'Bullet list',
              'Numbered list',
              'Heading',
            ])
              PopupMenuItem(value: format, child: Text(format)),
          ],
        )
      : IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              fixedSize: const Size(40, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Bold',
                onPressed: () => formatMeetingNotes('**', '**'),
                icon: const Icon(Icons.format_bold),
              ),
              IconButton(
                tooltip: 'Italic',
                onPressed: () => formatMeetingNotes('*', '*'),
                icon: const Icon(Icons.format_italic),
              ),
              IconButton(
                tooltip: 'Bullet list',
                onPressed: () => formatMeetingNotes('\n- '),
                icon: const Icon(Icons.format_list_bulleted),
              ),
              IconButton(
                tooltip: 'Numbered list',
                onPressed: () => formatMeetingNotes('\n1. '),
                icon: const Icon(Icons.format_list_numbered),
              ),
              IconButton(
                tooltip: 'Heading',
                onPressed: () => formatMeetingNotes('\n# '),
                icon: const Icon(Icons.title),
              ),
            ],
          ),
        );

  Widget _meetingNotesActions(
    int id, {
    required bool preview,
    required bool live,
    Widget? assistantToggle,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DropdownButton<String>(
        value: _reads.preference('noteStyle', 'Standard'),
        underline: const SizedBox.shrink(),
        items: [
          'Standard',
          'Concise',
        ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: (style) =>
            runAction(() => _settings.preference('noteStyle', style!)),
      ),
      const SizedBox(width: 18),
      if (preview)
        FilledButton.tonalIcon(
          onPressed:
              meetingEnhancing ||
                  _operations.busy ||
                  _chat.asking ||
                  meetingNotesController.text.trim().isEmpty
              ? null
              : () => enhanceMeetingNotes(id),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(meetingEnhancing ? 'Enhancing…' : 'Enhance'),
        )
      else
        FilledButton.tonalIcon(
          key: const ValueKey('meeting-live-enhance'),
          onPressed: () => update(() {
            unawaited(
              runAction(
                () => _settings.preference('liveEnhance', (!live).toString()),
              ),
            );
            meetingEnhancedVisible = !live;
            if (!live) unawaited(runAction(saveMeetingNotes));
          }),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffdce9ff),
            foregroundColor: const Color(0xff254ab5),
          ),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text('Live Enhance ${live ? 'ON' : 'OFF'}'),
        ),
      if (assistantToggle != null) ...[
        const SizedBox(width: 8),
        assistantToggle,
      ],
      if (!meetingEnhancedVisible)
        IconButton(
          tooltip: 'Show enhanced notes',
          onPressed: () => update(() => meetingEnhancedVisible = true),
          icon: const Icon(Icons.vertical_split),
        ),
    ],
  );
}
