import 'shell/feature_updates.dart';
import 'shell/test_access.dart';
export 'shell/test_access.dart' show WorkspaceTestAccess;
import 'desktop_environment.dart';
import 'features/chat/chat_controller.dart';
import 'features/meetings/meetings_controller.dart';
import 'feature_request_identity.dart';
import 'shell/feature_bridges.dart';
import 'features/integrations/integrations_controller.dart';
import 'shell/workspace_tab.dart';
import 'shell/ports.dart';
import 'features/settings/settings_controller.dart';
import 'features/sources/sources_controller.dart';
import 'shell/workspace_view.dart';

import 'features/onboarding/onboarding_controller.dart';

import 'failure_text.dart';

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foresight_core/desktop.dart';
import 'app_theme.dart';
import 'commands.dart';
import 'calendar_auth_links.dart';
import 'desktop_menu.dart';
import 'account_button.dart';
import 'agent_approval_surface.dart';

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
        WorkspaceLifecycle,
        // The composition root implements the test contract; only tests consume it.
        // ignore: invalid_use_of_visible_for_testing_member
        WorkspaceTestAccess {
  late final calendarAuthLinks = CalendarAuthLinks(
    capabilities: environment.capabilities,
  );
  @override
  late final OnboardingController onboardingFeature = OnboardingController(
    host: featureHost(DesktopFeature.onboarding),
    navigation: this,
    operations: this,
    lifecycle: this,
    settings: settingsFeature,
    sources: sourceFeature,
    integrations: integrationFeature,
  );
  @override
  late final SourcesController sourceFeature = SourcesController(
    host: featureHost(DesktopFeature.sources),
    navigation: this,
    operations: this,
    dialogs: this,
    integrations: integrationFeature,
  );
  @override
  late final ChatController chatFeature = ChatController(
    host: featureHost(DesktopFeature.chat),
    navigation: this,
    operations: this,
    meetings: meetingPorts,
    sources: sourceFeature,
  );
  @override
  late final MeetingsController meetingFeature = MeetingsController(
    host: featureHost(DesktopFeature.meetings),
    navigation: this,
    operations: this,
    dialogs: this,
    integrations: integrationFeature,
    integrationCommands: integrationFeature,
    settings: settingsFeature,
    chat: chatFeature,
    chatCommands: chatFeature,
  );
  @override
  late final SettingsController settingsFeature = SettingsController(
    host: featureHost(DesktopFeature.settings),
    navigation: this,
    operations: this,
    lifecycle: this,
    integrations: integrationFeature,
    integrationCommands: integrationFeature,
    meetings: meetingPorts,
  );
  @override
  late final IntegrationsController integrationFeature = IntegrationsController(
    host: featureHost(DesktopFeature.integrations),
    navigation: this,
    operations: this,
    dialogs: this,
    preferences: preferenceCommands,
    meetings: meetingPorts,
    meetingCommands: meetingPorts,
    onboarding: onboardingActivity,
  );

  @override
  late final PreferenceCommands preferenceCommands = PreferenceCommandBridge(
    (key, value) => settingsFeature.preference(key, value),
  );
  @override
  late final MeetingPortsBridge meetingPorts = MeetingPortsBridge(
    () => meetingFeature,
    () => meetingFeature,
  );
  @override
  late final OnboardingActivity onboardingActivity = OnboardingActivityBridge(
    () => onboardingFeature.active,
  );

  @override
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
  void update(VoidCallback action) {
    featureUpdates.all();
    setState(action);
  }

  final featureUpdates = FeatureUpdates();
  FeatureHost featureHost(DesktopFeature feature) =>
      FeatureHostBridge(this, (action) {
        if (!mounted) return;
        featureUpdates.changed(feature);
        setState(action);
      });

  @override
  final ValueNotifier<int> serviceUiRevision = ValueNotifier<int>(0);
  @override
  final ValueNotifier<List<double>> captureVolumes =
      ValueNotifier<List<double>>(const []);
  StreamSubscription<List<double>>? captureLevels;
  StreamSubscription<void>? connectionChanges;
  late final DesktopMenu desktopMenu;

  @override
  Timer? serviceUiTimer;

  /// Set while this desktop clears the workspace itself.
  @override
  bool clearingWorkspace = false;

  @override
  void setClearingWorkspace(bool value) => clearingWorkspace = value;

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

  @override
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
    desktopMenu = DesktopMenu(
      integrationFeature.activateMenuCommand,
      capabilities: environment.capabilities,
    );
    sourceFeature.initializeGraph();
    settingsFeature.start();
    onboardingFeature.start();
    meetingFeature.start();
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
    unawaited(_initializePreferences());
    integrationFeature.googleState = integrationFeature.googleAuth.loadError;
    unawaited(integrationFeature.refreshAudioDevices());
    if (environment.capabilities.requiresAudioPermissions) {
      unawaited(integrationFeature.refreshCaptureCapabilities());
      unawaited(integrationFeature.refreshLoginSetting());
    }

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
    integrationFeature.initialize();
    Future<void> initializeConnection() async {
      await d.initialize();
      try {
        await d.resume();
      } finally {
        if (mounted) setState(() => onboardingFeature.ready = true);
        await _offerInitialModelSetup();
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

  Future<void> _initializePreferences() async {
    final identity = FeatureRequestIdentity.capture(d);
    try {
      final shortcut = await d.store.read(
        StoreReadQueries.preference('globalShortcut', 'false'),
      );
      if (!identity.isCurrent(d, alive: mounted)) return;
      if (shortcut.error != null) throw shortcut.error!;
      if (shortcut.current && shortcut.value == 'true') {
        await integrationFeature.enableGlobalShortcuts();
      }
    } catch (error) {
      if (identity.isCurrent(d, alive: mounted)) {
        update(() => integrationFeature.globalShortcutState = error.toString());
      }
    }
    try {
      final notifications = await d.store.read(
        StoreReadQueries.preference('notifications', 'false'),
      );
      if (!identity.isCurrent(d, alive: mounted)) return;
      if (notifications.error != null) throw notifications.error!;
      if (notifications.current) {
        update(
          () =>
              integrationFeature.notifications = notifications.value == 'true',
        );
      }
    } catch (error) {
      if (identity.isCurrent(d, alive: mounted)) {
        update(() => integrationFeature.notificationState = error.toString());
      }
    }
  }

  Future<void> _offerInitialModelSetup() async {
    if (!mounted || widget.commands == null || settingsFeature.modelSetupShown)
      return;
    final identity = FeatureRequestIdentity.capture(d);
    final complete = await d.store.read(
      StoreReadQueries.preference('onboarding.complete'),
    );
    final embedding = await d.store.read(StoreReadQueries.model('embedding'));
    final generation = await d.store.read(StoreReadQueries.model('generation'));
    if (!identity.isCurrent(d, alive: mounted) ||
        !complete.current ||
        complete.error != null ||
        complete.value != 'true' ||
        !embedding.current ||
        embedding.error != null ||
        !generation.current ||
        generation.error != null ||
        settingsFeature.modelSetupShown)
      return;
    if (!preparedNeedsModel(embedding.value, 'embedding') &&
        !preparedNeedsModel(generation.value, 'generation'))
      return;
    settingsFeature.modelSetupShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identity.isCurrent(d, alive: mounted)) {
        unawaited(settingsFeature.chooseGemma(firstRun: true));
      }
    });
    update(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (environment.capabilities.requiresAudioPermissions &&
        state == AppLifecycleState.resumed) {
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
    final hasPendingNoteSave = meetingFeature.hasPendingNoteSave;
    final pendingNoteSave = meetingFeature.dispose();
    if (!hasPendingNoteSave)
      d.close();
    else
      unawaited(
        pendingNoteSave.then(
          (_) => d.close(),
          onError: (Object failure, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(exception: failure, stack: stack),
            );
            d.close();
          },
        ),
      );
    onboardingFeature.dispose();
    settingsFeature.dispose();
    integrationFeature.dispose();
    sourceFeature.dispose();
    chatFeature.dispose();
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
        sourceFeature.noteTitle.text != sourceFeature.noteBaseline.$1 ||
        sourceFeature.noteBody.text != sourceFeature.noteBaseline.$2 ||
        chatFeature.hasUnsavedDrafts;
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
    sourceFeature.noteEditorGeneration++;
    sourceFeature.noteId = null;
    sourceFeature.noteLoading = false;
    sourceFeature.noteTitle.clear();
    sourceFeature.noteBody.clear();
    sourceFeature.noteBaseline = ('', '');
    chatFeature.resetWorkspaceViews();
    for (final key in [
      sourceFeature.newNoteKey,
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
    update(() {
      _operations++;
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) update(() => error = failureText(e));
      // The request may have committed: read the views again.
      if (mounted && outcomeUnknown(e)) serviceUiRevision.value++;
      await integrationFeature.notify('Operation failed: ${failureText(e)}');
    } finally {
      _operations--;
      if (mounted) update(() => busy = _operations != 0);
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
            builder: (_, __, ___) => featureUpdates.view(
              WorkspaceTab.meetings,
              serviceUiRevision.value,
              meetingFeature.immersiveMeetingWorkspace,
            ),
          )
        : screenshotWorkspace(context);
    return AgentApprovalSurface(
      domain: d,
      allowAgentRequests: !onboarding,
      child: workspace,
    );
  }

  Widget workspaceHeader() => featureUpdates.presentation(
    'header',
    (
      serviceUiRevision.value,
      tab,
      busy,
      meetingFeature.quickStarting,
      meetingFeature.meetingEnhancing,
      meetingFeature.meetingId,
      meetingFeature.recording,
      settingsFeature.embeddingName(),
      settingsFeature.localWords(),
      settingsFeature.helperEmbeddingHealthy,
    ),
    () => WorkspaceHeader(
      embeddingName: settingsFeature.embeddingName(),
      localWords: settingsFeature.localWords(),
      helperHealthy: settingsFeature.helperEmbeddingHealthy,
      showHelperMonitor: settingsFeature.showHelperMonitor,
      recordingHeader: meetingFeature.recording == null
          ? null
          : meetingFeature.recordingHeader(),
      onRecord:
          busy ||
              meetingFeature.quickStarting ||
              meetingFeature.meetingEnhancing
          ? null
          : tab == WorkspaceTab.meetings && meetingFeature.meetingId != null
          ? () =>
                meetingFeature.recordExistingMeeting(meetingFeature.meetingId!)
          : meetingFeature.quickStart,
    ),
  );

  Widget screenshotWorkspace(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(
        LogicalKeyboardKey.digit1,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () =>
          navigate(WorkspaceTab.meetings),
      SingleActivator(
        LogicalKeyboardKey.digit2,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () =>
          navigate(WorkspaceTab.chat),
      SingleActivator(
        LogicalKeyboardKey.digit3,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () =>
          navigate(WorkspaceTab.sources),
      SingleActivator(
        LogicalKeyboardKey.digit4,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () =>
          navigate(WorkspaceTab.stats),
      SingleActivator(
        LogicalKeyboardKey.digit5,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () =>
          navigate(WorkspaceTab.settings),
      integrationFeature.quickActivator: () {
        if (!busy && meetingFeature.recording == null)
          unawaited(meetingFeature.quickStart());
      },
      SingleActivator(
        LogicalKeyboardKey.keyO,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () {
        if (!busy) unawaited(run(sourceFeature.import));
      },
      SingleActivator(
        LogicalKeyboardKey.keyN,
        control: !environment.capabilities.usesMetaShortcuts,
        meta: environment.capabilities.usesMetaShortcuts,
      ): () => update(() {
        navigate(WorkspaceTab.notes);
        sourceFeature.noteEditorGeneration++;
        sourceFeature.noteId = null;
        sourceFeature.noteLoading = false;
        sourceFeature.noteBaseline = ('', '');
        sourceFeature.newNoteKey.reset();
        sourceFeature.noteTitle.clear();
        sourceFeature.noteBody.clear();
      }),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: Column(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: serviceUiRevision,
              builder: (_, __, ___) => workspaceHeader(),
            ),
            Expanded(
              child: Row(
                children: [
                  featureUpdates.presentation(
                    'sidebar',
                    (tab, busy, integrationFeature.googlePresentation),
                    () => WorkspaceSidebar(
                      tab: tab,
                      navigate: navigate,
                      account: AccountButton(
                        connected: integrationFeature.googleAuth.connected,
                        busy: busy,
                        displayName: integrationFeature.googleAuth.displayName,
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
                    ),
                  ),
                  Expanded(
                    child: WorkspaceContent(
                      tab: tab,
                      meetingSelected: meetingFeature.meetingId != null,
                      busy: busy,
                      error: error,
                      child: ValueListenableBuilder<int>(
                        valueListenable: serviceUiRevision,
                        builder: (_, __, ___) => featureUpdates.view(
                          tab,
                          serviceUiRevision.value,
                          () => switch (tab) {
                            WorkspaceTab.sources => SourcesView(sourceFeature),
                            WorkspaceTab.chat => chatFeature.chat(),
                            WorkspaceTab.notes => sourceFeature.notes(),
                            WorkspaceTab.meetings => MeetingsView(
                              meetingFeature,
                            ),
                            WorkspaceTab.models => settingsFeature.models(),
                            WorkspaceTab.stats => settingsFeature.stats(),
                            WorkspaceTab.settings => SettingsView(
                              settingsFeature,
                            ),
                          },
                        ),
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
}
