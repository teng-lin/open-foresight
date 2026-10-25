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
part 'meeting_composition.dart';
part 'notes_view.dart';
part 'assistant_views.dart';
part 'ai_views.dart';

const _meetingAssistantMinWidth = 760.0;

class MeetingsController implements MeetingActivity, MeetingCommands {
  Widget immersiveMeetingWorkspace() => _composeImmersiveMeetingWorkspace();
  void syncCapture() => _composeSyncCapture();
  void loadMeetingNotes(int id, {bool acceptedSave = false}) =>
      _composeLoadMeetingNotes(id, acceptedSave: acceptedSave);
  void formatMeetingNotes(String before, [String after = '']) =>
      _composeFormatMeetingNotes(before, after);
  Widget meetingListTile(MeetingCollectionEntry meeting) =>
      _composeMeetingListTile(meeting);
  @override
  String get echoCancellationDescription => _composeEchoCancellationDescription;
  Future<void> saveMeetingNotes() => _composeSaveMeetingNotes();
  Future<void> flushMeetingNotesDraft() => _composeFlushMeetingNotesDraft();
  void scheduleMeetingNotesSave() => _composeScheduleMeetingNotesSave();
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
