import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import 'dart:async';
import '../../feature_request_identity.dart';
import 'read_model.dart';
import '../../shell/ports.dart';
import '../../shell/workspace_tab.dart';
import 'onboarding_view.dart';

class OnboardingController implements OnboardingActivity {
  OnboardingController({
    required FeatureHost host,
    required WorkspaceNavigation navigation,
    required OperationGate operations,
    required WorkspaceLifecycle lifecycle,
    required SettingsCommands settings,
    required SourceCommands sources,
    required IntegrationsPort integrations,
  }) : _host = host,
       _navigation = navigation,
       _operations = operations,
       _lifecycle = lifecycle,
       settingsFeature = settings,
       sourceFeature = sources,
       integrationFeature = integrations;

  final FeatureHost _host;
  final WorkspaceNavigation _navigation;
  final OperationGate _operations;
  final WorkspaceLifecycle _lifecycle;
  final SettingsCommands settingsFeature;
  final SourceCommands sourceFeature;
  final IntegrationsPort integrationFeature;
  bool _disposed = false;
  DesktopConnection get d => _host.connection;
  bool get mounted => !_disposed && _host.mounted;
  BuildContext get context => _host.context;
  void setState(VoidCallback action) {
    if (mounted) _host.update(action);
  }

  Object? _preparedOwner;
  int _actionGeneration = 0;
  late final OnboardingReadModel _reads = OnboardingReadModel(
    connection: () => d,
    changed: () {
      if (!mounted) return;
      _host.update(() {
        if (!identical(_preparedOwner, _reads.ownerKey)) {
          _preparedOwner = _reads.ownerKey;
          _actionGeneration++;
          working = false;
          failure = '';
        }
      });
    },
  );
  void start() => _reads.start();
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_reads.dispose());
  }

  bool finished = false, ready = false, working = false;
  String failure = '';
  @override
  bool get active => _host.commands != null && !finished && !_reads.complete;

  Future<void> perform(Future<void> Function() action) async {
    if (working) return;
    final identity = FeatureRequestIdentity.capture(d);
    final generation = ++_actionGeneration;
    setState(() {
      working = true;
      failure = '';
    });
    try {
      await action();
    } catch (error) {
      if (generation == _actionGeneration &&
          identity.isCurrent(d, alive: mounted)) {
        setState(
          () => failure = error is StateError
              ? error.message.toString()
              : error.toString(),
        );
      }
    } finally {
      if (mounted && generation == _actionGeneration) {
        setState(() => working = false);
      }
    }
  }

  Widget action(
    IconData icon,
    String title,
    Future<void> Function() callback, {
    String? subtitle,
    bool complete = false,
    bool reviewable = false,
  }) => Card(
    color: const Color(0xfff2f4fa),
    child: ListTile(
      leading: Icon(icon, color: const Color(0xff006c97)),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Icon(complete ? Icons.check_circle_outline : Icons.add),
      onTap: working || (complete && !reviewable)
          ? null
          : () => perform(callback),
    ),
  );

  Widget status() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (working) const LinearProgressIndicator(),
      if (failure.isNotEmpty)
        Text(
          failure,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );

  Widget permissions(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _host.environment.capabilities.requiresAudioPermissions
            ? 'Allow access for meeting transcription. You can skip this step and grant access before your first recording.'
            : 'This Linux build records through PipeWire. It does not need a separate macOS-style microphone or system-audio permission grant. Choose audio devices in Settings; desktop or sandbox policies may still restrict access.',
      ),
      const SizedBox(height: 20),
      if (_host.environment.capabilities.requiresAudioPermissions) ...[
        action(
          Icons.mic_none,
          'Microphone access',
          integrationFeature.requestMicrophoneAccess,
          subtitle: integrationFeature.microphoneAccessLabel,
          complete: integrationFeature.microphoneAuthorized,
        ),
        action(
          Icons.volume_up_outlined,
          'System audio capture',
          () async {
            await integrationFeature.setupSystemAudioAccess();
          },
          subtitle: integrationFeature.systemAudioAccessLabel,
          complete: integrationFeature.systemAudioSetupComplete,
          reviewable: true,
        ),
        TextButton(
          onPressed: working
              ? null
              : () => perform(integrationFeature.refreshCaptureCapabilities),
          child: const Text('Refresh access status'),
        ),
        if (integrationFeature.captureCapabilityError.isNotEmpty)
          Text(integrationFeature.captureCapabilityError),
      ],
      action(
        Icons.notifications_none,
        integrationFeature.notifications
            ? 'Notifications enabled'
            : 'Enable notifications',
        () => integrationFeature.setNotifications(true),
        subtitle: integrationFeature.notificationState,
        complete: integrationFeature.notifications,
      ),
      const SizedBox(height: 12),
      const Text(
        'Audio access does not start a recording. Notifications report completion and errors; they are optional.',
      ),
      status(),
    ],
  );

  Widget imports(BuildContext context) => Column(
    children: [
      action(
        Icons.add_to_drive_outlined,
        'Add files from Drive',
        integrationFeature.chooseDrive,
      ),
      action(
        Icons.search,
        'Find files on this ${_host.environment.capabilities.deviceName}',
        sourceFeature.findLocalFiles,
      ),
      action(
        Icons.folder_outlined,
        'Import folder',
        sourceFeature.importFolder,
      ),
      action(Icons.upload_file_outlined, 'Import file', sourceFeature.import),
      action(Icons.link, 'Add from URL', sourceFeature.importUrl),
      status(),
    ],
  );

  Widget library(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _host.serviceUiRevision,
    builder: (_, __, ___) {
      final sources = _reads.sources;
      final indexed = sources.where((s) => s.state == 'indexed').length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Documents added (${sources.length})',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          if (sources.isEmpty)
            const Text(
              'Add documents to see them here. You can also do this later from Knowledge sources.',
            ),
          if (sources.isNotEmpty) ...[
            if (_reads.embedding == null && indexed < sources.length) ...[
              const Text(
                'Documents are saved. Finish model setup to make them searchable.',
              ),
              TextButton(
                onPressed: working
                    ? null
                    : () => perform(
                        () => settingsFeature.chooseGemma(
                          firstRun: true,
                          embeddingOnly: true,
                        ),
                      ),
                child: const Text('Set up indexing model'),
              ),
              const SizedBox(height: 12),
            ],
            Text('${sources.length} sources added · $indexed indexed'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: indexed / sources.length),
            const SizedBox(height: 20),
            SizedBox(
              height: math.min(520, sources.length * 100.0),
              child: ListView.builder(
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final source = sources[index];
                  return Card(
                    color: const Color(0xfff7f8fa),
                    child: ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(
                        source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(sourceStatus(source)),
                      trailing: IconButton(
                        tooltip: 'Remove document',
                        onPressed: working
                            ? null
                            : () => perform(() async {
                                await sourcesDeleteDescriptor.send(
                                  d,
                                  SourcesDeleteInput(id: source.id),
                                );
                                _lifecycle.serviceChanged();
                              }),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      );
    },
  );

  String sourceStatus(SourceSummary source) {
    final state = source.state;
    final error = source.error;
    if (_reads.embedding == null &&
        (state == 'pending' ||
            (state == 'failed' &&
                error.contains('Pipeline not initialized')))) {
      return 'Waiting for model setup';
    }
    return switch (state) {
      'indexed' => 'Ready',
      'pending' => 'Waiting to index',
      'indexing' => 'Indexing…',
      'failed' => 'Couldn’t index this document. Retry from Knowledge sources.',
      _ => 'Saved',
    };
  }

  Future<void> _preference(String key, String value) async {
    final identity = FeatureRequestIdentity.capture(d);
    await preferencesSetDescriptor.send(
      d,
      PreferencesSetInput(key: key, value: value),
    );
    if (!identity.isCurrent(d, alive: mounted)) {
      throw RpcError(RpcErrorCode.cancelled, 'Setup owner changed');
    }
  }

  Widget build() {
    if (!_reads.preferencesReady) {
      return Center(
        child: _reads.problem == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Setup could not load. Retry to continue.'),
                  TextButton(
                    onPressed: _reads.retry,
                    child: const Text('Retry setup'),
                  ),
                ],
              ),
      );
    }
    return OnboardingView(
      key: ValueKey(_reads.ownerKey),
      initialStep: _reads.step,
      runtimeReady: ready,
      externalBusy: working,
      runtimeError: _operations.error,
      retryRuntime: () async {
        _operations.setError('');
        final connection = d;
        await connection.initialize();
        await connection.resume();
        // A successful resume can replace its underlying client session. Runtime
        // readiness belongs to this connection, rather than to a data snapshot.
        if (mounted && identical(d, connection)) setState(() => ready = true);
      },
      saveStep: (step) async {
        await _preference('onboarding.step', '$step');
      },
      complete: () async {
        if (working) throw StateError('Wait for the current import to finish.');
        await _preference('onboarding.complete', 'true');
        if (mounted)
          setState(() {
            finished = true;
            _navigation.navigate(WorkspaceTab.sources);
          });
      },
      generation: (done) =>
          settingsFeature.gemmaSetup(firstRun: true, onDone: done),
      transcription: (done) => settingsFeature.speechSetup(onDone: done),
      permissions: permissions,
      imports: imports,
      library: library,
      googleConnected: integrationFeature.googlePresentation.connected,
      googleEmail: integrationFeature.googlePresentation.email,
      connectGoogle: () async {
        await integrationFeature.connectGoogle();
        return integrationFeature.googlePresentation.connected;
      },
    );
  }
}
