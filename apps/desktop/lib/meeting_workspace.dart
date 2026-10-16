part of 'main.dart';

extension _MeetingWorkspace on _WorkspaceState {
  void saveMeetingNotes() {
    final id = loadedMeetingNotes;
    if (id == null) return;
    d.store.saveMeetingNotes(id, meetingNotesController.text);
    if (mounted) update(() {});
    meetingEnhanceTimer?.cancel();
    if (d.store.preference('liveEnhance', 'true') == 'true') {
      meetingEnhanceTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && meetingId == id) unawaited(enhanceMeetingNotes(id));
      });
    }
  }

  void formatMeetingNotes(String before, [String after = '']) {
    final value = meetingNotesController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : start;
    final replacement = '$before${value.text.substring(start, end)}$after';
    meetingNotesController.value = TextEditingValue(
      text: value.text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(
        offset: start + replacement.length - after.length,
      ),
    );
    saveMeetingNotes();
  }

  Future<void> enhanceMeetingNotes(int id) async {
    if (meetingEnhancing || busy || asking || d.generator?.generating == true) {
      if (mounted &&
          loadedMeetingNotes == id &&
          d.store.preference('liveEnhance', 'true') == 'true') {
        meetingEnhanceTimer?.cancel();
        meetingEnhanceTimer = Timer(const Duration(seconds: 3), () {
          if (mounted && meetingId == id) unawaited(enhanceMeetingNotes(id));
        });
      }
      return;
    }
    final notes = d.store.rows(
      'SELECT body,revision FROM meeting_notes WHERE meeting_id=?',
      [id],
    ).firstOrNull;
    if (notes == null || (notes['body'] as String).trim().isEmpty) return;
    final transcript = d.store
        .rows(
          'SELECT text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
          [id],
        )
        .map((t) => t['text'])
        .join('\n');
    if (d.generator == null || transcript.isEmpty) {
      if (mounted)
        update(
          () => meetingEnhanceStatus = d.generator == null
              ? 'Set up a generation model to enhance notes.'
              : 'Waiting for a transcript to enrich these notes.',
        );
      return;
    }
    update(() {
      meetingEnhancing = true;
      meetingEnhanceStatus = '';
    });
    var result = '', status = 'failed';
    try {
      final revision =
          d.store.rows('SELECT revision FROM meetings WHERE id=?', [
                id,
              ]).single['revision']
              as int;
      await for (final event in d.generator!.generate(
        'notes-${DateTime.now().microsecondsSinceEpoch}',
        'Enrich each shorthand note using only the transcript below. Preserve the user names and spelling. '
            'Do not add unsupported details. Write ${d.store.preference('noteStyle', 'Standard') == 'Concise' ? 'brief phrases' : 'complete sentences'}, one bullet per note. '
            'Notes:\n${boundUtf8(notes['body'] as String, 1500)}\nTranscript:\n${boundUtf8(transcript, 2800)}',
        maxOutputTokens: 512,
      )) {
        if (event['type'] == 'delta') result += event['text'] as String;
        if (event['type'] == 'done') status = event['status'] as String;
        if (event['type'] == 'error')
          throw StateError(event['message'].toString());
      }
      if (status != 'completed') throw StateError('Note enhancement $status');
      final current = d.store.rows(
        'SELECT revision FROM meeting_notes WHERE meeting_id=?',
        [id],
      ).firstOrNull;
      if (!mounted || current?['revision'] != notes['revision']) return;
      final digest =
          d.store
                  .rows("SELECT digest FROM models WHERE kind='generation'")
                  .firstOrNull?['digest']
              as String? ??
          'unknown';
      d.store.artifact(
        id,
        'enhanced_notes',
        result,
        digest,
        inputRevision: revision,
      );
    } catch (e) {
      if (mounted) update(() => meetingEnhanceStatus = e.toString());
    } finally {
      if (mounted) update(() => meetingEnhancing = false);
    }
  }

  Widget meetingWorkspace() {
    final id = meetingId!;
    if (loadedMeetingNotes != id) {
      meetingEnhanceTimer?.cancel();
      loadedMeetingNotes = id;
      meetingNotesController.text =
          d.store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
                id,
              ]).firstOrNull?['body']
              as String? ??
          '';
      meetingEnhanceStatus = '';
    }
    final meeting = d.store.rows(
      'SELECT meetings.*,meeting_details.created,calendar_events.starts,calendar_events.ends FROM meetings '
      'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
      'LEFT JOIN calendar_events ON calendar_events.meeting_id=meetings.id WHERE meetings.id=?',
      [id],
    ).single;
    final start = (meeting['starts'] ?? meeting['created'] ?? 0) as int;
    final end =
        (meeting['ends'] ?? start + const Duration(minutes: 30).inMilliseconds)
            as int;
    final date = DateTime.fromMillisecondsSinceEpoch(start).toLocal();
    final dateText =
        '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1]}, ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]} ${date.day}, ${date.year}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton.filledTonal(
              tooltip: 'All meetings',
              onPressed: () => update(() => meetingId = null),
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
                  Text(
                    meeting['title'] as String,
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      Chip(label: Text(dateText)),
                      Chip(
                        label: Text(
                          '${meetingClock(start)} - ${meetingClock(end)}',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!meetingSidecarVisible)
              IconButton(
                tooltip: 'Open assistant',
                onPressed: () => update(() => meetingSidecarVisible = true),
                icon: const Icon(Icons.chat_bubble_outline),
              ),
            PopupMenuButton<String>(
              tooltip: 'Meeting options',
              onSelected: (action) {
                if (action == 'record') unawaited(run(startRecording));
                if (action == 'transcript')
                  update(() {
                    meetingPanel = 'Transcript';
                    meetingSidecarVisible = true;
                  });
                if (action == 'import') unawaited(run(importMeetingTranscript));
                if (action == 'attachments')
                  unawaited(run(() => google.importAttachments(id)));
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'record',
                  enabled:
                      !busy &&
                      recording == null &&
                      speechSetupProblem(d.store) == null,
                  child: const Text('Record microphone + playback'),
                ),
                const PopupMenuItem(
                  value: 'transcript',
                  child: Text('Transcript'),
                ),
                const PopupMenuItem(
                  value: 'import',
                  child: Text('Import transcript'),
                ),
                if (google.attachments(id).isNotEmpty)
                  PopupMenuItem(
                    value: 'attachments',
                    enabled: googleAuth.connected,
                    child: const Text('Import meeting attachments'),
                  ),
              ],
            ),
          ],
        ),
        if (speechSetupProblem(d.store) != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline),
            title: Text(speechSetupProblem(d.store)!),
            trailing: TextButton(
              onPressed: () => update(() {
                tab = 4;
                modelKind = 'speech';
              }),
              child: const Text('Set up speech'),
            ),
          ),
        const SizedBox(height: 16),
        Expanded(
          child: LayoutBuilder(
            builder: (_, size) {
              final showSidecar = meetingSidecarVisible;
              final sideWidth = meetingSidecarWidth
                  .clamp(280.0, math.max(280.0, size.maxWidth / 2))
                  .toDouble();
              final notesWidth = showSidecar && size.maxWidth >= 760
                  ? size.maxWidth - sideWidth - 16
                  : size.maxWidth;
              final editor = meetingNotesEditor(id, notesWidth >= 640);
              if (size.maxWidth < 760 && showSidecar) {
                return Column(
                  children: [
                    Row(
                      children: [
                        TextButton(
                          onPressed: () =>
                              update(() => meetingCompactAssistant = false),
                          child: const Text('Notes'),
                        ),
                        TextButton(
                          onPressed: () =>
                              update(() => meetingCompactAssistant = true),
                          child: const Text('Assistant'),
                        ),
                      ],
                    ),
                    Expanded(
                      child: meetingCompactAssistant
                          ? meetingAssistant(id)
                          : editor,
                    ),
                  ],
                );
              }
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
                          () =>
                              meetingSidecarWidth = (sideWidth - drag.delta.dx)
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
  }

  Future<void> importMeetingTranscript() async {
    final id = meetingId!;
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Transcript text', extensions: ['txt']),
      ],
    );
    if (file == null) return;
    d.store.transcript(
      id,
      await file.readAsString(),
      true,
      0,
      0,
      'import:${file.path}',
    );
    await indexMeeting(id);
  }

  Widget meetingNotesEditor(int id, bool wide) {
    final enhanced = d.store.rows(
      "SELECT * FROM artifacts WHERE meeting_id=? AND kind='enhanced_notes' ORDER BY id DESC LIMIT 1",
      [id],
    ).firstOrNull;
    final live = d.store.preference('liveEnhance', 'true') == 'true';
    final editor = TextField(
      key: const ValueKey('meeting-notes-editor'),
      controller: meetingNotesController,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontSize: 16, height: 1.7),
      onChanged: (_) => saveMeetingNotes(),
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.all(24),
        hintStyle: TextStyle(
          color: Color(0xff9ba3b3),
          fontWeight: FontWeight.w500,
        ),
        hintText:
            'Enter your notes here. Markdown formatting is supported.\n\nMarkdown guide:\n• # Heading\n• **bold**\n• *italics*\n• - Bullet list\n• 1. Numbered list',
      ),
    );
    final enhancedPane = Container(
      margin: const EdgeInsets.fromLTRB(0, 24, 24, 24),
      decoration: BoxDecoration(
        color: const Color(0xffeaf0f8),
        borderRadius: BorderRadius.circular(18),
      ),
      child: LayoutBuilder(
        builder: (_, bounds) => SingleChildScrollView(
          child: SizedBox(
            height: math.max(260, bounds.maxHeight),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome,
                        size: 19,
                        color: Color(0xff556272),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Live enhanced notes',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy enhanced notes',
                        onPressed: enhanced == null
                            ? null
                            : () => Clipboard.setData(
                                ClipboardData(
                                  text:
                                      (enhanced['edited'] ??
                                              enhanced['generated'])
                                          as String,
                                ),
                              ),
                        icon: const Icon(Icons.copy_outlined, size: 19),
                      ),
                      if (enhanced != null)
                        IconButton(
                          tooltip: 'Edit enhanced notes',
                          onPressed: () => editArtifact(enhanced),
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
                if (meetingEnhancing) const LinearProgressIndicator(),
                Expanded(
                  child: enhanced == null
                      ? Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.auto_awesome,
                                  color: Color(0xffb8bec8),
                                  size: 32,
                                ),
                                const SizedBox(height: 16),
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
                          child: SelectableText(
                            (enhanced['edited'] ?? enhanced['generated'])
                                as String,
                            style: const TextStyle(fontSize: 15, height: 1.6),
                          ),
                        ),
                ),
                if (meetingNotesController.text.isNotEmpty)
                  TextButton.icon(
                    onPressed: meetingEnhancing || busy || asking
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
        borderRadius: BorderRadius.circular(28),
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
                Row(
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
                      onChanged: (style) => update(
                        () => d.store.setPreference('noteStyle', style!),
                      ),
                    ),
                    const SizedBox(width: 18),
                    FilledButton.tonalIcon(
                      onPressed: () => update(() {
                        d.store.setPreference(
                          'liveEnhance',
                          (!live).toString(),
                        );
                        meetingEnhancedVisible = !live;
                        if (!live) saveMeetingNotes();
                      }),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xffdce9ff),
                        foregroundColor: const Color(0xff254ab5),
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: Text('Live Enhance ${live ? 'ON' : 'OFF'}'),
                    ),
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

  Widget meetingAssistant(int id) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(28),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
          child: Row(
            children: [
              for (final panel in ['Chat', 'Live Q&A', 'Summary'])
                Flexible(
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      backgroundColor: meetingPanel == panel ? _blue : null,
                      foregroundColor: meetingPanel == panel
                          ? _ink
                          : const Color(0xff4d5358),
                    ),
                    onPressed: () => update(() => meetingPanel = panel),
                    child: Text(
                      panel,
                      maxLines: 1,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: 'More meeting panels',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                onSelected: (panel) => update(() => meetingPanel = panel),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'Transcript',
                    child: Text('Transcript'),
                  ),
                  const PopupMenuItem(
                    value: 'Action items',
                    child: Text('Action items'),
                  ),
                ],
              ),
              for (final delta in [-1, 1])
                SizedBox(
                  width: 24,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(24, 32),
                    ),
                    onPressed: () => update(
                      () => answerFontSize = (answerFontSize + delta).clamp(
                        12,
                        24,
                      ),
                    ),
                    child: Text(
                      delta < 0 ? 'A−' : 'A+',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Close assistant',
                constraints: const BoxConstraints(minWidth: 28),
                padding: EdgeInsets.zero,
                onPressed: () => update(() => meetingSidecarVisible = false),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: const [
              'Chat',
              'Live Q&A',
              'Summary',
              'Transcript',
              'Action items',
            ].indexOf(meetingPanel),
            children: [
              chat(meetingScope: id, compact: true),
              meetingTranscriptPanel(id, questions: true),
              meetingSummaryPanel(id),
              meetingTranscriptPanel(id),
              meetingSummaryPanel(id, actions: true),
            ],
          ),
        ),
      ],
    ),
  );

  Widget meetingTranscriptPanel(int id, {bool questions = false}) {
    final rows = d.store.rows(
      'SELECT * FROM transcript WHERE meeting_id=? ORDER BY id',
      [id],
    );
    final displayed = questions
        ? rows.where((t) => (t['text'] as String).contains('?')).toList()
        : rows;
    return Column(
      children: [
        if (!questions)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Transcript',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        Expanded(
          child:
              displayed.isEmpty && (questions || provisionalTranscript.isEmpty)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      questions
                          ? 'Questions from the live transcript will appear here.'
                          : 'Your live transcript will appear here.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff87a8b7),
                        fontSize: 17,
                      ),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final t in displayed)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: SelectableText(t['text'] as String),
                        subtitle: Text(
                          (t['source'] as String).startsWith('microphone')
                              ? 'Microphone'
                              : (t['source'] as String).startsWith('playback')
                              ? 'System audio'
                              : 'Transcript',
                        ),
                        trailing: questions
                            ? IconButton(
                                tooltip: 'Answer this question',
                                onPressed: busy || asking || meetingEnhancing
                                    ? null
                                    : () {
                                        question.text = t['text'] as String;
                                        update(() => meetingPanel = 'Chat');
                                        unawaited(
                                          askQuestion(meetingScope: id),
                                        );
                                      },
                                icon: const Icon(Icons.arrow_upward),
                              )
                            : null,
                      ),
                    if (!questions && recordingMeeting == id)
                      for (final entry in provisionalTranscript.entries.where(
                        (e) => e.value.isNotEmpty,
                      ))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            entry.value,
                            style: const TextStyle(color: Color(0xff818995)),
                          ),
                          subtitle: const Text('Live'),
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget meetingSummaryPanel(int id, {bool actions = false}) {
    final kind = actions ? 'actions' : 'summary';
    final title = actions ? 'Action items' : 'Summary';
    final versions = d.store.rows(
      'SELECT * FROM artifacts WHERE meeting_id=? AND kind=? ORDER BY id DESC',
      [id, kind],
    );
    final artifact = versions.firstOrNull;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Generate $title',
                onPressed: busy || asking || meetingEnhancing
                    ? null
                    : () => run(() => generateMeeting(kind)),
                icon: const Icon(Icons.auto_awesome),
              ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Edit $title',
                  onPressed: () => editArtifact(artifact),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
        ),
        Expanded(
          child: artifact == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Generate ${title.toLowerCase()} from the meeting transcript.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff87a8b7),
                        fontSize: 17,
                      ),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        (artifact['edited'] ?? artifact['generated']) as String,
                        style: TextStyle(fontSize: answerFontSize, height: 1.6),
                      ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final previous in versions.skip(1))
                              ListTile(
                                title: SelectableText(
                                  (previous['edited'] ?? previous['generated'])
                                      as String,
                                ),
                                trailing: IconButton(
                                  tooltip: 'Edit previous version',
                                  onPressed: () => editArtifact(previous),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget recordingHeader() {
    final elapsed = recordingBegan == null
        ? Duration.zero
        : DateTime.now().difference(recordingBegan!);
    final clock =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return Container(
      width: MediaQuery.sizeOf(context).width > 1100 ? 400 : 310,
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      decoration: BoxDecoration(
        color: _blue,
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        children: [
          Text(
            clock,
            style: const TextStyle(
              color: _ink,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 30,
              child: CustomPaint(
                painter: _CaptureWaveform(recording!.currentVolumes),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Stop transcribing',
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: const EdgeInsets.all(6),
            onPressed: recording!.finishing ? null : () => run(stopRecording),
            icon: const Icon(Icons.stop_circle_outlined, color: _ink, size: 23),
          ),
          IconButton(
            tooltip: 'Open transcription workspace',
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: const EdgeInsets.all(6),
            onPressed: () => update(() {
              tab = 3;
              meetingId = recordingMeeting;
              meetingSidecarVisible = true;
            }),
            icon: const Icon(Icons.fullscreen, color: _ink, size: 23),
          ),
        ],
      ),
    );
  }
}

class _CaptureWaveform extends CustomPainter {
  final List<double> volumes;
  _CaptureWaveform(List<double> levels) : volumes = List.of(levels);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _ink
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final level = volumes.isEmpty ? 0.0 : volumes.reduce(math.max);
    final count = math.max(1, (size.width / 10).floor());
    for (var i = 0; i < count; i++) {
      final x = (i + .5) * size.width / count;
      final amplitude = math.max(0.0, (level * 60).clamp(0, 12).toDouble());
      canvas.drawLine(
        Offset(x, size.height / 2 - amplitude),
        Offset(x + 1, size.height / 2 + amplitude),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_CaptureWaveform old) => true;
}
