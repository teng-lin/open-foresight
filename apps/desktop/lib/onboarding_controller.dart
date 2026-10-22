part of 'main.dart';

class _OnboardingController extends _FeatureController {
  _OnboardingController(super.shell);
  bool finished = false, ready = false, working = false;
  String failure = '';
  bool get active =>
      widget.commands != null &&
      !finished &&
      d.store.preference('onboarding.complete') != 'true';

  Future<void> perform(Future<void> Function() action) async {
    if (working) return;
    setState(() {
      working = true;
      failure = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => failure = error is StateError
              ? error.message.toString()
              : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
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
        Platform.isMacOS
            ? 'Allow access for meeting transcription. You can skip this step and grant access before your first recording.'
            : 'This Linux build records through PipeWire. It does not need a separate macOS-style microphone or system-audio permission grant. Choose audio devices in Settings; desktop or sandbox policies may still restrict access.',
      ),
      const SizedBox(height: 20),
      if (Platform.isMacOS) ...[
        action(
          Icons.mic_none,
          'Microphone access',
          integrationFeature.requestMicrophoneAccess,
          subtitle: integrationFeature.microphoneAccessLabel,
          complete:
              integrationFeature.captureCapabilities['microphone'] ==
              'authorized',
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
        Platform.isMacOS
            ? 'Find files on this Mac'
            : 'Find files on this computer',
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
    valueListenable: shell.serviceUiRevision,
    builder: (_, __, ___) {
      final sources = readRows(d.store.sourceSummaries);
      final indexed = sources.where((s) => s['state'] == 'indexed').length;
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
            if (d.store.model('embedding')?.toRow() == null &&
                indexed < sources.length) ...[
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
                        '${source['title']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(sourceStatus(source)),
                      trailing: IconButton(
                        tooltip: 'Remove document',
                        onPressed: working
                            ? null
                            : () => perform(() async {
                                await d.command(Operation.sourcesDelete, {
                                  'id': source['id'],
                                });
                                shell.serviceChanged();
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

  String sourceStatus(Map<String, Object?> source) {
    final state = source['state'];
    final error = source['error']?.toString() ?? '';
    if (d.store.model('embedding')?.toRow() == null &&
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

  Widget build() => OnboardingView(
    initialStep: int.tryParse(d.store.preference('onboarding.step', '0')) ?? 0,
    runtimeReady: ready,
    externalBusy: working,
    runtimeError: shell.error,
    retryRuntime: () async {
      setState(() => shell.error = '');
      await d.initialize();
      await d.resume();
    },
    saveStep: (step) async {
      await d.command(Operation.preferencesSet, {
        'key': 'onboarding.step',
        'value': '$step',
      });
    },
    complete: () async {
      if (working) throw StateError('Wait for the current import to finish.');
      await d.command(Operation.preferencesSet, {
        'key': 'onboarding.complete',
        'value': 'true',
      });
      if (mounted)
        setState(() {
          finished = true;
          shell.tab = 0;
        });
    },
    generation: (done) =>
        settingsFeature.gemmaSetup(firstRun: true, onDone: done),
    transcription: (done) => settingsFeature.speechSetup(onDone: done),
    permissions: permissions,
    imports: imports,
    library: library,
    googleConnected: integrationFeature.googleAuth.connected,
    googleEmail: integrationFeature.googleAuth.email,
    connectGoogle: () async {
      await integrationFeature.connectGoogle();
      return integrationFeature.googleAuth.connected;
    },
  );
}
