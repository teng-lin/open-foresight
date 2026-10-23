import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foresight_core/desktop.dart';
import '../../desktop_reader_adapters.dart';
import '../../failure_text.dart';
import '../../feature_request_identity.dart';
import '../../generated_content.dart';
import '../../model_setup.dart';
import '../../presentation/workspace_presentation.dart';
import '../../service_edit_dialog.dart';
import '../../shell/ports.dart';
import '../../shell/workspace_tab.dart';
import 'capture_waveform.dart';
import 'meeting_export.dart';
import 'meeting_note_state.dart';
import 'meeting_visuals.dart';
import 'note_save_scheduler.dart';
part 'collection_view.dart';
part 'workspace_view.dart';
part 'notes_view.dart';
part 'assistant_views.dart';
part 'summary_view.dart';
part 'recording_view.dart';
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
    unawaited(noteEnhancementChanges?.cancel());
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

  @override
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
  StreamSubscription<void>? noteEnhancementChanges;

  bool meetingEnhancementStarting = false;

  MeetingNoteSnapshot? loadedMeetingNoteSnapshot;

  int? meetingNoteManualEdit;

  bool meetingSidecarVisible = true;

  bool meetingEnhancedVisible = true;

  @override
  bool meetingEnhancing = false;

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

  String exportMeetingMarkdown() => meetingMarkdown();

  Widget immersiveMeetingWorkspace() => _immersiveMeetingWorkspace();

  Widget recordingHeader() => _recordingHeader();

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

  Future<void> editArtifact(Map<String, Object?> a) async {
    // The artifact ID belongs to the workspace of the rows on screen.
    if (!_dialogs.rowsAreCurrent()) return;
    final epoch = d.workspaceEpoch;
    final controller = TextEditingController(
      text: (a['edited'] ?? a['generated']) as String,
    );
    final original = controller.text;
    int? lastManualEdit;
    final saved = await _dialogs.showInputDialog<bool>(
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

  @override
  Future<void> quickStart() async {
    if (!mounted || quickStarting || _operations.busy || recording != null)
      return;
    update(() => quickStarting = true);
    try {
      if (speechSetupProblem(d.store) != null) {
        await _settings.chooseSpeech();
        if (!mounted || speechSetupProblem(d.store) != null) return;
      }
      if (!await _integrationCommands.ensureRecordingAccess() || !mounted)
        return;
      await _operations.run(() async {
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
        update(() {
          _navigation.navigate(WorkspaceTab.meetings);
          meetingId = created['id'] as int;
        });
        await startRecording(accessReviewed: true);
      });
    } catch (failure, stack) {
      if (mounted)
        await _operations.run(() => Future<void>.error(failure, stack));
    } finally {
      if (mounted) update(() => quickStarting = false);
    }
  }

  Future<void> recordExistingMeeting(int id) async {
    if (_operations.busy || recording != null || quickStarting) return;
    update(() => quickStarting = true);
    try {
      if (speechSetupProblem(d.store) != null) await _settings.chooseSpeech();
      if (!mounted || speechSetupProblem(d.store) != null) return;
      forgetPendingMeetingCreates();
      update(() => meetingId = id);
      await _operations.run(startRecording);
    } finally {
      if (mounted) update(() => quickStarting = false);
    }
  }

  Future<void> exportMeetings() async {
    await saveMeetingNotes();
    if (!mounted || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => MeetingExportDialog(
        environment: _host.environment,
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
