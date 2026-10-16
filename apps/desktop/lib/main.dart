import 'package:foresight_core/foresight_core.dart'
    show
        runtimeConfiguration,
        privateDirectory,
        configureProfileRuntime,
        openPlatformUri,
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
import 'domain.dart';
import 'package:foresight_core/remote.dart';
import 'graph_labels.dart';
import 'graph_label_controls.dart';
import 'graph_clusters.dart';
import 'cluster_rendering.dart';
import 'force_layout.dart';
import 'label_propagation.dart';
import 'recording.dart';
import 'model_setup.dart';
import 'app_theme.dart';
import 'desktop_settings.dart';
import 'commands.dart';
import 'global_shortcuts.dart';
import 'hypr_shortcuts.dart';
import 'google_auth.dart';
import 'google_connections.dart';
import 'google_picker.dart';
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

part 'screenshot_ui.dart';
part 'meeting_workspace.dart';

Future<void> main([List<String> arguments = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = ProfilePaths.resolve(Platform.environment);
  final data = profile.data;
  final runtime = profile.runtime;
  ensurePrivateDirectory(data);
  ensurePrivateDirectory(runtime);
  configureProfileRuntime(data);
  final commandPath = '$runtime/commands.sock';
  final launchCommand = arguments.contains('--stop-meeting')
      ? 'stop-meeting'
      : arguments.contains('--quick-meeting')
      ? 'quick-meeting'
      : 'activate';
  if (await AppCommands.forward(
    commandPath,
    command: launchCommand,
    activationToken: Platform.environment['XDG_ACTIVATION_TOKEN'],
  ))
    exit(0);
  if (launchCommand == 'stop-meeting') exit(0);
  AppCommands ownedCommands;
  try {
    ownedCommands = await AppCommands.bind(commandPath);
  } catch (error) {
    if (error is! SocketException && error is! FileSystemException) rethrow;
    if (await AppCommands.forward(commandPath, command: launchCommand)) exit(0);
    rethrow;
  }
  final domain = await RemoteDomain.connect(profile);
  runApp(
    Foresight(
      domain,
      commands: ownedCommands,
      quickOnLaunch: arguments.contains('--quick-meeting'),
    ),
  );
}

Future<void> openSourceLink(Uri uri) => openPlatformUri(uri);
void ensurePrivateDirectory(String path) => privateDirectory(path);

class Foresight extends StatelessWidget {
  final Domain domain;
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
  final Domain domain;
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

class _WorkspaceState extends State<Workspace> with TickerProviderStateMixin {
  Domain get d => widget.domain;
  void update(VoidCallback action) => setState(action);
  int tab = 3;
  bool graphView = false,
      gridView = false,
      ascending = true,
      gemmaExplanation = true;
  String sourceQuery = '', meetingQuery = '', labelFilter = '';
  final sourceSearchController = TextEditingController();
  String sourceSearchCacheKey = '';
  Set<String> sourceSearchMatches = {};
  SourceType? typeFilter;
  final graphTransform = TransformationController();
  final graphLabelInput = TextEditingController();
  Size? graphViewportSize;
  late final AnimationController graphCameraController;
  Matrix4Tween? graphCameraTween;
  Curve graphCameraCurve = const Cubic(.645, .045, .355, 1);
  Map<String, GraphPoint> graphPoints = {};
  Map<String, GraphPoint> graphWorldPoints = {};
  List<GraphCluster> graphSceneClusters = [];
  Map<String, List<DocumentLabel>> graphSceneLabels = {};
  List<GraphEdge> graphEdges = [];
  Map<String, List<double>> graphSceneVectors = {};
  String? graphSelectedDocument;
  int graphOrganizationRevision = 0;
  List<GraphEdge> graphSelectionEdges = [];
  int graphSelectionRevision = 0;
  bool graphRelatedLoading = false;
  String graphRelatedError = '';
  String graphLayoutKey = '';
  bool graphOrganizing = false;
  String graphLayoutError = '';
  double graphYaw = 0, graphPitch = 0;
  int? graphMousePointer;
  Offset? graphPointerStart, graphPointerLast;
  bool graphPointerRotates = false, graphDragMoved = false;
  final graphVectorCache = <String, List<double>>{};
  final graphMotionFrames = ValueNotifier<int>(0);
  late final Ticker graphMotionTicker;
  Duration? graphLastTick;
  bool graphAnimationPaused = false,
      graphManualPitch = false,
      graphModalOpen = false;

  void syncGraphMotion() {
    final enabled =
        mounted &&
        tab == 0 &&
        graphView &&
        d.store.sources.isNotEmpty &&
        !graphAnimationPaused &&
        graphMousePointer == null &&
        !graphModalOpen &&
        !MediaQuery.disableAnimationsOf(context);
    if (enabled && !graphMotionTicker.isActive) {
      graphLastTick = null;
      graphMotionTicker.start();
    } else if (!enabled && graphMotionTicker.isActive) {
      graphMotionTicker.stop();
      graphLastTick = null;
    }
  }

  void tickGraphMotion(Duration elapsed) {
    final previous = graphLastTick;
    graphLastTick = elapsed;
    if (!mounted ||
        previous == null ||
        graphMousePointer != null ||
        graphAnimationPaused ||
        graphModalOpen ||
        tab != 0 ||
        !graphView)
      return;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    // Keep idle graph motion slow, with gentler motion while a source is selected.
    graphYaw += seconds * .025 * (graphSelectedDocument == null ? 1 : .05);
    if (!graphManualPitch) graphPitch = .4 + math.sin(graphYaw * .4) * .08;
    graphMotionFrames.value++;
  }

  late final DesktopSettings desktopSettings = DesktopSettings(
    Directory(
      Platform.environment['XDG_CONFIG_HOME'] ??
          '${Platform.environment['HOME']}/.config',
    ),
    '${File(Platform.resolvedExecutable).parent.parent.path}/open-foresight',
  );
  bool busy = false, asking = false;
  int _operations = 0;
  double answerFontSize = 16;
  final hiddenAnswers = <int>{};
  String error = '', answer = '', modelState = '';
  final question = TextEditingController(),
      noteTitle = TextEditingController(),
      noteBody = TextEditingController(),
      modelPath = TextEditingController(),
      runtimePath = TextEditingController(),
      tokenizer = TextEditingController();
  int? noteId, meetingId, recordingMeeting;
  final meetingNotesController = TextEditingController();
  int? loadedMeetingNotes;
  bool meetingSidecarVisible = true,
      meetingEnhancedVisible = true,
      meetingEnhancing = false,
      meetingCompactAssistant = false;
  String meetingPanel = 'Chat', meetingEnhanceStatus = '';
  double meetingSidecarWidth = 400;
  DateTime? recordingBegan;
  String modelKind = 'embedding';
  bool embeddingGpu = false;
  bool notifications = false;
  String notificationState = 'checking notify-send';
  Recording? recording;
  final provisionalTranscript = <String, String>{};
  AppCommands? commands;
  GlobalShortcuts? globalShortcuts;
  String globalShortcutState = 'disabled';
  late final GoogleAuth googleAuth = d is RemoteDomain
      ? RemoteGoogleAuth(d as RemoteDomain)
      : d.application.googleAuth;
  late final GoogleConnections google = d is RemoteDomain
      ? RemoteGoogleConnections(d as RemoteDomain, googleAuth)
      : d.application.google;
  String googleState = '';
  List<AudioDevice> availableAudioDevices = [];
  String audioDeviceState = '';
  Map<String, dynamic> captureCapabilities = {};
  String captureCapabilityError = '';
  String loginState = '';
  String get microphoneAccessLabel =>
      const {
        'authorized': 'Allowed',
        'denied': 'Denied',
        'restricted': 'Restricted by system policy',
        'not_determined': 'Not requested',
      }[captureCapabilities['microphone']] ??
      'Checking';

  bool get googleSyncing => d is RemoteDomain
      ? (d as RemoteDomain).googleStatus['syncing'] == true
      : d.application.google.syncing;
  HyprShortcuts get hyprShortcuts =>
      HyprShortcuts(desktopSettings.config, desktopSettings.launcher);
  String recordingState = 'idle';
  @override
  void initState() {
    super.initState();
    graphMotionTicker = createTicker(tickGraphMotion);
    graphCameraController = AnimationController(vsync: this);
    graphCameraController.addListener(() {
      final tween = graphCameraTween;
      if (mounted && tween != null) {
        graphTransform.value = tween.transform(
          graphCameraCurve.transform(graphCameraController.value),
        );
      }
    });
    embeddingGpu =
        d.store
            .rows("SELECT backend FROM models WHERE kind='embedding'")
            .firstOrNull?['backend'] ==
        'litert_lm_embedding_gpu';
    commands = widget.commands;
    commands?.setHandler(
      (command, token) => command == 'quick-meeting'
          ? activateQuickMeeting(token)
          : command == 'stop-meeting'
          ? (recording != null && !recording!.finishing
                ? run(stopRecording)
                : Future<void>.value())
          : activateWindow(token),
    );
    if (widget.quickOnLaunch)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(
          activateQuickMeeting(Platform.environment['XDG_ACTIVATION_TOKEN']),
        ),
      );
    if (d.store.preference('globalShortcut') == 'true') {
      unawaited(
        enableGlobalShortcuts().catchError((Object e) {
          if (mounted) setState(() => globalShortcutState = e.toString());
        }),
      );
    }
    google; // Create the independently versioned connection tables.
    googleState = googleAuth.loadError;
    unawaited(refreshAudioDevices());
    if (Platform.isMacOS) {
      unawaited(refreshCaptureCapabilities());
      unawaited(refreshLoginSetting());
    }

    notifications = d.store.preference('notifications') == 'true';
    unawaited(refreshNotifications());
    syncCapture();
    d.helper.changed = () {
      if (mounted) setState(syncCapture);
    };
    d.helper.onReady = () async {
      try {
        await d.resume();
      } finally {
        if (mounted &&
            widget.commands != null &&
            !modelSetupShown &&
            (needsModel(d.store, 'embedding') ||
                needsModel(d.store, 'generation'))) {
          modelSetupShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(chooseGemma(firstRun: true));
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
  void dispose() {
    if (d is! RemoteDomain) google.close();
    d.close();
    unawaited(googleAuth.close());
    unawaited(commands?.close() ?? Future<void>.value());
    unawaited(globalShortcuts?.close() ?? Future<void>.value());
    graphMotionTicker.dispose();
    graphCameraController.dispose();
    graphMotionFrames.dispose();
    graphTransform.dispose();
    recording?.dispose();
    d.generator?.close();
    unawaited(d.helper.close());
    d.store.close();
    for (final c in [
      question,
      sourceSearchController,
      graphLabelInput,
      noteTitle,
      noteBody,
      modelPath,
      runtimePath,
      tokenizer,
      meetingNotesController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> activateWindow(String? token) async {
    if (!mounted) return;
    try {
      await const MethodChannel(
        'foresight/window',
      ).invokeMethod<void>('activate', {'token': token ?? ''});
    } on MissingPluginException {
      /* pure widget tests */
    }
    if (!Platform.isMacOS &&
        Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
      final active = await Process.run('hyprctl', ['activewindow', '-j']);
      if (active.exitCode == 0 &&
          (jsonDecode(active.stdout as String) as Map)['pid'] != pid) {
        await Process.run('hyprctl', [
          'eval',
          'hl.dispatch(hl.dsp.focus({window="pid:$pid"}))',
        ]);
      }
    }
  }

  Future<void> activateQuickMeeting(String? token) async {
    await activateWindow(token);
    if (mounted && !busy && recording == null) await quickStart();
  }

  Future<void> enableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null) {
      await hyprShortcuts.install(
        d.store.preference('quickShortcut', 'CTRL + SHIFT + F'),
      );
      globalShortcutState = 'Global shortcut installed';
    } else {
      await desktopSettings.ensureApplicationEntry();
      globalShortcuts ??= GlobalShortcuts(
        (id, token) {
          if (id == 'quick-meeting') unawaited(activateQuickMeeting(token));
        },
        changed: () {
          if (mounted)
            setState(() => globalShortcutState = globalShortcuts!.state);
        },
      );
      await globalShortcuts!.enable(
        preferredTrigger: d.store
            .preference('quickShortcut', 'CTRL + SHIFT + F')
            .replaceAll(' ', ''),
      );
      globalShortcutState = globalShortcuts!.state;
    }
    await d.command('preferences.set', {
      'key': 'globalShortcut',
      'value': 'true',
    });
    if (mounted) setState(() {});
  }

  Future<void> disableGlobalShortcuts() async {
    if (!Platform.isMacOS &&
        Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null &&
        hyprShortcuts.installed)
      await hyprShortcuts.remove();
    await globalShortcuts?.disable();
    await d.command('preferences.set', {
      'key': 'globalShortcut',
      'value': 'false',
    });
    if (mounted) setState(() => globalShortcutState = 'disabled');
  }

  Future<void> refreshLoginSetting() async {
    try {
      await desktopSettings.refresh();
      if (mounted) setState(() => loginState = '');
    } catch (error) {
      if (mounted) setState(() => loginState = error.toString());
    }
  }

  Future<void> setOpenAtLogin(bool value) async {
    try {
      await desktopSettings.setOpenAtLogin(value);
      if (mounted) setState(() => loginState = '');
    } catch (error) {
      if (mounted) setState(() => loginState = error.toString());
      rethrow;
    }
  }

  Future<void> refreshCaptureCapabilities() async {
    try {
      final result = await d.command('audio.capabilities') as Map;
      if (mounted)
        setState(() {
          captureCapabilities = Map<String, dynamic>.from(result);
          captureCapabilityError =
              result['microphone_purpose_present'] == false ||
                  result['system_audio_purpose_present'] == false
              ? 'The recording service is missing audio access configuration. Reinstall Open Foresight.'
              : '';
        });
    } catch (error) {
      if (mounted) setState(() => captureCapabilityError = error.toString());
    }
  }

  Future<void> requestMicrophoneAccess() async {
    try {
      final result = await d.command('audio.request_microphone') as Map;
      if (mounted)
        setState(() {
          captureCapabilities = Map<String, dynamic>.from(result);
          captureCapabilityError = result['granted'] == true
              ? ''
              : 'Microphone access was denied. Enable Open Foresight in System Settings > Privacy & Security > Microphone, then refresh access status.';
        });
    } catch (error) {
      if (mounted) setState(() => captureCapabilityError = error.toString());
      rethrow;
    }
  }

  Future<void> refreshAudioDevices() async {
    try {
      final devices = await widget.deviceLoader();
      if (mounted)
        setState(() {
          availableAudioDevices = devices;
          audioDeviceState = '';
        });
    } catch (error) {
      if (mounted) setState(() => audioDeviceState = error.toString());
    }
  }

  bool modelSetupShown = false;
  Future<void> chooseGemma({bool firstRun = false}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GemmaSetupDialog(
        store: d.store,
        firstRun: firstRun,
        needsEmbedding: needsModel(d.store, 'embedding'),
        needsGeneration: !firstRun || needsModel(d.store, 'generation'),
        installEmbedding: (asset, current) async {
          await d.commandCurrent('models.embedding', {
            'path': asset.path,
            'gpu': true,
            'digest': embeddingGemmaModel.digest,
          }, current);
          if (!current()) return;
          if (mounted) setState(() => embeddingGpu = true);
        },
        directory: Directory('${File(d.store.path).parent.path}/models/gemma4'),
        library: runtimeConfiguration.nativeLibrary,
        runner: runtimeConfiguration['FORESIGHT_LITERT_RUNNER'] ?? '',
        memoryGb: physicalMemoryGb(),
        installGeneration: (path, runtime, current) async {
          await d.commandCurrent('models.generation', {
            'path': path,
            'runtime': runtime,
            'backend': 'litert_lm',
          }, current);
          return d is RemoteDomain ? (d as RemoteDomain).runtime : d.generator!;
        },
        installed: (runtime, model) {
          d.generator?.close();
          d.generator = runtime;
          if (mounted)
            setState(() {
              error = '';
              modelState = '${model.name} ready';
            });
        },
        localSetup: () {
          if (mounted) setState(() => tab = 4);
        },
      ),
    );
    if (mounted) setState(() {});
  }

  String speechModelName() {
    final registration = d.store
        .rows("SELECT * FROM models WHERE kind='speech'")
        .firstOrNull;
    if (registration == null) return 'Select a transcription model';
    final known = speechModels
        .where((model) => model.digest == registration['digest'])
        .firstOrNull;
    if (known != null) return known.name;
    final name = File(registration['path'] as String).uri.pathSegments.last;
    return name.contains('.en.') ? '$name (English only)' : name;
  }

  Future<void> chooseSpeech() async {
    final registration = d.store
        .rows("SELECT runtime FROM models WHERE kind='speech'")
        .firstOrNull;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SpeechSetupDialog(
        store: d.store,
        directory: Directory(
          '${File(d.store.path).parent.path}/models/whisper',
        ),
        runner:
            runtimeConfiguration['FORESIGHT_WHISPER_RUNTIME'] ??
            registration?['runtime'] as String? ??
            '',
        installSpeech: (asset, runner, digest, current) async {
          await d.commandCurrent('models.speech', {
            'path': asset.path,
            'runtime': runner,
            'digest': digest,
          }, current);
        },
        installed: () {
          if (mounted)
            setState(
              () => modelState =
                  '${speechModelName()} ready; automatic language detection',
            );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> importGoogleClient() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Google Desktop OAuth client',
          extensions: ['json'],
        ),
      ],
    );
    if (file != null) await googleAuth.configure(File(file.path));
    if (mounted) setState(() {});
  }

  Future<void> connectGoogle() async {
    await googleAuth.signIn((uri) async {
      if (mounted)
        setState(
          () => googleState = 'Complete Google sign-in in your browser.',
        );
      await openPlatformUri(uri);
    });
    if (mounted)
      setState(() => googleState = 'Connected as ${googleAuth.email}');
    await google.syncCalendar();
  }

  Future<void> setMeetingReminders(bool value) async {
    if (value && Platform.isMacOS) {
      final result = await d.command('notifications.request_permission') as Map;
      if (result['granted'] != true) {
        throw StateError(
          'Meeting reminders need notification access. Enable Open Foresight in System Settings > Notifications.',
        );
      }
    }
    await preference('googleReminders', value.toString());
    await refreshNotifications();
  }

  Future<void> refreshNotifications() async {
    try {
      final result = await d.command('notifications.capabilities') as Map;
      if (mounted)
        setState(
          () => notificationState = result['available'] == true
              ? 'Notifications available'
              : Platform.isMacOS
              ? 'Notification permission required; enable to request access'
              : 'Notifications unavailable',
        );
    } catch (error) {
      if (mounted) setState(() => notificationState = error.toString());
    }
  }

  Future<void> setNotifications(bool value) async {
    if (value && Platform.isMacOS) {
      final result = await d.command('notifications.request_permission') as Map;
      if (result['granted'] != true) {
        if (mounted)
          setState(
            () => notificationState =
                'Notification permission denied; enable Open Foresight in System Settings',
          );
        return;
      }
    }
    await d.command('preferences.set', {
      'key': 'notifications',
      'value': value.toString(),
    });
    if (mounted) setState(() => notifications = value);
    await refreshNotifications();
  }

  Future<void> notify(String message) async {
    if (!notifications) return;
    try {
      await platformNotification('Open Foresight', message);
    } catch (e) {
      if (mounted)
        setState(() => notificationState = 'notification unavailable: $e');
    }
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
      await notify('Operation failed: $e');
    } finally {
      _operations--;
      if (mounted) setState(() => busy = _operations != 0);
    }
  }

  Future<void> chooseDrive({bool folder = false}) async {
    if (!googleAuth.connected)
      throw StateError('Connect Google in Settings first.');
    final selection = await showDialog<List<String>>(
      context: context,
      builder: (_) => GoogleDrivePicker(google, folder: folder),
    );
    if (selection == null) return;
    final failures = <String>[];
    for (final id in selection) {
      try {
        if (folder) {
          await google.importDriveFolder(id);
        } else {
          await google.importDriveFile(id);
        }
      } catch (error) {
        failures.add(error.toString());
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  }

  Future<void> importFolderPath(String path) => importDirectory(path);

  Future<void> findLocalFiles({List<String>? roots}) =>
      findFilesOnComputer(roots: roots);
  Future<void> refreshSources() => reimport();
  Future<void> importSourceUrl(String address) => importAddress(address);
  String exportMeetingMarkdown() => meetingMarkdown();

  Future<void> import() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Sources',
          extensions: ['txt', 'md', 'pdf', 'rtf'],
        ),
      ],
    );
    if (file == null) return;
    await importPath(file.path);
  }

  Future<void> source(Map<String, Object?> s) async {
    if (!s.containsKey('content')) {
      final current = d.store.rows(
        'SELECT * FROM sources WHERE id=? AND deleted=0',
        [s['id']],
      );
      if (current.isEmpty) return;
      s = {...s, ...current.single};
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${s['title']} · revision ${s['revision']}'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: SelectableText(s['content'] as String),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy
                ? null
                : () {
                    Navigator.pop(context);
                    editSource(s);
                  },
            child: const Text('Edit source'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<T?> showInputDialog<T>({required WidgetBuilder builder}) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final result = await Navigator.of(context).push(route);
    await route.completed;
    // The departing route has unmounted before callers release input controllers.
    return result;
  }

  void editSource(Map<String, Object?> s) async {
    final text = TextEditingController(text: s['content'] as String);
    final saved = await showInputDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text('Edit ${s['title']}'),
        content: SizedBox(
          width: 650,
          height: 400,
          child: TextField(controller: text, maxLines: null, expands: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save and index'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) {
      await run(() async {
        await importText(
          s['title'] as String,
          text.text,
          s['mime'] as String,
          'user edit; ${s['provenance']}',
          id: s['id'] as String,
        );
        await d.index(s['id'] as String);
      });
    }
    text.dispose();
  }

  void citation(Map c) {
    final s = d.store.rows('SELECT * FROM sources WHERE id=?', [
      c['document_id'],
    ]);
    if (s.isEmpty ||
        s.first['deleted'] == 1 ||
        s.first['revision'] != c['revision']) {
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Archived citation: source changed or deleted'),
          content: SelectableText(c['excerpt'] as String),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      source(s.first);
    }
  }

  Widget notes() => Row(
    children: [
      SizedBox(
        width: 260,
        child: Column(
          children: [
            FilledButton(
              onPressed: () {
                setState(() {
                  noteId = null;
                  noteTitle.clear();
                  noteBody.clear();
                });
              },
              child: const Text('New note'),
            ),
            Expanded(
              child: ListView(
                children: d.store
                    .rows('SELECT * FROM notes ORDER BY id DESC')
                    .map(
                      (n) => ListTile(
                        title: Text(n['title'] as String),
                        subtitle: Text('Revision ${n['revision']}'),
                        onTap: () => setState(() {
                          noteId = n['id'] as int;
                          noteTitle.text = n['title'] as String;
                          noteBody.text = n['body'] as String;
                        }),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
      const VerticalDivider(),
      Expanded(
        child: Column(
          children: [
            TextField(
              controller: noteTitle,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            Expanded(
              child: TextField(
                controller: noteBody,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'Your editable note',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            FilledButton(
              onPressed: () => run(() async {
                final saved =
                    await d.command('notes.save', {
                          'id': noteId,
                          'title': noteTitle.text,
                          'body': noteBody.text,
                        })
                        as Map;
                if (mounted) setState(() => noteId = saved['id'] as int);
              }),
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    ],
  );
  Widget models() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Local models',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const Text('Choose a local model and load it on this computer.'),
        DropdownButton<String>(
          value: modelKind,
          items: [
            'embedding',
            'generation',
            'speech',
          ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: (s) => setState(() => modelKind = s!),
        ),
        TextField(
          controller: modelPath,
          decoration: const InputDecoration(labelText: 'Model file'),
        ),
        if (modelKind != 'embedding')
          TextField(
            controller: runtimePath,
            decoration: const InputDecoration(
              labelText: 'Generation / speech runner executable',
            ),
          ),
        const SizedBox(height: 12),
        if (modelKind == 'embedding')
          CheckboxListTile(
            value: embeddingGpu,
            title: const Text('Use GPU for EmbeddingGemma 2'),
            onChanged: busy
                ? null
                : (value) => setState(() => embeddingGpu = value!),
          ),
        FilledButton(
          onPressed: busy
              ? null
              : () => run(() async {
                  await d.command(
                    modelKind == 'embedding'
                        ? 'models.embedding'
                        : modelKind == 'generation'
                        ? 'models.generation'
                        : 'models.register',
                    {
                      'kind': modelKind,
                      'path': modelPath.text,
                      'runtime': runtimePath.text,
                      'gpu': embeddingGpu,
                    },
                  );
                  modelState = '$modelKind ready';
                }),
          child: const Text('Register and load'),
        ),
        if (modelState.isNotEmpty) Text('Last setup: $modelState'),
        Text(
          'Embedding: ${d.helper.snapshot?.pipeline ?? 'unconfigured'} · Index: ${d.helper.snapshot?.index ?? 'empty'}',
        ),
        Text(
          'Speech: ${speechSetupProblem(d.store) ?? 'Ready for live transcription'}',
        ),
        SelectableText(
          'Generator: ${d.generator?.effectiveState ?? {'state': 'unconfigured'}}',
        ),
        CheckboxListTile(
          value: notifications,
          onChanged:
              (Platform.isMacOS
                  ? runtimeConfiguration['FORESIGHT_NOTIFICATIONS'] != null
                  : notificationState.startsWith('Notifications available'))
              ? (value) => run(() => setNotifications(value!))
              : null,
          title: const Text('Desktop completion/error notifications'),
          subtitle: Text(notificationState),
        ),
        ListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: d.store
              .rows('SELECT * FROM models')
              .map(
                (m) => ListTile(
                  title: Text('${m['kind']}: ${m['path']}'),
                  subtitle: SelectableText(
                    'SHA256 ${m['digest']}\nRunner ${m['runtime']}',
                  ),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
  Widget meetings() => meetingId == null ? meetingList() : meetingWorkspace();
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
        await d.command('sources.import', {
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
    final state = d is RemoteDomain
        ? (d as RemoteDomain).capture
        : d.application.captureState;
    recording = state['active'] == true
        ? RemoteRecording(Map<String, dynamic>.from(state))
        : null;
    recordingMeeting = state['meeting_id'] as int?;
    recordingState = state['state'] as String? ?? 'idle';
    final began = state['began'] as int?;
    recordingBegan = began == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(began);
    provisionalTranscript
      ..clear()
      ..addAll(Map<String, String>.from(state['provisional'] as Map? ?? {}));
  }

  Future<void> startRecording() async {
    await d.command('meetings.start', {'id': meetingId!});
    syncCapture();
    if (mounted) setState(() {});
  }

  Future<void> stopRecording() async {
    await d.command('meetings.stop');
    syncCapture();
    if (mounted) setState(() {});
    await notify('Meeting transcription completed');
  }

  Future<void> indexMeeting(int id) async {
    await d.command('meetings.index', {'id': id});
  }

  Future<void> generateMeeting(String kind) async {
    await d.command('meetings.generate', {'id': meetingId!, 'kind': kind});
  }

  void editArtifact(Map<String, Object?> a) async {
    final controller = TextEditingController(
      text: (a['edited'] ?? a['generated']) as String,
    );
    await showInputDialog<void>(
      builder: (context) => AlertDialog(
        title: const Text('Edit generated artifact'),
        content: SizedBox(
          width: 650,
          height: 300,
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await d.command('artifacts.edit', {
                'id': a['id'],
                'text': controller.text,
              });
              if (!context.mounted) return;
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text('Save edit'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    syncGraphMotion();
    return screenshotWorkspace(context);
  }
}
