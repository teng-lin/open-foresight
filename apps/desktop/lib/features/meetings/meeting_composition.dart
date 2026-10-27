part of 'meetings_controller.dart';

extension _MeetingComposition on MeetingsController {
  Widget _composeImmersiveMeetingWorkspace() => ImmersiveMeetingWorkspace(
    workspace: meetingWorkspace(),
    recordingHeader: recording == null ? null : recordingHeader(),
    onExit: () => update(() => meetingImmersive = false),
  );

  Widget meetingWorkspace() {
    final id = meetingId!;
    final meeting = _reads.meeting(id);
    if (meeting == null)
      return MeetingReadStatus(loaded: _reads.meetingLoaded(id));
    final start = meeting.starts ?? meeting.created ?? 0;
    final end =
        meeting.ends ?? start + const Duration(minutes: 30).inMilliseconds;
    final date = DateTime.fromMillisecondsSinceEpoch(start).toLocal();
    final dateText =
        '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1]}, ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]} ${date.day}, ${date.year}';
    final identity = _reads.presentationIdentity;
    return MeetingWorkspacePanel(
      header: MeetingWorkspaceHeader(
        title: meeting.title,
        dateText: dateText,
        timeText: '${meetingClock(start)} - ${meetingClock(end)}',
        onRename: identity == null
            ? null
            : () => _renameMeeting(meeting, identity),
        onBack: () async {
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
      ),
      speechProblem: preparedSpeechSetupProblem(_reads.speech),
      onSetupSpeech: () => _settings.showModelSetup('speech'),
      sidecarVisible: meetingSidecarVisible,
      assistantFallback: meetingAssistantFallback,
      sidecarWidth: meetingSidecarWidth,
      assistantMinWidth: _meetingAssistantMinWidth,
      onAssistantWidth: (wide) => meetingAssistantWide = wide,
      onSidecarWidth: (width) => update(() => meetingSidecarWidth = width),
      onHideAssistant: () => update(() => meetingSidecarVisible = false),
      onOpenAssistant: (context) => openMeetingAssistant(context),
      notesBuilder: (large, toggle) =>
          meetingNotesEditor(id, large, assistantToggle: toggle),
      assistantBuilder: () => meetingAssistant(id),
    );
  }

  String meetingClock(int milliseconds) => meetingClockLabel(milliseconds);
  int meetingStart(MeetingDetails meeting) => meetingStartMilliseconds(meeting);
  int meetingEnd(MeetingDetails meeting) => meetingEndMilliseconds(meeting);
  String meetingDay(int timestamp) => meetingDayLabel(timestamp);

  MeetingTimelineEntry _meetingEntry(MeetingCollectionEntry meeting) =>
      MeetingTimelineEntry(
        meeting: meeting,
        dayLabel: meetingDay(meetingStart(meeting)),
        attachmentCount: _reads.attachments(meeting.id).length,
        selected: meetingPreviewId == meeting.id,
        canRecord: !_operations.busy && recording == null && !quickStarting,
      );

  void _openMeetingPreview(int id) => update(() {
    forgetPendingMeetingCreates();
    meetingPreviewId = id;
  });

  Widget _composeMeetingListTile(MeetingCollectionEntry meeting) =>
      MeetingCollectionTile(
        entry: _meetingEntry(meeting),
        onOpen: () => _openMeetingPreview(meeting.id),
        onRecord: () => recordExistingMeeting(meeting.id),
      );

  Widget meetingList({bool showHeading = true}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return MeetingTimeline(
      entries: _reads.meetings
          .where(
            (meeting) => meeting.title.toLowerCase().contains(
              meetingQuery.toLowerCase(),
            ),
          )
          .map(_meetingEntry)
          .toList(),
      now: now,
      nowClock: meetingClock(now),
      nowKey: meetingNowKey,
      heading: showHeading ? meetingListHeading() : null,
      search: searchBox(
        'Search meetings',
        (value) => meetingQuery = value,
        controller: meetingSearchController,
      ),
      onOpen: _openMeetingPreview,
      onRecord: (id) => recordExistingMeeting(id),
      onNow: () {
        meetingSearchController.clear();
        update(() => meetingQuery = '');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = meetingNowKey.currentContext;
          if (target != null) {
            // The controller owns the scheduled scroll, including its key.
            // ignore: discarded_futures
            Scrollable.ensureVisible(
              target,
              duration: const Duration(milliseconds: 250),
              alignment: .5,
            );
          }
        });
      },
    );
  }

  Widget meetingCollection() {
    final id = meetingPreviewId;
    if (id == null) return meetingList();
    return MeetingCollectionLayout(
      previewBuilder: (_) => meetingPreview(id),
      headingBuilder: (_) => meetingListHeading(),
      listBuilder: (_) => meetingList(showHeading: false),
    );
  }

  Widget meetingPreview(int id) {
    final meeting = _reads.meeting(id, preview: true);
    if (meeting == null)
      return MeetingReadStatus(loaded: _reads.meetingLoaded(id, preview: true));
    final start = meetingStart(meeting), end = meetingEnd(meeting);
    return MeetingPreviewCard(
      title: meeting.title,
      metadata:
          '${meetingDay(start)} · ${meetingClock(start)} – ${meetingClock(end)}',
      selectedTab: meetingPreviewTab,
      onExpand: () => update(() {
        forgetPendingMeetingCreates();
        meetingId = id;
      }),
      onClose: () async {
        try {
          await flushMeetingNotesDraft();
        } catch (_) {
          return;
        }
        if (mounted) update(() => meetingPreviewId = null);
      },
      onTab: (tab) => update(() => meetingPreviewTab = tab),
      content: switch (meetingPreviewTab) {
        'Transcript' => meetingTranscriptPanel(id),
        'AI summary' => meetingSummaryPanel(id),
        _ => meetingNotesEditor(id, false, preview: true),
      },
    );
  }

  Widget meetings() => MeetingStyleScope(
    child: meetingId == null ? meetingCollection() : meetingWorkspace(),
  );

  void _composeSyncCapture() {
    _reads.reconcile();
    final state = d.capturePresentation;
    meetingEnhancements = state.noteEnhancements;
    meetingEnhancing =
        meetingEnhancementStarting ||
        meetingEnhancements.values.any((value) => value.active);
    recording = state.active ? RecordingSnapshot.fromPresentation(state) : null;
    recordingMeeting = state.meetingId;
    recordingState = state.state;
    final began = state.beganMilliseconds;
    recordingBegan = began == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(began);
    recordingElapsedAt = DateTime.now();
    recordingElapsed = Duration(
      milliseconds: state.elapsedMillisecondsProvided
          ? state.elapsedMilliseconds
          : recordingBegan == null
          ? 0
          : recordingElapsedAt.difference(recordingBegan!).inMilliseconds,
    );
    provisionalTranscript
      ..clear()
      ..addAll(state.provisional);
  }

  Future<void> exportMeetings() async {
    final identity = FeatureRequestIdentity.capture(d);
    bool current() => identity.isCurrent(d, alive: mounted);
    await saveMeetingNotes();
    if (!current() || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => MeetingExportDialog(
        environment: _host.environment,
        store: d.store,
        current: current,
        save: (markdown) async {
          if (!current()) return false;
          final location = await getSaveLocation(
            suggestedName: 'meeting_notes.md',
            acceptedTypeGroups: [
              const XTypeGroup(label: 'Markdown', extensions: ['md']),
            ],
          );
          if (location == null || !current()) return false;
          await writePrivateTextFile(File(location.path), markdown);
          return true;
        },
      ),
    );
  }

  Future<String> meetingMarkdown() async =>
      (await readMeetingExport(d.store)).markdown;

  void _composeFormatMeetingNotes(String before, [String after = '']) {
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
    scheduleMeetingNotesSave();
  }

  Future<void> openMeetingAssistant(BuildContext workspaceContext) async {
    final id = meetingId;
    final availableWidth = workspaceContext.size!.width;
    update(() {
      meetingSidecarVisible = true;
      meetingAssistantFallback = false;
    });
    if (availableWidth >= _meetingAssistantMinWidth) return;
    try {
      await const MethodChannel('foresight/window').invokeMethod<void>(
        'ensureWidth',
        {
          // The app adds 24px more right padding above 1000px window width.
          'width':
              MediaQuery.sizeOf(context).width +
              _meetingAssistantMinWidth -
              availableWidth +
              24,
        },
      );
      // Native resize requests are asynchronous, especially on Wayland.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } on MissingPluginException {
      // Hosts without native window control can still open the assistant.
    } on PlatformException {
      // A compositor may decline application-requested window resizing.
    }
    if (!mounted || !workspaceContext.mounted || meetingId != id) return;
    if (workspaceContext.size!.width < _meetingAssistantMinWidth &&
        meetingSidecarVisible)
      update(() => meetingAssistantFallback = true);
  }

  String get _composeEchoCancellationDescription {
    final capture = d.capturePresentation;
    final echo = capture.echoCancellation;
    if (!capture.active)
      return 'Reduce system playback picked up by your microphone.';
    if (capture.paused)
      return 'The selected setting will apply when recording resumes.';
    if (echo.pending) return 'Applying echo cancellation…';
    if (echo.fallbackStatus != 0)
      return 'Echo cancellation is unavailable; microphone recording continues.';
    if (echo.restartRequired)
      return 'Restart recording to enable echo cancellation.';
    return echo.active
        ? 'Echo cancellation is active for this microphone.'
        : 'Echo cancellation is off.';
  }

  Future<String?> _speechSetupProblem({
    required bool Function() current,
  }) async {
    final registration = await readCurrentRecordingSetup<ModelRegistration?>(
      d.store,
      StoreReadQueries.model('speech'),
      current: current,
      ownerChanges: [d.changes, _recordingAdmissionChanges.stream],
    );
    return preparedSpeechSetupProblem(registration);
  }

  Future<void> _refreshSavedNote(int id) async {
    final identity = FeatureRequestIdentity.capture(d),
        generation = _noteReadGeneration;
    final body = meetingNotesController.text,
        manualEdit = meetingNoteManualEdit;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        generation == _noteReadGeneration &&
        loadedMeetingNotes == id &&
        !meetingNoteSaves.isDirty(id) &&
        meetingNotesController.text == body &&
        meetingNoteManualEdit == manualEdit;
    try {
      await Future.wait([
        readCurrentMeeting(d.store, StoreReadQueries.meetingNote(id)),
        readCurrentMeeting(d.store, StoreReadQueries.enhancedNotes(id)),
      ]);
      if (current()) loadMeetingNotes(id, acceptedSave: true);
    } catch (_) {
      // The write is accepted. Retain its draft until a later current watch
      // reply arrives rather than turning a read failure into a save failure.
    }
  }

  void _composeLoadMeetingNotes(int id, {bool acceptedSave = false}) {
    if (!_reads.noteLoaded(id) || !_reads.enhancedLoaded(id)) return;
    final row = _reads.note(id);
    final stored = MeetingNoteSnapshot(
      body: row?.body ?? '',
      enhanced: _reads.enhanced(id),
      timestamp: row?.timestamp,
      lastEnhanced: row?.lastEnhancedAt,
      lastManualEdit: row?.lastManualEdit,
    );
    final changedId = loadedMeetingNotes != id;
    if (changedId ||
        acceptedSave ||
        (row != null &&
            !stored.sameRecord(loadedMeetingNoteSnapshot) &&
            stored.shouldReload(
              currentBody: meetingNotesController.text,
              currentEnhanced: loadedMeetingNoteSnapshot?.enhanced ?? '',
              localManualEdit: meetingNoteManualEdit,
              localEnhanced: loadedMeetingNoteSnapshot?.lastEnhanced,
              dirty: meetingNoteSaves.isDirty(id),
              programmaticWrite: meetingEnhancing,
            ))) {
      if (changedId) {
        unawaited(flushMeetingNotesDraft().catchError((Object _) {}));
        loadedMeetingNotes = id;
      }
      if (meetingNotesController.text != stored.body)
        meetingNotesController.text = stored.body;
      loadedMeetingNoteSnapshot = stored;
      meetingNoteManualEdit = stored.lastManualEdit;
      meetingEnhanceStatus = '';
    }
  }

  Future<void> _composeSaveMeetingNotes() async {
    final id = loadedMeetingNotes;
    if (id == null) return;
    meetingNoteSaves.schedule(
      id,
      meetingNotesController.text,
      lastManualEdit: meetingNoteManualEdit,
    );
    try {
      await flushMeetingNotesDraft();
    } catch (_) {
      // flushMeetingNotesDraft already presented this failed save.
    }
  }

  Future<void> _composeFlushMeetingNotesDraft() async {
    try {
      await meetingNoteSaves.flush();
    } catch (failure) {
      if (mounted) {
        update(
          () => _operations.setError(
            'Unable to save meeting notes: ${failureText(failure)}',
          ),
        );
      }
      rethrow;
    }
  }

  void _composeScheduleMeetingNotesSave() {
    final id = loadedMeetingNotes;
    if (id == null) return;
    if (meetingNotesController.text != loadedMeetingNoteSnapshot?.body) {
      meetingNoteManualEdit = DateTime.now().millisecondsSinceEpoch;
    }
    meetingNoteSaves.schedule(
      id,
      meetingNotesController.text,
      lastManualEdit: meetingNoteManualEdit,
    );
  }
}
