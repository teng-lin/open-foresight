part of 'application.dart';

const _meetingAssistantMinWidth = 760.0;

class _MeetingsController extends _FeatureController {
  _MeetingsController(super.shell);

  String meetingQuery = '';

  final meetingSearchController = TextEditingController();

  final meetingNowKey = GlobalKey();

  bool quickStarting = false;

  bool meetingImmersive = false;

  Duration recordingElapsed = Duration.zero;

  DateTime recordingElapsedAt = DateTime.now();

  bool systemAudioSetupReviewed = false;

  int? meetingId;

  int? recordingMeeting;

  int? meetingPreviewId;

  String meetingPreviewTab = 'Notes';

  final meetingNotesController = TextEditingController();

  /// A retry of an unconfirmed create reuses its key, so it creates once.
  final newMeetingKey = PendingRequestKey(),
      quickStartKey = PendingRequestKey(),
      transcriptImportKey = PendingRequestKey();

  /// The meeting, file and text of the transcript import that
  /// [transcriptImportKey] belongs to. Choosing the same file again retries
  /// that import; any other choice is a new import.
  (int, String, String)? transcriptImport;

  /// The user moved to another meeting: an unconfirmed create is not retried
  /// later, where its stored result would name an old meeting.
  void forgetPendingMeetingCreates() {
    newMeetingKey.reset();
    quickStartKey.reset();
  }

  late final NoteSaveScheduler meetingNoteSaves = NoteSaveScheduler(
    (id, body, lastManualEdit) async {
      await d.command(Operation.meetingsNotes, {
        'id': id,
        'body': body,
        if (lastManualEdit != null) 'last_manual_edit': lastManualEdit,
      });
    },
    onSaved: (id) {
      if (mounted) {
        if (loadedMeetingNotes == id && !meetingNoteSaves.isDirty(id)) {
          loadMeetingNotes(id, acceptedSave: true);
        }
        shell.update(() {});
      }
    },
    onError: (failure, stack) {
      if (mounted)
        shell.update(
          () => shell.error =
              'Unable to save meeting notes: ${failureText(failure)}',
        );
      else
        FlutterError.reportError(
          FlutterErrorDetails(exception: failure, stack: stack),
        );
    },
  );

  int? loadedMeetingNotes;

  Map<String, NoteEnhancementPresentation> meetingEnhancements = {};

  // Cancelled by the controller dispose lifecycle.
  // ignore: cancel_subscriptions
  StreamSubscription<void>? noteEnhancementChanges;

  bool meetingEnhancementStarting = false;

  MeetingNoteSnapshot? loadedMeetingNoteSnapshot;

  int? meetingNoteManualEdit;

  bool meetingSidecarVisible = true;

  bool meetingEnhancedVisible = true;

  bool meetingEnhancing = false;

  bool meetingAssistantFallback = false;

  bool meetingAssistantWide = false;

  String meetingPanel = 'Chat';

  String meetingEnhanceStatus = '';

  double meetingSidecarWidth = 400;

  DateTime? recordingBegan;

  RecordingStatus? recording;

  final provisionalTranscript = <String, String>{};

  String recordingState = 'idle';

  String exportMeetingMarkdown() => meetingMarkdown();

  Widget meetings() => MeetingStyleScope(
    child: meetingId == null ? meetingCollection() : meetingWorkspace(),
  );

  Future<String> importText(
    String title,
    String text,
    String mime,
    String provenance, {
    String? id,
    int? modifiedAtMs,
    String? sourceUri,
  }) async {
    final result =
        await d.command(Operation.sourcesImport, {
              'title': title,
              'text': text,
              'mime': mime,
              'provenance': provenance,
              'id': id,
              'modifiedAtMs': modifiedAtMs,
              'sourceUri': sourceUri,
              'index': false,
            })
            as Map;
    return result['id'] as String;
  }

  void syncCapture() {
    final state = d.capturePresentation;
    meetingEnhancements = state.noteEnhancements;
    meetingEnhancing =
        meetingEnhancementStarting ||
        meetingEnhancements.values.any((value) => value.active);
    // The immutable recording facade is the remaining legacy constructor seam;
    // UI decisions below use the typed presentation.
    recording = state.active ? RecordingSnapshot(d.capture) : null;
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

  Future<void> startRecording({bool accessReviewed = false}) async {
    final id = meetingId, epoch = d.workspaceEpoch;
    if (!accessReviewed && !await integrationFeature.ensureRecordingAccess())
      return;
    if (!mounted) return;
    // The OS access prompt can stay open while another client clears the
    // workspace, which closes this meeting. Never record into another one.
    if (d.workspaceEpoch != epoch)
      throw StateError(
        'Recording did not start: the workspace was cleared while recording '
        'access was requested.',
      );
    if (id == null || meetingId != id)
      throw StateError(
        'Recording did not start: the meeting was closed while recording '
        'access was requested.',
      );
    await d.command(Operation.meetingsStart, {'id': id});
    syncCapture();
    if (mounted) setState(() {});
  }

  Future<void> stopRecording() async {
    await d.command(Operation.meetingsStop);
    syncCapture();
    if (mounted) setState(() {});
    await integrationFeature.notify('Meeting transcription completed');
  }

  Future<void> indexMeeting(int id) async {
    await d.command(Operation.meetingsIndex, {'id': id});
  }

  Future<void> generateMeeting(
    String kind, {
    int? id,
    String? workspaceEpoch,
    bool Function()? current,
  }) async {
    final args = {
      'id': id ?? meetingId!,
      'kind': kind,
      if (workspaceEpoch != null) 'workspace_epoch': workspaceEpoch,
    };
    if (current == null) {
      await d.command(Operation.meetingsGenerate, args);
    } else {
      await d.commandCurrent(Operation.meetingsGenerate, args, current);
    }
  }

  Future<void> editArtifact(Map<String, Object?> a) async {
    // The artifact ID belongs to the workspace of the rows on screen.
    if (!shell.rowsAreCurrent()) return;
    final epoch = d.workspaceEpoch;
    final controller = TextEditingController(
      text: (a['edited'] ?? a['generated']) as String,
    );
    final original = controller.text;
    int? lastManualEdit;
    final saved = await shell.showInputDialog<bool>(
      builder: (context) => ServiceEditDialog(
        title: 'Edit generated artifact',
        controller: controller,
        saveLabel: 'Save edit',
        onChanged: (text) {
          if (a['kind'] == 'enhanced_notes' &&
              (text != original ||
                  (loadedMeetingNotes == a['meeting_id'] &&
                      meetingNotesController.text !=
                          loadedMeetingNoteSnapshot?.body))) {
            lastManualEdit = DateTime.now().millisecondsSinceEpoch;
          }
        },
        onSave: () async {
          await d.command(Operation.artifactsEdit, {
            'id': a['id'],
            'text': controller.text,
            if (lastManualEdit != null) 'last_manual_edit': lastManualEdit,
            if (epoch != null) 'workspace_epoch': epoch,
          });
        },
      ),
    );
    if (saved == true && mounted) setState(() {});
    controller.dispose();
  }

  String get echoCancellationDescription {
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

  Future<void> quickStart() async {
    if (!mounted || quickStarting || shell.busy || recording != null) return;
    shell.update(() => quickStarting = true);
    try {
      if (speechSetupProblem(d.store) != null) {
        await settingsFeature.chooseSpeech();
        if (!mounted || speechSetupProblem(d.store) != null) return;
      }
      if (!await integrationFeature.ensureRecordingAccess() || !mounted) return;
      await shell.run(() async {
        final epoch = d.workspaceEpoch;
        final created =
            await quickStartKey.run(
                  {'title': '[New Meeting]'},
                  (keyed) => d.command(Operation.meetingsCreate, {
                    ...keyed,
                    if (epoch != null) 'workspace_epoch': epoch,
                  }),
                )
                as Map;
        // A reply from before a workspace reset names a dropped meeting.
        if (!mounted || d.workspaceEpoch != epoch) return;
        shell.update(() {
          shell.navigate(WorkspaceTab.meetings);
          meetingId = created['id'] as int;
        });
        await startRecording(accessReviewed: true);
      });
    } catch (failure, stack) {
      if (mounted) await shell.run(() => Future<void>.error(failure, stack));
    } finally {
      if (mounted) shell.update(() => quickStarting = false);
    }
  }

  String meetingClock(int milliseconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
  }

  int meetingStart(Map<String, Object?> meeting) =>
      (meeting['calendar_starts'] ?? meeting['created'] ?? 0) as int;

  int meetingEnd(Map<String, Object?> meeting) =>
      (meeting['calendar_ends'] ??
              meetingStart(meeting) +
                  ((meeting['duration_ms'] as int?) ??
                      const Duration(minutes: 30).inMilliseconds))
          as int;

  String meetingDay(int timestamp) {
    if (timestamp == 0) return 'Saved meetings';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day)
      return 'Today';
    return '${['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][date.weekday - 1]}, ${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][date.month - 1]} ${date.day}';
  }

  Widget meetingListHeading() => heading(
    'Meetings',
    actions: [
      if (!integrationFeature.googlePresentation.connected)
        OutlinedButton.icon(
          onPressed: shell.busy
              ? null
              : () => shell.run(integrationFeature.connectGoogle),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: const Text('Connect Calendar'),
        ),
      if (integrationFeature.googlePresentation.connected)
        OutlinedButton.icon(
          onPressed: shell.busy || integrationFeature.googleSyncing
              ? null
              : () => shell.run(integrationFeature.syncCalendar),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(
            integrationFeature.lastCompletedRefreshMilliseconds == 0
                ? 'Import Calendar'
                : 'Last imported: ${timeLabel(integrationFeature.lastCompletedRefreshMilliseconds)}',
          ),
        ),
      OutlinedButton.icon(
        onPressed: shell.busy ? null : () => shell.run(exportMeetings),
        icon: const Icon(Icons.ios_share, size: 18),
        label: const Text('Export meeting notes'),
      ),
      pill(
        'New meeting',
        shell.busy || recording != null
            ? null
            : () => shell.run(() async {
                final epoch = d.workspaceEpoch;
                final created =
                    await newMeetingKey.run(
                          {'title': '[New Meeting]'},
                          (keyed) => d.command(Operation.meetingsCreate, {
                            ...keyed,
                            if (epoch != null) 'workspace_epoch': epoch,
                          }),
                        )
                        as Map;
                if (mounted && d.workspaceEpoch == epoch)
                  shell.update(() => meetingId = created['id'] as int);
              }),
        icon: Icons.add,
      ),
    ],
  );

  Widget meetingList({bool showHeading = true}) {
    final rows = readRows(d.store.meetingCollection)
        .where(
          (m) => (m['title'] as String).toLowerCase().contains(
            meetingQuery.toLowerCase(),
          ),
        )
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    var insertedNow = false;
    Widget nowMarker() => Padding(
      key: meetingNowKey,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
          const SizedBox(width: 12),
          Chip(
            backgroundColor: _blue,
            label: Text(
              '●  Now · ${meetingClock(now)}',
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
        ],
      ),
    );
    final entries = <Widget>[];
    String? previousDay;
    for (final meeting in rows) {
      if (!insertedNow && meetingStart(meeting) > now) {
        entries.add(nowMarker());
        insertedNow = true;
      }
      final day = meetingDay(meetingStart(meeting));
      if (day != previousDay) {
        entries.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            child: Text(day, style: MeetingVisuals.dateHeading),
          ),
        );
        previousDay = day;
      }
      entries.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: meetingListTile(meeting),
        ),
      );
    }
    if (!insertedNow && rows.isNotEmpty) entries.add(nowMarker());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) meetingListHeading(),
        searchBox(
          'Search meetings',
          (value) => meetingQuery = value,
          controller: meetingSearchController,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            meetingSearchController.clear();
            shell.update(() => meetingQuery = '');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final target = meetingNowKey.currentContext;
              if (target != null)
                // The callback intentionally schedules work owned by its controller.
                // ignore: discarded_futures
                Scrollable.ensureVisible(
                  target,
                  duration: const Duration(milliseconds: 250),
                  alignment: .5,
                );
            });
          },
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Now'),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'No meetings yet. Start transcribing or create a new meeting.',
                    ),
                  ),
                ...entries,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget meetingListTile(Map<String, Object?> meeting) {
    final id = meeting['id'] as int;
    final start = meetingStart(meeting);
    final end = meetingEnd(meeting);
    final attachmentCount = readRows(d.store.calendarAttachments(id)).length;
    final state = meeting['state'] as String;
    final active = state == 'recording' || state == 'transcribing';
    void open() => shell.update(() {
      forgetPendingMeetingCreates();
      meetingPreviewId = id;
    });
    return Card(
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: MeetingVisuals.previewRadius,
      ),
      color: meetingPreviewId == id ? const Color(0xffd2deee) : Colors.white,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 650;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meeting['title'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MeetingVisuals.listTitle,
              ),
              if (narrow && start > 0)
                Text(
                  '${meetingClock(start)} – ${meetingClock(end)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (meeting['has_transcript'] == 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xfff3e5f9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.graphic_eq,
                          size: 12,
                          color: Color(0xff7b2cbf),
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Transcript',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xff7b2cbf),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (meeting['calendar_status'] != null &&
                  meeting['calendar_status'] != 'confirmed')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Calendar ${meeting['calendar_status']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (active || state == 'failed' || state == 'interrupted')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    state,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
          return InkWell(
            onTap: open,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  if (!narrow && start > 0)
                    SizedBox(
                      width: 155,
                      child: Text(
                        '${meetingClock(start)} – ${meetingClock(end)}',
                        style: MeetingVisuals.metadata,
                      ),
                    ),
                  Expanded(child: details),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: open,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(40, 28),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.attach_file, size: 14),
                        Text(
                          '$attachmentCount',
                          style: MeetingVisuals.metadata,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: shell.busy || recording != null || quickStarting
                        ? null
                        : () => recordExistingMeeting(id),
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('Start'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> recordExistingMeeting(int id) async {
    if (shell.busy || recording != null || quickStarting) return;
    shell.update(() => quickStarting = true);
    try {
      if (speechSetupProblem(d.store) != null)
        await settingsFeature.chooseSpeech();
      if (!mounted || speechSetupProblem(d.store) != null) return;
      forgetPendingMeetingCreates();
      shell.update(() => meetingId = id);
      await shell.run(startRecording);
    } finally {
      if (mounted) shell.update(() => quickStarting = false);
    }
  }

  Future<void> exportMeetings() async {
    await saveMeetingNotes();
    if (!mounted || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => MeetingExportDialog(
        environment: widget.environment,
        store: d.store,
        save: (markdown) async {
          final location = await getSaveLocation(
            suggestedName: 'meeting_notes.md',
            acceptedTypeGroups: [
              const XTypeGroup(label: 'Markdown', extensions: ['md']),
            ],
          );
          if (location == null) return false;
          await writePrivateTextFile(File(location.path), markdown);
          return true;
        },
      ),
    );
  }

  String meetingMarkdown() => composeMeetingExport(d.store).markdown;

  Widget immersiveMeetingWorkspace() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          shell.update(() => meetingImmersive = false),
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
                        onPressed: () =>
                            shell.update(() => meetingImmersive = false),
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

  Future<void> saveMeetingNotes() async {
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

  Future<void> flushMeetingNotesDraft() async {
    try {
      await meetingNoteSaves.flush();
    } catch (failure) {
      if (mounted) {
        shell.update(
          () => shell.error =
              'Unable to save meeting notes: ${failureText(failure)}',
        );
      }
      rethrow;
    }
  }

  void scheduleMeetingNotesSave() {
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
    scheduleMeetingNotesSave();
  }

  Future<void> enhanceMeetingNotes(int id) async {
    if (meetingEnhancing) return;
    shell.update(() {
      meetingEnhancementStarting = true;
      meetingEnhancing = true;
      meetingEnhanceStatus = '';
    });
    // The ID was read before the flush below; a clear during it must not
    // enhance whichever meeting now has the ID.
    final epoch = d.workspaceEpoch;
    try {
      await flushMeetingNotesDraft();
      await d.command(Operation.meetingsEnhance, {
        'id': id,
        if (epoch != null) 'workspace_epoch': epoch,
      });
    } catch (e) {
      if (mounted) shell.update(() => meetingEnhanceStatus = failureText(e));
    } finally {
      if (mounted)
        shell.update(() {
          meetingEnhancementStarting = false;
          syncCapture();
        });
    }
  }

  void loadMeetingNotes(int id, {bool acceptedSave = false}) {
    final row = d.store.meetingNoteRows(id).firstOrNull;
    final enhanced = d.store.meetingEnhancedNotes(id);
    final stored = MeetingNoteSnapshot(
      body: row?['body'] as String? ?? '',
      enhanced: enhanced,
      timestamp: row?['timestamp'] as int?,
      lastEnhanced: row?['last_enhanced'] as int?,
      lastManualEdit: row?['last_manual_edit'] as int?,
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

  Widget meetingCollection() {
    final id = meetingPreviewId;
    if (id == null) return meetingList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final preview = meetingPreview(id);
        if (constraints.maxWidth < 900) return preview;
        return Column(
          children: [
            meetingListHeading(),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 6, child: meetingList(showHeading: false)),
                  const SizedBox(width: 24),
                  Expanded(flex: 4, child: preview),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget meetingPreview(int id) {
    loadMeetingNotes(id);
    final meeting = d.store.meetingPreviewRows(id).single;
    final start = meetingStart(meeting);
    final end = meetingEnd(meeting);
    return Container(
      key: const ValueKey('meeting-preview'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: MeetingVisuals.previewRadius,
      ),
      child: Column(
        children: [
          Container(
            color: const Color(0xffdfebfb),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        meeting['title'] as String,
                        style: MeetingVisuals.title,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Expand meeting',
                      onPressed: () => shell.update(() {
                        forgetPendingMeetingCreates();
                        meetingId = id;
                      }),
                      icon: const Icon(Icons.open_in_full, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Close meeting preview',
                      onPressed: () async {
                        try {
                          await flushMeetingNotesDraft();
                        } catch (_) {
                          return;
                        }
                        if (mounted)
                          shell.update(() => meetingPreviewId = null);
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Text(
                  '${meetingDay(start)} · ${meetingClock(start)} – ${meetingClock(end)}',
                  style: MeetingVisuals.metadata,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                for (final tab in ['Notes', 'AI summary', 'Transcript'])
                  TextButton(
                    onPressed: () =>
                        shell.update(() => meetingPreviewTab = tab),
                    style: TextButton.styleFrom(
                      backgroundColor: meetingPreviewTab == tab
                          ? _blue
                          : Colors.transparent,
                      foregroundColor: meetingPreviewTab == tab
                          ? _ink
                          : const Color(0xff50555b),
                    ),
                    child: Text(tab),
                  ),
              ],
            ),
          ),
          Expanded(
            child: switch (meetingPreviewTab) {
              'Transcript' => meetingTranscriptPanel(id),
              'AI summary' => meetingSummaryPanel(id),
              _ => meetingNotesEditor(id, false, preview: true),
            },
          ),
        ],
      ),
    );
  }

  Widget meetingWorkspace() {
    final id = meetingId!;
    loadMeetingNotes(id);
    final meeting = d.store.meetingWorkspaceRows(id).single;
    final start = (meeting['starts'] ?? meeting['created'] ?? 0) as int;
    final end =
        (meeting['ends'] ?? start + const Duration(minutes: 30).inMilliseconds)
            as int;
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
            Row(
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
                      shell.update(() {
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
                      Text(
                        meeting['title'] as String,
                        style: MeetingVisuals.title,
                      ),
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
            ),
            if (speechSetupProblem(d.store) != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.info_outline),
                title: Text(speechSetupProblem(d.store)!),
                trailing: TextButton(
                  onPressed: () => settingsFeature.showModelSetup('speech'),
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
                          backgroundColor: showAssistant ? _blue : null,
                          foregroundColor: _ink,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: showAssistant
                            ? () => shell.update(
                                () => meetingSidecarVisible = false,
                              )
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
                            onHorizontalDragUpdate: (drag) => shell.update(
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

  Future<void> openMeetingAssistant(BuildContext workspaceContext) async {
    final id = meetingId;
    final availableWidth = workspaceContext.size!.width;
    shell.update(() {
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
      shell.update(() => meetingAssistantFallback = true);
  }

  Future<void> importMeetingTranscript(int id) async {
    if (!shell.rowsAreCurrent()) return;
    final epoch = d.workspaceEpoch;
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Transcript text', extensions: ['txt']),
      ],
    );
    if (file == null) return;
    final text = await File(file.path).readAsString();
    // An append is not idempotent: retrying an import whose reply was lost
    // must not add its segments twice.
    final chosen = (id, file.path, text);
    if (transcriptImport != chosen) {
      transcriptImportKey.reset();
      transcriptImport = chosen;
    }
    await transcriptImportKey.run(
      {'id': id, 'text': text, 'source': 'imported transcript'},
      (keyed) => d.command(Operation.meetingsTranscript, {
        ...keyed,
        if (epoch != null) 'workspace_epoch': epoch,
      }),
    );
    transcriptImport = null;
  }

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
                            }).catchError(shell.reportAsyncError),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                      IconButton(
                        tooltip: 'Hide enhanced notes',
                        onPressed: () =>
                            shell.update(() => meetingEnhancedVisible = false),
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
                            openLink: widget.environment.openUri,
                          ),
                        ),
                ),
                if (meetingNotesController.text.isNotEmpty)
                  TextButton.icon(
                    onPressed:
                        meetingEnhancing || shell.busy || chatFeature.asking
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
                        () => settingsFeature.preference('noteStyle', style!),
                      ),
                    ),
                    const SizedBox(width: 18),
                    if (preview)
                      FilledButton.tonalIcon(
                        onPressed:
                            meetingEnhancing ||
                                shell.busy ||
                                chatFeature.asking ||
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
                        onPressed: () => shell.update(() {
                          unawaited(
                            runAction(
                              () => settingsFeature.preference(
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
                            shell.update(() => meetingEnhancedVisible = true),
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
          onPanelSelected: (panel) => shell.update(() => meetingPanel = panel),
          onFontSizeChanged: (delta) => chatFeature.setAnswerFontSize(
            (chatFeature.answerFontSize + delta).clamp(12, 24),
          ),
          onClose: () => shell.update(() => meetingSidecarVisible = false),
        ),
        if (meetingPanel == 'Chat' || meetingPanel == 'Live Q&A')
          meetingAnswerScope(id, automatic: meetingPanel == 'Live Q&A'),
        Expanded(
          child: IndexedStack(
            index: MeetingAssistantHeader.panels.indexOf(meetingPanel),
            children: [
              chatFeature.chat(meetingScope: id, compact: true),
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
    final automatic = d.store.preference('proactiveAnswers', 'true') == 'true';
    final detected = readRows(d.store.meetingQuestions(id));
    final manual = d.store
        .finalTranscript(id)
        .where(
          (row) =>
              (row['text'] as String).contains(RegExp('[?？]')) &&
              !detected.any((question) => question['question'] == row['text']),
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
            () => settingsFeature.preference('proactiveAnswers', '$enabled'),
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
              onPressed: () => shell.run(() async {
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
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item['question'] as String,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(switch (item['state']) {
                                'queued' => 'Automatic · Waiting',
                                'answering' => 'Automatic · Answering…',
                                'completed' => 'Automatic · Answered',
                                'insufficient_context' =>
                                  'Automatic · No supporting sources found',
                                'failed' => 'Automatic · Could not answer',
                                'cancelled' => 'Automatic · Cancelled',
                                'superseded' =>
                                  'Automatic · Replaced by an updated question',
                                _ => 'Automatic · Saved question',
                              }),
                              if ((item['error'] as String).isNotEmpty)
                                Text(item['error'] as String),
                              if (item['body'] != null)
                                GeneratedContent(
                                  item['body'] as String,
                                  openLink: widget.environment.openUri,
                                  fontSize: chatFeature.answerFontSize,
                                ),
                              if (item['body'] != null)
                                IconButton(
                                  tooltip: 'Copy automatic answer',
                                  onPressed: () => Clipboard.setData(
                                    ClipboardData(text: item['body'] as String),
                                  ),
                                  icon: const Icon(Icons.copy_outlined),
                                ),
                              if (item['citations'] != null)
                                Wrap(
                                  children: [
                                    for (final source
                                        in jsonDecode(
                                              item['citations'] as String,
                                            )
                                            as List)
                                      TextButton(
                                        onPressed: () => chatFeature.citation(
                                          Map<String, Object?>.from(
                                            source as Map,
                                          ),
                                        ),
                                        child: Text(
                                          '[${source['citation']}] source revision ${source['revision']}',
                                        ),
                                      ),
                                  ],
                                ),
                              if ([
                                'failed',
                                'insufficient_context',
                                'cancelled',
                              ].contains(item['state']))
                                TextButton(
                                  onPressed: () => shell.run(() async {
                                    await d.command(
                                      Operation.meetingsRetryQuestion,
                                      {'id': item['id']},
                                    );
                                  }),
                                  child: const Text('Try again'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    for (final row in manual)
                      ListTile(
                        title: SelectableText(row['text'] as String),
                        trailing: IconButton(
                          tooltip: 'Answer this question',
                          onPressed:
                              shell.busy ||
                                  chatFeature.asking ||
                                  meetingEnhancing
                              ? null
                              : () {
                                  chatFeature.setQuestion(
                                    id,
                                    row['text'] as String,
                                  );
                                  shell.update(() => meetingPanel = 'Chat');
                                  unawaited(
                                    chatFeature.askQuestion(meetingScope: id),
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
    final rows = readRows(d.store.meetingTranscript(id));
    final displayed = questions
        ? rows.where((t) => (t['text'] as String).contains('?')).toList()
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
                  onPressed: shell.busy
                      ? null
                      : () => shell.run(() => importMeetingTranscript(id)),
                  icon: const Icon(Icons.file_upload_outlined),
                ),
                if (readRows(d.store.calendarAttachments(id)).isNotEmpty)
                  IconButton(
                    tooltip: 'Import meeting attachments',
                    onPressed:
                        shell.busy ||
                            !integrationFeature.googlePresentation.connected
                        ? null
                        : () => shell.run(
                            () =>
                                integrationFeature.importMeetingAttachments(id),
                          ),
                    icon: const Icon(Icons.attach_file),
                  ),
                IconButton(
                  tooltip: 'Copy full transcript',
                  onPressed: rows.isEmpty
                      ? null
                      : () => Clipboard.setData(
                          ClipboardData(
                            text: rows.map((row) => row['text']).join('\n\n'),
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
                                    '${MeetingSpeaker.fromSource(rows[index]['source'] as String).label}\n',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              TextSpan(text: rows[index]['text'] as String),
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
                          title: SelectableText(t['text'] as String),
                          subtitle: Text(
                            MeetingSpeaker.fromSource(
                              t['source'] as String,
                            ).label,
                          ),
                          trailing: questions
                              ? IconButton(
                                  tooltip: 'Answer this question',
                                  onPressed:
                                      shell.busy ||
                                          chatFeature.asking ||
                                          meetingEnhancing
                                      ? null
                                      : () {
                                          chatFeature.setQuestion(
                                            id,
                                            t['text'] as String,
                                          );
                                          shell.update(
                                            () => meetingPanel = 'Chat',
                                          );
                                          unawaited(
                                            chatFeature.askQuestion(
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

  Widget meetingSummaryPanel(int id, {bool actions = false}) {
    if (actions) return meetingActionsPanel(id);
    final identity = FeatureRequestIdentity.capture(d);
    final fromPreview = meetingId == null;
    final kind = actions ? 'actions' : 'summary';
    final title = actions ? 'Action items' : 'Summary';
    final versions = readRows(d.store.meetingArtifacts(id, kind));
    final artifact = versions.firstOrNull;
    final summary = actions ? null : d.capturePresentation.summary(id);
    final active = summary?.active == true;
    final preview = summary?.preview ?? '';
    final manifest = artifact?['manifest'] as String?;
    final clipped =
        manifest != null &&
        (jsonDecode(manifest) as Map)['reduction_clipped'] == true;
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
                onPressed:
                    active ||
                        shell.busy ||
                        chatFeature.asking ||
                        meetingEnhancing
                    ? null
                    : () => _runMeetingAction(
                        id,
                        identity,
                        (current) => generateMeeting(
                          kind,
                          id: id,
                          workspaceEpoch: identity.workspaceEpoch,
                          current: current,
                        ),
                        preview: fromPreview,
                      ),
                icon: const Icon(Icons.auto_awesome),
              ),
              if (active)
                IconButton(
                  tooltip: 'Cancel summary',
                  onPressed: () => unawaited(
                    d
                        .command(Operation.meetingsCancelSummary, {'id': id})
                        .catchError(shell.reportAsyncError),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Copy $title',
                  onPressed: () => Clipboard.setData(
                    ClipboardData(
                      text:
                          (artifact['edited'] ?? artifact['generated'])
                              as String,
                    ),
                  ),
                  icon: const Icon(Icons.copy_outlined),
                ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Edit $title',
                  onPressed: active
                      ? null
                      : () => unawaited(
                          editArtifact(
                            artifact,
                          ).catchError(shell.reportAsyncError),
                        ),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
        ),
        if (active) ...[
          LinearProgressIndicator(
            value: (summary?.total ?? 0) > 0
                ? ((summary?.completed ?? 0) / summary!.total).clamp(0.0, 1.0)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(switch (summary?.phase) {
              'mapping' =>
                'Summarizing transcript ${summary?.completed}/${summary?.total}',
              'reducing' => 'Combining meeting topics…',
              'updating' => 'Updating the meeting brief…',
              'summarizing' => 'Writing the meeting brief…',
              _ => 'Preparing the meeting summary…',
            }),
          ),
        ],
        Expanded(
          child: active && preview.isNotEmpty
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: GeneratedContent(
                    preview,
                    openLink: widget.environment.openUri,
                    fontSize: chatFeature.answerFontSize,
                  ),
                )
              : artifact == null
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
                      if ((artifact['input_revision'] as int? ?? 0) <
                          (d.store.meetingRevision(id) ?? 0))
                        const Text('Out of date — regenerate'),
                      if (clipped)
                        const Text(
                          'This summary used shortened excerpts. Review the transcript for full context.',
                        ),
                      GeneratedContent(
                        (artifact['edited'] ?? artifact['generated']) as String,
                        openLink: widget.environment.openUri,
                        fontSize: chatFeature.answerFontSize,
                      ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final previous in versions.skip(1))
                              ListTile(
                                title: GeneratedContent(
                                  (previous['edited'] ?? previous['generated'])
                                      as String,
                                  openLink: widget.environment.openUri,
                                ),
                                trailing: IconButton(
                                  tooltip: 'Edit previous version',
                                  onPressed: () => unawaited(
                                    editArtifact(
                                      previous,
                                    ).catchError(shell.reportAsyncError),
                                  ),
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
    final elapsed =
        recordingElapsed +
        (recording!.paused
            ? Duration.zero
            : DateTime.now().difference(recordingElapsedAt));
    final clock =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => shell.update(() {
        shell.navigate(WorkspaceTab.meetings);
        meetingId = recordingMeeting;
        meetingSidecarVisible = true;
        meetingImmersive = !meetingImmersive;
      }),
      child: Container(
        key: const ValueKey('recording-pill'),
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
              key: const ValueKey('recording-clock'),
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
                child: ValueListenableBuilder<List<double>>(
                  valueListenable: shell.captureVolumes,
                  builder: (context, volumes, child) => CustomPaint(
                    key: const ValueKey('capture-waveform'),
                    painter: _CaptureWaveform(
                      d is CaptureLevelEvents
                          ? volumes
                          : recording!.currentVolumes,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: recording!.paused
                  ? 'Resume transcribing'
                  : 'Pause transcribing',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: shell.busy || recording!.finishing
                  ? null
                  : () => shell.run(() async {
                      await d.command(
                        recording!.paused
                            ? Operation.meetingsResume
                            : Operation.meetingsPause,
                        {'id': recordingMeeting},
                      );
                      if (mounted) shell.update(syncCapture);
                    }),
              icon: Icon(
                recording!.paused ? Icons.play_arrow : Icons.pause,
                color: _ink,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: 'Stop transcribing',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: recording!.finishing
                  ? null
                  : () => shell.run(stopRecording),
              icon: const Icon(
                Icons.stop_circle_outlined,
                color: _ink,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: 'Open transcription workspace',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: () => shell.update(() {
                shell.navigate(WorkspaceTab.meetings);
                meetingId = recordingMeeting;
                meetingSidecarVisible = true;
              }),
              icon: const Icon(Icons.fullscreen, color: _ink, size: 23),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeetingsView extends StatelessWidget {
  final _MeetingsController controller;
  const _MeetingsView(this.controller);
  @override
  Widget build(BuildContext context) => controller.meetings();
}
