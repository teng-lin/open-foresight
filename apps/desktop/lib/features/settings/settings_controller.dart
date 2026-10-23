import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import '../../background_store.dart';
import '../../desktop_visuals.dart';
import '../../feature_request_identity.dart';
import '../../presentation/workspace_presentation.dart';
import '../../shell/ports.dart';
import '../../shell/workspace_tab.dart';
import 'gemma_setup_view.dart';
import 'speech_setup_view.dart';
import 'model_terms_dialog.dart';
import 'usage_chart.dart';
import 'read_model.dart';

part 'models_view.dart';
part 'stats_view.dart';
part 'settings_view.dart';

class SettingsController implements SettingsCommands {
  SettingsController({
    required FeatureHost host,
    required WorkspaceNavigation navigation,
    required OperationGate operations,
    required WorkspaceLifecycle lifecycle,
    required IntegrationActivity integrations,
    required IntegrationCommands integrationCommands,
    required MeetingActivity meetings,
  }) : _host = host,
       _navigation = navigation,
       _operations = operations,
       _lifecycle = lifecycle,
       _integrations = integrations,
       _integrationCommands = integrationCommands,
       _meetings = meetings;

  bool _embeddingChoiceInitialized = false;

  late final SettingsReadModel _reads = SettingsReadModel(
    connection: () => d,
    changed: () {
      if (!mounted) return;
      _host.update(() {
        if (!_embeddingChoiceInitialized && _reads.modelsCurrent) {
          _embeddingChoiceInitialized = true;
          embeddingGpu =
              _reads.currentModel('embedding')?.backend ==
              'litert_lm_embedding_gpu';
        }
      });
    },
  );
  void start() => _reads.start();

  final FeatureHost _host;
  final WorkspaceNavigation _navigation;
  final OperationGate _operations;
  final WorkspaceLifecycle _lifecycle;
  final IntegrationActivity _integrations;
  final IntegrationCommands _integrationCommands;
  final MeetingActivity _meetings;
  bool _disposed = false;
  DesktopConnection get d => _host.connection;
  bool get mounted => !_disposed && _host.mounted;
  BuildContext get context => _host.context;
  void setState(VoidCallback action) {
    if (mounted) _host.update(action);
  }

  Widget heading(String title) => workspaceHeading(title);
  Widget pill(
    String title,
    VoidCallback? action, {
    IconData? icon,
    bool selected = false,
  }) => workspacePill(title, action, icon: icon, selected: selected);

  Future<void> runAction(
    Future<void> Function() action, {
    bool Function()? selectionCurrent,
  }) async {
    final identity = FeatureRequestIdentity.capture(d);
    final tab = _navigation.selectedTab;
    final selected = _meetings.selectedMeetingId;
    final preview = _meetings.previewMeetingId;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        _navigation.selectedTab == tab &&
        _meetings.selectedMeetingId == selected &&
        _meetings.previewMeetingId == preview &&
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

  @override
  void showModelSetup(String kind) => setState(() {
    modelKind = kind;
    _navigation.navigate(WorkspaceTab.models);
  });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_reads.dispose());
    modelPath.dispose();
    runtimePath.dispose();
    tokenizer.dispose();
  }

  bool gemmaExplanation = true;

  bool queryModelDownloading = false;
  bool portableQuery = false;
  String queryDigest = '';

  String modelState = '';

  final modelPath = TextEditingController();

  final runtimePath = TextEditingController();

  final tokenizer = TextEditingController();

  String modelKind = 'embedding';

  bool embeddingGpu = false;

  bool modelSetupShown = false;

  Future<void> saveModelPreference(String key, String value) async {
    await d.command(Operation.preferencesSet, {'key': key, 'value': value});
  }

  @override
  Future<void> chooseGemma({
    bool firstRun = false,
    bool embeddingOnly = false,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          gemmaSetup(firstRun: firstRun, embeddingOnly: embeddingOnly),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget gemmaSetup({
    bool firstRun = false,
    bool embeddingOnly = false,
    VoidCallback? onDone,
  }) {
    final generation = _reads.generation;
    return GemmaSetupDialog(
      environment: _host.environment,
      store: d.store,
      ownerCurrent: () => mounted && _reads.owns(generation),
      savePreference: saveModelPreference,
      onDone: onDone,
      firstRun: firstRun,
      needsEmbedding: preparedNeedsModel(
        _reads.currentModel('embedding'),
        'embedding',
      ),
      needsGeneration:
          !embeddingOnly &&
          (!firstRun ||
              preparedNeedsModel(
                _reads.currentModel('generation'),
                'generation',
              )),
      installEmbedding: (asset, current) async {
        await d.commandCurrent(Operation.modelsEmbedding, {
          'path': asset.path,
          'gpu': true,
          'digest': embeddingGemmaModel.digest,
        }, current);
        if (!current()) return;
        if (mounted)
          setState(() {
            embeddingGpu = true;
            modelState = 'EmbeddingGemma 2 ready for local source search';
          });
      },
      directory: d.modelAssets.generation,
      library: desktopRuntimeSettings.nativeLibrary,
      runner: desktopRuntimeSettings['FORESIGHT_LITERT_RUNNER'] ?? '',
      memoryGb: physicalMemoryGb(),
      installGeneration: (path, runtime, current) async {
        await d.commandCurrent(Operation.modelsGeneration, {
          'path': path,
          'runtime': runtime,
          'backend': 'litert_lm',
        }, current);
        return d.runtime;
      },
      installed: (runtime, model) {
        if (mounted)
          setState(() {
            _operations.setError('');
            modelState = '${model.name} ready';
          });
      },
      localSetup: () {
        if (mounted) setState(() => _navigation.navigate(WorkspaceTab.models));
      },
    );
  }

  String speechModelName() {
    final registration = _reads.model('speech');
    if (registration == null) return 'Select a transcription model';
    final known = speechModels
        .where((model) => model.digest == registration.digest)
        .firstOrNull;
    if (known != null) return known.name;
    final name = File(registration.path).uri.pathSegments.last;
    return name.contains('.en.') ? '$name (English only)' : name;
  }

  @override
  Future<void> chooseSpeech() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => speechSetup(),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget speechSetup({VoidCallback? onDone}) {
    final generation = _reads.generation;
    final registration = _reads.model('speech');
    return SpeechSetupDialog(
      environment: _host.environment,
      store: d.store,
      ownerCurrent: () => mounted && _reads.owns(generation),
      savePreference: saveModelPreference,
      onDone: onDone,
      directory: d.modelAssets.speech,
      runner:
          desktopRuntimeSettings['FORESIGHT_WHISPER_RUNTIME'] ??
          registration?.runtime ??
          '',
      installSpeech: (asset, runner, digest, current) async {
        await d.commandCurrent(Operation.modelsSpeech, {
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
    );
  }

  Widget models() => _buildModels();

  bool get helperEmbeddingHealthy {
    final snapshot = d.helper.snapshot;
    return snapshot != null &&
        snapshot.pipeline == 'ready' &&
        snapshot.lastError.isEmpty &&
        snapshot.index != 'degraded' &&
        snapshot.index != 'failed';
  }

  void showHelperMonitor() => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      shape: const RoundedRectangleBorder(
        borderRadius: DesktopVisuals.panelRadius,
      ),
      title: const Text('Local helper'),
      content: SelectableText(
        'Connection: ${d.helper.state}\nEmbedding: ${d.helper.snapshot?.pipeline ?? 'unconfigured'}\nBackend: ${d.helper.snapshot?.model.backend ?? 'unconfigured'}\nDimensions: ${d.helper.snapshot?.model.dimensions ?? 0}\nIndex: ${d.helper.snapshot?.index ?? 'empty'}\nLast error: ${d.helper.snapshot?.lastError.isNotEmpty == true ? d.helper.snapshot!.lastError : 'None'}\nGeneration: ${d.generator?.presentation.diagnosticText}\nSpeech: ${preparedSpeechSetupProblem(_reads.model('speech')) ?? 'Ready'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: _operations.busy
              ? null
              : () {
                  Navigator.pop(context);
                  unawaited(_operations.run(d.resume));
                },
          child: const Text('Reload models'),
        ),
      ],
    ),
  );

  String generationName() {
    final model = _reads.model('generation');
    if (model == null) return 'Choose a local model';
    final known = gemmaModels
        .where((candidate) => candidate.digest == model.digest)
        .firstOrNull;
    return known?.name ?? File(model.path).uri.pathSegments.last;
  }

  String embeddingName() {
    final backend = d.helper.snapshot?.model.backend;
    if (backend == 'litert-lm-embedding-cpu' ||
        backend == 'litert-lm-embedding-gpu') {
      return 'EmbeddingGemma 2';
    }
    final path = _reads.model('embedding')?.path;
    return path == null
        ? 'local models'
        : path.split('/').where((s) => s.isNotEmpty).last;
  }

  String? localOutputRevision;
  FeatureRequestIdentity? _localOutputIdentity;
  Object? _localOutputRequest;
  int localOutputCount = 0;
  int recordedMeetings = 0, sourceCount = 0, completedAnswers = 0;
  List<int> localOutputWeekly = List<int>.filled(5, 0);

  int localWords() {
    final revision =
        '${d.store.dataRevision}:${outputWeekStart(DateTime.now()).millisecondsSinceEpoch}';
    if (localOutputRevision != revision ||
        !(_localOutputIdentity?.isCurrent(d, alive: mounted) ?? false)) {
      final identity = FeatureRequestIdentity.capture(d);
      final request = Object();
      localOutputRevision = revision;
      _localOutputIdentity = identity;
      _localOutputRequest = request;
      bool current() =>
          identical(_localOutputRequest, request) &&
          localOutputRevision == revision &&
          identity.isCurrent(d, alive: mounted);
      unawaited(
        localOutputStats(d.store).then(
          (stats) {
            if (!current()) return;
            var changed = localOutputCount != stats.words;
            for (var i = 0; i < 5; i++) {
              changed |= localOutputWeekly[i] != stats.weekly[i];
            }
            changed |=
                recordedMeetings != stats.recordedMeetings ||
                sourceCount != stats.sources ||
                completedAnswers != stats.completedAnswers;
            recordedMeetings = stats.recordedMeetings;
            sourceCount = stats.sources;
            completedAnswers = stats.completedAnswers;
            localOutputCount = stats.words;
            localOutputWeekly = stats.weekly;
            if (changed) _lifecycle.serviceChanged();
          },
          onError: (Object _) {
            // Retry on the next normal read, retaining the last successful values.
            // Scheduling a rebuild here would loop while the service is failing.
            if (current()) localOutputRevision = null;
          },
        ),
      );
    }
    return localOutputCount;
  }

  Widget stats() => _buildStats();

  Future<void> clearWorkspace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all workspace data?'),
        content: const Text(
          'This removes your imported sources, saved answers, meetings and notes. Your model files and registrations are kept. Google will be disconnected. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete workspace'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _operations.run(() async {
      _lifecycle.setClearingWorkspace(true);
      try {
        await d.command(Operation.workspaceClear);
      } finally {
        _lifecycle.setClearingWorkspace(false);
      }
      _host.update(_lifecycle.resetWorkspaceViews);
    });
  }

  @override
  Future<void> preference(String key, String value) async {
    await d.command(Operation.preferencesSet, {'key': key, 'value': value});
    if (mounted) _host.update(() {});
  }

  Widget settings() => _buildSettings();
}
