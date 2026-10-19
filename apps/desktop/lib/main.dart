import 'system_audio_setup_dialog.dart';
import 'onboarding_view.dart';
import 'model_terms_dialog.dart';
import 'package:foresight_core/foresight_core.dart'
    show dedicatedQueryTermsKey, dedicatedQueryTermsUri;
import 'background_store.dart';
import 'store.dart' show outputWeekStart;
import 'service_edit_dialog.dart';
import 'package:foresight_core/foresight_core.dart'
    show
        runtimeConfiguration,
        privateDirectory,
        writePrivateTextFile,
        configureProfileRuntime,
        openPlatformUri,
        allowedSourceUri,
        openForesightBuildNumber,
        openForesightBuildLabel,
        openForesightVersion,
        MeetingSpeaker,
        platformNotification;
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
import 'package:foresight_core/remote.dart';
import 'graph_labels.dart';
import 'graph_label_controls.dart';
import 'graph_clusters.dart';
import 'cluster_rendering.dart';
import 'force_layout.dart';
import 'model_setup.dart';
import 'app_theme.dart';
import 'meeting_visuals.dart';
import 'desktop_settings.dart';
import 'desktop_visuals.dart';
import 'commands.dart';
import 'global_shortcuts.dart';
import 'desktop_menu.dart';
import 'hypr_shortcuts.dart';
import 'google_picker.dart';
import 'google_sign_in_dialog.dart';
import 'audio_devices.dart';
import 'gemma_setup_view.dart';
import 'speech_setup_view.dart';
import 'speech_models.dart';
import 'profile_paths.dart';
import 'gemma_download.dart';
import 'source_type.dart';
import 'file_discovery.dart';
import 'file_discovery_sheet.dart';
import 'graph_layout.dart';
import 'graph_rendering.dart';
import 'graph_persistence.dart';
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
part 'settings_controller.dart';
part 'integrations_controller.dart';

Future<void> main([List<String> arguments = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(DesktopStartup(arguments: arguments));
}

Future<DesktopConnection> connectDesktopDomain(ProfilePaths profile) =>
    RemoteDomain.connect(profile);
void quitDesktop() => exit(0);

/// Mount before connecting so service/profile failures remain visible and can
/// be retried without retaining the failed attempt's activation socket.
class DesktopStartup extends StatefulWidget {
  final List<String> arguments;
  final ProfilePaths? profile;
  final Future<DesktopConnection> Function(ProfilePaths) connect;
  final VoidCallback quit;
  final void Function(String) configureRuntime;
  const DesktopStartup({
    super.key,
    this.arguments = const [],
    this.profile,
    this.connect = connectDesktopDomain,
    this.quit = quitDesktop,
    this.configureRuntime = configureProfileRuntime,
  });
  @override
  State<DesktopStartup> createState() => _DesktopStartupState();
}

class _DesktopStartupState extends State<DesktopStartup> {
  Widget? application;
  Object? failure;
  bool starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    if (starting) return;
    setState(() {
      starting = true;
      failure = null;
    });
    AppCommands? ownedCommands;
    try {
      final profile =
          widget.profile ?? ProfilePaths.resolve(Platform.environment);
      privateDirectory(profile.data, repairOwnedPermissions: true);
      ensurePrivateDirectory(profile.runtime);
      widget.configureRuntime(profile.data);
      final commandPath = '${profile.runtime}/commands.sock';
      final launchCommand = widget.arguments.contains('--stop-meeting')
          ? 'stop-meeting'
          : widget.arguments.contains('--quick-meeting')
          ? 'quick-meeting'
          : 'activate';
      if (await AppCommands.forward(
        commandPath,
        command: launchCommand,
        activationToken: Platform.environment['XDG_ACTIVATION_TOKEN'],
      )) {
        widget.quit();
        return;
      }
      if (launchCommand == 'stop-meeting') {
        widget.quit();
        return;
      }
      try {
        ownedCommands = await AppCommands.bind(commandPath);
      } catch (error) {
        if (error is! SocketException && error is! FileSystemException) rethrow;
        if (await AppCommands.forward(commandPath, command: launchCommand)) {
          widget.quit();
          return;
        }
        rethrow;
      }
      final domain = await widget.connect(profile);
      if (!mounted) {
        await ownedCommands.close();
        ownedCommands = null;
        domain.close();
        return;
      }
      setState(
        () => application = Foresight(
          domain,
          commands: ownedCommands,
          quickOnLaunch: widget.arguments.contains('--quick-meeting'),
        ),
      );
      ownedCommands = null; // Workspace now owns the successful connection.
    } catch (error) {
      // Cleanup finishes before Retry becomes available or another app binds.
      try {
        await ownedCommands?.close();
      } catch (_) {
        // Preserve the actionable connection error if cleanup also fails.
      }
      if (mounted) setState(() => failure = error);
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      application ??
      MaterialApp(
        title: 'Open Foresight',
        debugShowCheckedModeBanner: false,
        theme: foresightTheme(),
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      starting
                          ? 'Starting Open Foresight…'
                          : 'Open Foresight could not start',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    if (starting)
                      const LinearProgressIndicator()
                    else ...[
                      SelectableText(failure.toString()),
                      const SizedBox(height: 16),
                      const Text(
                        'Resolve the problem above, then retry. If another installation owns this profile, stop its application service explicitly or use a different profile.',
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          FilledButton(
                            onPressed: start,
                            child: const Text('Retry'),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: widget.quit,
                            child: const Text('Quit'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

Future<void> openSourceLink(Uri uri) => openPlatformUri(uri);
void ensurePrivateDirectory(String path) => privateDirectory(path);

class Foresight extends StatelessWidget {
  final DesktopConnection domain;
  final AppCommands? commands;
  final bool quickOnLaunch;
  final Future<List<AudioDevice>> Function() deviceLoader;
  final Future<void> Function(Uri) sourceLinkOpener;
  const Foresight(
    this.domain, {
    super.key,
    this.commands,
    this.quickOnLaunch = false,
    this.deviceLoader = audioDevices,
    this.sourceLinkOpener = openSourceLink,
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
    ),
  );
}

class Workspace extends StatefulWidget {
  final DesktopConnection domain;
  final AppCommands? commands;
  final bool quickOnLaunch;
  final Future<List<AudioDevice>> Function() deviceLoader;
  final Future<void> Function(Uri) sourceLinkOpener;
  const Workspace(
    this.domain, {
    super.key,
    this.commands,
    this.quickOnLaunch = false,
    this.deviceLoader = audioDevices,
    this.sourceLinkOpener = openSourceLink,
  });
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final onboardingFeature = _OnboardingController(this);
  late final sourceFeature = _SourcesController(this);
  late final chatFeature = _ChatController(this);
  late final meetingFeature = _MeetingsController(this);
  late final settingsFeature = _SettingsController(this);
  late final integrationFeature = _IntegrationsController(this);

  DesktopConnection get d => widget.domain;

  void update(VoidCallback action) => setState(action);

  final serviceUiRevision = ValueNotifier<int>(0);
  final captureVolumes = ValueNotifier<List<double>>(const []);
  StreamSubscription<List<double>>? captureLevels;
  late final DesktopMenu desktopMenu;

  Timer? serviceUiTimer;
  void serviceChanged() {
    if (!mounted || serviceUiTimer != null) return;
    serviceUiTimer = Timer(const Duration(milliseconds: 100), () {
      serviceUiTimer = null;
      if (!mounted) return;
      meetingFeature.syncCapture();
      sourceFeature.syncGraphMotion();
      serviceUiRevision.value++;
    });
  }

  int tab = 3;

  bool busy = false;

  int _operations = 0;

  String error = '';

  @override
  void initState() {
    super.initState();
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
        d.store.registeredEmbedding().firstOrNull?['backend'] ==
        'litert_lm_embedding_gpu';
    meetingFeature.systemAudioSetupReviewed =
        d.store.preference('audio.systemSetupReviewed') == 'true';
    integrationFeature.commands = widget.commands;
    integrationFeature.commands?.onError =
        integrationFeature.reportShortcutFailure;
    integrationFeature.commands?.setHandler(
      (command, token) => command == 'quick-meeting'
          ? integrationFeature.activateQuickMeeting(token)
          : command == 'stop-meeting'
          ? (meetingFeature.recording != null &&
                    !meetingFeature.recording!.finishing
                ? run(meetingFeature.stopRecording)
                : Future<void>.value())
          : integrationFeature.activateWindow(token),
    );
    if (widget.quickOnLaunch)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(
          integrationFeature.activateQuickMeeting(
            Platform.environment['XDG_ACTIVATION_TOKEN'],
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
    d.helper.changed = serviceChanged;
    d.helper.onReady = () async {
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
    };
    unawaited(
      d.helper.start().catchError((Object e) {
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
    desktopMenu.close();
    WidgetsBinding.instance.removeObserver(this);
    serviceUiTimer?.cancel();
    serviceUiRevision.dispose();
    unawaited(captureLevels?.cancel());
    captureVolumes.dispose();
    unawaited(meetingFeature.noteEnhancementChanges?.cancel());
    void releaseDomain() {
      d.close();
      d.generator?.close();
      unawaited(d.helper.close());
      d.store.close();
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

  void reportAsyncError(Object failure) {
    if (mounted) setState(() => error = failure.toString());
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      _operations++;
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is StateError ? e.message.toString() : e.toString(),
        );
      await integrationFeature.notify('Operation failed: $e');
    } finally {
      _operations--;
      if (mounted) setState(() => busy = _operations != 0);
    }
  }

  Future<T?> showInputDialog<T>({required WidgetBuilder builder}) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final result = await Navigator.of(context).push(route);
    await route.completed;
    // The departing route has unmounted before callers release input controllers.
    return result;
  }

  @override
  Widget build(BuildContext context) {
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
          update(() => tab = 3),
      SingleActivator(
        LogicalKeyboardKey.digit2,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          update(() => tab = 1),
      SingleActivator(
        LogicalKeyboardKey.digit3,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          update(() => tab = 0),
      SingleActivator(
        LogicalKeyboardKey.digit4,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          update(() => tab = 5),
      SingleActivator(
        LogicalKeyboardKey.digit5,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          update(() => tab = 6),
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
        tab = 2;
        meetingFeature.noteId = null;
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
                                : tab == 3 && meetingFeature.meetingId != null
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
                                3,
                                'Meetings',
                                tab == 3
                                    ? Icons.description
                                    : Icons.description_outlined,
                              ),
                              navItem(
                                1,
                                'Ask',
                                tab == 1
                                    ? Icons.chat_bubble
                                    : Icons.chat_bubble_outline,
                              ),
                              navItem(
                                0,
                                'Sources',
                                tab == 0
                                    ? Icons.snippet_folder
                                    : Icons.snippet_folder_outlined,
                              ),
                              navItem(
                                5,
                                'Stats',
                                tab == 5
                                    ? Icons.emoji_events
                                    : Icons.emoji_events_outlined,
                              ),
                            ],
                          ),
                        ),
                        navItem(
                          6,
                          'Settings',
                          tab == 6 || tab == 4
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
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: Color(0xff008577),
                            child: Icon(
                              Icons.person_outline,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        tab == 1 ||
                                (tab == 3 && meetingFeature.meetingId != null)
                            ? 16
                            : MediaQuery.sizeOf(context).width > 1000
                            ? 56
                            : 16,
                        tab == 3 && meetingFeature.meetingId != null
                            ? 12
                            : tab == 1
                            ? 22
                            : 34,
                        MediaQuery.sizeOf(context).width > 1000
                            ? (tab == 1 ||
                                      (tab == 3 &&
                                          meetingFeature.meetingId != null)
                                  ? 40
                                  : tab == 6
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
                              builder: (_, __, ___) => [
                                () => _SourcesView(sourceFeature),
                                () => _ChatView(chatFeature),
                                sourceFeature.notes,
                                () => _MeetingsView(meetingFeature),
                                settingsFeature.models,
                                settingsFeature.stats,
                                () => _SettingsView(settingsFeature),
                              ][tab](),
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

  Widget navItem(int index, String title, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: Material(
      color: tab == index || index == 6 && tab == 4
          ? _blue
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => update(() => tab = index),
        child: SizedBox(
          width: 56 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          height: 54 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: tab == index ? _ink : const Color(0xff45494b),
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
