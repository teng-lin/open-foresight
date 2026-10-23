import 'desktop_environment.dart';
import 'features/integrations/audio_access.dart';
import 'shell/workspace_tab.dart';
import 'shell/ports.dart';
import 'presentation/workspace_presentation.dart';
import 'system_audio_setup_dialog.dart';
import 'onboarding_view.dart';
import 'model_terms_dialog.dart';

import 'background_store.dart';
import 'desktop_reader_adapters.dart';
import 'service_edit_dialog.dart';
import 'failure_text.dart';
import 'feature_request_identity.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show SemanticsProperties;
import 'package:intl/intl.dart' show NumberFormat;
import 'package:foresight_core/desktop.dart';
import 'graph_label_controls.dart';
import 'cluster_rendering.dart';
import 'model_setup.dart';
import 'app_theme.dart';
import 'meeting_visuals.dart';
import 'desktop_settings.dart';
import 'desktop_visuals.dart';
import 'commands.dart';
import 'calendar_auth_links.dart';
import 'global_shortcuts.dart';
import 'desktop_menu.dart';
import 'hypr_shortcuts.dart';
import 'google_picker.dart';
import 'google_sign_in_dialog.dart';
import 'account_button.dart';
import 'gemma_setup_view.dart';
import 'speech_setup_view.dart';
import 'file_discovery_sheet.dart';
import 'graph_rendering.dart';
import 'meeting_export.dart';
import 'note_save_scheduler.dart';
import 'meeting_note_state.dart';
import 'generated_content.dart';
import 'agent_approval_surface.dart';

part 'onboarding_controller.dart';
part 'workspace_controller.dart';
part 'workspace_visuals.dart';
part 'sources_controller.dart';
part 'chat_controller.dart';
part 'meetings_controller.dart';
part 'meeting_ai_views.dart';
part 'settings_controller.dart';
part 'integrations_controller.dart';
part 'shell/legacy_feature_adapters.dart';

class Foresight extends StatelessWidget {
  final DesktopConnection domain;
  final AppCommands? commands;
  final bool quickOnLaunch;
  final Future<List<AudioDevice>> Function()? deviceLoader;
  final Future<void> Function(Uri)? sourceLinkOpener;
  final DesktopEnvironment environment;
  const Foresight(
    this.domain, {
    super.key,
    this.commands,
    this.quickOnLaunch = false,
    this.deviceLoader,
    this.sourceLinkOpener,
    this.environment = const DesktopEnvironment(),
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Open Foresight',
    debugShowCheckedModeBanner: false,
    theme: foresightTheme(),
    home: Workspace(
      domain,
      commands: commands,
      quickOnLaunch: quickOnLaunch,
      deviceLoader: deviceLoader,
      sourceLinkOpener: sourceLinkOpener,
      environment: environment,
    ),
  );
}

class Workspace extends StatefulWidget {
  final DesktopConnection domain;
  final AppCommands? commands;
  final bool quickOnLaunch;
  final Future<List<AudioDevice>> Function()? deviceLoader;
  final Future<void> Function(Uri)? sourceLinkOpener;
  final DesktopEnvironment environment;
  const Workspace(
    this.domain, {
    super.key,
    this.commands,
    this.quickOnLaunch = false,
    this.deviceLoader,
    this.sourceLinkOpener,
    this.environment = const DesktopEnvironment(),
  });
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace>
    with TickerProviderStateMixin, WidgetsBindingObserver
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceDialogs,
        WorkspaceLifecycle {
  final calendarAuthLinks = CalendarAuthLinks();
  late final onboardingFeature = _OnboardingController(this);
  late final sourceFeature = _SourcesController(this);
  late final chatFeature = _ChatController(this);
  late final meetingFeature = _MeetingsController(this);
  late final settingsFeature = _SettingsController(this);
  late final integrationFeature = _IntegrationsController(this);

  late final PreferenceCommands preferenceCommands = _LegacyPreferenceCommands(
    settingsFeature,
  );
  late final meetingPorts = _LegacyMeetingPorts(meetingFeature);
  late final OnboardingActivity onboardingActivity = _LegacyOnboardingActivity(
    onboardingFeature,
  );

  DesktopConnection get d => widget.domain;

  @override
  DesktopConnection get connection => d;
  @override
  DesktopEnvironment get environment => widget.environment;
  @override
  TickerProvider get vsync => this;
  @override
  Future<List<AudioDevice>> Function()? get deviceLoader => widget.deviceLoader;
  @override
  Future<void> Function(Uri) get sourceLinkOpener =>
      widget.sourceLinkOpener ?? widget.environment.openUri;
  @override
  AppCommands? get commands => widget.commands;

  @override
  void update(VoidCallback action) => setState(action);

  @override
  final ValueNotifier<int> serviceUiRevision = ValueNotifier<int>(0);
  @override
  final ValueNotifier<List<double>> captureVolumes =
      ValueNotifier<List<double>>(const []);
  StreamSubscription<List<double>>? captureLevels;
  StreamSubscription<void>? connectionChanges;
  late final DesktopMenu desktopMenu;

  Timer? serviceUiTimer;

  /// Set while this desktop clears the workspace itself.
  @override
  bool clearingWorkspace = false;

  @override
  void setClearingWorkspace(bool value) =>
      update(() => clearingWorkspace = value);

  @override
  void serviceChanged() {
    if (d.store.failure case final failure?) {
      if (mounted) setState(() => error = failure.message);
      return;
    }
    if (mounted && chatFeature.retireChangedAnswer()) setState(() {});
    // Another client cleared the workspace: views must not keep editing IDs
    // that the service may hand to new items.
    if (mounted && d.workspaceReplaced) {
      final discarded = !clearingWorkspace && unsavedWorkspaceEdits();
      update(resetWorkspaceViews);
      if (discarded) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Workspace cleared elsewhere; unsaved edits were discarded.',
            ),
          ),
        );
      }
    }
    if (!mounted || serviceUiTimer != null) return;
    serviceUiTimer = Timer(const Duration(milliseconds: 100), () {
      serviceUiTimer = null;
      if (!mounted) return;
      meetingFeature.syncCapture();
      sourceFeature.syncGraphMotion();
      serviceUiRevision.value++;
    });
  }

  WorkspaceTab tab = WorkspaceTab.meetings;

  @override
  WorkspaceTab get selectedTab => tab;

  @override
  void navigate(WorkspaceTab destination) => update(() => tab = destination);

  @override
  bool busy = false;

  int _operations = 0;

  @override
  String error = '';

  @override
  void setError(String message) => update(() => error = message);

  @override
  void initState() {
    super.initState();
    // No view holds an ID yet, so a clear before startup needs no reset.
    if (d.workspaceReplaced) d.adoptWorkspace();
    WidgetsBinding.instance.addObserver(this);
    desktopMenu = DesktopMenu(integrationFeature.activateMenuCommand);
    sourceFeature.graphMotionTicker = createTicker(
      sourceFeature.tickGraphMotion,
    );
    sourceFeature.graphCameraController = AnimationController(vsync: this);
    sourceFeature.graphCameraController.addListener(() {
      final tween = sourceFeature.graphCameraTween;
      if (mounted && tween != null) {
        sourceFeature.graphTransform.value = tween.transform(
          sourceFeature.graphCameraCurve.transform(
            sourceFeature.graphCameraController.value,
          ),
        );
      }
    });
    settingsFeature.embeddingGpu =
        d.store.model('embedding')?.backend == 'litert_lm_embedding_gpu';
    meetingFeature.systemAudioSetupReviewed =
        d.store.preference('audio.systemSetupReviewed') == 'true';
    integrationFeature.commands = widget.commands;
    integrationFeature.commands?.onError =
        integrationFeature.reportShortcutFailure;
    integrationFeature.commands?.setHandler(
      (command, token) => command == 'calendar-auth'
          ? integrationFeature.completeCalendarSignIn(token!)
          : command == 'quick-meeting'
          ? integrationFeature.requestQuickMeeting(token)
          : command == 'stop-meeting'
          ? (meetingFeature.recording != null &&
                    !meetingFeature.recording!.finishing
                ? run(meetingFeature.stopRecording)
                : Future<void>.value())
          : integrationFeature.activateWindow(token),
    );
    unawaited(
      calendarAuthLinks.start(
        (url) => run(() => integrationFeature.completeCalendarSignIn(url)),
      ),
    );
    if (widget.quickOnLaunch)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(
          integrationFeature.requestQuickMeeting(
            widget.environment.variables['XDG_ACTIVATION_TOKEN'],
          ),
        ),
      );
    if (d.store.preference('globalShortcut') == 'true') {
      unawaited(
        integrationFeature.enableGlobalShortcuts().catchError((Object e) {
          if (mounted)
            setState(
              () => integrationFeature.globalShortcutState = e.toString(),
            );
        }),
      );
    }
    integrationFeature
        .google; // Create the independently versioned connection tables.
    integrationFeature.googleState = integrationFeature.googleAuth.loadError;
    unawaited(integrationFeature.refreshAudioDevices());
    if (Platform.isMacOS) {
      unawaited(integrationFeature.refreshCaptureCapabilities());
      unawaited(integrationFeature.refreshLoginSetting());
    }

    integrationFeature.notifications =
        d.store.preference('notifications') == 'true';
    unawaited(integrationFeature.refreshNotifications());
    meetingFeature.syncCapture();
    final connection = d;
    if (connection is CaptureLevelEvents) {
      captureLevels = (connection as CaptureLevelEvents).captureLevels.listen((
        volumes,
      ) {
        if (mounted) captureVolumes.value = volumes;
      });
    }
    connectionChanges = d.changes.listen((_) => serviceChanged());
    Future<void> initializeConnection() async {
      await d.initialize();
      try {
        await d.resume();
      } finally {
        if (mounted) setState(() => onboardingFeature.ready = true);
        if (mounted &&
            !onboardingFeature.active &&
            widget.commands != null &&
            !settingsFeature.modelSetupShown &&
            (needsModel(d.store, 'embedding') ||
                needsModel(d.store, 'generation'))) {
          settingsFeature.modelSetupShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(settingsFeature.chooseGemma(firstRun: true));
          });
          if (mounted) setState(() {});
        }
      }
    }

    unawaited(
      initializeConnection().catchError((Object e) {
        if (mounted)
          setState(
            () => error = e is StateError ? e.message.toString() : e.toString(),
          );
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isMacOS && state == AppLifecycleState.resumed) {
      unawaited(integrationFeature.refreshCaptureCapabilities());
    }
  }

  @override
  void didChangeMetrics() {
    if (!meetingFeature.meetingAssistantFallback) return;
    // Measure the workspace after layout; a compositor may cap the requested
    // resize, leaving the compact assistant necessary.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          meetingFeature.meetingAssistantFallback &&
          meetingFeature.meetingAssistantWide) {
        update(() => meetingFeature.meetingAssistantFallback = false);
      }
    });
  }

  @override
  void dispose() {
    chatFeature.retireAnswer();
    desktopMenu.close();
    WidgetsBinding.instance.removeObserver(this);
    calendarAuthLinks.close();
    serviceUiTimer?.cancel();
    serviceUiRevision.dispose();
    unawaited(captureLevels?.cancel());
    unawaited(connectionChanges?.cancel());
    captureVolumes.dispose();
    unawaited(meetingFeature.noteEnhancementChanges?.cancel());
    void releaseDomain() {
      d.close();
    }

    void closeDomain() => releaseDomain();

    final hasPendingNoteSave = meetingFeature.meetingNoteSaves.hasWork;
    final pendingNoteSave = meetingFeature.meetingNoteSaves.close();
    if (!hasPendingNoteSave)
      closeDomain();
    else
      unawaited(
        pendingNoteSave.then(
          (_) => closeDomain(),
          onError: (Object failure, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(exception: failure, stack: stack),
            );
            closeDomain();
          },
        ),
      );
    unawaited(integrationFeature.googleAuth.close());
    unawaited(integrationFeature.commands?.close() ?? Future<void>.value());
    unawaited(
      integrationFeature.globalShortcuts?.close() ?? Future<void>.value(),
    );
    sourceFeature.graphMotionTicker.dispose();
    sourceFeature.graphCameraController.dispose();
    sourceFeature.graphMotionFrames.dispose();
    sourceFeature.graphTransform.dispose();
    meetingFeature.recording?.dispose();
    for (final c in [
      ...chatFeature.questionDrafts.values,
      sourceFeature.sourceSearchController,
      sourceFeature.graphLabelInput,
      meetingFeature.noteTitle,
      meetingFeature.noteBody,
      settingsFeature.modelPath,
      settingsFeature.runtimePath,
      settingsFeature.tokenizer,
      meetingFeature.meetingNotesController,
      meetingFeature.meetingSearchController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Whether the rows on screen belong to the workspace the views edit. A
  /// clear elsewhere can commit before its event resets the views; until
  /// then a row on screen may name an ID that the new workspace reuses, so
  /// a dialog that edits one is not opened.
  @override
  bool rowsAreCurrent() {
    if (d.store.failure != null) return false;
    final stored = d.store.workspaceEpoch;
    if (stored.isEmpty || stored == d.workspaceEpoch) return true;
    update(
      () => error =
          'The workspace was cleared elsewhere. Wait for the views to '
          'refresh, then try again.',
    );
    return false;
  }

  /// Whether a reset would drop text the user has not saved. Only whether,
  /// never the text itself, is reported.
  bool unsavedWorkspaceEdits() {
    final meetings = meetingFeature;
    final loaded = meetings.loadedMeetingNotes;
    return meetings.meetingNoteSaves.hasWork ||
        (loaded != null && meetings.meetingNoteSaves.isDirty(loaded)) ||
        meetings.noteTitle.text != meetings.noteBaseline.$1 ||
        meetings.noteBody.text != meetings.noteBaseline.$2 ||
        chatFeature.questionDrafts.values.any((draft) => draft.text.isNotEmpty);
  }

  /// Drop every view and draft that holds an ID from the cleared workspace,
  /// then let by-ID edits name the new one.
  @override
  void resetWorkspaceViews() {
    chatFeature.retireAnswer();
    meetingFeature.meetingNoteSaves.discardAll();
    meetingFeature.meetingId = null;
    meetingFeature.meetingPreviewId = null;
    sourceFeature.graphSelectedDocument = null;
    meetingFeature.loadedMeetingNotes = null;
    meetingFeature.meetingNotesController.clear();
    meetingFeature.meetingEnhanceStatus = '';
    sourceFeature.sourceQuery = '';
    sourceFeature.sourceSearchController.clear();
    meetingFeature.meetingQuery = '';
    sourceFeature.labelFilter = '';
    meetingFeature.noteEditorGeneration++;
    meetingFeature.noteId = null;
    meetingFeature.noteTitle.clear();
    meetingFeature.noteBody.clear();
    meetingFeature.noteBaseline = ('', '');
    chatFeature.hiddenAnswers.clear();
    chatFeature.answer = '';
    // Drafts are keyed by meeting ID, which the new workspace can reuse.
    for (final draft in chatFeature.questionDrafts.values) {
      draft.clear();
    }
    for (final key in [
      meetingFeature.newNoteKey,
      meetingFeature.newMeetingKey,
      meetingFeature.quickStartKey,
      meetingFeature.transcriptImportKey,
    ]) {
      key.reset();
    }
    meetingFeature.transcriptImport = null;
    d.adoptWorkspace();
  }

  @override
  void reportAsyncError(Object failure) {
    if (mounted) setState(() => error = failure.toString());
  }

  @override
  Future<void> run(Future<void> Function() action) async {
    setState(() {
      _operations++;
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = failureText(e));
      // The request may have committed: read the views again.
      if (mounted && outcomeUnknown(e)) serviceUiRevision.value++;
      await integrationFeature.notify('Operation failed: ${failureText(e)}');
    } finally {
      _operations--;
      if (mounted) setState(() => busy = _operations != 0);
    }
  }

  @override
  Future<T?> showInputDialog<T>({required WidgetBuilder builder}) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final result = await Navigator.of(context).push(route);
    await route.completed;
    // The departing route has unmounted before callers release input controllers.
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (d.store.failure case final failure?) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(failure.message),
          ),
        ),
      );
    }
    sourceFeature.syncGraphMotion();
    final onboarding = onboardingFeature.active;
    final workspace = onboarding
        ? onboardingFeature.build()
        : meetingFeature.meetingImmersive && meetingFeature.meetingId != null
        ? ValueListenableBuilder<int>(
            valueListenable: serviceUiRevision,
            builder: (_, __, ___) => meetingFeature.immersiveMeetingWorkspace(),
          )
        : screenshotWorkspace(context);
    return AgentApprovalSurface(
      domain: d,
      allowAgentRequests: !onboarding,
      child: workspace,
    );
  }

  Widget screenshotWorkspace(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(
        LogicalKeyboardKey.digit1,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          navigate(WorkspaceTab.meetings),
      SingleActivator(
        LogicalKeyboardKey.digit2,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          navigate(WorkspaceTab.chat),
      SingleActivator(
        LogicalKeyboardKey.digit3,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          navigate(WorkspaceTab.sources),
      SingleActivator(
        LogicalKeyboardKey.digit4,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          navigate(WorkspaceTab.stats),
      SingleActivator(
        LogicalKeyboardKey.digit5,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          navigate(WorkspaceTab.settings),
      integrationFeature.quickActivator: () {
        if (!busy && meetingFeature.recording == null)
          unawaited(meetingFeature.quickStart());
      },
      SingleActivator(
        LogicalKeyboardKey.keyO,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () {
        if (!busy) unawaited(run(sourceFeature.import));
      },
      SingleActivator(
        LogicalKeyboardKey.keyN,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () => update(() {
        navigate(WorkspaceTab.notes);
        meetingFeature.noteEditorGeneration++;
        meetingFeature.noteId = null;
        meetingFeature.noteBaseline = ('', '');
        meetingFeature.newNoteKey.reset();
        meetingFeature.noteTitle.clear();
        meetingFeature.noteBody.clear();
      }),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: Column(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: serviceUiRevision,
              builder: (_, __, ___) => Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  28,
                  meetingFeature.recording != null ? 16 : 24,
                  8,
                ),
                child: LayoutBuilder(
                  builder: (_, constraints) => SizedBox(
                    width: constraints.maxWidth,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.max(200, constraints.maxWidth - 260),
                          ),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Image.asset(
                                    'assets/images/open-foresight-logo.png',
                                    width: 24,
                                    height: 24,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text.rich(
                                      TextSpan(
                                        children: const [
                                          TextSpan(
                                            text: 'Open ',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          TextSpan(text: 'Foresight'),
                                        ],
                                      ),
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                  ),
                                ],
                              ),
                              if (MediaQuery.sizeOf(context).width > 1100) ...[
                                Chip(
                                  label: Text(
                                    'Powered by ${settingsFeature.embeddingName()}',
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    '${settingsFeature.localWords()} Local output words',
                                  ),
                                ),
                              ],
                              SizedBox(
                                width: 32,
                                height: 28,
                                child: IconButton(
                                  tooltip: 'Local helper status',
                                  onPressed: settingsFeature.showHelperMonitor,
                                  padding: EdgeInsets.zero,
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.white.withValues(
                                      alpha: .7,
                                    ),
                                    foregroundColor: _ink,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  icon: Icon(
                                    settingsFeature.helperEmbeddingHealthy
                                        ? Icons.task_alt
                                        : Icons.info_outline,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (meetingFeature.recording != null)
                          meetingFeature.recordingHeader()
                        else
                          FilledButton.icon(
                            onPressed:
                                busy ||
                                    meetingFeature.quickStarting ||
                                    meetingFeature.meetingEnhancing
                                ? null
                                : tab == WorkspaceTab.meetings &&
                                      meetingFeature.meetingId != null
                                ? () => meetingFeature.recordExistingMeeting(
                                    meetingFeature.meetingId!,
                                  )
                                : meetingFeature.quickStart,
                            icon: Icon(
                              meetingFeature.recording != null
                                  ? Icons.stop
                                  : Icons.graphic_eq,
                            ),
                            label: Text(
                              meetingFeature.recording != null
                                  ? 'Stop transcribing'
                                  : 'Start transcribing',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: _ink,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 16,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width:
                        72 *
                        MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                    child: Column(
                      children: [
                        Expanded(
                          child: ListView(
                            children: [
                              navItem(
                                WorkspaceTab.meetings,
                                'Meetings',
                                tab == WorkspaceTab.meetings
                                    ? Icons.description
                                    : Icons.description_outlined,
                              ),
                              navItem(
                                WorkspaceTab.chat,
                                'Ask',
                                tab == WorkspaceTab.chat
                                    ? Icons.chat_bubble
                                    : Icons.chat_bubble_outline,
                              ),
                              navItem(
                                WorkspaceTab.sources,
                                'Sources',
                                tab == WorkspaceTab.sources
                                    ? Icons.snippet_folder
                                    : Icons.snippet_folder_outlined,
                              ),
                              navItem(
                                WorkspaceTab.stats,
                                'Stats',
                                tab == WorkspaceTab.stats
                                    ? Icons.emoji_events
                                    : Icons.emoji_events_outlined,
                              ),
                            ],
                          ),
                        ),
                        navItem(
                          WorkspaceTab.settings,
                          'Settings',
                          tab == WorkspaceTab.settings ||
                                  tab == WorkspaceTab.models
                              ? Icons.settings
                              : Icons.settings_outlined,
                        ),
                        IconButton(
                          tooltip: 'Help',
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => const AlertDialog(
                              title: Text('Foresight'),
                              content: Text(
                                'Add local knowledge sources, then ask a question with citations. Start transcribing captures microphone and system playback; live transcription updates during recording.\n\nCtrl+1–5: navigate\nCtrl+O: add file\nCtrl+N: new note\nCtrl+Shift+F: start a meeting',
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.help_outline),
                        ),
                        AccountButton(
                          connected: integrationFeature.googleAuth.connected,
                          busy: busy,
                          displayName:
                              integrationFeature.googleAuth.displayName,
                          email: integrationFeature.googleAuth.email,
                          photoUrl: integrationFeature.googleAuth.photoUrl,
                          account: integrationFeature.googleAuth.account,
                          accounts: integrationFeature.googleAuth.accounts,
                          onSignIn: () => run(integrationFeature.connectGoogle),
                          onAddAccount: () =>
                              run(integrationFeature.addGoogleAccount),
                          onSwitchAccount: (id) => run(
                            () => integrationFeature.switchGoogleAccount(id),
                          ),
                          onSignOutAccount: (id) => run(
                            () => integrationFeature.signOutGoogleAccount(id),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        tab == WorkspaceTab.chat ||
                                (tab == WorkspaceTab.meetings &&
                                    meetingFeature.meetingId != null)
                            ? 16
                            : MediaQuery.sizeOf(context).width > 1000
                            ? 56
                            : 16,
                        tab == WorkspaceTab.meetings &&
                                meetingFeature.meetingId != null
                            ? 12
                            : tab == WorkspaceTab.chat
                            ? 22
                            : 34,
                        MediaQuery.sizeOf(context).width > 1000
                            ? (tab == WorkspaceTab.chat ||
                                      (tab == WorkspaceTab.meetings &&
                                          meetingFeature.meetingId != null)
                                  ? 40
                                  : tab == WorkspaceTab.settings
                                  ? 88
                                  : 68)
                            : 16,
                        28,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (busy) const LinearProgressIndicator(),
                          if (error.isNotEmpty)
                            Material(
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText(error),
                              ),
                            ),
                          Expanded(
                            child: ValueListenableBuilder<int>(
                              valueListenable: serviceUiRevision,
                              builder: (_, __, ___) => switch (tab) {
                                WorkspaceTab.sources => _SourcesView(
                                  sourceFeature,
                                ),
                                WorkspaceTab.chat => _ChatView(chatFeature),
                                WorkspaceTab.notes => sourceFeature.notes(),
                                WorkspaceTab.meetings => _MeetingsView(
                                  meetingFeature,
                                ),
                                WorkspaceTab.models => settingsFeature.models(),
                                WorkspaceTab.stats => settingsFeature.stats(),
                                WorkspaceTab.settings => _SettingsView(
                                  settingsFeature,
                                ),
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget navItem(
    WorkspaceTab destination,
    String title,
    IconData icon,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: Material(
      color:
          tab == destination ||
              destination == WorkspaceTab.settings && tab == WorkspaceTab.models
          ? _blue
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => navigate(destination),
        child: SizedBox(
          width: 56 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          height: 54 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: tab == destination ? _ink : const Color(0xff45494b),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
