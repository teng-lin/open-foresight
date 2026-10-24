import 'workspace_view.dart';
import 'collection_view.dart';
import 'summary_view.dart';
import 'recording_view.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foresight_core/desktop.dart';
import '../../failure_text.dart';
import '../../feature_request_identity.dart';
import '../../generated_content.dart';
import '../../presentation/workspace_presentation.dart';
import '../../service_edit_dialog.dart';
import '../../shell/ports.dart';
import '../../shell/workspace_tab.dart';
import 'meeting_export.dart';
import 'meeting_note_state.dart';
import 'meeting_visuals.dart';
import 'note_save_scheduler.dart';
import 'read_model.dart';
part 'notes_view.dart';
part 'assistant_views.dart';
part 'ai_views.dart';

const _meetingAssistantMinWidth = 760.0;

class MeetingsController implements MeetingActivity, MeetingCommands {
  MeetingsController({
    required FeatureHost host,
    required WorkspaceNavigation navigation,
    required OperationGate operations,
    required WorkspaceDialogs dialogs,
    required IntegrationActivity integrations,
    required IntegrationCommands integrationCommands,
    required SettingsCommands settings,
    required ChatActivity chat,
    required ChatCommands chatCommands,
  }) : _host = host,
       _navigation = navigation,
       _operations = operations,
       _dialogs = dialogs,
       _integrations = integrations,
       _integrationCommands = integrationCommands,
       _settings = settings,
       _chat = chat,
       _chatCommands = chatCommands;
  final FeatureHost _host;
  final WorkspaceNavigation _navigation;
  final OperationGate _operations;
  final WorkspaceDialogs _dialogs;
  final IntegrationActivity _integrations;
  final IntegrationCommands _integrationCommands;
  final SettingsCommands _settings;
  final ChatActivity _chat;
  final ChatCommands _chatCommands;
  bool _started = false;
  int _noteReadGeneration = 0;
  late final MeetingReadModel _reads = MeetingReadModel(
    connection: () => d,
    currentPreference: (key, value) {
      if (key == 'audio.systemSetupReviewed' && !_systemAudioSetupInitialized) {
        _systemAudioSetupInitialized = true;
        _systemAudioSetupReviewed = value == 'true';
      }
    },
    changed: () {
      if (!mounted) return;
      final id = meetingId ?? meetingPreviewId;
      if (id != null) loadMeetingNotes(id);
      update(() {});
    },
  );
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _reads.start(selected: meetingId, preview: meetingPreviewId);
  }

  bool _disposed = false;
  Future<void>? _closing;
  DesktopConnection get d => _host.connection;
  bool get mounted => !_disposed && _host.mounted;
  BuildContext get context => _host.context;
  void update(VoidCallback action) {
    if (mounted) _host.update(action);
  }

  void setState(VoidCallback action) => update(action);
  Widget heading(String title, {List<Widget> actions = const []}) =>
      workspaceHeading(title, actions: actions);
  Widget pill(
    String title,
    VoidCallback? action, {
    IconData? icon,
    bool selected = false,
  }) => workspacePill(title, action, icon: icon, selected: selected);
  Widget searchBox(
    String hint,
    ValueChanged<String> onChanged, {
    TextEditingController? controller,
  }) => workspaceSearchBox(
    hint,
    (value) => update(() => onChanged(value)),
    controller: controller,
  );
  String timeLabel(Object? stamp) => workspaceTimeLabel(stamp);
  @override
  int? get selectedMeetingId => meetingId;
  @override
  int? get previewMeetingId => meetingPreviewId;
  @override
  void setSystemAudioSetupReviewed(bool reviewed) =>
      update(() => systemAudioSetupReviewed = reviewed);
  bool get hasPendingNoteSave => meetingNoteSaves.hasWork;
  Future<void> dispose() {
    if (_disposed) return _closing ?? Future<void>.value();
    _disposed = true;
    quickStarting = false;
    unawaited(_reads.dispose());
    _noteReadGeneration++;
    recording?.dispose();
    meetingNotesController.dispose();
    meetingSearchController.dispose();
    return _closing = meetingNoteSaves.close();
  }

  Future<void> runAction(
    Future<void> Function() action, {
    bool Function()? selectionCurrent,
  }) async {
    final identity = FeatureRequestIdentity.capture(d);
    final tab = _navigation.selectedTab,
        selected = meetingId,
        preview = meetingPreviewId;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        _navigation.selectedTab == tab &&
        meetingId == selected &&
        meetingPreviewId == preview &&
        (selectionCurrent?.call() ?? true);
    if (!current()) return;
    await _operations.run(() async {
      try {
        await action();
      } catch (_) {
        if (current()) rethrow;
      }
    });
  }

  String meetingQuery = '';

  final meetingSearchController = TextEditingController();

  final meetingNowKey = GlobalKey();

  bool quickStarting = false;

  bool meetingImmersive = false;

  Duration recordingElapsed = Duration.zero;

  DateTime recordingElapsedAt = DateTime.now();

  bool _systemAudioSetupInitialized = false, _systemAudioSetupReviewed = false;
  @override
  bool get systemAudioSetupReviewed => _systemAudioSetupReviewed;
  set systemAudioSetupReviewed(bool value) {
    _systemAudioSetupInitialized = true;
    _systemAudioSetupReviewed = value;
  }

  int? _meetingId;
  int? get meetingId => _meetingId;
  set meetingId(int? value) {
    if (_meetingId == value) return;
    _meetingId = value;
    _noteReadGeneration++;
    _reads.select(_meetingId, _meetingPreviewId);
  }

  int? recordingMeeting;

  int? _meetingPreviewId;
  int? get meetingPreviewId => _meetingPreviewId;
  set meetingPreviewId(int? value) {
    if (_meetingPreviewId == value) return;
    _meetingPreviewId = value;
    _noteReadGeneration++;
    _reads.select(_meetingId, _meetingPreviewId);
  }

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
          unawaited(_refreshSavedNote(id));
        }
        update(() {});
      }
    },
    onError: (failure, stack) {
      if (mounted)
        update(
          () => _operations.setError(
            'Unable to save meeting notes: ${failureText(failure)}',
          ),
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

  bool meetingEnhancementStarting = false;

  MeetingNoteSnapshot? loadedMeetingNoteSnapshot;

  int? meetingNoteManualEdit;

  bool meetingSidecarVisible = true;

  bool meetingEnhancedVisible = true;

  bool _meetingEnhancing = false;
  @override
  bool get meetingEnhancing => _meetingEnhancing;
  set meetingEnhancing(bool value) {
    if (_meetingEnhancing == value) return;
    _meetingEnhancing = value;
    final id = meetingId ?? meetingPreviewId;
    if (!value && _started && !_disposed && id != null) loadMeetingNotes(id);
  }

  bool meetingAssistantFallback = false;

  bool meetingAssistantWide = false;

  String meetingPanel = 'Chat';

  String meetingEnhanceStatus = '';

  double meetingSidecarWidth = 400;

  DateTime? recordingBegan;

  @override
  RecordingSnapshot? recording;

  final provisionalTranscript = <String, String>{};

  String recordingState = 'idle';

  Future<String> exportMeetingMarkdown() => meetingMarkdown();

  Widget immersiveMeetingWorkspace() => ImmersiveMeetingWorkspace(
    workspace: meetingWorkspace(),
    recordingHeader: recording == null ? null : recordingHeader(),
    onExit: () => update(() => meetingImmersive = false),
  );

  Future<void> _renameMeeting(
    MeetingDetails meeting,
    FeatureRequestIdentity identity,
  ) async {
    bool current() => _meetingActionCurrent(meeting.id, identity);
    if (!current() || !_dialogs.rowsAreCurrent()) return;
    final controller = TextEditingController(text: meeting.title);
    try {
      await _dialogs.showInputDialog<bool>(
        builder: (context) => ServiceEditDialog(
          title: 'Rename meeting',
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
            await d.commandCurrent(Operation.meetingsRename, {
              'id': meeting.id,
              'title': controller.text.trim(),
              'workspace_epoch': identity.workspaceEpoch,
            }, current);
          },
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Widget meetingWorkspace() {
    final id = meetingId!;
    final meeting = _reads.meeting(id);
    if (meeting == null)
      return Center(
        child: Text(
          _reads.meetingLoaded(id)
              ? 'Meeting no longer exists.'
              : 'Loading meeting…',
        ),
      );
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

  Widget meetingListHeading() => heading(
    'Meetings',
    actions: [
      if (!_integrations.googlePresentation.connected)
        OutlinedButton.icon(
          onPressed: _operations.busy
              ? null
              : () => _operations.run(
                  _integrations.granolaCalendar
                      ? _integrationCommands.connectGranolaCalendar
                      : _integrationCommands.connectGoogle,
                ),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: const Text('Connect Calendar'),
        ),
      if (_integrations.googlePresentation.connected)
        OutlinedButton.icon(
          onPressed: _operations.busy || _integrations.googleSyncing
              ? null
              : () => _operations.run(_integrationCommands.syncCalendar),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(
            _integrations.lastCompletedRefreshMilliseconds == 0
                ? 'Import Calendar'
                : 'Last imported: ${timeLabel(_integrations.lastCompletedRefreshMilliseconds)}',
          ),
        ),
      OutlinedButton.icon(
        onPressed: _operations.busy
            ? null
            : () => _operations.run(exportMeetings),
        icon: const Icon(Icons.ios_share, size: 18),
        label: const Text('Export meeting notes'),
      ),
      pill(
        'New meeting',
        _operations.busy || recording != null
            ? null
            : () => _operations.run(() async {
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
                  update(() => meetingId = created['id'] as int);
              }),
        icon: Icons.add,
      ),
    ],
  );

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

  Widget meetingListTile(MeetingCollectionEntry meeting) =>
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
    final meeting = _reads.meeting(id, preview: true);
    if (meeting == null)
      return Center(
        child: Text(
          _reads.meetingLoaded(id, preview: true)
              ? 'Meeting no longer exists.'
              : 'Loading meeting…',
        ),
      );
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

  Widget meetingSummaryPanel(int id, {bool actions = false}) {
    if (actions) return meetingActionsPanel(id);
    final identity = _reads.presentationIdentity;
    final fromPreview = meetingId == null;
    final summary = d.capturePresentation.summary(id);
    final active = summary?.active == true;
    return MeetingSummaryPanel(
      versions: _reads.artifacts(id, 'summary'),
      summary: summary,
      revision: _reads.revision(id) ?? 0,
      fontSize: _chat.answerFontSize,
      openLink: _host.environment.openUri,
      onGenerate:
          identity == null ||
              active ||
              _operations.busy ||
              _chat.asking ||
              meetingEnhancing
          ? null
          : () => _runMeetingAction(
              id,
              identity,
              (current) => generateMeeting(
                'summary',
                id: id,
                workspaceEpoch: identity.workspaceEpoch,
                current: current,
              ),
              preview: fromPreview,
            ),
      onCancel: () => unawaited(
        d
            .command(Operation.meetingsCancelSummary, {'id': id})
            .catchError(_operations.reportAsyncError),
      ),
      onEdit: (artifact) => unawaited(
        editArtifact(artifact).catchError(_operations.reportAsyncError),
      ),
      onCopy: (body) => Clipboard.setData(ClipboardData(text: body)),
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
    return RecordingHeader(
      clock: clock,
      paused: recording!.paused,
      captureVolumes: _host.captureVolumes,
      fallbackVolumes: d is CaptureLevelEvents
          ? null
          : recording!.currentVolumes,
      onToggleWorkspace: () => update(() {
        _navigation.navigate(WorkspaceTab.meetings);
        meetingId = recordingMeeting;
        meetingSidecarVisible = true;
        meetingImmersive = !meetingImmersive;
      }),
      onOpenWorkspace: () => update(() {
        _navigation.navigate(WorkspaceTab.meetings);
        meetingId = recordingMeeting;
        meetingSidecarVisible = true;
      }),
      onPauseResume: _operations.busy || recording!.finishing
          ? null
          : () => _operations.run(() async {
              await d.command(
                recording!.paused
                    ? Operation.meetingsResume
                    : Operation.meetingsPause,
                {'id': recordingMeeting},
              );
              if (mounted) update(syncCapture);
            }),
      onStop: recording!.finishing
          ? null
          : () => _operations.run(stopRecording),
    );
  }

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

  Future<void> startRecording({bool accessReviewed = false}) async {
    final id = meetingId, epoch = d.workspaceEpoch;
    if (!accessReviewed && !await _integrationCommands.ensureRecordingAccess())
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
    await _integrationCommands.notify('Meeting transcription completed');
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

  Future<void> editArtifact(MeetingArtifact a, {String? initialText}) async {
    // The artifact ID belongs to the workspace of the rows on screen.
    if (!_dialogs.rowsAreCurrent()) return;
    final epoch = d.workspaceEpoch;
    final controller = TextEditingController(text: initialText ?? a.body);
    final original = controller.text;
    int? lastManualEdit;
    final saved = await _dialogs.showInputDialog<bool>(
      builder: (context) => ServiceEditDialog(
        title: 'Edit generated artifact',
        controller: controller,
        saveLabel: 'Save edit',
        onChanged: (text) {
          if (a.kind == 'enhanced_notes' &&
              (text != original ||
                  (loadedMeetingNotes == a.meetingId &&
                      meetingNotesController.text !=
                          loadedMeetingNoteSnapshot?.body))) {
            lastManualEdit = DateTime.now().millisecondsSinceEpoch;
          }
        },
        onSave: () async {
          await d.command(Operation.artifactsEdit, {
            'id': a.id,
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

  @override
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

  Future<String?> _speechSetupProblem() async {
    final registration = await readCurrentMeeting<ModelRegistration?>(
      d.store,
      StoreReadQueries.model('speech'),
    );
    return preparedSpeechSetupProblem(registration);
  }

  @override
  Future<void> quickStart() async {
    if (!mounted || quickStarting || _operations.busy || recording != null)
      return;
    final identity = FeatureRequestIdentity.capture(d);
    bool current() => identity.isCurrent(d, alive: mounted);
    update(() => quickStarting = true);
    try {
      final problem = await _speechSetupProblem();
      if (!current()) return;
      if (problem != null) {
        await _settings.chooseSpeech();
        if (!current()) return;
        final problem = await _speechSetupProblem();
        if (!current() || problem != null) return;
      }
      if (!await _integrationCommands.ensureRecordingAccess() || !current())
        return;
      await _operations.run(() async {
        final epoch = d.workspaceEpoch;
        final created =
            await quickStartKey.run(
                  {'title': '[New Meeting]'},
                  (keyed) => d.commandCurrent(Operation.meetingsCreate, {
                    ...keyed,
                    if (epoch != null) 'workspace_epoch': epoch,
                  }, current),
                )
                as Map;
        if (!current()) return;
        update(() {
          _navigation.navigate(WorkspaceTab.meetings);
          meetingId = created['id'] as int;
        });
        await startRecording(accessReviewed: true);
      });
    } catch (failure, stack) {
      if (current())
        await _operations.run(() => Future<void>.error(failure, stack));
    } finally {
      if (mounted) update(() => quickStarting = false);
    }
  }

  Future<void> recordExistingMeeting(int id) async {
    if (_operations.busy || recording != null || quickStarting) return;
    final identity = FeatureRequestIdentity.capture(d),
        selected = meetingId,
        preview = meetingPreviewId;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        meetingId == selected &&
        meetingPreviewId == preview;
    update(() => quickStarting = true);
    try {
      final problem = await _speechSetupProblem();
      if (!current()) return;
      if (problem != null) {
        await _settings.chooseSpeech();
        if (!current()) return;
        final problem = await _speechSetupProblem();
        if (!current() || problem != null) return;
      }
      forgetPendingMeetingCreates();
      update(() => meetingId = id);
      await _operations.run(startRecording);
    } catch (failure, stack) {
      if (current())
        await _operations.run(() => Future<void>.error(failure, stack));
    } finally {
      if (mounted) update(() => quickStarting = false);
    }
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
        update(
          () => _operations.setError(
            'Unable to save meeting notes: ${failureText(failure)}',
          ),
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
    update(() {
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
      if (mounted) update(() => meetingEnhanceStatus = failureText(e));
    } finally {
      if (mounted)
        update(() {
          meetingEnhancementStarting = false;
          syncCapture();
        });
    }
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

  void loadMeetingNotes(int id, {bool acceptedSave = false}) {
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

  Future<void> importMeetingTranscript(int id) async {
    if (!_dialogs.rowsAreCurrent()) return;
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
}

class MeetingsView extends StatelessWidget {
  final MeetingsController controller;
  const MeetingsView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) => controller.meetings();
}
