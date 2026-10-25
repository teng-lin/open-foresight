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
                await d.command(Operation.meetingsRetryDetection, {'id': id});
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

  Widget meetingTranscriptPanel(int id, {bool questions = false}) =>
      MeetingTranscriptPanel(
        id: id,
        rows: _reads.transcript(id),
        provisional: provisionalTranscript,
        questions: questions,
        showProvisional: recordingMeeting == id,
        hasAttachments: _reads.attachments(id).isNotEmpty,
        canAnswer: !_operations.busy && !_chat.asking && !meetingEnhancing,
        onImportTranscript: _operations.busy
            ? null
            : () => _operations.run(() => importMeetingTranscript(id)),
        onImportAttachments:
            _operations.busy || !_integrations.googlePresentation.connected
            ? null
            : () => _operations.run(
                () => _integrationCommands.importMeetingAttachments(id),
              ),
        onCopy: (text) => Clipboard.setData(ClipboardData(text: text)),
        onQuestion: (text) {
          _chatCommands.setQuestion(id, text);
          update(() => meetingPanel = 'Chat');
          unawaited(_chatCommands.askQuestion(meetingScope: id));
        },
      );

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
                await d.command(Operation.meetingsRetryQuestion, {
                  'id': item.id,
                });
              }),
              child: const Text('Try again'),
            ),
        ],
      ),
    ),
  );
}
