part of 'meetings_controller.dart';

extension _NotesView on MeetingsController {
  Widget meetingNotesEditor(
    int id,
    bool wide, {
    bool preview = false,
    Widget? assistantToggle,
  }) {
    final enhanced = d.store.enhancedNoteArtifacts(id).firstOrNull;
    final progress = meetingEnhancements['$id'];
    final enhancedText = progress?.bodyProvided == true
        ? progress!.body
        : d.store.meetingEnhancedNotes(id);
    final live = d.store.preference('liveEnhance', 'true') == 'true';
    final editorField = TextField(
      key: const ValueKey('meeting-notes-editor'),
      controller: meetingNotesController,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: MeetingVisuals.notes,
      onChanged: (_) => scheduleMeetingNotesSave(),
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.all(24),
      ),
    );
    final editor = Stack(
      fit: StackFit.expand,
      children: [
        Semantics(label: 'Meeting notes', child: editorField),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: meetingNotesController,
          builder: (_, value, _) => value.text.isNotEmpty
              ? const SizedBox.shrink()
              : IgnorePointer(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Enter your notes here. Markdown formatting is supported.\n\nMarkdown guide:\n• # Heading\n• **bold**\n• *italics*\n• - Bullet list\n• 1. Numbered list',
                      style: MeetingVisuals.notes.copyWith(
                        color: const Color(0xff9ba3b3),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
    final enhancedPane = Container(
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
                            editArtifact({
                              ...enhanced,
                              'edited': enhancedText,
                            }).catchError(_operations.reportAsyncError),
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
                if (enhanced?['manifest'] != null &&
                    (jsonDecode(enhanced!['manifest'] as String)
                            as Map)['degraded'] ==
                        true)
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
                  child: enhancedText.isEmpty && progress == null
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: MeetingVisuals.panelRadius,
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (preview)
                  PopupMenuButton<String>(
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
                else
                  IconButtonTheme(
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
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: d.store.preference('noteStyle', 'Standard'),
                      underline: const SizedBox.shrink(),
                      items: ['Standard', 'Concise']
                          .map(
                            (s) => DropdownMenuItem(value: s, child: Text(s)),
                          )
                          .toList(),
                      onChanged: (style) => runAction(
                        () => _settings.preference('noteStyle', style!),
                      ),
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
                        label: Text(
                          meetingEnhancing ? 'Enhancing…' : 'Enhance',
                        ),
                      )
                    else
                      FilledButton.tonalIcon(
                        key: const ValueKey('meeting-live-enhance'),
                        onPressed: () => update(() {
                          unawaited(
                            runAction(
                              () => _settings.preference(
                                'liveEnhance',
                                (!live).toString(),
                              ),
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
                        onPressed: () =>
                            update(() => meetingEnhancedVisible = true),
                        icon: const Icon(Icons.vertical_split),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: !meetingEnhancedVisible
                ? editor
                : preview
                ? Column(
                    children: [
                      Expanded(flex: 3, child: editor),
                      Expanded(flex: 2, child: enhancedPane),
                    ],
                  )
                : wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 11, child: editor),
                      const SizedBox(width: 24),
                      Expanded(flex: 9, child: enhancedPane),
                    ],
                  )
                : DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        const TabBar(
                          tabs: [
                            Tab(text: 'Notes'),
                            Tab(text: 'Enhanced'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(children: [editor, enhancedPane]),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
