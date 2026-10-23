part of 'sources_controller.dart';

extension _SourceCollection on SourcesController {
  Map<String, String> _featureDriveSourceMimes() => _reads.originalMimes;

  SourceType _featureTypeOf(
    SourceSummary source,
    Map<String, String> originals,
  ) => typedSourceType(source, originalMime: originals[source.id]);

  String _featureTypeName(SourceType type) => switch (type) {
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

  IconData _featureTypeIcon(SourceType type) => switch (type) {
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

  List<SourceSummary> _featureFilteredSources([
    List<SourceSummary>? collection,
    Map<String, String>? originalMimes,
  ]) {
    final originals = originalMimes ?? driveSourceMimes();
    final searchMatches = sourceQuery.isEmpty
        ? null
        : _reads.searchMatches ??
              {
                for (final source in collection ?? _reads.sources)
                  if (source.title.toLowerCase().contains(
                    sourceQuery.toLowerCase(),
                  ))
                    source.id,
              };
    final rows = (collection ?? _reads.sources)
        .where(
          (s) =>
              (searchMatches == null || searchMatches.contains(s.id)) &&
              (labelFilter.isEmpty || sourceLabels(s).contains(labelFilter)) &&
              (typeFilter == null || typeOf(s, originals) == typeFilter),
        )
        .toList();
    rows.sort(
      (a, b) =>
          (ascending ? 1 : -1) *
          (a.title).toLowerCase().compareTo((b.title).toLowerCase()),
    );
    return rows;
  }

  Color _featureSourceColor(SourceType type) => switch (type) {
    SourceType.pdf => const Color(0xffe67b7b),
    SourceType.spreadsheet => const Color(0xff3da963),
    SourceType.presentation => const Color(0xffde9e35),
    SourceType.other || SourceType.text => const Color(0xff666666),
    _ => const Color(0xff4083df),
  };

  IconData _featureSourceIcon(SourceSummary source, {String? originalMime}) =>
      typeIcon(typedSourceType(source, originalMime: originalMime));

  _SourceCollectionSnapshot _collectionSnapshot() {
    final all = _reads.sources;
    final originals = driveSourceMimes();
    final rows = filteredSources(all, originals);
    final labelRecords = _reads.labels;
    final clusters = _reads.clusters
        .map((c) => GraphCluster(c.label, GraphPoint(c.x, c.y, 0), c.radius))
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
    final graphRows = _graphRows;
    final counts = <SourceType, int>{};
    for (final source in all) {
      final type = typeOf(source, originals);
      counts[type] = (counts[type] ?? 0) + 1;
    }
    final labels = {
      ...all.expand(sourceLabels),
      ..._reads.clusterNames,
      if (labelFilter.isNotEmpty) labelFilter,
    }.toList()..sort();
    return (
      all: all,
      rows: rows,
      graphRows: graphRows,
      originals: originals,
      clusters: clusters,
      documentLabelRecords: documentLabelRecords,
      documentLabelColors: documentLabelColors,
      labelColorsByName: labelColorsByName,
      counts: counts,
      labels: labels,
    );
  }

  Widget _featureSources() {
    final view = _collectionSnapshot();
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
                if (_reads.problem != null) Text(_reads.problem!),
                _collectionHeading(),
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
                _collectionSearch(),
                const SizedBox(height: 16),
                _collectionLabels(view),
                const SizedBox(height: 16),
                _collectionFilters(view),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        _collectionBody(view),
      ],
    );
  }

  Widget _collectionHeading() => heading(
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
            icon: Icon(d.sourcesPaused ? Icons.play_arrow : Icons.pause),
          ),
          if (d.sourcesPaused)
            const Text('Paused', style: TextStyle(fontSize: 12)),
          if (integrationFeature.googlePresentation.connected)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_outlined, size: 18, color: _ink),
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
            _operations.busy ? null : () => _operations.run(reimport),
            icon: Icons.refresh,
          ),
        ],
      ),
    ],
  );

  Widget _collectionSearch() => Row(
    children: [
      Expanded(
        child: searchBox(
          'Search knowledge sources…',
          (value) => sourceQuery = value,
          controller: sourceSearchController,
        ),
      ),
      const SizedBox(width: 16),
      _collectionImportMenu(),
    ],
  );

  Widget _collectionLabels(_SourceCollectionSnapshot view) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      ActionChip(
        side: const BorderSide(color: Color(0xffaeb5bc)),
        shape: const DashedStadiumBorder(
          side: BorderSide(color: Color(0xffaeb5bc)),
        ),
        color: WidgetStatePropertyAll(
          Theme.of(context).scaffoldBackgroundColor,
        ),
        avatar: const Icon(Icons.add, size: 18),
        label: const Text('Add label', style: DesktopVisuals.control),
        onPressed: _operations.busy ? null : createOrganizationLabel,
      ),
      ...view.labels.map(
        (label) => FilterChip(
          label: Text(label),
          onDeleted: _operations.busy
              ? null
              : () => deleteOrganizationLabel(label),
          selected: labelFilter == label,
          onSelected: (_) =>
              update(() => labelFilter = labelFilter == label ? '' : label),
        ),
      ),
    ],
  );

  Widget _collectionFilters(_SourceCollectionSnapshot view) => LayoutBuilder(
    builder: (_, constraints) {
      final filters = _collectionTypeFilters(view);
      final controls = _collectionControls(view);
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
  );

  Widget _collectionBody(_SourceCollectionSnapshot view) => Expanded(
    child: ClipRRect(
      borderRadius: DesktopVisuals.panelRadius,
      child: ColoredBox(
        color: const Color(0xfff8faff),
        child: (graphView ? view.all : view.rows).isEmpty
            ? Center(
                child: Text(
                  view.all.isEmpty
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
                  view.graphRows,
                  graphWorldPoints,
                  view.rows,
                  view.documentLabelColors,
                  view.labelColorsByName,
                  view.documentLabelRecords,
                  view.clusters,
                ),
              )
            : gridView
            ? GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 360,
                  mainAxisExtent: 180,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: view.rows.length,
                itemBuilder: (_, i) => Card(
                  child: sourceTile(
                    view.rows[i],
                    originalMime: view.originals[view.rows[i].id],
                  ),
                ),
              )
            : ListView.builder(
                itemCount: view.rows.length + 2,
                itemBuilder: (_, index) {
                  if (index == 0)
                    return Padding(
                      padding: DesktopVisuals.sourceHeaderPadding,
                      child: sourceCells(null),
                    );
                  if (index == 1) return const Divider(height: 1);
                  final source = view.rows[index - 2];
                  return KeyedSubtree(
                    key: ValueKey(source.id),
                    child: sourceTile(
                      source,
                      originalMime: view.originals[source.id],
                    ),
                  );
                },
              ),
      ),
    ),
  );

  List<Widget> _collectionTypeFilters(
    _SourceCollectionSnapshot view,
  ) => <Widget>[
    Text(
      '${view.all.length} sources identified, ${view.all.where((s) => s.state == 'indexed').length} indexed',
      style: const TextStyle(
        fontSize: 14,
        color: Color(0xff83898e),
        fontWeight: FontWeight.w500,
      ),
    ),
    FilterChip(
      showCheckmark: false,
      shape: const StadiumBorder(side: BorderSide.none),
      label: Text('All ${view.all.length}', style: DesktopVisuals.control),
      selected: typeFilter == null,
      onSelected: (_) => update(() => typeFilter = null),
    ),
    for (final type in SourceType.values.where(
      (type) => view.counts.containsKey(type) || type == typeFilter,
    ))
      Tooltip(
        message: '${typeName(type)}: ${view.counts[type] ?? 0}',
        child: FilterChip(
          showCheckmark: false,
          shape: const StadiumBorder(side: BorderSide.none),
          backgroundColor: Colors.white,
          selectedColor: _blue,
          visualDensity: VisualDensity.compact,
          avatar: Icon(typeIcon(type), size: 16, color: sourceColor(type)),
          label: Text(
            '${view.counts[type] ?? 0}',
            style: DesktopVisuals.control,
          ),
          selected: typeFilter == type,
          onSelected: (_) =>
              update(() => typeFilter = typeFilter == type ? null : type),
        ),
      ),
  ];

  List<Widget> _collectionControls(_SourceCollectionSnapshot view) => <Widget>[
    if (typeFilter != null || sourceQuery.isNotEmpty || labelFilter.isNotEmpty)
      Text('${view.rows.length} of ${view.all.length} shown'),
    if (typeFilter != null || sourceQuery.isNotEmpty || labelFilter.isNotEmpty)
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
                    onPressed: () => update(() => gridView = grid),
                    style: IconButton.styleFrom(
                      backgroundColor: gridView == grid ? _blue : Colors.white,
                      foregroundColor: _ink,
                      shape: const RoundedRectangleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    icon: Icon(
                      grid ? Icons.grid_view : Icons.view_list,
                      size: 20,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
  ];

  Widget _collectionImportMenu() => PopupMenuButton<String>(
    enabled: !_operations.busy,
    tooltip: 'Add source',
    position: PopupMenuPosition.under,
    onSelected: (choice) => _operations.run(() async {
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
          if (!integrationFeature.googlePresentation.connected)
            await integrationFeature.connectGoogle();
          if (mounted && integrationFeature.googlePresentation.connected) {
            await integrationFeature.importLastYear();
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
        enabled: !_operations.busy && integrationFeature.driveAvailable,
        child: DesktopImportMenuTile(
          icon: Icons.cloud_outlined,
          label: 'Add files from Drive',
        ),
      ),
      PopupMenuItem(
        value: 'drive-folder',
        enabled: !_operations.busy && integrationFeature.driveAvailable,
        child: DesktopImportMenuTile(
          icon: Icons.folder_shared_outlined,
          label: 'Add an entire Drive folder',
        ),
      ),
      PopupMenuItem(
        value: 'drive-year',
        enabled: !_operations.busy && integrationFeature.driveAvailable,
        child: DesktopImportMenuTile(
          icon: Icons.history,
          label: 'Import last 1 year from Drive',
        ),
      ),
      PopupMenuItem(
        value: 'url',
        child: DesktopImportMenuTile(icon: Icons.link, label: 'Add from URL'),
      ),
    ],
    child: Chip(
      shape: const StadiumBorder(side: BorderSide.none),
      backgroundColor: _blue,
      padding: const EdgeInsets.all(16),
      avatar: const Icon(Icons.add),
      label: const Text('Add source', style: DesktopVisuals.control),
    ),
  );
}

typedef _SourceCollectionSnapshot = ({
  List<SourceSummary> all,
  List<SourceSummary> rows,
  List<SourceSummary> graphRows,
  Map<String, String> originals,
  List<GraphCluster> clusters,
  Map<String, List<DocumentLabel>> documentLabelRecords,
  Map<String, List<Color>> documentLabelColors,
  Map<String, Color> labelColorsByName,
  Map<SourceType, int> counts,
  List<String> labels,
});
