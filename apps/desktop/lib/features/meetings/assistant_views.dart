part of 'meetings_controller.dart';

extension _AssistantViews on MeetingsController {
  Widget meetingAssistant(int id) => MeetingAssistant(
    selectedPanel: meetingPanel,
    onPanelSelected: (panel) => update(() => meetingPanel = panel),
    onFontSizeChanged: (delta) => update(
      () => _chatCommands.setAnswerFontSize(
        (_chat.answerFontSize + delta).clamp(12, 24),
      ),
    ),
    onClose: () => update(() => meetingSidecarVisible = false),
    answerScope: meetingPanel == 'Chat' || meetingPanel == 'Live Q&A'
        ? meetingAnswerScope(id, automatic: meetingPanel == 'Live Q&A')
        : null,
    panels: [
      _chatCommands.chat(meetingScope: id, compact: true),
      meetingQuestionsPanel(id),
      meetingSummaryPanel(id),
      meetingTranscriptPanel(id),
      meetingSummaryPanel(id, actions: true),
      meetingPreparationPanel(id),
    ],
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
    return MeetingQuestionsPanel(
      automatic: automatic,
      detectorConfigured: capture.questionDetector.configured,
      queuedAnswers: pipeline.queuedAnswers,
      oldestQueueAgeMs: pipeline.oldestQueueAgeMs,
      waiting:
          (pipeline.running && pipeline.activeMeeting == id) ||
          pipeline.pendingMeetings.contains(id),
      detectionError: detectionError,
      onAutomaticChanged: (enabled) =>
          runAction(() => _settings.preference('proactiveAnswers', '$enabled')),
      onRetryDetection: () => _operations.run(() async {
        await meetingsRetryDetectionDescriptor.send(
          d,
          MeetingsRetryDetectionInput(id: id),
        );
      }),
      questions: [for (final item in detected) _meetingAutomaticQuestion(item)],
      manual: [for (final row in manual) row.text],
      canAnswer: !_operations.busy && !_chat.asking && !meetingEnhancing,
      onQuestion: (text) {
        _chatCommands.setQuestion(id, text);
        update(() => meetingPanel = 'Chat');
        unawaited(_chatCommands.askQuestion(meetingScope: id));
      },
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
        onListen: _audioTranscriptListener(id),
        onCorrectSpeaker: _operations.busy
            ? null
            : (row) => _correctSpeaker(id, row),
        onMarkUnnamed: _operations.busy
            ? null
            : (row) => _operations.run(() => _markSpeakerUnnamed(id, row)),
        onResetSpeaker: _operations.busy
            ? null
            : (row) => _operations.run(() => _resetSpeaker(id, row)),
        onRenameParticipant: _operations.busy
            ? null
            : (row) => _renameParticipant(id, row),
        onQuestion: (text) {
          _chatCommands.setQuestion(id, text);
          update(() => meetingPanel = 'Chat');
          unawaited(_chatCommands.askQuestion(meetingScope: id));
        },
      );

  Widget _meetingAutomaticQuestion(MeetingQuestion item) =>
      MeetingAutomaticQuestion(
        item: item,
        fontSize: _chat.answerFontSize,
        openLink: _host.environment.openUri,
        onCopy: (text) => Clipboard.setData(ClipboardData(text: text)),
        onCite: _chatCommands.cite,
        onRetry: () => _operations.run(() async {
          await meetingsRetryQuestionDescriptor.send(
            d,
            MeetingsRetryQuestionInput(id: item.id),
          );
        }),
      );
}

/// Speaker corrections on saved transcript rows. Each action is bound to the
/// rendered workspace identity, so a view that has since changed is refused.
extension _TranscriptActions on MeetingsController {
  ClientEnvelope _envelope(FeatureRequestIdentity identity) =>
      ClientEnvelope(workspaceEpoch: WireField(identity.workspaceEpoch));

  Future<void> _nameDialog({
    required int meeting,
    required String title,
    required String initial,
    required Future<void> Function(
      String name,
      FeatureRequestIdentity identity,
      bool Function() current,
    )
    save,
  }) async {
    final identity = _reads.presentationIdentity;
    if (identity == null) return;
    bool current() => _meetingActionCurrent(meeting, identity);
    if (!current() || !_dialogs.rowsAreCurrent()) return;
    final controller = TextEditingController(text: initial);
    try {
      await _dialogs.showInputDialog<bool>(
        builder: (context) => ServiceEditDialog(
          title: title,
          controller: controller,
          saveLabel: 'Save',
          height: 90,
          maxLines: 1,
          onSave: () async {
            if (!current()) {
              throw StateError(
                'The meeting view changed. Close this editor and try again.',
              );
            }
            final name = controller.text.trim();
            if (name.isEmpty) {
              throw StateError(
                'Enter a name. To remove a name, use Clear speaker name.',
              );
            }
            await save(name, identity, current);
          },
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _correctSpeaker(int meeting, TranscriptSegment row) =>
      _nameDialog(
        meeting: meeting,
        title: 'Correct speaker',
        initial: AttributedTranscript.personName(row) ?? '',
        save: (name, identity, current) =>
            meetingsAttributeDescriptor.sendCurrent(
              d,
              MeetingsAttributeInput(
                id: row.id,
                name: WireField(name),
                envelope: _envelope(identity),
              ),
              current,
            ),
      );

  Future<void> _renameParticipant(int meeting, TranscriptSegment row) {
    final participant = row.participantId;
    if (participant == null) return Future.value();
    return _nameDialog(
      meeting: meeting,
      title: 'Rename participant',
      initial: AttributedTranscript.personName(row) ?? '',
      save: (name, identity, current) =>
          meetingsRenameParticipantDescriptor.sendCurrent(
            d,
            MeetingsRenameParticipantInput(
              id: participant,
              name: name,
              envelope: _envelope(identity),
            ),
            current,
          ),
    );
  }

  Future<void> _markSpeakerUnnamed(int meeting, TranscriptSegment row) async {
    final identity = _reads.presentationIdentity;
    if (identity == null) return;
    bool current() => _meetingActionCurrent(meeting, identity);
    if (!current()) return;
    await meetingsAttributeDescriptor.sendCurrent(
      d,
      MeetingsAttributeInput(id: row.id, envelope: _envelope(identity)),
      current,
    );
  }

  Future<void> _resetSpeaker(int meeting, TranscriptSegment row) async {
    final identity = _reads.presentationIdentity;
    if (identity == null) return;
    bool current() => _meetingActionCurrent(meeting, identity);
    if (!current()) return;
    await meetingsResetAttributionDescriptor.sendCurrent(
      d,
      MeetingsResetAttributionInput(id: row.id, envelope: _envelope(identity)),
      current,
    );
  }
}
