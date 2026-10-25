part of 'meetings_controller.dart';

extension _AssistantViews on MeetingsController {
  Widget meetingAssistant(int id) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: MeetingVisuals.panelRadius,
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        MeetingAssistantHeader(
          selectedPanel: meetingPanel,
          onPanelSelected: (panel) => update(() => meetingPanel = panel),
          onFontSizeChanged: (delta) => update(
            () => _chatCommands.setAnswerFontSize(
              (_chat.answerFontSize + delta).clamp(12, 24),
            ),
          ),
          onClose: () => update(() => meetingSidecarVisible = false),
        ),
        if (meetingPanel == 'Chat' || meetingPanel == 'Live Q&A')
          meetingAnswerScope(id, automatic: meetingPanel == 'Live Q&A'),
        Expanded(
          child: IndexedStack(
            index: MeetingAssistantHeader.panels.indexOf(meetingPanel),
            children: [
              _chatCommands.chat(meetingScope: id, compact: true),
              meetingQuestionsPanel(id),
              meetingSummaryPanel(id),
              meetingTranscriptPanel(id),
              meetingSummaryPanel(id, actions: true),
              meetingPreparationPanel(id),
            ],
          ),
        ),
      ],
    ),
  );

  Widget meetingQuestionsPanel(int id) {
    final automatic = _reads.preference('proactiveAnswers', 'true') == 'true';
    final detected = _reads.questions(id);
    final manual = _reads
        .transcript(id)
        .where((row) => row.finalSegment)
        .where(
          (row) =>
              row.text.contains(RegExp('[?？]')) &&
              !detected.any((question) => question.question == row.text),
        )
        .toList();
    final capture = d.capturePresentation;
    final pipeline = capture.proactive;
    final detectionError = pipeline.errors['$id'];
    return Column(
      children: [
        if (!capture.questionDetector.configured)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Set up a dedicated question detector in Settings → Local models. Automatic answers retain queued work while setup is unavailable.',
            ),
          ),
        if (pipeline.queuedAnswers > 0)
          Text(
            '${pipeline.queuedAnswers} queued · oldest waiting ${(pipeline.oldestQueueAgeMs / 1000).floor()}s',
          ),
        SwitchListTile(
          dense: true,
          title: const Text('Automatic answers'),
          subtitle: const Text(
            'Detect questions and answer with your local model.',
          ),
          value: automatic,
          onChanged: (enabled) => runAction(
            () => _settings.preference('proactiveAnswers', '$enabled'),
          ),
        ),
        if ((pipeline.running && pipeline.activeMeeting == id) ||
            pipeline.pendingMeetings.contains(id))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              automatic
                  ? 'Waiting for the local model or processing transcript…'
                  : 'Automatic answering is off. Queued questions are saved.',
            ),
          ),
        if (detectionError != null)
          ListTile(
            title: Text(detectionError),
            trailing: TextButton(
              onPressed: () => _operations.run(() async {
                await meetingsRetryDetectionDescriptor.send(
                  d,
                  MeetingsRetryDetectionInput(id: id),
                );
              }),
              child: const Text('Retry detection'),
            ),
          ),
        Expanded(
          child: detected.isEmpty && manual.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Questions detected during the conversation will be answered here.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final item in detected)
                      _meetingAutomaticQuestion(item),
                    for (final row in manual)
                      ListTile(
                        title: SelectableText(row.text),
                        trailing: IconButton(
                          tooltip: 'Answer this question',
                          onPressed:
                              _operations.busy ||
                                  _chat.asking ||
                                  meetingEnhancing
                              ? null
                              : () {
                                  _chatCommands.setQuestion(id, row.text);
                                  update(() => meetingPanel = 'Chat');
                                  unawaited(
                                    _chatCommands.askQuestion(meetingScope: id),
                                  );
                                },
                          icon: const Icon(Icons.arrow_upward),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget meetingTranscriptPanel(int id, {bool questions = false}) {
    final rows = _reads.transcript(id);
    final displayed = questions
        ? rows.where((t) => (t.text).contains('?')).toList()
        : rows;
    return Column(
      children: [
        if (!questions)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Transcript',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Import transcript',
                  onPressed: _operations.busy
                      ? null
                      : () =>
                            _operations.run(() => importMeetingTranscript(id)),
                  icon: const Icon(Icons.file_upload_outlined),
                ),
                if (_reads.attachments(id).isNotEmpty)
                  IconButton(
                    tooltip: 'Import meeting attachments',
                    onPressed:
                        _operations.busy ||
                            !_integrations.googlePresentation.connected
                        ? null
                        : () => _operations.run(
                            () => _integrationCommands.importMeetingAttachments(
                              id,
                            ),
                          ),
                    icon: const Icon(Icons.attach_file),
                  ),
                IconButton(
                  tooltip: 'Copy full transcript',
                  onPressed: rows.isEmpty
                      ? null
                      : () => Clipboard.setData(
                          ClipboardData(
                            text: rows.map((row) => row.text).join('\n\n'),
                          ),
                        ),
                  icon: const Icon(Icons.copy_all),
                ),
              ],
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
                    if (!questions && rows.isNotEmpty)
                      SelectableText.rich(
                        key: ValueKey('meeting-transcript-$id'),
                        TextSpan(
                          children: [
                            for (
                              var index = 0;
                              index < rows.length;
                              index++
                            ) ...[
                              TextSpan(
                                text:
                                    '${MeetingSpeaker.fromSource(rows[index].source).label}\n',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              TextSpan(text: rows[index].text),
                              if (index < rows.length - 1)
                                const TextSpan(text: '\n\n'),
                            ],
                          ],
                        ),
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    if (questions)
                      for (final t in displayed)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: SelectableText(t.text),
                          subtitle: Text(
                            MeetingSpeaker.fromSource(t.source).label,
                          ),
                          trailing: questions
                              ? IconButton(
                                  tooltip: 'Answer this question',
                                  onPressed:
                                      _operations.busy ||
                                          _chat.asking ||
                                          meetingEnhancing
                                      ? null
                                      : () {
                                          _chatCommands.setQuestion(id, t.text);
                                          update(() => meetingPanel = 'Chat');
                                          unawaited(
                                            _chatCommands.askQuestion(
                                              meetingScope: id,
                                            ),
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
                          subtitle: Text(
                            '${MeetingSpeaker.fromSource(entry.key).label} · Live',
                          ),
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _meetingAutomaticQuestion(MeetingQuestion item) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.question,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(switch (item.state) {
            'queued' => 'Automatic · Waiting',
            'answering' => 'Automatic · Answering…',
            'completed' => 'Automatic · Answered',
            'insufficient_context' => 'Automatic · No supporting sources found',
            'failed' => 'Automatic · Could not answer',
            'cancelled' => 'Automatic · Cancelled',
            'superseded' => 'Automatic · Replaced by an updated question',
            _ => 'Automatic · Saved question',
          }),
          if ((item.error).isNotEmpty) Text(item.error),
          if (item.body != null)
            GeneratedContent(
              item.body!,
              openLink: _host.environment.openUri,
              fontSize: _chat.answerFontSize,
            ),
          if (item.body != null)
            IconButton(
              tooltip: 'Copy automatic answer',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: item.body!)),
              icon: const Icon(Icons.copy_outlined),
            ),
          if (item.citations.isNotEmpty)
            Wrap(
              children: [
                for (final source in item.citations)
                  TextButton(
                    onPressed: () => _chatCommands.cite(source),
                    child: Text(
                      '[${source.label}] source revision ${source.revision}',
                    ),
                  ),
              ],
            ),
          if ([
            'failed',
            'insufficient_context',
            'cancelled',
          ].contains(item.state))
            TextButton(
              onPressed: () => _operations.run(() async {
                await meetingsRetryQuestionDescriptor.send(
                  d,
                  MeetingsRetryQuestionInput(id: item.id),
                );
              }),
              child: const Text('Try again'),
            ),
        ],
      ),
    ),
  );
}
