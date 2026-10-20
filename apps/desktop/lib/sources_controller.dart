part of 'main.dart';

class _SourcesController extends _FeatureController {
  _SourcesController(super.shell);

  bool graphView = false;

  bool gridView = false;

  bool ascending = true;

  String sourceQuery = '';

  String labelFilter = '';

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

  double graphYaw = 0;

  double graphPitch = 0;

  int? graphMousePointer;

  Offset? graphPointerStart;

  Offset? graphPointerLast;

  bool graphPointerRotates = false;

  bool graphDragMoved = false;

  final graphVectorCache = <String, List<double>>{};

  final graphMotionFrames = ValueNotifier<int>(0);

  late final Ticker graphMotionTicker;

  Duration? graphLastTick;

  bool graphAnimationPaused = false;

  bool graphManualPitch = false;

  bool graphModalOpen = false;

  void syncGraphMotion() {
    final enabled =
        mounted &&
        shell.tab == 0 &&
        graphView &&
        d.store.sourceSummaries.isNotEmpty &&
        !graphAnimationPaused &&
        graphMousePointer == null &&
        !graphModalOpen &&
        !MediaQuery.disableAnimationsOf(context);
    if (enabled && !graphMotionTicker.isActive) {
      graphLastTick = null;
      // The callback intentionally schedules work owned by its controller.
      // ignore: discarded_futures
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
        shell.tab != 0 ||
        !graphView)
      return;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    // Keep idle graph motion slow, with gentler motion while a source is selected.
    graphYaw += seconds * .025 * (graphSelectedDocument == null ? 1 : .05);
    if (!graphManualPitch) graphPitch = .4 + math.sin(graphYaw * .4) * .08;
    graphMotionFrames.value++;
  }

  Future<void> importFolderPath(String path) => importDirectory(path);

  Future<void> findLocalFiles({List<String>? roots}) =>
      findFilesOnComputer(roots: roots);

  Future<void> refreshSources() => reimport();

  Future<void> importSourceUrl(String address) => importAddress(address);

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
      final current = d.store.sourceById(s['id'] as String);
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
            onPressed: shell.busy
                ? null
                : () {
                    Navigator.pop(context);
                    unawaited(editSource(s).catchError(shell.reportAsyncError));
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

  Future<void> editSource(Map<String, Object?> s) async {
    final text = TextEditingController(text: s['content'] as String);
    final saved = await shell.showInputDialog<bool>(
      builder: (context) => ServiceEditDialog(
        title: 'Edit ${s['title']}',
        controller: text,
        height: 400,
        saveLabel: 'Save and index',
        onSave: () async {
          await d.command(Operation.sourcesImport, {
            'title': s['title'],
            'text': text.text,
            'mime': s['mime'],
            'provenance': s['provenance'],
            'id': s['id'],
            'locallyEdited': true,
            'index': false,
          });
          await d.index(s['id'] as String);
        },
      ),
    );
    if (saved == true && mounted) setState(() {});
    text.dispose();
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
                  meetingFeature.noteId = null;
                  meetingFeature.noteTitle.clear();
                  meetingFeature.noteBody.clear();
                });
              },
              child: const Text('New note'),
            ),
            Expanded(
              child: ListView(
                children: d.store
                    .noteSummaries()
                    .map(
                      (n) => ListTile(
                        title: Text(n['title'] as String),
                        subtitle: Text('Revision ${n['revision']}'),
                        onTap: () => setState(() {
                          meetingFeature.noteId = n['id'] as int;
                          meetingFeature.noteTitle.text = n['title'] as String;
                          meetingFeature.noteBody.text = d.store.noteBody(
                            n['id'] as int,
                          );
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
              controller: meetingFeature.noteTitle,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            Expanded(
              child: TextField(
                controller: meetingFeature.noteBody,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'Your editable note',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            FilledButton(
              onPressed: () => shell.run(() async {
                final saved =
                    await d.command(Operation.notesSave, {
                          'id': meetingFeature.noteId,
                          'title': meetingFeature.noteTitle.text,
                          'body': meetingFeature.noteBody.text,
                        })
                        as Map;
                if (mounted)
                  setState(() => meetingFeature.noteId = saved['id'] as int);
              }),
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> importPath(String path) async {
    await d.command(Operation.sourcesImportFile, {'path': path});
    if (mounted) shell.update(() {});
  }

  Future<void> findFilesOnComputer({List<String>? roots}) async {
    final excluded = <String>{};
    for (final row in d.store.sourceSummaries) {
      final uri = Uri.tryParse(row['source_uri'] as String? ?? '');
      if (uri == null || uri.scheme != 'file' || !allowedSourceUri(uri))
        continue;
      try {
        excluded.add(uri.toFilePath());
      } on UnsupportedError {
        // Persisted source URIs can originate from arbitrary imports.
      } on ArgumentError {
        // A malformed URI must not prevent discovery of other local files.
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
    await importSelectedPaths(selected);
  }

  Future<void> importSelectedPaths(List<String> selected) async {
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
    if (!mounted || path == null) return;
    await reviewFolderImport(path);
  }

  Future<void> reviewFolderImport(String path) async {
    final selected = await shell.showInputDialog<List<String>>(
      builder: (_) => FileDiscoverySheet(
        initialFolders: [path],
        excludedPaths: const {},
        pickFolder: () async => null,
        folderImport: true,
      ),
    );
    if (!mounted || selected == null) return;
    await importSelectedPaths(selected);
  }

  Future<void> importDirectory(String path) async {
    await d.command(Operation.sourcesImportDirectory, {'path': path});
  }

  Future<void> reimport() async {
    await d.command(Operation.sourcesRefresh);
  }

  Future<void> importUrl() async {
    final input = TextEditingController();
    var allowPrivateNetwork = false;
    final accepted = await shell.showInputDialog<bool>(
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
    await d.command(Operation.sourcesImportUrl, {
      'url': value,
      if (allowPrivateNetwork) 'allow_private_network': true,
    });
  }

  List<String> sourceLabels(Map<String, Object?> s) =>
      (jsonDecode(s['labels'] as String? ?? '[]') as List).cast<String>();

  Future<void> putDocumentLabel(DocumentLabel label) async {
    await d.command(Operation.labelsPut, {
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
    return await d.command(Operation.graphSave, {
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
    final source = d.store.sourceSummaries
        .where((row) => row['id'] == id)
        .single;
    await d.command(Operation.labelsSet, {
      'id': id,
      'labels': sourceLabels(source).where((label) => label != name).toList(),
    });
    await d.command(Operation.graphAcknowledge);
    if (mounted) shell.update(() {});
  }

  Future<void> createOrganizationLabel() async {
    final input = TextEditingController();
    final name = await shell.showInputDialog<String>(
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
      await shell.run(() => autoAssignOrganizationLabel(name));
  }

  Future<void> autoAssignOrganizationLabel(String name) async {
    await d.command(Operation.labelsAutoAssign, {'name': name});
    if (mounted)
      shell.update(() {
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
    final confirmed = await shell.showInputDialog<bool>(
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
      await d.command(Operation.labelsDelete, {'name': name});
      await d.command(Operation.graphAcknowledge);
      if (mounted)
        shell.update(() {
          if (labelFilter == name) labelFilter = '';
        });
    }
  }

  Future<void> editLabels(Map<String, Object?>? s) async {
    final input = TextEditingController(
      text: s == null ? '' : sourceLabels(s).join(', '),
    );
    final ok = await shell.showInputDialog<bool>(
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
      await d.command(Operation.labelsSet, {
        'id': row['id'],
        'labels': s == null
            ? {...sourceLabels(row), ...values}.toList()
            : values,
      });
    }
    if (mounted) shell.update(() {});
  }

  Map<String, String> driveSourceMimes() => {
    for (final row in d.store.googleSourceMimes())
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
        sourceSearchCacheKey = key;
        sourceSearchMatches = {
          for (final source in collection ?? d.store.sourceSummaries)
            if ((source['title'] as String).toLowerCase().contains(
              sourceQuery.toLowerCase(),
            ))
              source['id'] as String,
        };
        final databasePath = d.store.path;
        final query = sourceQuery.toLowerCase();
        unawaited(
          searchSourceIds(databasePath, query).then(
            (matches) {
              if (mounted && sourceSearchCacheKey == key)
                update(() => sourceSearchMatches = matches);
            },
            onError: (Object error) {
              if (mounted && sourceSearchCacheKey == key)
                update(() => shell.error = error.toString());
            },
          ),
        );
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

  Widget sources() {
    final all = d.store.sourceSummaries;
    final originals = driveSourceMimes();
    final rows = filteredSources(all, originals);
    final labelRecords = d.store.documentLabels;
    final clusters = d.store
        .documentClusters()
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
      ...d.store.documentClusterNames().map((row) => row['label'] as String),
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
                          onPressed: () => shell.update(() {
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
                        if (integrationFeature.googleAuth.connected)
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
                                integrationFeature.googleSyncStatus(),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff83898e),
                                ),
                              ),
                            ],
                          ),
                        pill(
                          'Import again',
                          shell.busy ? null : () => shell.run(reimport),
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
                      () => shell.update(() => graphView = false),
                      selected: !graphView,
                    ),
                    pill(
                      'Graph view',
                      () => shell.update(() => graphView = true),
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
                      enabled: !shell.busy,
                      tooltip: 'Add source',
                      position: PopupMenuPosition.under,
                      onSelected: (choice) => shell.run(() async {
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
                            await integrationFeature.chooseDrive();
                          case 'drive-folder':
                            await integrationFeature.chooseDrive(folder: true);
                          case 'drive-year':
                            if (!integrationFeature.googleAuth.connected)
                              await integrationFeature.connectGoogle();
                            if (mounted &&
                                integrationFeature.googleAuth.connected) {
                              await integrationFeature.google.importLastYear();
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
                          enabled:
                              !shell.busy && integrationFeature.driveAvailable,
                          child: DesktopImportMenuTile(
                            icon: Icons.cloud_outlined,
                            label: 'Add files from Drive',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'drive-folder',
                          enabled:
                              !shell.busy && integrationFeature.driveAvailable,
                          child: DesktopImportMenuTile(
                            icon: Icons.folder_shared_outlined,
                            label: 'Add an entire Drive folder',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'drive-year',
                          enabled:
                              !shell.busy && integrationFeature.driveAvailable,
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
                      onPressed: shell.busy ? null : createOrganizationLabel,
                    ),
                    ...labels.map(
                      (label) => FilterChip(
                        label: Text(label),
                        onDeleted: shell.busy
                            ? null
                            : () => deleteOrganizationLabel(label),
                        selected: labelFilter == label,
                        onSelected: (_) => shell.update(
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
                        onSelected: (_) =>
                            shell.update(() => typeFilter = null),
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
                            onSelected: (_) => shell.update(
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
                          onPressed: () => shell.update(() {
                            sourceQuery = '';
                            sourceSearchController.clear();
                            labelFilter = '';
                            typeFilter = null;
                          }),
                          child: const Text('Clear filters'),
                        ),
                      pill(
                        ascending ? 'A → Z' : 'Z → A',
                        () => shell.update(() => ascending = !ascending),
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
                                          shell.update(() => gridView = grid),
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
                  onTap: () => shell.update(() => ascending = !ascending),
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
                      onPressed: shell.busy ? null : () => editLabels(source),
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
                        onPressed: shell.busy
                            ? null
                            : () => shell.run(
                                () => d.index(source['id'] as String),
                              ),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: IconButton(
                        tooltip: 'Delete source',
                        onPressed: shell.busy
                            ? null
                            : () => shell.run(
                                () => d.delete(source['id'] as String),
                              ),
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
          onPressed: shell.busy ? null : () => editLabels(s),
          icon: const Icon(Icons.label_outline, size: 18),
        ),
        IconButton(
          tooltip: 'Index / retry',
          onPressed: shell.busy
              ? null
              : () => shell.run(() => d.index(s['id'] as String)),
          icon: const Icon(Icons.refresh, size: 20),
        ),
        IconButton(
          tooltip: 'Delete source',
          onPressed: shell.busy
              ? null
              : () => shell.run(() => d.delete(s['id'] as String)),
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
            !d.store.sourceSummaries.any((row) => row['id'] == selected)) {
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
      final registered = d.store.registeredEmbedding();
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
        shell.update(() {
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
              shell.update(() {
                graphLayoutKey = '';
                graphOrganizing = false;
              });
              return;
            }
          }
          shell.update(() {
            if (scene != null) graphPoints = scene.points;
            graphEdges = edges;
            graphOrganizing = false;
          });
          refreshGraphSelection();
          scheduleGraphFit();
        } catch (e) {
          if (!mounted || graphLayoutKey != key) return;
          shell.update(() {
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
      shell.update(() {
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
          shell.update(() {
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
            shell.update(() {
              graphLayoutKey = '';
              graphOrganizing = false;
            });
            return;
          }
        }
        shell.update(() {
          graphPoints = layout;
          graphEdges = scene.edges;
          graphSceneVectors = vectors;
          graphOrganizing = false;
        });
        refreshGraphSelection();
        scheduleGraphFit();
      } catch (e) {
        if (!mounted || graphLayoutKey != key) return;
        shell.update(() {
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
      if (mounted && shell.tab == 0 && graphView) fitGraph();
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
    // The callback intentionally schedules work owned by its controller.
    // ignore: discarded_futures
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
    shell.update(() {
      graphMousePointer = event.pointer;
      graphPointerStart = graphPointerLast = event.localPosition;
      graphPointerRotates = event.buttons == kPrimaryMouseButton || modifier;
      graphDragMoved = false;
    });
  }

  void moveGraphPointer(PointerMoveEvent event) {
    if (graphMousePointer != event.pointer || graphPointerLast == null) return;
    final delta = event.localPosition - graphPointerLast!;
    shell.update(() {
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
    shell.update(() {
      graphMousePointer = null;
      graphPointerStart = graphPointerLast = null;
    });
  }

  void selectGraphDocument(String? document) {
    shell.update(() {
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
    shell.update(() {
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
      // The callback intentionally schedules work owned by its controller.
      // ignore: discarded_futures
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
      shell.update(() {
        graphSelectionEdges = edges;
        graphRelatedLoading = false;
      });
    } catch (e) {
      if (!mounted || revision != graphSelectionRevision) return;
      shell.update(() {
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
                        if (context.mounted)
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
              enabled: !shell.busy,
              onAdd: (value) =>
                  shell.run(() => addSelectedGraphLabel(id, value)),
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
                        : () => shell.update(
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
}

class _SourcesView extends StatelessWidget {
  final _SourcesController controller;
  const _SourcesView(this.controller);
  @override
  Widget build(BuildContext context) => controller.sources();
}
