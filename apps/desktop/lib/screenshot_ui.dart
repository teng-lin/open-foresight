part of 'main.dart';

const _blue = Color(0xffbfe8ff);
const _ink = Color(0xff07577b);

extension _ScreenshotScreens on _WorkspaceState {
  String get echoCancellationDescription {
    final capture = d is RemoteDomain
        ? (d as RemoteDomain).capture
        : d.application.captureState;
    final echo = capture['echo_cancellation'] as Map? ?? {};
    if (capture['active'] != true)
      return 'Reduce system playback picked up by your microphone.';
    if (capture['paused'] == true)
      return 'The selected setting will apply when recording resumes.';
    if (echo['pending'] == true) return 'Applying echo cancellation…';
    if ((echo['fallback_status'] as num? ?? 0) != 0)
      return 'Echo cancellation is unavailable; microphone recording continues.';
    if (echo['restart_required'] == true)
      return 'Restart recording to enable echo cancellation.';
    return echo['active'] == true
        ? 'Echo cancellation is active for this microphone.'
        : 'Echo cancellation is off.';
  }

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
          onPressed: busy
              ? null
              : () {
                  Navigator.pop(context);
                  unawaited(run(d.resume));
                },
          child: const Text('Reload models'),
        ),
      ],
    ),
  );

  Widget pill(
    String title,
    VoidCallback? action, {
    IconData? icon,
    bool selected = false,
  }) => FilledButton.tonalIcon(
    onPressed: action,
    style: FilledButton.styleFrom(
      backgroundColor: selected ? _blue : Colors.white,
      foregroundColor: _ink,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),
    icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 20),
    label: Text(title),
  );

  Widget heading(String title, {List<Widget> actions = const []}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Text(title, style: DesktopVisuals.pageTitle);
        final controls = Wrap(spacing: 12, runSpacing: 8, children: actions);
        if (constraints.maxWidth < 700 && actions.isNotEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 12), controls],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            if (actions.isNotEmpty) controls,
          ],
        );
      },
    ),
  );

  Widget searchBox(
    String hint,
    ValueChanged<String> onChanged, {
    TextEditingController? controller,
  }) => TextField(
    controller: controller,
    style: DesktopVisuals.field,
    onChanged: (value) => update(() => onChanged(value)),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: Color(0xffb8babd),
        fontWeight: FontWeight.w400,
      ),
      prefixIcon: const Icon(Icons.search, color: Color(0xffb8babd)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(40),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(40),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Future<void> quickStart() async {
    if (!mounted || quickStarting || busy || recording != null) return;
    update(() => quickStarting = true);
    try {
      if (speechSetupProblem(d.store) != null) {
        await chooseSpeech();
        if (!mounted || speechSetupProblem(d.store) != null) return;
      }
      if (!await ensureRecordingAccess() || !mounted) return;
      await run(() async {
        final created =
            await d.command('meetings.create', {'title': '[New Meeting]'})
                as Map;
        if (!mounted) return;
        update(() {
          tab = 3;
          meetingId = created['id'] as int;
        });
        await startRecording(accessReviewed: true);
      });
    } catch (failure, stack) {
      if (mounted) await run(() => Future<void>.error(failure, stack));
    } finally {
      if (mounted) update(() => quickStarting = false);
    }
  }

  SingleActivator get quickActivator {
    final parts = d.store
        .preference('quickShortcut', 'CTRL + SHIFT + F')
        .split(' + ');
    return SingleActivator(
      LogicalKeyboardKey(parts.last.toLowerCase().codeUnitAt(0)),
      control: parts.contains('CTRL'),
      shift: parts.contains('SHIFT'),
      alt: parts.contains('ALT'),
      meta: parts.any({'SUPER', 'CMD', 'COMMAND', 'META'}.contains),
    );
  }

  Future<void> changeQuickShortcut() async {
    final input = TextEditingController(
      text: d.store.preference('quickShortcut', 'CTRL + SHIFT + F'),
    );
    final saved = await showInputDialog<bool>(
      builder: (context) => AlertDialog(
        title: const Text('Meeting shortcut'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(hintText: 'CTRL + SHIFT + F'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save shortcut'),
          ),
        ],
      ),
    );
    final value = input.text;
    input.dispose();
    if (saved != true || !mounted) return;
    await run(() async {
      final normalized = HyprShortcuts.normalize(
        Platform.isMacOS
            ? value
                  .toUpperCase()
                  .replaceAll(RegExp(r'\b(CMD|COMMAND|META)\b'), 'SUPER')
                  .replaceAll('OPTION', 'ALT')
                  .replaceAll('CONTROL', 'CTRL')
            : value,
      );
      if (d.store.preference('globalShortcut') == 'true') {
        if (Platform.isMacOS) {
          await globalShortcuts!.enable(
            preferredTrigger: normalized.replaceAll(' ', ''),
          );
        } else if (Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] !=
            null) {
          await hyprShortcuts.install(normalized);
        } else {
          await globalShortcuts!.configure();
          return;
        }
      }
      await preference('quickShortcut', normalized);
    });
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
      quickActivator: () {
        if (!busy && recording == null) unawaited(quickStart());
      },
      SingleActivator(
        LogicalKeyboardKey.keyO,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () {
        if (!busy) unawaited(run(import));
      },
      SingleActivator(
        LogicalKeyboardKey.keyN,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () => update(() {
        tab = 2;
        noteId = null;
        noteTitle.clear();
        noteBody.clear();
      }),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                28,
                recording != null ? 16 : 24,
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
                                label: Text('Powered by ${embeddingName()}'),
                              ),
                              Chip(
                                label: Text(
                                  '${localTokens()} Local output tokens',
                                ),
                              ),
                            ],
                            SizedBox(
                              width: 32,
                              height: 28,
                              child: IconButton(
                                tooltip: 'Local helper status',
                                onPressed: showHelperMonitor,
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
                                  helperEmbeddingHealthy
                                      ? Icons.task_alt
                                      : Icons.info_outline,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (recording != null)
                        recordingHeader()
                      else
                        FilledButton.icon(
                          onPressed: busy || quickStarting || meetingEnhancing
                              ? null
                              : quickStart,
                          icon: Icon(
                            recording != null ? Icons.stop : Icons.graphic_eq,
                          ),
                          label: Text(
                            recording != null
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
                        tab == 1 || (tab == 3 && meetingId != null)
                            ? 16
                            : MediaQuery.sizeOf(context).width > 1000
                            ? 56
                            : 16,
                        tab == 3 && meetingId != null
                            ? 12
                            : tab == 1
                            ? 22
                            : 34,
                        MediaQuery.sizeOf(context).width > 1000
                            ? (tab == 1 || (tab == 3 && meetingId != null)
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
                            child: [
                              sources,
                              chat,
                              notes,
                              meetings,
                              models,
                              stats,
                              settings,
                            ][tab](),
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
    final path =
        d.store
                .rows("SELECT path FROM models WHERE kind='embedding'")
                .firstOrNull?['path']
            as String?;
    return path == null
        ? 'local models'
        : path.split('/').where((s) => s.isNotEmpty).last;
  }

  int localTokens() =>
      d.store
          .rows('SELECT body FROM answers WHERE status=\'completed\'')
          .fold<int>(
            0,
            (n, row) =>
                n + (row['body'] as String).split(RegExp(r'\s+')).length,
          ) +
      d.store
          .rows('SELECT generated FROM artifacts')
          .fold<int>(
            0,
            (n, row) =>
                n + (row['generated'] as String).split(RegExp(r'\s+')).length,
          );

  Future<void> importPath(String path) async {
    await d.command('sources.import_file', {'path': path});
    if (mounted) update(() {});
  }

  Future<void> findFilesOnComputer({List<String>? roots}) async {
    final excluded = <String>{};
    for (final row in d.store.sources) {
      final provenance = row['provenance'] as String;
      for (final prefix in [
        'UTF-8 text; ',
        'pdftotext -layout (Linux adapter); ',
        'unrtf --text (Linux adapter); ',
        'PDFKit (macOS adapter); ',
        'NSAttributedString RTF (macOS adapter); ',
      ]) {
        if (provenance.startsWith(prefix))
          excluded.add(provenance.substring(prefix.length));
      }
    }
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (_) => FileDiscoverySheet(
        initialFolders:
            roots ??
            LocalFileDiscovery.defaultFolders(Platform.environment['HOME']!),
        excludedPaths: excluded,
        pickFolder: () => getDirectoryPath(),
      ),
    );
    if (!mounted || selected == null) return;
    final failures = <String>[];
    for (final path in selected) {
      try {
        await importPath(path);
      } catch (e) {
        failures.add('${path.split('/').last}: $e');
      }
    }
    if (failures.isNotEmpty)
      throw StateError(
        'Imported ${selected.length - failures.length} files. ${failures.join('\n')}',
      );
  }

  Future<void> importFolder() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    await importDirectory(path);
  }

  Future<void> importDirectory(String path) async {
    await d.command('sources.import_directory', {'path': path});
  }

  Future<void> reimport() async {
    await d.command('sources.refresh');
  }

  String googleSyncStatus() {
    if (googleSyncing) return 'Syncing…';
    final timestamp = google.lastCompletedRefreshMs;
    if (timestamp == 0) return 'Not synced yet';
    final last = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final days = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(last.year, last.month, last.day)).inDays;
    if (days == 0) return 'Last synced today';
    if (days == 1) return 'Last synced yesterday';
    return 'Last synced $days days ago';
  }

  Future<void> importUrl() async {
    final input = TextEditingController();
    var allowPrivateNetwork = false;
    final accepted = await showInputDialog<bool>(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Please enter the URL'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: input,
                autofocus: true,
                style: DesktopVisuals.field,
                decoration: const InputDecoration(
                  hintText: 'Please enter the URL',
                  filled: true,
                  fillColor: Color(0xffe1e6ef),
                  border: UnderlineInputBorder(),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xff74777d)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xff006c97), width: 2),
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow private network addresses'),
                value: allowPrivateNetwork,
                onChanged: (value) =>
                    setDialogState(() => allowPrivateNetwork = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    final value = input.text.trim();
    input.dispose();
    if (accepted != true) return;
    await importAddress(value, allowPrivateNetwork: allowPrivateNetwork);
  }

  Future<void> importAddress(
    String value, {
    bool allowPrivateNetwork = false,
  }) async {
    await d.command('sources.import_url', {
      'url': value,
      if (allowPrivateNetwork) 'allow_private_network': true,
    });
  }

  List<String> sourceLabels(Map<String, Object?> s) =>
      (jsonDecode(s['labels'] as String? ?? '[]') as List).cast<String>();
  Future<void> putDocumentLabel(DocumentLabel label) async {
    await d.command('labels.put', {
      'id': label.documentId,
      'name': label.name,
      'source': label.source,
      'color': label.colorHex,
      'rationale': label.rationale,
    });
  }

  Future<bool> saveGraphLayout(
    String identity,
    List<Map<String, Object?>> sources,
    Map<String, List<double>> vectors,
    Map<String, GraphPoint> points, {
    String? labelSet,
    List<GraphCluster> clusters = const [],
  }) async {
    return await d.command('graph.save', {
          'identity': identity,
          'sources': sources,
          'vectors': vectors,
          'points': points.map((k, v) => MapEntry(k, [v.x, v.y, v.z])),
          'labelSet': labelSet,
          'clusters': clusters
              .map(
                (c) => {
                  'label': c.label,
                  'center_proj_x': c.center.x,
                  'center_proj_y': c.center.y,
                  'radius': c.radius,
                },
              )
              .toList(),
        })
        as bool;
  }

  Future<void> addSelectedGraphLabel(String id, String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    await putDocumentLabel(
      DocumentLabel(
        id,
        name,
        'user_defined',
        allocateGraphLabelColor(name, d.store.documentLabels),
      ),
    );
    graphLabelInput.clear();
    await autoAssignOrganizationLabel(name);
  }

  Future<void> removeSelectedGraphLabel(String id, String name) async {
    final source = d.store.sources.where((row) => row['id'] == id).single;
    await d.command('labels.set', {
      'id': id,
      'labels': sourceLabels(source).where((label) => label != name).toList(),
    });
    await d.command('graph.acknowledge');
    if (mounted) update(() {});
  }

  Future<void> createOrganizationLabel() async {
    final input = TextEditingController();
    final name = await showInputDialog<String>(
      builder: (context) => AlertDialog(
        title: const Text('Create New Organization Label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Automatically attach this label to related documents and organize them into a cluster.',
            ),
            TextField(
              controller: input,
              decoration: const InputDecoration(
                hintText: 'e.g. Eloquent Project',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = input.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            child: const Text('Create & Auto-Assign'),
          ),
        ],
      ),
    );
    input.dispose();
    if (name != null && mounted)
      await run(() => autoAssignOrganizationLabel(name));
  }

  Future<void> autoAssignOrganizationLabel(String name) async {
    final all = d.store.sources;
    final indexed = all.where((row) => row['state'] == 'indexed').toList();
    final snapshot = d.helper.snapshot;
    final saved = snapshot?.pipeline == 'ready'
        ? d.store.loadGraphLayout(
            jsonEncode([
              graphLayoutAlgorithmVersion,
              snapshot!.model.modelDigest,
              snapshot.model.tokenizerDigest,
              snapshot.model.preprocessing,
              snapshot.model.backend,
              snapshot.model.dimensions,
            ]),
            indexed,
            snapshot.model.dimensions,
          )
        : d.store.loadRegisteredGraphLayout(indexed);
    final vectors = Map<String, List<double>>.from(saved.vectors);
    final missing = indexed
        .where((row) => !vectors.containsKey(row['id']))
        .toList();
    if (missing.isNotEmpty) vectors.addAll(await d.graphEmbeddings(missing));
    final edges = await graphEdgesInBackground(vectors);
    final plan = await planLabelPropagationInBackground(
      name,
      [
        for (final row in all)
          LabelDocument(
            row['id'] as String,
            row['content'] as String,
            title: row['title'] as String?,
          ),
      ],
      d.store.documentLabels,
      vectors,
      edges,
    );
    if (!mounted) return;
    for (final write in plan.writes) {
      await putDocumentLabel(write);
    }
    await d.command('labels.cluster', {'name': name});
    await d.command('graph.invalidate');
    if (mounted)
      update(() {
        graphOrganizationRevision++;
        graphLayoutKey = '';
      });
    if (mounted && graphView) {
      await WidgetsBinding.instance.endOfFrame;
      while (mounted && graphView && graphOrganizing)
        await Future<void>.delayed(const Duration(milliseconds: 16));
      if (mounted && graphLayoutError.isNotEmpty)
        throw StateError(graphLayoutError);
    }
  }

  Future<void> deleteOrganizationLabel(String name) async {
    final confirmed = await showInputDialog<bool>(
      builder: (context) => AlertDialog(
        title: const Text('Delete Label'),
        content: Text(
          'Are you sure you want to remove the label "$name" across all documents?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await d.command('labels.delete', {'name': name});
      await d.command('graph.acknowledge');
      if (mounted)
        update(() {
          if (labelFilter == name) labelFilter = '';
        });
    }
  }

  Future<void> editLabels(Map<String, Object?>? s) async {
    final input = TextEditingController(
      text: s == null ? '' : sourceLabels(s).join(', '),
    );
    final ok = await showInputDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text(
          s == null ? 'Add label to sources' : 'Labels · ${s['title']}',
        ),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(hintText: 'Comma-separated labels'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save labels'),
          ),
        ],
      ),
    );
    final values = input.text
        .split(',')
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toSet()
        .toList();
    input.dispose();
    if (ok != true || !mounted) return;
    for (final row in s == null ? filteredSources() : [s]) {
      await d.command('labels.set', {
        'id': row['id'],
        'labels': s == null
            ? {...sourceLabels(row), ...values}.toList()
            : values,
      });
    }
    if (mounted) update(() {});
  }

  Map<String, String> driveSourceMimes() => {
    for (final row in d.store.rows('SELECT source_id,mime FROM google_sources'))
      row['source_id'] as String: row['mime'] as String,
  };

  SourceType typeOf(
    Map<String, Object?> source,
    Map<String, String> originals,
  ) => sourceType(source, originalMime: originals[source['id']]);

  String typeName(SourceType type) => switch (type) {
    SourceType.pdf => 'PDF',
    SourceType.document => 'Documents',
    SourceType.spreadsheet => 'Spreadsheets',
    SourceType.presentation => 'Presentations',
    SourceType.url => 'Web pages',
    SourceType.meeting => 'Transcripts',
    SourceType.calendar => 'Calendar',
    SourceType.text => 'Text',
    SourceType.other => 'Other',
  };
  IconData typeIcon(SourceType type) => switch (type) {
    SourceType.pdf => Icons.picture_as_pdf_outlined,
    SourceType.document => Icons.description_outlined,
    SourceType.spreadsheet => Icons.table_chart_outlined,
    SourceType.presentation => Icons.slideshow,
    SourceType.url => Icons.language,
    SourceType.meeting => Icons.edit_note,
    SourceType.calendar => Icons.calendar_today,
    SourceType.text => Icons.notes,
    SourceType.other => Icons.insert_drive_file_outlined,
  };

  List<Map<String, Object?>> filteredSources([
    List<Map<String, Object?>>? collection,
    Map<String, String>? originalMimes,
  ]) {
    final originals = originalMimes ?? driveSourceMimes();
    Set<String>? searchMatches;
    if (sourceQuery.isNotEmpty) {
      final key = jsonEncode([sourceQuery, d.store.dataRevision]);
      if (key != sourceSearchCacheKey) {
        final searchable =
            collection != null &&
                collection.every((s) => s.containsKey('content'))
            ? collection
            : d.store.sources;
        final query = sourceQuery.toLowerCase();
        sourceSearchMatches = {
          for (final source in searchable)
            if ('${source['title']} ${source['content']}'
                .toLowerCase()
                .contains(query))
              source['id'] as String,
        };
        sourceSearchCacheKey = key;
      }
      searchMatches = sourceSearchMatches;
    }
    final rows = (collection ?? d.store.sourceSummaries)
        .where(
          (s) =>
              (searchMatches == null || searchMatches.contains(s['id'])) &&
              (labelFilter.isEmpty || sourceLabels(s).contains(labelFilter)) &&
              (typeFilter == null || typeOf(s, originals) == typeFilter),
        )
        .toList();
    rows.sort(
      (a, b) =>
          (ascending ? 1 : -1) *
          (a['title'] as String).toLowerCase().compareTo(
            (b['title'] as String).toLowerCase(),
          ),
    );
    return rows;
  }

  Color sourceColor(SourceType type) => switch (type) {
    SourceType.pdf => const Color(0xffe67b7b),
    SourceType.spreadsheet => const Color(0xff3da963),
    SourceType.presentation => const Color(0xffde9e35),
    SourceType.other || SourceType.text => const Color(0xff666666),
    _ => const Color(0xff4083df),
  };

  IconData sourceIcon(Map<String, Object?> source, {String? originalMime}) =>
      typeIcon(sourceType(source, originalMime: originalMime));
  String timeLabel(Object? stamp) {
    if (stamp == null || stamp == 0) return 'Unknown';
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(stamp as int),
    );
    return elapsed.inMinutes < 1
        ? 'Just now'
        : elapsed.inHours < 1
        ? '${elapsed.inMinutes} ${elapsed.inMinutes == 1 ? 'min' : 'mins'} ago'
        : elapsed.inDays < 1
        ? '${elapsed.inHours} ${elapsed.inHours == 1 ? 'hour' : 'hours'} ago'
        : '${elapsed.inDays} ${elapsed.inDays == 1 ? 'day' : 'days'} ago';
  }

  Widget sources() {
    final all = graphView ? d.store.sources : d.store.sourceSummaries;
    final originals = driveSourceMimes();
    final rows = filteredSources(all, originals);
    final labelRecords = d.store.documentLabels;
    final clusters = d.store
        .rows('SELECT * FROM document_clusters')
        .map(GraphCluster.fromRow)
        .toList();
    final fallbackLabelColor = Theme.of(context).colorScheme.primary;
    final documentLabelRecords = <String, List<DocumentLabel>>{};
    final documentLabelColors = <String, List<Color>>{};
    final labelColorsByName = <String, Color>{};
    for (final record in labelRecords) {
      documentLabelRecords.putIfAbsent(record.documentId, () => []).add(record);
      final color = graphLabelColor(record.colorHex, fallbackLabelColor);
      documentLabelColors.putIfAbsent(record.documentId, () => []).add(color);
      labelColorsByName.putIfAbsent(record.name, () => color);
    }
    // Prepare the database/model-dependent scene only on workspace updates.
    // Vsync frames below reuse this snapshot and only project the points.
    graphSceneClusters = clusters;
    graphSceneLabels = documentLabelRecords;
    if (graphView) scheduleGraphLayout(all);
    final graphRows = graphView
        ? graphSceneSources(all, graphSceneVectors)
        : <Map<String, Object?>>[];
    final graphIds = graphRows.map((source) => source['id'] as String).toList()
      ..sort();
    final graphFallback = uniformGraphLayout(graphIds);
    graphWorldPoints = {
      for (final id in graphIds)
        id: graphWorldPoint(
          graphPoints[id] ?? graphFallback[id]!,
          uniform: !graphPoints.containsKey(id),
        ),
    };
    final counts = <SourceType, int>{};
    for (final source in all) {
      final type = typeOf(source, originals);
      counts[type] = (counts[type] ?? 0) + 1;
    }
    final labels = {
      ...all.expand(sourceLabels),
      ...d.store
          .rows('SELECT label FROM document_clusters')
          .map((row) => row['label'] as String),
      if (labelFilter.isNotEmpty) labelFilter,
    }.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(180, MediaQuery.sizeOf(context).height * .48),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading(
                  'Knowledge Sources',
                  actions: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          tooltip: d.sourcesPaused
                              ? 'Resume source imports and indexing'
                              : 'Pause source imports and indexing',
                          onPressed: () => update(() {
                            if (d.sourcesPaused) {
                              d.resumeSources();
                            } else {
                              d.pauseSources();
                            }
                          }),
                          icon: Icon(
                            d.sourcesPaused ? Icons.play_arrow : Icons.pause,
                          ),
                        ),
                        if (d.sourcesPaused)
                          const Text('Paused', style: TextStyle(fontSize: 12)),
                        if (googleAuth.connected)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.cloud_outlined,
                                size: 18,
                                color: _ink,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                googleSyncStatus(),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff83898e),
                                ),
                              ),
                            ],
                          ),
                        pill(
                          'Import again',
                          busy ? null : () => run(reimport),
                          icon: Icons.refresh,
                        ),
                      ],
                    ),
                  ],
                ),
                Wrap(
                  spacing: 10,
                  children: [
                    pill(
                      'File list',
                      () => update(() => graphView = false),
                      selected: !graphView,
                    ),
                    pill(
                      'Graph view',
                      () => update(() => graphView = true),
                      selected: graphView,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: searchBox(
                        'Search knowledge sources…',
                        (value) => sourceQuery = value,
                        controller: sourceSearchController,
                      ),
                    ),
                    const SizedBox(width: 16),
                    PopupMenuButton<String>(
                      enabled: !busy,
                      tooltip: 'Add source',
                      position: PopupMenuPosition.under,
                      onSelected: (choice) => run(() async {
                        switch (choice) {
                          case 'file':
                            await import();
                          case 'folder':
                            await importFolder();
                          case 'find-files':
                            await findLocalFiles();
                          case 'url':
                            await importUrl();
                          case 'drive-file':
                            await chooseDrive();
                          case 'drive-folder':
                            await chooseDrive(folder: true);
                          case 'drive-year':
                            if (!googleAuth.connected) await connectGoogle();
                            if (mounted && googleAuth.connected) {
                              await google.importLastYear();
                            }
                        }
                      }),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'file',
                          child: DesktopImportMenuTile(
                            icon: Icons.attach_file,
                            label: 'Add a file',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'folder',
                          child: DesktopImportMenuTile(
                            icon: Icons.folder,
                            label: 'Import folder',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'find-files',
                          child: DesktopImportMenuTile(
                            icon: Icons.search,
                            label: Platform.isMacOS
                                ? 'Find files on this Mac'
                                : 'Find files on this computer',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'drive-file',
                          enabled: !busy,
                          child: DesktopImportMenuTile(
                            icon: Icons.cloud_outlined,
                            label: 'Add files from Drive',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'drive-folder',
                          enabled: !busy,
                          child: DesktopImportMenuTile(
                            icon: Icons.folder_shared_outlined,
                            label: 'Add an entire Drive folder',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'drive-year',
                          enabled: !busy,
                          child: DesktopImportMenuTile(
                            icon: Icons.history,
                            label: 'Import last 1 year from Drive',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'url',
                          child: DesktopImportMenuTile(
                            icon: Icons.link,
                            label: 'Add from URL',
                          ),
                        ),
                      ],
                      child: Chip(
                        shape: const StadiumBorder(side: BorderSide.none),
                        backgroundColor: _blue,
                        padding: const EdgeInsets.all(16),
                        avatar: const Icon(Icons.add),
                        label: const Text(
                          'Add source',
                          style: DesktopVisuals.control,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      side: const BorderSide(color: Color(0xffaeb5bc)),
                      shape: const _DashedStadiumBorder(
                        side: BorderSide(color: Color(0xffaeb5bc)),
                      ),
                      color: WidgetStatePropertyAll(
                        Theme.of(context).scaffoldBackgroundColor,
                      ),
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text(
                        'Add label',
                        style: DesktopVisuals.control,
                      ),
                      onPressed: busy ? null : createOrganizationLabel,
                    ),
                    ...labels.map(
                      (label) => FilterChip(
                        label: Text(label),
                        onDeleted: busy
                            ? null
                            : () => deleteOrganizationLabel(label),
                        selected: labelFilter == label,
                        onSelected: (_) => update(
                          () => labelFilter = labelFilter == label ? '' : label,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (_, constraints) {
                    final filters = <Widget>[
                      Text(
                        '${all.length} sources identified, ${all.where((s) => s['state'] == 'indexed').length} indexed',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xff83898e),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      FilterChip(
                        showCheckmark: false,
                        shape: const StadiumBorder(side: BorderSide.none),
                        label: Text(
                          'All ${all.length}',
                          style: DesktopVisuals.control,
                        ),
                        selected: typeFilter == null,
                        onSelected: (_) => update(() => typeFilter = null),
                      ),
                      for (final type in SourceType.values.where(
                        (type) =>
                            counts.containsKey(type) || type == typeFilter,
                      ))
                        Tooltip(
                          message: '${typeName(type)}: ${counts[type] ?? 0}',
                          child: FilterChip(
                            showCheckmark: false,
                            shape: const StadiumBorder(side: BorderSide.none),
                            backgroundColor: Colors.white,
                            selectedColor: _blue,
                            visualDensity: VisualDensity.compact,
                            avatar: Icon(
                              typeIcon(type),
                              size: 16,
                              color: sourceColor(type),
                            ),
                            label: Text(
                              '${counts[type] ?? 0}',
                              style: DesktopVisuals.control,
                            ),
                            selected: typeFilter == type,
                            onSelected: (_) => update(
                              () =>
                                  typeFilter = typeFilter == type ? null : type,
                            ),
                          ),
                        ),
                    ];
                    final controls = <Widget>[
                      if (typeFilter != null ||
                          sourceQuery.isNotEmpty ||
                          labelFilter.isNotEmpty)
                        Text('${rows.length} of ${all.length} shown'),
                      if (typeFilter != null ||
                          sourceQuery.isNotEmpty ||
                          labelFilter.isNotEmpty)
                        TextButton(
                          onPressed: () => update(() {
                            sourceQuery = '';
                            sourceSearchController.clear();
                            labelFilter = '';
                            typeFilter = null;
                          }),
                          child: const Text('Clear filters'),
                        ),
                      pill(
                        ascending ? 'A → Z' : 'Z → A',
                        () => update(() => ascending = !ascending),
                        icon: Icons.sort,
                      ),
                      if (!graphView)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: ColoredBox(
                            color: Colors.white,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final grid in [false, true])
                                  SizedBox(
                                    width: 56,
                                    height: 32,
                                    child: IconButton(
                                      tooltip: grid ? 'Grid view' : 'List view',
                                      onPressed: () =>
                                          update(() => gridView = grid),
                                      style: IconButton.styleFrom(
                                        backgroundColor: gridView == grid
                                            ? _blue
                                            : Colors.white,
                                        foregroundColor: _ink,
                                        shape: const RoundedRectangleBorder(),
                                        padding: EdgeInsets.zero,
                                      ),
                                      icon: Icon(
                                        grid
                                            ? Icons.grid_view
                                            : Icons.view_list,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ];
                    final badges = Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: filters,
                    );
                    final actions = Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: controls,
                    );
                    if (constraints.maxWidth < 760)
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [badges, const SizedBox(height: 8), actions],
                      );
                    return Row(
                      children: [
                        Expanded(child: badges),
                        const SizedBox(width: 16),
                        actions,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: DesktopVisuals.panelRadius,
            child: ColoredBox(
              color: const Color(0xfff8faff),
              child: (graphView ? all : rows).isEmpty
                  ? Center(
                      child: Text(
                        all.isEmpty
                            ? 'Add a source to build your knowledge.'
                            : 'No sources match the current filters.',
                      ),
                    )
                  : graphView
                  ? AnimatedBuilder(
                      animation: Listenable.merge([
                        graphMotionFrames,
                        graphTransform,
                      ]),
                      builder: (_, __) => sourceGraph(
                        graphRows,
                        graphWorldPoints,
                        rows,
                        documentLabelColors,
                        labelColorsByName,
                        documentLabelRecords,
                        clusters,
                      ),
                    )
                  : gridView
                  ? GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 360,
                            mainAxisExtent: 180,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: rows.length,
                      itemBuilder: (_, i) => Card(
                        child: sourceTile(
                          rows[i],
                          originalMime: originals[rows[i]['id']],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length + 2,
                      itemBuilder: (_, index) {
                        if (index == 0)
                          return Padding(
                            padding: DesktopVisuals.sourceHeaderPadding,
                            child: sourceCells(null),
                          );
                        if (index == 1) return const Divider(height: 1);
                        final source = rows[index - 2];
                        return KeyedSubtree(
                          key: ValueKey(source['id']),
                          child: sourceTile(
                            source,
                            originalMime: originals[source['id']],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }

  String sourceTimeLabel(Object? stamp) =>
      stamp == null || stamp == 0 ? '--' : timeLabel(stamp);

  Widget sourceCells(Map<String, Object?>? source, {String? originalMime}) {
    final header = source == null;
    final wide = MediaQuery.sizeOf(context).width > 950;
    final textStyle = TextStyle(
      fontSize: 14,
      color: header ? const Color(0xff999999) : null,
      fontWeight: header ? FontWeight.w500 : FontWeight.w400,
    );
    Widget cell(String text, {Color? color}) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: color == null ? textStyle : textStyle.copyWith(color: color),
    );
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: header
              ? null
              : Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    sourceIcon(source, originalMime: originalMime),
                    size: 20,
                    color: sourceColor(
                      sourceType(source, originalMime: originalMime),
                    ),
                  ),
                ),
        ),
        Expanded(
          flex: 2,
          child: header
              ? InkWell(
                  onTap: () => update(() => ascending = !ascending),
                  child: cell(ascending ? 'Name ↑' : 'Name ↓'),
                )
              : Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: cell(source['title'] as String),
                ),
        ),
        if (wide) ...[
          Expanded(
            child: cell(
              header ? 'Imported' : sourceTimeLabel(source['imported']),
              color: const Color(0xff999999),
            ),
          ),
          Expanded(
            child: cell(
              header ? 'Last changed' : sourceTimeLabel(source['changed']),
              color: const Color(0xff999999),
            ),
          ),
        ],
        Expanded(
          child: header
              ? cell('Labels')
              : Row(
                  children: [
                    Expanded(child: cell(sourceLabels(source).join(', '))),
                    IconButton(
                      tooltip: 'Edit labels',
                      onPressed: busy ? null : () => editLabels(source),
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.label_outline, size: 16),
                    ),
                  ],
                ),
        ),
        SizedBox(
          width: 72,
          child: header
              ? Center(child: cell('Actions'))
              : Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: IconButton(
                        tooltip: 'Index / retry',
                        onPressed: busy
                            ? null
                            : () => run(() => d.index(source['id'] as String)),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: IconButton(
                        tooltip: 'Delete source',
                        onPressed: busy
                            ? null
                            : () => run(() => d.delete(source['id'] as String)),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget sourceTile(Map<String, Object?> source, {String? originalMime}) {
    if (gridView) return sourceCardTile(source, originalMime: originalMime);
    final showState = source['state'] != 'indexed' || source['error'] != '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => this.source(source),
        child: Padding(
          padding: DesktopVisuals.sourceRowPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sourceCells(source, originalMime: originalMime),
              if (showState)
                Padding(
                  padding: const EdgeInsets.only(left: 40),
                  child: Text(
                    '${source['state']}${source['error'] == '' ? '' : ' · ${source['error']}'}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget sourceCardTile(
    Map<String, Object?> s, {
    String? originalMime,
  }) => ListTile(
    leading: Icon(
      sourceIcon(s, originalMime: originalMime),
      color: sourceColor(sourceType(s, originalMime: originalMime)),
    ),
    title: Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            s['title'] as String,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
    subtitle: Text(
      '${s['state']}${sourceLabels(s).isEmpty ? '' : ' · ${sourceLabels(s).join(', ')}'}${s['error'] == '' ? '' : ' · ${s['error']}'}',
    ),
    onTap: () => source(s),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Edit labels',
          onPressed: busy ? null : () => editLabels(s),
          icon: const Icon(Icons.label_outline, size: 18),
        ),
        IconButton(
          tooltip: 'Index / retry',
          onPressed: busy ? null : () => run(() => d.index(s['id'] as String)),
          icon: const Icon(Icons.refresh, size: 20),
        ),
        IconButton(
          tooltip: 'Delete source',
          onPressed: busy ? null : () => run(() => d.delete(s['id'] as String)),
          icon: const Icon(Icons.delete_outline, size: 20),
        ),
      ],
    ),
  );

  void scheduleGraphLayout(List<Map<String, Object?>> all) {
    final selected = graphSelectedDocument;
    if (selected != null && !all.any((row) => row['id'] == selected)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            graphSelectedDocument == selected &&
            !d.store.sources.any((row) => row['id'] == selected)) {
          selectGraphDocument(null);
        }
      });
    }
    final labelSet = d.store.graphLabelSet();
    final labelRecords = d.store.documentLabels;
    final forceLabels = <String, List<String>>{};
    final forceNames = <String>{};
    for (final source in all) {
      final id = source['id'] as String;
      forceLabels[id] = labelRecords
          .where((label) => label.documentId == id)
          .map((label) => label.name)
          .toList();
      forceNames.addAll(forceLabels[id]!);
    }
    forceNames.addAll(
      labelRecords
          .where(
            (label) =>
                label.source == 'user_defined' ||
                label.source == 'user_attached',
          )
          .map((label) => label.name),
    );
    final snapshot = d.helper.snapshot;
    if (snapshot?.pipeline != 'ready') {
      var sources = all
          .where((s) => (s['title'] as String? ?? '').trim().isNotEmpty)
          .toList();
      final registered = d.store.rows(
        "SELECT digest FROM models WHERE kind='embedding'",
      );
      final key = jsonEncode([
        'cached',
        snapshot?.pipeline,
        registered.firstOrNull?['digest'],
        graphDocumentSet(sources),
        labelSet,
        graphOrganizationRevision,
      ]);
      if (key == graphLayoutKey) return;
      graphLayoutKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || graphLayoutKey != key) return;
        var saved = d.store.loadRegisteredGraphLayout(
          sources,
          labelSet: labelSet,
        );
        sources = graphSceneSources(sources, saved.vectors);
        saved = d.store.loadRegisteredGraphLayout(sources, labelSet: labelSet);
        update(() {
          graphPoints = saved.points;
          graphEdges = [];
          graphSceneVectors = saved.vectors;
          graphSelectionRevision++;
          graphSelectionEdges = [];
          graphOrganizing = true;
          graphLayoutError = '';
        });
        try {
          final scene = saved.complete
              ? null
              : await organizeForceGraphSceneInBackground(
                  saved.vectors,
                  forceLabels,
                  forceNames.toList(),
                  saved.points,
                  documents: sources.map((s) => s['id'] as String).toList(),
                );
          final edges =
              scene?.edges ?? await graphEdgesInBackground(saved.vectors);
          if (!mounted || graphLayoutKey != key) return;
          if (scene != null &&
              saved.identity != null &&
              scene.points.length == sources.length &&
              sources.length >= 2) {
            final published = await saveGraphLayout(
              saved.identity!,
              sources,
              saved.vectors,
              scene.points,
              labelSet: labelSet,
              clusters: scene.clusters,
            );
            if (!published) {
              update(() {
                graphLayoutKey = '';
                graphOrganizing = false;
              });
              return;
            }
          }
          update(() {
            if (scene != null) graphPoints = scene.points;
            graphEdges = edges;
            graphOrganizing = false;
          });
          refreshGraphSelection();
          scheduleGraphFit();
        } catch (e) {
          if (!mounted || graphLayoutKey != key) return;
          update(() {
            graphOrganizing = false;
            graphLayoutError = e.toString();
          });
        }
      });
      return;
    }
    if (d.sourcesPaused) {
      graphLayoutKey = '';
      graphOrganizing = false;
      return;
    }
    var sources = all
        .where((s) => (s['title'] as String? ?? '').trim().isNotEmpty)
        .toList();
    final identity = snapshot!.model.writeToJson();
    final instance = snapshot.instanceId;
    final generation = snapshot.activeGeneration.toString();
    final persistentIdentity = jsonEncode([
      graphLayoutAlgorithmVersion,
      snapshot.model.modelDigest,
      snapshot.model.tokenizerDigest,
      snapshot.model.preprocessing,
      snapshot.model.backend,
      snapshot.model.dimensions,
    ]);
    final key = jsonEncode([
      identity,
      instance,
      generation,
      sources.map((s) => [s['id'], s['revision']]).toList(),
      labelSet,
      graphOrganizationRevision,
    ]);
    if (key == graphLayoutKey) return;
    graphLayoutKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || graphLayoutKey != key) return;
      final saved = d.store.loadGraphLayout(
        persistentIdentity,
        sources,
        snapshot.model.dimensions,
        labelSet: labelSet,
      );
      for (final source in sources) {
        final vector = saved.vectors[source['id']];
        if (vector != null) {
          graphVectorCache[jsonEncode([
                identity,
                source['id'],
                source['revision'],
              ])] =
              vector;
        }
      }
      update(() {
        graphPoints = saved.points;
        graphEdges = [];
        graphSceneVectors = saved.vectors;
        graphSelectionRevision++;
        graphSelectionEdges = [];
        graphOrganizing = true;
        graphLayoutError = '';
      });
      try {
        if (saved.complete) {
          final edges = await graphEdgesInBackground(saved.vectors);
          if (!mounted || graphLayoutKey != key) return;
          final current = d.helper.snapshot;
          if (d.sourcesPaused ||
              current?.pipeline != 'ready' ||
              current!.model.writeToJson() != identity ||
              current.instanceId != instance ||
              current.activeGeneration.toString() != generation)
            return;
          update(() {
            graphEdges = edges;
            graphOrganizing = false;
          });
          refreshGraphSelection();
          scheduleGraphFit();
          return;
        }
        final missing = sources
            .where(
              (s) =>
                  s['state'] == 'indexed' &&
                  !graphVectorCache.containsKey(
                    jsonEncode([identity, s['id'], s['revision']]),
                  ),
            )
            .toList();
        final fresh = await d.graphEmbeddings(missing);
        if (!mounted || graphLayoutKey != key) return;
        for (final source in missing) {
          final vector = fresh[source['id']];
          if (vector != null)
            graphVectorCache[jsonEncode([
                  identity,
                  source['id'],
                  source['revision'],
                ])] =
                vector;
        }
        final vectors = <String, List<double>>{};
        final retained = <String>{};
        for (final source in sources) {
          final cacheKey = jsonEncode([
            identity,
            source['id'],
            source['revision'],
          ]);
          retained.add(cacheKey);
          final vector = graphVectorCache[cacheKey];
          if (vector != null) vectors[source['id'] as String] = vector;
        }
        graphVectorCache.removeWhere((key, _) => !retained.contains(key));
        sources = graphSceneSources(sources, vectors);
        final scene = await organizeForceGraphSceneInBackground(
          vectors,
          forceLabels,
          forceNames.toList(),
          saved.points,
          documents: sources.map((s) => s['id'] as String).toList(),
        );
        final layout = scene.points;
        if (!mounted || graphLayoutKey != key) return;
        final current = d.helper.snapshot;
        if (d.sourcesPaused ||
            current?.pipeline != 'ready' ||
            current!.model.writeToJson() != identity ||
            current.instanceId != instance ||
            current.activeGeneration.toString() != generation)
          return;
        if (layout.length == sources.length && sources.length >= 2) {
          final published = await saveGraphLayout(
            persistentIdentity,
            sources,
            vectors,
            layout,
            labelSet: labelSet,
            clusters: scene.clusters,
          );
          if (!published) {
            update(() {
              graphLayoutKey = '';
              graphOrganizing = false;
            });
            return;
          }
        }
        update(() {
          graphPoints = layout;
          graphEdges = scene.edges;
          graphSceneVectors = vectors;
          graphOrganizing = false;
        });
        refreshGraphSelection();
        scheduleGraphFit();
      } catch (e) {
        if (!mounted || graphLayoutKey != key) return;
        update(() {
          graphPoints = {};
          graphEdges = [];
          graphSceneVectors = {};
          graphSelectionRevision++;
          graphSelectionEdges = [];
          graphOrganizing = false;
          graphLayoutError = e.toString();
        });
      }
    });
  }

  void scheduleGraphFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && tab == 0 && graphView) fitGraph();
    });
  }

  void fitGraph() {
    // The Mac MediaQuery provider scope remains unresolved. Fit the measured
    // Linux graph panel so window headers cannot put sources below its bounds.
    final viewport = graphViewportSize ?? MediaQuery.sizeOf(context);
    // Use the current projection and include node extent, including collinear
    // layouts. The recovered Mac degenerate fallback at scale 1 can clip nodes
    // in Linux's smaller responsive panels.
    final projected = graphWorldPoints.values
        .map((point) {
          final rotated = rotateGraphPoint(
            point,
            yaw: graphYaw,
            pitch: graphPitch,
          );
          final perspective = graphPaintPerspective(rotated.z);
          final radius = 40 * perspective;
          final x = rotated.x * perspective;
          final y = rotated.y * perspective;
          return [
            GraphPoint(x - radius, y - radius, 0),
            GraphPoint(x + radius, y + radius, 0),
          ];
        })
        .expand((points) => points);
    var fit = fitGraphCamera(projected, viewport.width, viewport.height);
    // Captions scale inversely with zoom. Recompute their scene bounds at the
    // proposed zoom until the fit settles; circle/wire bounds use the same
    // projection as the painter. Include every cluster regardless of filter.
    for (var pass = 0; pass < 8; pass++) {
      final painter = GraphClusterPainter(
        clusters: graphSceneClusters,
        points: graphWorldPoints,
        labels: graphSceneLabels,
        yaw: graphYaw,
        pitch: graphPitch,
        zoom: fit.scale,
        fallback: Theme.of(context).colorScheme.primary,
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      );
      final bounds = painter.paintedBounds().expand(
        (rect) => [
          GraphPoint(
            rect.left - graphSceneOrigin,
            rect.top - graphSceneOrigin,
            0,
          ),
          GraphPoint(
            rect.right - graphSceneOrigin,
            rect.bottom - graphSceneOrigin,
            0,
          ),
        ],
      );
      final next = fitGraphCamera(
        [...projected, ...bounds],
        viewport.width,
        viewport.height,
      );
      final settled = (next.scale - fit.scale).abs() < 1e-6;
      fit = next;
      if (settled) break;
    }
    final target = Matrix4.identity()
      ..translateByDouble(fit.x, fit.y, 0, 1)
      ..scaleByDouble(fit.scale, fit.scale, fit.scale, 1);
    animateGraphCamera(target);
  }

  void animateGraphCamera(Matrix4 target, {bool zoomButton = false}) {
    graphCameraController.stop();
    graphCameraTween = Matrix4Tween(
      begin: graphTransform.value.clone(),
      end: target,
    );
    graphCameraCurve = zoomButton
        ? const Cubic(.215, .61, .355, 1)
        : const Cubic(.645, .045, .355, 1);
    // Original _animateCameraTo / _zoomByFactor: 350ms / 250ms.
    graphCameraController.duration = Duration(
      milliseconds: zoomButton ? 250 : 350,
    );
    graphCameraController.forward(from: 0);
  }

  void zoomGraph(double factor) {
    final scale = graphTransform.value.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(.015, 5.0);
    if ((next - scale).abs() < .001) return;
    final size = graphViewportSize ?? MediaQuery.sizeOf(context);
    final center = Offset(size.width / 2, size.height / 2);
    final scene = graphTransform.toScene(center);
    final target = Matrix4.identity()
      ..translateByDouble(
        center.dx - scene.dx * next,
        center.dy - scene.dy * next,
        0,
        1,
      )
      ..scaleByDouble(next, next, next, 1);
    animateGraphCamera(target, zoomButton: true);
  }

  void startGraphPointer(PointerDownEvent event) {
    if (graphMousePointer != null) return;
    graphDragMoved = false;
    if (event.kind != PointerDeviceKind.mouse) return;
    final modifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (event.buttons != kPrimaryMouseButton &&
        event.buttons != kSecondaryMouseButton &&
        event.buttons != kMiddleMouseButton)
      return;
    update(() {
      graphMousePointer = event.pointer;
      graphPointerStart = graphPointerLast = event.localPosition;
      graphPointerRotates = event.buttons == kPrimaryMouseButton || modifier;
      graphDragMoved = false;
    });
  }

  void moveGraphPointer(PointerMoveEvent event) {
    if (graphMousePointer != event.pointer || graphPointerLast == null) return;
    final delta = event.localPosition - graphPointerLast!;
    update(() {
      graphPointerLast = event.localPosition;
      graphDragMoved =
          graphDragMoved ||
          (event.localPosition - graphPointerStart!).distance > kTouchSlop;
      if (graphPointerRotates) {
        // Direction and clamp structure are recovered. Sensitivity and pitch
        // limits remain Linux choices pending Mac numeric-pool recovery.
        graphManualPitch = true;
        graphYaw += delta.dx * .005;
        graphPitch = (graphPitch + delta.dy * .005).clamp(
          -math.pi / 2,
          math.pi / 2,
        );
      } else {
        final matrix = graphTransform.value.clone();
        matrix.storage[12] += delta.dx;
        matrix.storage[13] += delta.dy;
        graphTransform.value = matrix;
      }
    });
  }

  void endGraphPointer(PointerEvent event) {
    if (graphMousePointer != event.pointer) return;
    update(() {
      graphMousePointer = null;
      graphPointerStart = graphPointerLast = null;
    });
  }

  void selectGraphDocument(String? document) {
    update(() {
      graphSelectedDocument = document;
      labelFilter = '';
    });
    refreshGraphSelection();
  }

  void refreshGraphSelection() {
    final document = graphSelectedDocument;
    final revision = ++graphSelectionRevision;
    final vectors = graphSceneVectors;
    final whole = graphEdges;
    update(() {
      graphSelectionEdges = document == null
          ? []
          : whole
                .where(
                  (edge) => edge.source == document || edge.target == document,
                )
                .toList();
      graphRelatedLoading = document != null;
      graphRelatedError = '';
    });
    if (document != null) {
      completeGraphSelection(document, revision, vectors, whole);
    }
  }

  Future<void> completeGraphSelection(
    String document,
    int revision,
    Map<String, List<double>> vectors,
    List<GraphEdge> whole,
  ) async {
    try {
      final edges = await selectedGraphEdgesInBackground(
        document,
        vectors,
        whole,
      );
      if (!mounted ||
          revision != graphSelectionRevision ||
          graphSelectedDocument != document ||
          !identical(vectors, graphSceneVectors) ||
          !identical(whole, graphEdges))
        return;
      update(() {
        graphSelectionEdges = edges;
        graphRelatedLoading = false;
      });
    } catch (e) {
      if (!mounted || revision != graphSelectionRevision) return;
      update(() {
        graphRelatedLoading = false;
        graphRelatedError = e.toString();
      });
    }
  }

  Widget graphInspector(
    Map<String, Object?> selected,
    List<Map<String, Object?>> rows,
    List<GraphEdge> edges,
    List<DocumentLabel> labels,
  ) {
    final id = selected['id'] as String;
    final sourceUri = selected['source_uri'] as String? ?? '';
    final byId = {for (final row in rows) row['id']: row};
    final related =
        edges
            .map(
              (edge) => (
                row: byId[edge.source == id ? edge.target : edge.source],
                similarity: edge.similarity,
              ),
            )
            .where((item) => item.row != null)
            .toList()
          ..sort((a, b) => b.similarity.compareTo(a.similarity));
    return Material(
      key: const ValueKey('graph-inspector'),
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    selected['title'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (sourceUri.isNotEmpty)
                  IconButton(
                    key: const ValueKey('graph-inspector-link'),
                    tooltip: sourceUri,
                    onPressed: () async {
                      final uri = Uri.tryParse(sourceUri);
                      if (uri == null || !allowedSourceUri(uri)) return;
                      try {
                        await widget.sourceLinkOpener(uri);
                      } catch (_) {
                        if (mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Could not open the source link.'),
                            ),
                          );
                      }
                    },
                    icon: const Icon(Icons.link, size: 18),
                  ),
                IconButton(
                  key: const ValueKey('graph-inspector-close'),
                  tooltip: 'Close inspector',
                  onPressed: () => selectGraphDocument(null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            GraphLabelControls(
              labels: labels,
              controller: graphLabelInput,
              enabled: !busy,
              onAdd: (value) => run(() => addSelectedGraphLabel(id, value)),
              onRemove: (name) => removeSelectedGraphLabel(id, name),
            ),
            const SizedBox(height: 8),
            const Text(
              'Related documents:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (graphRelatedLoading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Finding Related Docs..',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else if (graphRelatedError.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Related documents unavailable.',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else if (related.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No direct high-similarity connections found.',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else
              for (final item in related)
                ListTile(
                  key: ValueKey('graph-related-${item.row!['id']}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    item.row!['title'] as String,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(
                    '${(item.similarity * 100).round()}% Match',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => selectGraphDocument(item.row!['id'] as String),
                ),
          ],
        ),
      ),
    );
  }

  Color fallbackGraphLabelColor() => Theme.of(context).colorScheme.primary;

  Widget sourceGraph(
    List<Map<String, Object?>> rows,
    Map<String, GraphPoint> worldPoints,
    List<Map<String, Object?>> matches,
    Map<String, List<Color>> documentLabelColors,
    Map<String, Color> labelColorsByName,
    Map<String, List<DocumentLabel>> documentLabelRecords,
    List<GraphCluster> clusters,
  ) => LayoutBuilder(
    builder: (_, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (graphViewportSize != size) {
        graphViewportSize = size;
        scheduleGraphFit();
      }
      final rotated = rows.map((row) {
        final id = row['id'] as String;
        return rotateGraphPoint(
          worldPoints[id] ?? const GraphPoint(0, 0, 0),
          yaw: graphYaw,
          pitch: graphPitch,
        );
      }).toList();
      final positions = rotated
          .map(
            (point) => Offset(
              graphSceneOrigin + point.x * graphPaintPerspective(point.z),
              graphSceneOrigin + point.y * graphPaintPerspective(point.z),
            ),
          )
          .toList();
      final paintOrder = List.generate(rows.length, (i) => i)
        ..sort((a, b) => rotated[b].z.compareTo(rotated[a].z));
      final zoom = graphTransform.value.getMaxScaleOnAxis();
      final selected = rows
          .where((row) => row['id'] == graphSelectedDocument)
          .firstOrNull;
      final selectedId = selected?['id'] as String?;
      final selectionEdges = selectedId == null
          ? <GraphEdge>[]
          : graphSelectionEdges;
      final connected = <String>{
        if (selectedId != null) selectedId,
        for (final edge in selectionEdges) ...[edge.source, edge.target],
      };
      final matchingIds = matches.map((row) => row['id']).toSet();
      final dimmed = <String>{
        for (final row in rows)
          if (labelFilter.isNotEmpty
              ? !sourceLabels(row).contains(labelFilter)
              : selectedId != null
              ? !connected.contains(row['id'])
              : !matchingIds.contains(row['id']))
            row['id'] as String,
      };
      final painters = [
        for (var i = 0; i < rows.length; i++)
          GraphNodePainter(
            depth: rotated[i].z,
            zoom: zoom,
            labelColors: documentLabelColors[rows[i]['id']] ?? const [],
            matchColor: labelFilter.isEmpty
                ? Colors.white
                : labelColorsByName[labelFilter] ?? fallbackGraphLabelColor(),
            title: rows[i]['title'] as String? ?? rows[i]['id'] as String,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
            textDirection: Directionality.of(context),
            selected: selectedId == rows[i]['id'],
            dimmed: dimmed.contains(rows[i]['id']),
            activeMatch:
                (sourceQuery.isNotEmpty || labelFilter.isNotEmpty) &&
                !dimmed.contains(rows[i]['id']),
          ),
      ];
      return Stack(
        children: [
          if (graphOrganizing || graphLayoutError.isNotEmpty)
            Positioned(
              right: 16,
              bottom: 16,
              child: Tooltip(
                message: graphLayoutError.isEmpty
                    ? 'Organizing sources'
                    : graphLayoutError,
                child: Text(
                  graphLayoutError.isEmpty
                      ? 'Organizing sources…'
                      : 'Graph layout unavailable',
                ),
              ),
            ),
          Listener(
            key: const ValueKey('source-graph-canvas'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: startGraphPointer,
            onPointerMove: moveGraphPointer,
            onPointerUp: endGraphPointer,
            onPointerCancel: endGraphPointer,
            child: GestureDetector(
              onTapDown: (details) {
                final scenePoint = graphTransform.toScene(
                  details.localPosition,
                );
                String? document;
                var depth = double.infinity;
                for (var i = 0; i < rows.length; i++) {
                  final raw = graphPerspective(rotated[i].z);
                  final center = Offset(
                    graphSceneOrigin + rotated[i].x * raw,
                    graphSceneOrigin + rotated[i].y * raw,
                  );
                  if ((scenePoint - center).distance <=
                          graphHitRadius(rotated[i].z, zoom) &&
                      rotated[i].z < depth) {
                    document = rows[i]['id'] as String;
                    depth = rotated[i].z;
                  }
                }
                selectGraphDocument(document);
              },
              child: InteractiveViewer(
                transformationController: graphTransform,
                panEnabled: graphMousePointer == null,
                minScale: .015,
                maxScale: 5,
                constrained: false,
                child: SizedBox(
                  width: graphSceneSize,
                  height: graphSceneSize,
                  child: Stack(
                    children: [
                      CustomPaint(
                        key: const ValueKey('source-graph-clusters'),
                        size: const Size(graphSceneSize, graphSceneSize),
                        painter: GraphClusterPainter(
                          clusters: clusters,
                          points: worldPoints,
                          labels: documentLabelRecords,
                          yaw: graphYaw,
                          pitch: graphPitch,
                          zoom: zoom,
                          filter: labelFilter,
                          fallback: Theme.of(context).colorScheme.primary,
                          fontFamily: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.fontFamily,
                        ),
                      ),
                      CustomPaint(
                        key: const ValueKey('source-graph-links'),
                        size: const Size(graphSceneSize, graphSceneSize),
                        painter: _SourceLinks(
                          rows,
                          positions,
                          selectionEdges,
                          rotated.map((p) => p.z).toList(),
                        ),
                      ),
                      for (final i in paintOrder)
                        Positioned(
                          left: positions[i].dx - painters[i].extent,
                          top: positions[i].dy - painters[i].extent,
                          child: Tooltip(
                            message: rows[i]['title'] as String,
                            child: Semantics(
                              button: true,
                              label: rows[i]['title'] as String,
                              onTap: () =>
                                  selectGraphDocument(rows[i]['id'] as String),
                              child: SizedBox(
                                key: ValueKey('graph-node-${rows[i]['id']}'),
                                width: painters[i].extent * 2,
                                height: painters[i].extent * 2,
                                child: CustomPaint(
                                  key: ValueKey(
                                    'graph-node-paint-${rows[i]['id']}',
                                  ),
                                  painter: painters[i],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (selected != null)
            Positioned(
              right: 20,
              bottom: 20,
              child: SizedBox(
                width: math.min(360, math.max(0, size.width - 40)),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(0, size.height - 40),
                  ),
                  child: graphInspector(
                    selected,
                    rows,
                    selectionEdges,
                    documentLabelRecords[selected['id']] ?? const [],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 18,
            bottom: 16,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Zoom out',
                    onPressed: () => zoomGraph(0.7692307692307692),
                    icon: const Icon(Icons.remove),
                  ),
                  ValueListenableBuilder<Matrix4>(
                    valueListenable: graphTransform,
                    builder: (_, value, _) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '${(value.getMaxScaleOnAxis() * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zoom in',
                    onPressed: () => zoomGraph(1.3),
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: 'Fit graph',
                    onPressed: fitGraph,
                    icon: const Icon(Icons.center_focus_strong),
                  ),
                  IconButton(
                    tooltip: MediaQuery.disableAnimationsOf(context)
                        ? 'Graph animation is disabled by reduced motion'
                        : graphAnimationPaused
                        ? 'Resume graph animation'
                        : 'Pause graph animation',
                    onPressed: MediaQuery.disableAnimationsOf(context)
                        ? null
                        : () => update(
                            () => graphAnimationPaused = !graphAnimationPaused,
                          ),
                    icon: Icon(
                      graphAnimationPaused ||
                              MediaQuery.disableAnimationsOf(context)
                          ? Icons.play_arrow
                          : Icons.pause,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Future<void> askQuestion({int? meetingScope}) => run(() async {
    if (meetingEnhancing)
      throw StateError('Wait for note enhancement to finish.');
    final prompt = questionFor(meetingScope).text;
    if (prompt.trim().isEmpty) throw StateError('Enter a question.');
    final scope = meetingScope == null ? 'desktop' : 'meeting:$meetingScope';
    update(() {
      answer = '';
      asking = true;
      askingScope = scope;
    });
    try {
      final ask = webSearchScopes.contains(scope)
          ? d.askWithWebInConversation
          : d.askInConversation;
      await for (final text in ask(prompt, scope, meetingId: meetingScope)) {
        if (mounted) update(() => answer = text);
      }
    } finally {
      if (mounted)
        update(() {
          asking = false;
          askingScope = null;
        });
    }
  });
  Widget chat({int? meetingScope, bool compact = false}) {
    final scope = meetingScope == null ? 'desktop' : 'meeting:$meetingScope';
    final searchWeb = webSearchScopes.contains(scope);
    final scopeAsking = asking && askingScope == scope;
    final question = questionFor(meetingScope);
    final history = d.store
        .rows(
          meetingScope == null
              ? "SELECT * FROM answers WHERE conversation='desktop' ORDER BY id"
              : 'SELECT answers.* FROM answers JOIN meeting_answers ON answer_id=answers.id WHERE meeting_id=? ORDER BY answers.id',
          meetingScope == null ? [] : [meetingScope],
        )
        .where((a) => !hiddenAnswers.contains(a['id']))
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: EdgeInsets.all(compact ? 20 : 28),
      child: Column(
        children: [
          Expanded(
            child: history.isEmpty && !scopeAsking
                ? const Center(
                    child: Text(
                      'Get answer from your personalized\nknowledge sources.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, color: Color(0xff87a8b7)),
                    ),
                  )
                : ListView(
                    key: ValueKey('chat-history:$scope'),
                    children: [
                      for (final a in history)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      a['question'] as String,
                                      style: const TextStyle(
                                        fontSize: 21,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Close answer',
                                    onPressed: () => update(
                                      () => hiddenAnswers.add(a['id'] as int),
                                    ),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                              GeneratedContent(
                                a['body'] as String,
                                fontSize: answerFontSize,
                              ),
                              if (a['status'] != 'completed')
                                Text('Status: ${a['status']}'),
                              Wrap(
                                children: (jsonDecode(a['citations'] as String) as List)
                                    .map(
                                      (c) => TextButton(
                                        onPressed: () => citation(c as Map),
                                        child: Text(
                                          c['kind'] == 'web'
                                              ? '[${c['citation']}] ${c['title'] == '' ? c['url'] : c['title']}'
                                              : '[${c['citation']}] source revision ${c['revision']}',
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                              const Divider(),
                            ],
                          ),
                        ),
                      if (scopeAsking)
                        GeneratedContent(
                          answer.isEmpty
                              ? searchWeb
                                    ? 'Preparing your answer…'
                                    : 'Searching your knowledge…'
                              : answer,
                          fontSize: answerFontSize,
                        ),
                    ],
                  ),
          ),
          Row(
            children: [
              IconButton(
                key: const ValueKey('chat-web-search'),
                tooltip: d.webSearchAvailable
                    ? searchWeb
                          ? 'Answer include web search result'
                          : 'Answer does not use web search'
                    : 'Web search is unavailable in this build',
                isSelected: searchWeb,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffeeeeee),
                  foregroundColor: const Color(0xff757575),
                  minimumSize: const Size(36, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: asking || (!d.webSearchAvailable && !searchWeb)
                    ? null
                    : () => update(() {
                        if (searchWeb) {
                          webSearchScopes.remove(scope);
                        } else {
                          webSearchScopes.add(scope);
                        }
                      }),
                icon: const Icon(Icons.travel_explore, size: 18),
                selectedIcon: const Icon(
                  Icons.travel_explore,
                  size: 18,
                  color: _ink,
                ),
              ),
              const Spacer(),
              if (history.isNotEmpty && !compact)
                TextButton(
                  onPressed: () => update(
                    () => answerFontSize = (answerFontSize - 1).clamp(12, 24),
                  ),
                  child: const Text('A−'),
                ),
              if (history.isNotEmpty && !compact)
                TextButton(
                  onPressed: () => update(
                    () => answerFontSize = (answerFontSize + 1).clamp(12, 24),
                  ),
                  child: const Text('A+'),
                ),
            ],
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: question,
            builder: (_, value, __) => TextField(
              key: ValueKey('chat-input:$scope'),
              controller: question,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              style: DesktopVisuals.field,
              onSubmitted: (_) {
                if (!busy &&
                    !meetingEnhancing &&
                    question.text.trim().isNotEmpty)
                  unawaited(askQuestion(meetingScope: meetingScope));
              },
              decoration: InputDecoration(
                hintText: compact
                    ? 'Ask Foresight AI...'
                    : 'Ask Foresight about your meetings',
                hintStyle: const TextStyle(color: Color(0xffaaaaaa)),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                  borderSide: const BorderSide(color: Color(0xffeeeeee)),
                ),
                suffixIcon: Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton.filled(
                    tooltip: scopeAsking ? 'Cancel answer' : 'Ask',
                    onPressed: scopeAsking
                        ? () => d.generator?.cancel()
                        : busy || meetingEnhancing || value.text.trim().isEmpty
                        ? null
                        : () => askQuestion(meetingScope: meetingScope),
                    style: IconButton.styleFrom(
                      backgroundColor: _blue,
                      disabledBackgroundColor: _blue,
                      foregroundColor: _ink,
                      disabledForegroundColor: _ink.withValues(alpha: .5),
                      minimumSize: const Size(40, 40),
                      maximumSize: const Size(40, 40),
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    icon: Icon(scopeAsking ? Icons.stop : Icons.arrow_upward),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String meetingClock(int milliseconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
  }

  int meetingStart(Map<String, Object?> meeting) =>
      (meeting['calendar_starts'] ?? meeting['created'] ?? 0) as int;

  int meetingEnd(Map<String, Object?> meeting) =>
      (meeting['calendar_ends'] ??
              meetingStart(meeting) +
                  ((meeting['duration_ms'] as int?) ??
                      const Duration(minutes: 30).inMilliseconds))
          as int;

  String meetingDay(int timestamp) {
    if (timestamp == 0) return 'Saved meetings';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day)
      return 'Today';
    return '${['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][date.weekday - 1]}, ${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][date.month - 1]} ${date.day}';
  }

  Widget meetingListHeading() => heading(
    'Meetings',
    actions: [
      if (!googleAuth.connected)
        OutlinedButton.icon(
          onPressed: busy ? null : () => run(connectGoogle),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: const Text('Connect Calendar'),
        ),
      if (googleAuth.connected)
        OutlinedButton.icon(
          onPressed: busy || googleSyncing
              ? null
              : () => run(google.syncCalendar),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(
            google.lastCompletedRefreshMs == 0
                ? 'Import Calendar'
                : 'Last imported: ${timeLabel(google.lastCompletedRefreshMs)}',
          ),
        ),
      OutlinedButton.icon(
        onPressed: busy ? null : () => run(exportMeetings),
        icon: const Icon(Icons.ios_share, size: 18),
        label: const Text('Export meeting notes'),
      ),
      pill(
        'New meeting',
        busy || recording != null
            ? null
            : () => run(() async {
                final created =
                    await d.command('meetings.create', {
                          'title': '[New Meeting]',
                        })
                        as Map;
                if (mounted) update(() => meetingId = created['id'] as int);
              }),
        icon: Icons.add,
      ),
    ],
  );

  Widget meetingList({bool showHeading = true}) {
    final rows = d.store
        .rows(
          'SELECT meetings.*,meeting_details.created,meeting_details.reminder,'
          'calendar_events.starts AS calendar_starts,calendar_events.ends AS calendar_ends,'
          'calendar_events.status AS calendar_status,'
          'COALESCE(saved.has_transcript,0) AS has_transcript,saved.duration_ms '
          'FROM meetings LEFT JOIN meeting_details ON meetings.id=meeting_details.meeting_id '
          'LEFT JOIN calendar_events ON meetings.id=calendar_events.meeting_id '
          'LEFT JOIN (SELECT meeting_id,1 AS has_transcript,MAX(end_ms) AS duration_ms '
          'FROM transcript WHERE final=1 GROUP BY meeting_id) AS saved ON saved.meeting_id=meetings.id '
          'ORDER BY COALESCE(calendar_events.starts,meeting_details.created),meetings.id',
        )
        .where(
          (m) => (m['title'] as String).toLowerCase().contains(
            meetingQuery.toLowerCase(),
          ),
        )
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    var insertedNow = false;
    Widget nowMarker() => Padding(
      key: meetingNowKey,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
          const SizedBox(width: 12),
          Chip(
            backgroundColor: _blue,
            label: Text(
              '●  Now · ${meetingClock(now)}',
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
        ],
      ),
    );
    final entries = <Widget>[];
    String? previousDay;
    for (final meeting in rows) {
      if (!insertedNow && meetingStart(meeting) > now) {
        entries.add(nowMarker());
        insertedNow = true;
      }
      final day = meetingDay(meetingStart(meeting));
      if (day != previousDay) {
        entries.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            child: Text(day, style: MeetingVisuals.dateHeading),
          ),
        );
        previousDay = day;
      }
      entries.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: meetingListTile(meeting),
        ),
      );
    }
    if (!insertedNow && rows.isNotEmpty) entries.add(nowMarker());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) meetingListHeading(),
        searchBox(
          'Search meetings',
          (value) => meetingQuery = value,
          controller: meetingSearchController,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            meetingSearchController.clear();
            update(() => meetingQuery = '');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final target = meetingNowKey.currentContext;
              if (target != null)
                Scrollable.ensureVisible(
                  target,
                  duration: const Duration(milliseconds: 250),
                  alignment: .5,
                );
            });
          },
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Now'),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'No meetings yet. Start transcribing or create a new meeting.',
                    ),
                  ),
                ...entries,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget meetingListTile(Map<String, Object?> meeting) {
    final id = meeting['id'] as int;
    final start = meetingStart(meeting);
    final end = meetingEnd(meeting);
    final attachmentCount = google.attachments(id).length;
    final state = meeting['state'] as String;
    final active = state == 'recording' || state == 'transcribing';
    void open() => update(() => meetingPreviewId = id);
    return Card(
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: MeetingVisuals.previewRadius,
      ),
      color: meetingPreviewId == id ? const Color(0xffd2deee) : Colors.white,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 650;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meeting['title'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MeetingVisuals.listTitle,
              ),
              if (narrow && start > 0)
                Text(
                  '${meetingClock(start)} – ${meetingClock(end)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (meeting['has_transcript'] == 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xfff3e5f9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.graphic_eq,
                          size: 12,
                          color: Color(0xff7b2cbf),
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Transcript',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xff7b2cbf),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (meeting['calendar_status'] != null &&
                  meeting['calendar_status'] != 'confirmed')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Calendar ${meeting['calendar_status']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (active || state == 'failed' || state == 'interrupted')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    state,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
          return InkWell(
            onTap: open,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  if (!narrow && start > 0)
                    SizedBox(
                      width: 155,
                      child: Text(
                        '${meetingClock(start)} – ${meetingClock(end)}',
                        style: MeetingVisuals.metadata,
                      ),
                    ),
                  Expanded(child: details),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: open,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(40, 28),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.attach_file, size: 14),
                        Text(
                          '$attachmentCount',
                          style: MeetingVisuals.metadata,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: busy || recording != null || quickStarting
                        ? null
                        : () => recordExistingMeeting(id),
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('Start'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> recordExistingMeeting(int id) async {
    if (busy || recording != null || quickStarting) return;
    update(() => quickStarting = true);
    try {
      if (speechSetupProblem(d.store) != null) await chooseSpeech();
      if (!mounted || speechSetupProblem(d.store) != null) return;
      update(() => meetingId = id);
      await run(startRecording);
    } finally {
      if (mounted) update(() => quickStarting = false);
    }
  }

  Future<void> exportMeetings() async {
    await saveMeetingNotes();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => MeetingExportDialog(
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

  Widget stats() {
    final meetings =
        d.store
                .rows(
                  'SELECT COUNT(DISTINCT meeting_id) AS n FROM transcript WHERE final=1',
                )
                .single['n']
            as int;
    final sources = d.store.sources.length;
    final answers =
        d.store
                .rows(
                  "SELECT COUNT(*) AS n FROM answers WHERE status='completed'",
                )
                .single['n']
            as int;
    final weekly = List<int>.filled(5, 0);
    for (final a in d.store.rows(
      "SELECT body,created FROM answers WHERE status='completed'",
    )) {
      final week =
          DateTime.now()
              .difference(
                DateTime.fromMillisecondsSinceEpoch(a['created'] as int),
              )
              .inDays ~/
          7;
      if (week >= 0 && week < 5)
        weekly[4 - week] += (a['body'] as String).split(RegExp(r'\s+')).length;
    }
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
                            'Local output tokens',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          DesktopMetricValue(localTokens(), fontSize: 52),
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
                            'Your weekly token usage',
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
                            () => update(() => gemmaExplanation = true),
                            selected: gemmaExplanation,
                          ),
                          pill(
                            'What is on-device AI?',
                            () => update(() => gemmaExplanation = false),
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
    await run(() async {
      if (googleAuth.connected) await googleAuth.disconnect();
      await d.command('workspace.clear');
      update(() {
        meetingId = null;
        loadedMeetingNotes = null;
        meetingNotesController.clear();
        meetingEnhanceStatus = '';
        sourceQuery = '';
        sourceSearchController.clear();
        meetingQuery = '';
        labelFilter = '';
        noteId = null;
        noteTitle.clear();
        noteBody.clear();
        hiddenAnswers.clear();
        answer = '';
      });
    });
  }

  Future<void> preference(String key, String value) async {
    await d.command('preferences.set', {'key': key, 'value': value});
    if (mounted) update(() {});
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
  Widget deviceChoice(bool playback) {
    final key = playback ? 'playbackTarget' : 'microphoneTarget';
    final current = d.store.preference(key, 'auto');
    final devices = availableAudioDevices
        .where((device) => device.playback == playback)
        .toList();
    return DesktopSettingSelect<String>(
      width: 300,
      value: current,
      items: [
        const DropdownMenuItem(value: 'auto', child: Text('System default')),
        if (current != 'auto' &&
            !devices.any((device) => device.name == current))
          DropdownMenuItem(
            value: current,
            child: const Text('Saved device unavailable'),
          ),
        ...devices.map(
          (device) => DropdownMenuItem(
            value: device.name,
            child: Text(device.label, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: recording != null ? null : (value) => preference(key, value!),
    );
  }

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
                  loginState.isEmpty
                      ? 'Automatically open Foresight when you log in to your computer.'
                      : loginState,
                ),
                value: desktopSettings.openAtLogin,
                onChanged: busy
                    ? null
                    : (value) => run(() => setOpenAtLogin(value)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Upcoming meeting reminders'),
                subtitle: const Text(
                  'Notify five minutes before a timed Calendar meeting starts.',
                ),
                value: d.store.preference('googleReminders') == 'true',
                onChanged: busy
                    ? null
                    : (value) => run(() => setMeetingReminders(value)),
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
                        onPressed: busy || recording != null
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
                      busy ||
                          recording != null ||
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
                  onPressed: busy || recording != null ? null : chooseSpeech,
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
                  echoCancellationDescription,
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
                onTap: busy || recording != null ? null : clearWorkspace,
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
            subtitle: Text(globalShortcutState),
            value: d.store.preference('globalShortcut') == 'true',
            onChanged: busy
                ? null
                : (enabled) => run(
                    enabled ? enableGlobalShortcuts : disableGlobalShortcuts,
                  ),
          ),
        ),
        Card(
          child: settingRow(
            'Quick start new meeting transcript',
            'Use at least two modifiers and a letter or digit.',
            TextButton(
              onPressed: busy ? null : changeQuickShortcut,
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
              onPressed: () => update(() => tab = 2),
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
                    captureCapabilityError.isNotEmpty
                        ? captureCapabilityError
                        : 'Microphone: $microphoneAccessLabel\nSystem audio access is checked when you explicitly start recording. Enable Open Foresight under Privacy & Security > Screen & System Audio Recording > System Audio Recording Only if access is denied.',
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(requestMicrophoneAccess),
                      child: const Text('Allow microphone'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await setupSystemAudioAccess();
                            }),
                      child: const Text('Allow system audio'),
                    ),
                    TextButton(
                      onPressed: busy ? null : refreshCaptureCapabilities,
                      child: const Text('Refresh access status'),
                    ),
                  ],
                ),
                const Divider(height: 1),
              ],
              settingRow(
                'Microphone',
                'Select the microphone used for spoken transcription.',
                deviceChoice(false),
              ),
              const Divider(height: 1),
              settingRow(
                'System playback',
                'Select the output whose playback should be transcribed.',
                deviceChoice(true),
              ),
              if (audioDeviceState.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(audioDeviceState),
                ),
              TextButton(
                onPressed: refreshAudioDevices,
                child: const Text('Refresh audio devices'),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Desktop completion notifications'),
                subtitle: Text(notificationState),
                value: notifications,
                onChanged: busy
                    ? null
                    : (value) => run(() => setNotifications(value)),
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
                  googleAuth.connected
                      ? 'Connected as ${googleAuth.email}'
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
                if (!googleAuth.connected && googleAuth.client == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Google sign-in setup required. Choose Connect Google to get started.',
                    ),
                  ),
                if (googleState.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(googleState),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!googleAuth.connected) ...[
                      TextButton(
                        onPressed: busy ? null : () => run(importGoogleClient),
                        child: Text(
                          googleAuth.client == null
                              ? 'Import Desktop client configuration'
                              : 'Advanced OAuth configuration',
                        ),
                      ),
                      FilledButton(
                        onPressed: busy ? null : () => run(connectGoogle),
                        child: const Text('Connect Google'),
                      ),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text('Google connection setup'),
                            content: SelectableText(
                              googleAuth.client != null
                                  ? 'Choose Connect Google, select your account in the browser, and grant Drive and Calendar read access. This app already has its application sign-in configuration.\n\nYour Google password is never entered into Foresight. Advanced OAuth configuration is optional.'
                                  : 'This build has no application sign-in configuration. Import a complete Google OAuth Desktop app client JSON, then choose Connect Google. Enable Drive and Calendar APIs in that client’s project.\n\nSign-in opens your browser and asks for read access. Your Google password is never entered into Foresight.',
                            ),
                          ),
                        ),
                        child: const Text('Connection help'),
                      ),
                    ] else ...[
                      TextButton(
                        onPressed: busy || googleSyncing
                            ? null
                            : () => run(google.refresh),
                        child: const Text('Refresh Google'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await googleAuth.disconnect();
                                if (mounted)
                                  update(
                                    () => googleState =
                                        'Disconnected; imported documents remain on this device.',
                                  );
                              }),
                        child: const Text('Disconnect Google'),
                      ),
                    ],
                    if (googleAuth.signingIn)
                      TextButton(
                        onPressed: googleAuth.cancelSignIn,
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
                  '(build $openForesightBuildNumber)',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The reference Sources action uses a dashed pill outline.
class _DashedStadiumBorder extends StadiumBorder {
  const _DashedStadiumBorder({super.side});

  @override
  _DashedStadiumBorder copyWith({BorderSide? side}) =>
      _DashedStadiumBorder(side: side ?? this.side);

  @override
  _DashedStadiumBorder scale(double t) =>
      _DashedStadiumBorder(side: side.scale(t));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(side.width / 2),
          Radius.circular(rect.shortestSide / 2),
        ),
      );
    final paint = side.toPaint();
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 8) {
        canvas.drawPath(
          metric.extractPath(offset, math.min(offset + 4, metric.length)),
          paint,
        );
      }
    }
  }
}

class _SourceLinks extends CustomPainter {
  final List<Map<String, Object?>> rows;
  final List<Offset> positions;
  final List<GraphEdge> edges;
  final List<double> depths;
  _SourceLinks(this.rows, this.positions, this.edges, this.depths);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final visible = {
      for (var i = 0; i < rows.length; i++) rows[i]['id']: positions[i],
    };
    final depthById = {
      for (var i = 0; i < rows.length; i++) rows[i]['id']: depths[i],
    };
    for (final edge in edges) {
      final source = visible[edge.source], target = visible[edge.target];
      if (source != null && target != null) {
        final meanDepth =
            (depthById[edge.source]! + depthById[edge.target]!) / 2;
        final perspective = graphPaintPerspective(meanDepth);
        paint
          ..color = const Color(
            0xff455a64,
          ).withValues(alpha: .85 * graphDepthFade(meanDepth))
          ..strokeWidth = 2.4 * perspective;
        final delta = target - source;
        final distance = delta.distance;
        if (distance == 0) continue;
        final direction = delta / distance;
        for (var start = 0.0; start < distance; start += 8 * perspective) {
          canvas.drawLine(
            source + direction * start,
            source + direction * math.min(start + 3 * perspective, distance),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_SourceLinks oldDelegate) => true;
}

class _UsageChart extends CustomPainter {
  final List<int> values;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;
  _UsageChart(
    this.values, {
    required this.textStyle,
    required this.textScaler,
    required this.textDirection,
  });

  TextPainter label(
    String text,
    double fontSize, {
    double maxWidth = double.infinity,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: textStyle.copyWith(
        fontSize: fontSize,
        color: const Color(0xff50565c),
      ),
    ),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = math.max(4, values.reduce(math.max));
    final ticks = [
      for (var i = 0; i <= 4; i++)
        label(
          NumberFormat.compact().format((maxValue * (4 - i) / 4).round()),
          11,
        ),
    ];
    final gutter = math.min(
      size.width * .3,
      math.max(40.0, ticks.map((t) => t.width).reduce(math.max) + 8),
    );
    final columnWidth = (size.width - gutter) / values.length;
    final labels = [
      for (var i = 0; i < values.length; i++) label(_weekLabel(i), 12),
    ];
    for (var i = 0; i < labels.length; i++) {
      if (labels[i].width > columnWidth - 4) {
        labels[i].dispose();
        labels[i] = label(
          _weekLabel(i).replaceFirst('Week of ', ''),
          12,
          maxWidth: math.max(1, columnWidth - 4),
        );
      }
    }
    final plotHeight = math.max(
      0.0,
      size.height - labels.map((t) => t.height).reduce(math.max) - 10,
    );
    final paint = Paint()..color = const Color(0xffdfe3e9);
    for (var i = 0; i < ticks.length; i++) {
      final y = i * plotHeight / 4;
      canvas.drawLine(Offset(gutter, y), Offset(size.width, y), paint);
      ticks[i].paint(canvas, Offset(0, math.max(0, y - ticks[i].height / 2)));
    }
    paint.color = const Color(0xff75c8ff);
    for (var i = 0; i < values.length; i++) {
      final height = values[i] / maxValue * plotHeight;
      final center = gutter + (i + .5) * columnWidth;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            center - columnWidth * .2,
            plotHeight - height,
            columnWidth * .4,
            height,
          ),
          const Radius.circular(4),
        ),
        paint,
      );
      labels[i].paint(
        canvas,
        Offset(center - labels[i].width / 2, plotHeight + 8),
      );
    }
    for (final painter in [...ticks, ...labels]) {
      painter.dispose();
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (var i = 0; i < values.length; i++)
          CustomPainterSemantics(
            rect: Rect.fromLTWH(
              i * size.width / values.length,
              0,
              size.width / values.length,
              size.height,
            ),
            properties: SemanticsProperties(
              label: '${_weekLabel(i)}: ${values[i]} local output tokens',
              textDirection: textDirection,
            ),
          ),
      ];

  String _weekLabel(int index) {
    final today = DateTime.now();
    final week = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: today.weekday - 1 + (4 - index) * 7));
    return 'Week of ${week.month}/${week.day}';
  }

  @override
  bool shouldRepaint(_UsageChart oldDelegate) => true;
}
