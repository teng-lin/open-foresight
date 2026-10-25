import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import '../../desktop_visuals.dart';
import '../../presentation/workspace_presentation.dart';
import 'source_type_view.dart';
import 'source_painters.dart';
import 'source_tiles.dart';

SourceType sourceCollectionType(
  SourceSummary source,
  Map<String, String> originals,
) => typedSourceType(source, originalMime: originals[source.id]);

String sourceCollectionTypeName(SourceType type) => switch (type) {
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

IconData sourceCollectionTypeIcon(SourceType type) => switch (type) {
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

Color sourceCollectionColor(SourceType type) => switch (type) {
  SourceType.pdf => const Color(0xffe67b7b),
  SourceType.spreadsheet => const Color(0xff3da963),
  SourceType.presentation => const Color(0xffde9e35),
  SourceType.other || SourceType.text => const Color(0xff666666),
  _ => const Color(0xff4083df),
};

IconData sourceCollectionIcon(SourceSummary source, {String? originalMime}) =>
    sourceCollectionTypeIcon(
      typedSourceType(source, originalMime: originalMime),
    );

final class SourceCollectionEntry {
  SourceCollectionEntry(this.source, String? originalMime)
    : icon = sourceCollectionIcon(source, originalMime: originalMime),
      color = sourceCollectionColor(
        typedSourceType(source, originalMime: originalMime),
      ),
      labels = source.labels.join(', '),
      imported = source.imported == null || source.imported == 0
          ? '--'
          : workspaceTimeLabel(source.imported),
      changed = source.changed == null || source.changed == 0
          ? '--'
          : workspaceTimeLabel(source.changed);
  final SourceSummary source;
  final IconData icon;
  final Color color;
  final String labels, imported, changed;
}

final class SourceCollectionSnapshot {
  SourceCollectionSnapshot({
    required List<SourceSummary> all,
    required List<SourceSummary> rows,
    required List<SourceSummary> graphRows,
    required Map<String, String> originals,
    required List<GraphCluster> clusters,
    required Map<String, List<DocumentLabel>> documentLabelRecords,
    required Map<String, List<Color>> documentLabelColors,
    required Map<String, Color> labelColorsByName,
    required Map<SourceType, int> counts,
    required List<String> labels,
  }) : all = List.unmodifiable(all),
       rows = List.unmodifiable(rows),
       graphRows = List.unmodifiable(graphRows),
       originals = Map.unmodifiable(originals),
       clusters = List.unmodifiable(clusters),
       documentLabelRecords = Map.unmodifiable(
         documentLabelRecords.map(
           (key, value) =>
               MapEntry(key, List<DocumentLabel>.unmodifiable(value)),
         ),
       ),
       documentLabelColors = Map.unmodifiable(
         documentLabelColors.map(
           (key, value) => MapEntry(key, List<Color>.unmodifiable(value)),
         ),
       ),
       labelColorsByName = Map.unmodifiable(labelColorsByName),
       counts = Map.unmodifiable(counts),
       labels = List.unmodifiable(labels);
  final List<SourceSummary> all, rows, graphRows;
  final Map<String, String> originals;
  final List<GraphCluster> clusters;
  final Map<String, List<DocumentLabel>> documentLabelRecords;
  final Map<String, List<Color>> documentLabelColors;
  final Map<String, Color> labelColorsByName;
  final Map<SourceType, int> counts;
  final List<String> labels;
  SourceCollectionEntry entry(int index) =>
      SourceCollectionEntry(rows[index], originals[rows[index].id]);
}

final class SourceCollectionPresentation {
  const SourceCollectionPresentation({
    required this.graphView,
    required this.gridView,
    required this.ascending,
    required this.typeFilter,
    required this.labelFilter,
    required this.sourceQuery,
    required this.sourcesPaused,
    required this.googleConnected,
    required this.googleSyncStatus,
    required this.busy,
    required this.driveAvailable,
    required this.deviceName,
  });
  final bool graphView,
      gridView,
      ascending,
      sourcesPaused,
      googleConnected,
      busy,
      driveAvailable;
  final SourceType? typeFilter;
  final String labelFilter, sourceQuery, googleSyncStatus, deviceName;
}

class SourceCollectionView extends StatelessWidget {
  const SourceCollectionView({
    super.key,
    required this.view,
    required this.presentation,
    this.problem,
    required this.searchController,
    required this.graph,
    required this.onTogglePause,
    required this.onReimport,
    required this.onGraphView,
    required this.onSearch,
    required this.onCreateLabel,
    required this.onDeleteLabel,
    required this.onLabelSelected,
    required this.onTypeSelected,
    required this.onClearFilters,
    required this.onToggleSort,
    required this.onGridView,
    required this.onImport,
    required this.onOpen,
    required this.onEditLabels,
    required this.onIndex,
    required this.onDelete,
  });
  final SourceCollectionSnapshot view;
  final SourceCollectionPresentation presentation;
  final String? problem;
  final TextEditingController searchController;
  final Widget graph;
  final VoidCallback onTogglePause,
      onReimport,
      onCreateLabel,
      onClearFilters,
      onToggleSort;
  final ValueChanged<bool> onGraphView, onGridView;
  final ValueChanged<String> onSearch,
      onDeleteLabel,
      onLabelSelected,
      onImport,
      onOpen,
      onIndex,
      onDelete;
  final ValueChanged<SourceType?> onTypeSelected;
  final ValueChanged<SourceSummary> onEditLabels;
  Widget _cells(SourceCollectionEntry? entry) => SourceCells(
    source: entry?.source,
    icon: entry?.icon,
    color: entry?.color,
    imported: entry?.imported ?? '',
    changed: entry?.changed ?? '',
    labels: entry?.labels ?? '',
    ascending: presentation.ascending,
    onSort: onToggleSort,
    onEditLabels: entry == null || presentation.busy
        ? null
        : () => onEditLabels(entry.source),
    onIndex: entry == null || presentation.busy
        ? null
        : () => onIndex(entry.source.id),
    onDelete: entry == null || presentation.busy
        ? null
        : () => onDelete(entry.source.id),
  );
  Widget _tile(SourceCollectionEntry entry) => presentation.gridView
      ? SourceCard(
          s: entry.source,
          icon: entry.icon,
          color: entry.color,
          labels: entry.labels,
          onOpen: () => onOpen(entry.source.id),
          onEditLabels: presentation.busy
              ? null
              : () => onEditLabels(entry.source),
          onIndex: presentation.busy ? null : () => onIndex(entry.source.id),
          onDelete: presentation.busy ? null : () => onDelete(entry.source.id),
        )
      : SourceRow(
          source: entry.source,
          cells: _cells(entry),
          onOpen: () => onOpen(entry.source.id),
        );
  @override
  Widget build(BuildContext context) {
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
                if (problem != null) Text(problem!),
                _collectionHeading(),
                Wrap(
                  spacing: 10,
                  children: [
                    workspacePill(
                      'File list',
                      () => onGraphView(false),
                      selected: !presentation.graphView,
                    ),
                    workspacePill(
                      'Graph view',
                      () => onGraphView(true),
                      selected: presentation.graphView,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _collectionSearch(),
                const SizedBox(height: 16),
                _collectionLabels(context, view),
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

  Widget _collectionHeading() => workspaceHeading(
    'Knowledge Sources',
    actions: [
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: presentation.sourcesPaused
                ? 'Resume source imports and indexing'
                : 'Pause source imports and indexing',
            onPressed: onTogglePause,
            icon: Icon(
              presentation.sourcesPaused ? Icons.play_arrow : Icons.pause,
            ),
          ),
          if (presentation.sourcesPaused)
            const Text('Paused', style: TextStyle(fontSize: 12)),
          if (presentation.googleConnected)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_outlined, size: 18, color: workspaceInk),
                const SizedBox(width: 6),
                Text(
                  presentation.googleSyncStatus,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff83898e),
                  ),
                ),
              ],
            ),
          workspacePill(
            'Import again',
            presentation.busy ? null : onReimport,
            icon: Icons.refresh,
          ),
        ],
      ),
    ],
  );

  Widget _collectionSearch() => Row(
    children: [
      Expanded(
        child: workspaceSearchBox(
          'Search knowledge sources…',
          onSearch,
          controller: searchController,
        ),
      ),
      const SizedBox(width: 16),
      _collectionImportMenu(),
    ],
  );

  Widget _collectionLabels(
    BuildContext context,
    SourceCollectionSnapshot view,
  ) => Wrap(
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
        onPressed: presentation.busy ? null : onCreateLabel,
      ),
      ...view.labels.map(
        (label) => FilterChip(
          label: Text(label),
          onDeleted: presentation.busy ? null : () => onDeleteLabel(label),
          selected: presentation.labelFilter == label,
          onSelected: (_) => onLabelSelected(label),
        ),
      ),
    ],
  );

  Widget _collectionFilters(SourceCollectionSnapshot view) => LayoutBuilder(
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

  Widget _collectionBody(SourceCollectionSnapshot view) => Expanded(
    child: ClipRRect(
      borderRadius: DesktopVisuals.panelRadius,
      child: ColoredBox(
        color: const Color(0xfff8faff),
        child: (presentation.graphView ? view.all : view.rows).isEmpty
            ? Center(
                child: Text(
                  view.all.isEmpty
                      ? 'Add a source to build your knowledge.'
                      : 'No sources match the current filters.',
                ),
              )
            : presentation.graphView
            ? graph
            : presentation.gridView
            ? GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 360,
                  mainAxisExtent: 180,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: view.rows.length,
                itemBuilder: (_, i) => Card(child: _tile(view.entry(i))),
              )
            : ListView.builder(
                itemCount: view.rows.length + 2,
                itemBuilder: (_, index) {
                  if (index == 0)
                    return Padding(
                      padding: DesktopVisuals.sourceHeaderPadding,
                      child: _cells(null),
                    );
                  if (index == 1) return const Divider(height: 1);
                  final source = view.rows[index - 2];
                  return KeyedSubtree(
                    key: ValueKey(source.id),
                    child: _tile(view.entry(index - 2)),
                  );
                },
              ),
      ),
    ),
  );

  List<Widget> _collectionTypeFilters(
    SourceCollectionSnapshot view,
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
      selected: presentation.typeFilter == null,
      onSelected: (_) => onTypeSelected(null),
    ),
    for (final type in SourceType.values.where(
      (type) =>
          view.counts.containsKey(type) || type == presentation.typeFilter,
    ))
      Tooltip(
        message: '${sourceCollectionTypeName(type)}: ${view.counts[type] ?? 0}',
        child: FilterChip(
          showCheckmark: false,
          shape: const StadiumBorder(side: BorderSide.none),
          backgroundColor: Colors.white,
          selectedColor: workspaceBlue,
          visualDensity: VisualDensity.compact,
          avatar: Icon(
            sourceCollectionTypeIcon(type),
            size: 16,
            color: sourceCollectionColor(type),
          ),
          label: Text(
            '${view.counts[type] ?? 0}',
            style: DesktopVisuals.control,
          ),
          selected: presentation.typeFilter == type,
          onSelected: (_) => onTypeSelected(type),
        ),
      ),
  ];

  List<Widget> _collectionControls(SourceCollectionSnapshot view) => <Widget>[
    if (presentation.typeFilter != null ||
        presentation.sourceQuery.isNotEmpty ||
        presentation.labelFilter.isNotEmpty)
      Text('${view.rows.length} of ${view.all.length} shown'),
    if (presentation.typeFilter != null ||
        presentation.sourceQuery.isNotEmpty ||
        presentation.labelFilter.isNotEmpty)
      TextButton(onPressed: onClearFilters, child: const Text('Clear filters')),
    workspacePill(
      presentation.ascending ? 'A → Z' : 'Z → A',
      onToggleSort,
      icon: Icons.sort,
    ),
    if (!presentation.graphView)
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
                    onPressed: () => onGridView(grid),
                    style: IconButton.styleFrom(
                      backgroundColor: presentation.gridView == grid
                          ? workspaceBlue
                          : Colors.white,
                      foregroundColor: workspaceInk,
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
    enabled: !presentation.busy,
    tooltip: 'Add source',
    position: PopupMenuPosition.under,
    onSelected: onImport,
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
          label: 'Find files on this ${presentation.deviceName}',
        ),
      ),
      PopupMenuItem(
        value: 'drive-file',
        enabled: !presentation.busy && presentation.driveAvailable,
        child: DesktopImportMenuTile(
          icon: Icons.cloud_outlined,
          label: 'Add files from Drive',
        ),
      ),
      PopupMenuItem(
        value: 'drive-folder',
        enabled: !presentation.busy && presentation.driveAvailable,
        child: DesktopImportMenuTile(
          icon: Icons.folder_shared_outlined,
          label: 'Add an entire Drive folder',
        ),
      ),
      PopupMenuItem(
        value: 'drive-year',
        enabled: !presentation.busy && presentation.driveAvailable,
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
      backgroundColor: workspaceBlue,
      padding: const EdgeInsets.all(16),
      avatar: const Icon(Icons.add),
      label: const Text('Add source', style: DesktopVisuals.control),
    ),
  );
}
