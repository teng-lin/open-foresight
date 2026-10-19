part of 'main.dart';

class _SettingsController extends _FeatureController {
  _SettingsController(super.shell);

  bool gemmaExplanation = true;

  bool queryModelDownloading = false;

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

  Widget gemmaSetup({
    bool firstRun = false,
    bool embeddingOnly = false,
    VoidCallback? onDone,
  }) => GemmaSetupDialog(
    store: d.store,
    savePreference: saveModelPreference,
    onDone: onDone,
    firstRun: firstRun,
    needsEmbedding: needsModel(d.store, 'embedding'),
    needsGeneration:
        !embeddingOnly && (!firstRun || needsModel(d.store, 'generation')),
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
    directory: Directory('${File(d.store.path).parent.path}/models/gemma4'),
    library: runtimeConfiguration.nativeLibrary,
    runner: runtimeConfiguration['FORESIGHT_LITERT_RUNNER'] ?? '',
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
          shell.error = '';
          modelState = '${model.name} ready';
        });
    },
    localSetup: () {
      if (mounted) setState(() => shell.tab = 4);
    },
  );

  String speechModelName() {
    final registration = d.store.model('speech');
    if (registration == null) return 'Select a transcription model';
    final known = speechModels
        .where((model) => model.digest == registration['digest'])
        .firstOrNull;
    if (known != null) return known.name;
    final name = File(registration['path'] as String).uri.pathSegments.last;
    return name.contains('.en.') ? '$name (English only)' : name;
  }

  Future<void> chooseSpeech() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => speechSetup(),
    );
    if (mounted) setState(() {});
  }

  Widget speechSetup({VoidCallback? onDone}) {
    final registration = d.store.model('speech');
    return SpeechSetupDialog(
      store: d.store,
      savePreference: saveModelPreference,
      onDone: onDone,
      directory: Directory('${File(d.store.path).parent.path}/models/whisper'),
      runner:
          runtimeConfiguration['FORESIGHT_WHISPER_RUNTIME'] ??
          registration?['runtime'] as String? ??
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
          items: ['embedding', 'generation', 'speech', 'query-detection']
              .map(
                (s) => DropdownMenuItem(
                  value: s,
                  child: Text(
                    s == 'query-detection' ? 'Automatic questions' : s,
                  ),
                ),
              )
              .toList(),
          onChanged: (s) => setState(() => modelKind = s!),
        ),
        TextField(
          controller: modelPath,
          decoration: const InputDecoration(labelText: 'Model file'),
        ),
        if (modelKind == 'query-detection')
          const Text(
            'Download the dedicated question model using this distribution, or import an already-decrypted copy. Its identity and bundled runtime are verified before replacing the current model.',
          ),
        if (modelKind == 'query-detection')
          Row(
            children: [
              OutlinedButton(
                onPressed:
                    shell.busy ||
                        !Platform.isMacOS ||
                        (runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'] ??
                                '')
                            .isEmpty
                    ? null
                    : () async {
                        setState(() => queryModelDownloading = true);
                        try {
                          await shell.run(() async {
                            final terms = dedicatedQueryTermsUri();
                            if (terms == null)
                              throw StateError(
                                'This distribution has not supplied question model terms.',
                              );
                            if (d.store.preference(dedicatedQueryTermsKey) !=
                                'accepted') {
                              if (!await confirmQueryModelTerms(
                                context,
                                terms,
                                dedicatedQueryModelDigest,
                              ))
                                return;
                              await d.command(Operation.preferencesSet, {
                                'key': dedicatedQueryTermsKey,
                                'value': 'accepted',
                              });
                            }
                            await d.command(Operation.modelsAcquireQuery, {});
                            modelState = 'Automatic question model ready';
                          });
                        } finally {
                          if (mounted)
                            setState(() => queryModelDownloading = false);
                        }
                      },
                child: Text(
                  queryModelDownloading
                      ? 'Downloading and verifying…'
                      : 'Download question model',
                ),
              ),
              if (queryModelDownloading)
                TextButton(
                  onPressed: () async {
                    try {
                      await d.command(
                        Operation.modelsCancelQueryAcquisition,
                        {},
                      );
                    } catch (failure) {
                      if (mounted)
                        setState(() => shell.error = failure.toString());
                    }
                  },
                  child: const Text('Cancel download'),
                ),
            ],
          ),
        if (modelKind == 'query-detection' &&
            (!Platform.isMacOS ||
                (runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'] ?? '')
                    .isEmpty))
          const Text(
            'Automatic download is unavailable in this distribution. You can import a supported local copy.',
          ),
        if (modelKind != 'embedding' && modelKind != 'query-detection')
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
            onChanged: shell.busy
                ? null
                : (value) => setState(() => embeddingGpu = value!),
          ),
        FilledButton(
          onPressed: shell.busy
              ? null
              : () => shell.run(() async {
                  await d.command(
                    modelKind == 'embedding'
                        ? Operation.modelsEmbedding
                        : modelKind == 'generation'
                        ? Operation.modelsGeneration
                        : Operation.modelsRegister,
                    {
                      'kind': modelKind,
                      'path': modelPath.text,
                      'runtime': modelKind == 'query-detection'
                          ? ''
                          : runtimePath.text,
                      if (modelKind == 'query-detection')
                        'backend': 'legacy_query_cpu',
                      'gpu': embeddingGpu,
                    },
                  );
                  modelState = modelKind == 'query-detection'
                      ? 'Automatic question model ready'
                      : '$modelKind ready';
                }),
          child: Text(
            modelKind == 'query-detection'
                ? 'Verify and import'
                : 'Register and load',
          ),
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
          value: integrationFeature.notifications,
          onChanged:
              (Platform.isMacOS
                  ? runtimeConfiguration['FORESIGHT_NOTIFICATIONS'] != null
                  : integrationFeature.notificationState.startsWith(
                      'Notifications available',
                    ))
              ? (value) =>
                    shell.run(() => integrationFeature.setNotifications(value!))
              : null,
          title: const Text('Desktop completion/error notifications'),
          subtitle: Text(integrationFeature.notificationState),
        ),
        ListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: d.store.models
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
        'Connection: ${d.helper.state}\nEmbedding: ${d.helper.snapshot?.pipeline ?? 'unconfigured'}\nBackend: ${d.helper.snapshot?.model.backend ?? 'unconfigured'}\nDimensions: ${d.helper.snapshot?.model.dimensions ?? 0}\nIndex: ${d.helper.snapshot?.index ?? 'empty'}\nLast error: ${d.helper.snapshot?.lastError.isNotEmpty == true ? d.helper.snapshot!.lastError : 'None'}\nGeneration: ${d.generator?.effectiveState}\nSpeech: ${speechSetupProblem(d.store) ?? 'Ready'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: shell.busy
              ? null
              : () {
                  Navigator.pop(context);
                  unawaited(shell.run(d.resume));
                },
          child: const Text('Reload models'),
        ),
      ],
    ),
  );

  String generationName() {
    final model = d.store.model('generation');
    if (model == null) return 'Choose a local model';
    final known = gemmaModels
        .where((candidate) => candidate.digest == model['digest'])
        .firstOrNull;
    return known?.name ?? File(model['path'] as String).uri.pathSegments.last;
  }

  String embeddingName() {
    final backend = d.helper.snapshot?.model.backend;
    if (backend == 'litert-lm-embedding-cpu' ||
        backend == 'litert-lm-embedding-gpu') {
      return 'EmbeddingGemma 2';
    }
    final path = d.store.registeredEmbedding().firstOrNull?['path'] as String?;
    return path == null
        ? 'local models'
        : path.split('/').where((s) => s.isNotEmpty).last;
  }

  String? localOutputRevision;
  int localOutputCount = 0;
  List<int> localOutputWeekly = List<int>.filled(5, 0);

  int localWords() {
    final revision = d.store.dataRevision;
    if (localOutputRevision != revision) {
      localOutputRevision = revision;
      unawaited(
        localOutputStats(d.store.path).then((stats) {
          if (!mounted || localOutputRevision != revision) return;
          var changed = localOutputCount != stats.words;
          for (var i = 0; i < 5; i++) {
            changed |= localOutputWeekly[i] != stats.weekly[i];
          }
          localOutputCount = stats.words;
          localOutputWeekly = stats.weekly;
          if (changed) shell.serviceChanged();
        }, onError: (Object _) {}),
      );
    }
    return localOutputCount;
  }

  Widget stats() {
    final meetings = d.store.recordedMeetingCountRows().single['n'] as int;
    final sources = d.store.sourceSummaries.length;
    final answers = d.store.completedAnswerCountRows().single['n'] as int;
    localWords();
    final weekly = localOutputWeekly;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('Stats'),
          SizedBox(
            width: double.infinity,
            child: Card(
              shape: const RoundedRectangleBorder(
                borderRadius: DesktopVisuals.panelRadius,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Wrap(
                  spacing: 30,
                  runSpacing: 24,
                  children: [
                    Container(
                      width: 280,
                      height: 230 * MediaQuery.textScalerOf(context).scale(1),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xffe2edf8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Local output words',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          DesktopMetricValue(localWords(), fontSize: 52),
                          const Spacer(),
                          const Text('Estimated from saved local AI output'),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: math.max(
                        280,
                        MediaQuery.sizeOf(context).width - 650,
                      ),
                      height: 230 * MediaQuery.textScalerOf(context).scale(1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Your weekly output words',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Expanded(
                            child: CustomPaint(
                              size: const Size(
                                double.infinity,
                                double.infinity,
                              ),
                              painter: _UsageChart(
                                weekly,
                                textStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall!,
                                textScaler: MediaQuery.textScalerOf(context),
                                textDirection: Directionality.of(context),
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
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (_, constraints) {
              final cardWidth = constraints.maxWidth > 900
                  ? (constraints.maxWidth - 32) / 3
                  : math.min(320.0, constraints.maxWidth);
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  statCard(
                    meetings,
                    'Meetings transcribed',
                    'Fully processed on-device',
                    Icons.mic_none,
                    width: cardWidth,
                  ),
                  statCard(
                    sources,
                    'Knowledge sources added',
                    'Indexed with ${embeddingName()}',
                    Icons.folder_outlined,
                    width: cardWidth,
                  ),
                  statCard(
                    answers,
                    'AI answers provided',
                    'Zero cloud API calls',
                    Icons.auto_awesome,
                    width: cardWidth,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Card(
            shape: const RoundedRectangleBorder(
              borderRadius: DesktopVisuals.panelRadius,
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final introduction = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Foresight is built with on-device AI models that process your data locally on your computer.',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Get to know on-device AI models such as Gemma:',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        children: [
                          pill(
                            'What is Gemma?',
                            () => shell.update(() => gemmaExplanation = true),
                            selected: gemmaExplanation,
                          ),
                          pill(
                            'What is on-device AI?',
                            () => shell.update(() => gemmaExplanation = false),
                            selected: !gemmaExplanation,
                          ),
                        ],
                      ),
                    ],
                  );
                  final explanation = Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xfff2f4fa),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Image.asset(
                          'assets/images/gemma-mark.png',
                          width: 100,
                          height: 100,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          gemmaExplanation
                              ? 'Gemma is a family of lightweight AI models built by Google DeepMind using the same research and technology behind the Gemini models. Designed to run directly on local hardware such as a laptop without needing an internet connection.'
                              : 'Embedding, transcription and answer generation run on this computer using registered local models. After importing files, questions and recordings do not require a cloud AI service.',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  );
                  return constraints.maxWidth >= 800
                      ? Row(
                          children: [
                            Expanded(
                              flex: 9,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 24),
                                child: introduction,
                              ),
                            ),
                            const SizedBox(width: 28),
                            Expanded(flex: 11, child: explanation),
                          ],
                        )
                      : Column(
                          children: [
                            introduction,
                            const SizedBox(height: 24),
                            explanation,
                          ],
                        );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget statCard(
    int value,
    String title,
    String subtitle,
    IconData icon, {
    double width = 320,
  }) => SizedBox(
    width: width,
    child: Card(
      shape: const RoundedRectangleBorder(
        borderRadius: DesktopVisuals.panelRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: icon == Icons.mic_none
                  ? const Color(0xffebe6f8)
                  : icon == Icons.auto_awesome
                  ? const Color(0xffe1f3f2)
                  : const Color(0xffe2f2ff),
              child: Icon(
                icon,
                color: icon == Icons.mic_none
                    ? const Color(0xff673ab7)
                    : icon == Icons.auto_awesome
                    ? const Color(0xff008577)
                    : const Color(0xff006cda),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DesktopMetricValue(value),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(subtitle, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

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
    await shell.run(() async {
      meetingFeature.meetingNoteSaves.discardAll();
      await d.command(Operation.workspaceClear);
      shell.update(() {
        meetingFeature.meetingId = null;
        meetingFeature.loadedMeetingNotes = null;
        meetingFeature.meetingNotesController.clear();
        meetingFeature.meetingEnhanceStatus = '';
        sourceFeature.sourceQuery = '';
        sourceFeature.sourceSearchController.clear();
        meetingFeature.meetingQuery = '';
        sourceFeature.labelFilter = '';
        meetingFeature.noteId = null;
        meetingFeature.noteTitle.clear();
        meetingFeature.noteBody.clear();
        chatFeature.hiddenAnswers.clear();
        chatFeature.answer = '';
      });
    });
  }

  Future<void> preference(String key, String value) async {
    await d.command(Operation.preferencesSet, {'key': key, 'value': value});
    if (mounted) shell.update(() {});
  }

  Widget settingRow(String title, String subtitle, Widget control) =>
      LayoutBuilder(
        builder: (_, constraints) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (subtitle.isNotEmpty) Text(subtitle),
            ],
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: constraints.maxWidth < 720
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [text, const SizedBox(height: 12), control],
                  )
                : Row(
                    children: [
                      Expanded(child: text),
                      const SizedBox(width: 20),
                      control,
                    ],
                  ),
          );
        },
      );

  Widget settings() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('Settings'),
        const SizedBox(height: 30),
        const Text('General', style: DesktopVisuals.sectionTitle),
        const SizedBox(height: 6),
        const Text('Configure general application settings.'),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Open at login'),
                subtitle: Text(
                  integrationFeature.loginState.isEmpty
                      ? 'Automatically open Foresight when you log in to your computer.'
                      : integrationFeature.loginState,
                ),
                value: integrationFeature.desktopSettings.openAtLogin,
                onChanged: shell.busy
                    ? null
                    : (value) => shell.run(
                        () => integrationFeature.setOpenAtLogin(value),
                      ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Upcoming meeting reminders'),
                subtitle: const Text(
                  'Notify five minutes before a timed Calendar meeting starts.',
                ),
                value: d.store.preference('googleReminders') == 'true',
                onChanged: shell.busy
                    ? null
                    : (value) => shell.run(
                        () => integrationFeature.setMeetingReminders(value),
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Local Inference Model',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text('Select the local generative model to use.'),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed:
                            shell.busy || meetingFeature.recording != null
                            ? null
                            : chooseGemma,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xffdee3e9),
                          foregroundColor: const Color(0xff26272b),
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                generationName(),
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                            const Icon(Icons.unfold_more, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              settingRow(
                'Source Search Model',
                needsModel(d.store, 'embedding')
                    ? 'EmbeddingGemma 2 runs source search locally. Setup reuses an existing model or downloads 485 MB.'
                    : 'EmbeddingGemma 2 is installed and runs source search locally.',
                OutlinedButton(
                  onPressed:
                      shell.busy ||
                          meetingFeature.recording != null ||
                          !needsModel(d.store, 'embedding')
                      ? null
                      : () => chooseGemma(embeddingOnly: true),
                  child: Text(
                    needsModel(d.store, 'embedding')
                        ? 'Download EmbeddingGemma 2'
                        : 'Embedding model ready',
                  ),
                ),
              ),
              const Divider(height: 1),
              settingRow(
                'Transcription Model',
                'Choose multilingual speech recognition for Chinese and English.',
                OutlinedButton.icon(
                  onPressed: shell.busy || meetingFeature.recording != null
                      ? null
                      : chooseSpeech,
                  icon: const Icon(Icons.unfold_more, size: 18),
                  label: Text(speechModelName()),
                ),
              ),
              const Divider(height: 1),
              settingRow(
                'Default Note Enhancement Style',
                'Format enhanced notes as complete sentences or brief phrases.',
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    textStyle: WidgetStatePropertyAll(
                      TextStyle(
                        fontFamily: 'GoogleSans',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: 'Standard',
                      label: Text('Standard'),
                      icon: Icon(Icons.description_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: 'Concise',
                      label: Text('Concise'),
                      icon: Icon(Icons.short_text, size: 16),
                    ),
                  ],
                  selected: {d.store.preference('noteStyle', 'Standard')},
                  onSelectionChanged: (v) => preference('noteStyle', v.first),
                ),
              ),
              const Divider(height: 1),
              settingRow(
                'Auto-stop transcribing after inactivity',
                'Finalize when microphone and playback audio are inactive.',
                DesktopSettingSelect<String>(
                  value: d.store.preference('inactivity', '15'),
                  items: ['0', '5', '10', '15', '30']
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(
                            v == '0'
                                ? 'Never'
                                : v == '15'
                                ? '15 minutes (Default)'
                                : '$v minutes',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => preference('inactivity', v!),
                ),
              ),
              if (Platform.isMacOS) ...[
                const Divider(height: 1),
                settingRow(
                  'Echo cancellation',
                  meetingFeature.echoCancellationDescription,
                  Switch(
                    value:
                        d.store.preference('echoCancellation', 'false') ==
                        'true',
                    onChanged: (value) =>
                        preference('echoCancellation', '$value'),
                  ),
                ),
              ],
              const Divider(height: 1),
              settingRow(
                'Launch Agent Monitor',
                'Monitor and control the local helper.',
                IconButton(
                  tooltip: 'Helper monitor',
                  onPressed: showHelperMonitor,
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                title: const Text(
                  'Clear workspace data',
                  style: TextStyle(color: Colors.red),
                ),
                subtitle: const Text(
                  'Delete sources, answers, meetings and notes. Keep local model files.',
                ),
                trailing: const Icon(Icons.delete_outline, color: Colors.red),
                onTap: shell.busy || meetingFeature.recording != null
                    ? null
                    : clearWorkspace,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('Hotkeys', style: DesktopVisuals.sectionTitle),
        const SizedBox(height: 8),
        Text(
          d.store.preference('globalShortcut') == 'true'
              ? 'The meeting shortcut works across the desktop.'
              : 'Enable global shortcuts to use the meeting shortcut outside Foresight.',
        ),
        Card(
          child: SwitchListTile(
            title: const Text('Global meeting shortcut'),
            subtitle: Text(integrationFeature.globalShortcutState),
            value: d.store.preference('globalShortcut') == 'true',
            onChanged: shell.busy
                ? null
                : (enabled) => shell.run(
                    enabled
                        ? integrationFeature.enableGlobalShortcuts
                        : integrationFeature.disableGlobalShortcuts,
                  ),
          ),
        ),
        Card(
          child: settingRow(
            'Quick start new meeting transcript',
            'Use at least two modifiers and a letter or digit.',
            TextButton(
              onPressed: shell.busy
                  ? null
                  : integrationFeature.changeQuickShortcut,
              child: Text(
                d.store.preference('quickShortcut', 'CTRL + SHIFT + F'),
              ),
            ),
          ),
        ),
        Card(
          child: settingRow(
            'New editable note',
            '',
            TextButton(
              onPressed: () => shell.update(() => shell.tab = 2),
              child: Text(Platform.isMacOS ? '⌘ + N' : 'Ctrl + N'),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Audio and notifications',
          style: DesktopVisuals.sectionTitle,
        ),
        Card(
          child: Column(
            children: [
              if (Platform.isMacOS) ...[
                ListTile(
                  title: const Text('Recording access'),
                  subtitle: Text(
                    integrationFeature.captureCapabilityError.isNotEmpty
                        ? integrationFeature.captureCapabilityError
                        : 'Microphone: ${integrationFeature.microphoneAccessLabel}\nSystem audio: ${integrationFeature.systemAudioAccessLabel}',
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: shell.busy
                          ? null
                          : () => shell.run(
                              integrationFeature.requestMicrophoneAccess,
                            ),
                      child: const Text('Allow microphone'),
                    ),
                    TextButton(
                      onPressed: shell.busy
                          ? null
                          : () => shell.run(() async {
                              await integrationFeature.setupSystemAudioAccess();
                            }),
                      child: const Text('Allow system audio'),
                    ),
                    TextButton(
                      onPressed: shell.busy
                          ? null
                          : integrationFeature.refreshCaptureCapabilities,
                      child: const Text('Refresh access status'),
                    ),
                  ],
                ),
                const Divider(height: 1),
              ],
              settingRow(
                'Microphone',
                'Select the microphone used for spoken transcription.',
                integrationFeature.deviceChoice(false),
              ),
              const Divider(height: 1),
              settingRow(
                'System playback',
                'Select the output whose playback should be transcribed.',
                integrationFeature.deviceChoice(true),
              ),
              if (integrationFeature.audioDeviceState.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(integrationFeature.audioDeviceState),
                ),
              TextButton(
                onPressed: integrationFeature.refreshAudioDevices,
                child: const Text('Refresh audio devices'),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Desktop completion notifications'),
                subtitle: Text(integrationFeature.notificationState),
                value: integrationFeature.notifications,
                onChanged: shell.busy
                    ? null
                    : (value) => shell.run(
                        () => integrationFeature.setNotifications(value),
                      ),
              ),
              const Divider(height: 1),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('Connected services', style: DesktopVisuals.sectionTitle),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  integrationFeature.googleAuth.connected
                      ? 'Connected as ${integrationFeature.googleAuth.email}'
                      : 'Google Drive and Calendar',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Connect to import files and upcoming meetings. Foresight requests read-only access; imported text is indexed on this computer.',
                ),
                if (!integrationFeature.googleAuth.connected &&
                    integrationFeature.googleAuth.client == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Google sign-in is unavailable in this build. Install a distribution with Google sign-in included.',
                    ),
                  ),
                if (integrationFeature.googleState.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(integrationFeature.googleState),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!integrationFeature.googleAuth.connected) ...[
                      FilledButton(
                        onPressed: shell.busy
                            ? null
                            : () => shell.run(integrationFeature.connectGoogle),
                        child: const Text('Connect Google'),
                      ),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text('Google connection setup'),
                            content: SelectableText(
                              integrationFeature.googleAuth.client != null
                                  ? 'Choose Connect Google, select your account in the browser, and grant Drive and Calendar read access. This app already has its application sign-in configuration.\n\nYour Google password is never entered into Foresight. After signing in, you return to the app automatically.'
                                  : 'Google sign-in is unavailable in this build. Install a distribution with Google sign-in included.\n\nSign-in opens your default browser and asks for read access. Your Google password is never entered into Foresight.',
                            ),
                          ),
                        ),
                        child: const Text('Connection help'),
                      ),
                    ] else ...[
                      TextButton(
                        onPressed:
                            shell.busy || integrationFeature.googleSyncing
                            ? null
                            : () =>
                                  shell.run(integrationFeature.google.refresh),
                        child: const Text('Refresh Google'),
                      ),
                      TextButton(
                        onPressed: shell.busy
                            ? null
                            : () => shell.run(
                                integrationFeature.disconnectGoogle,
                              ),
                        child: const Text('Disconnect Google'),
                      ),
                    ],
                    if (integrationFeature.googleAuth.signingIn)
                      TextButton(
                        onPressed: integrationFeature.googleAuth.cancelSignIn,
                        child: const Text('Cancel sign-in'),
                      ),
                  ],
                ),
                const Divider(),
                settingRow(
                  'Refresh interval for Calendar events and Drive files',
                  'Refreshes imported Drive folders, files and upcoming Calendar events.',
                  DesktopSettingSelect<String>(
                    value: d.store.preference('googleRefreshHours', '4'),
                    items: ['1', '2', '4', '8', '24']
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('$value hours'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        preference('googleRefreshHours', value!),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Foresight processes knowledge sources and AI requests on your computer. Transcribing listens to microphone and system playback while active. Transcripts update during recording; Stop finalizes pending speech. Imported URL pages are fetched only when you request an import.',
            ),
          ),
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('Third-party Libraries'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Foresight',
                  applicationVersion: openForesightVersion,
                ),
              ),
              const Divider(height: 1),
              const ListTile(
                title: Text('Version'),
                subtitle: Text(
                  'Open Foresight $openForesightVersion '
                  '(build $openForesightBuildNumber)'
                  '${openForesightBuildLabel == '' ? '' : ' · $openForesightBuildLabel'}',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SettingsView extends StatelessWidget {
  final _SettingsController controller;
  const _SettingsView(this.controller);
  @override
  Widget build(BuildContext context) => controller.settings();
}
