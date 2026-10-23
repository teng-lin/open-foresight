part of 'sources_controller.dart';

extension _SourceTiles on SourcesController {
  String _featureSourceTimeLabel(Object? stamp) =>
      stamp == null || stamp == 0 ? '--' : timeLabel(stamp);

  Widget _featureSourceCells(SourceSummary? source, {String? originalMime}) {
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
                      typedSourceType(source, originalMime: originalMime),
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
                  child: cell(source.title),
                ),
        ),
        if (wide) ...[
          Expanded(
            child: cell(
              header ? 'Imported' : sourceTimeLabel(source.imported),
              color: const Color(0xff999999),
            ),
          ),
          Expanded(
            child: cell(
              header ? 'Last changed' : sourceTimeLabel(source.changed),
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
                      onPressed: _operations.busy
                          ? null
                          : () => editLabels(source),
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
                        onPressed: _operations.busy
                            ? null
                            : () => _operations.run(() => d.index(source.id)),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: IconButton(
                        tooltip: 'Delete source',
                        onPressed: _operations.busy
                            ? null
                            : () => _operations.run(() => d.delete(source.id)),
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

  Widget _featureSourceTile(SourceSummary source, {String? originalMime}) {
    if (gridView) return sourceCardTile(source, originalMime: originalMime);
    final showState = source.state != 'indexed' || source.error != '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showSource(source.id),
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
                    '${source.state}${source.error == '' ? '' : ' · ${source.error}'}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _featureSourceCardTile(
    SourceSummary s, {
    String? originalMime,
  }) => ListTile(
    leading: Icon(
      sourceIcon(s, originalMime: originalMime),
      color: sourceColor(typedSourceType(s, originalMime: originalMime)),
    ),
    title: Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
    subtitle: Text(
      '${s.state}${sourceLabels(s).isEmpty ? '' : ' · ${sourceLabels(s).join(', ')}'}${s.error == '' ? '' : ' · ${s.error}'}',
    ),
    onTap: () => showSource(s.id),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Edit labels',
          onPressed: _operations.busy ? null : () => editLabels(s),
          icon: const Icon(Icons.label_outline, size: 18),
        ),
        IconButton(
          tooltip: 'Index / retry',
          onPressed: _operations.busy
              ? null
              : () => _operations.run(() => d.index(s.id)),
          icon: const Icon(Icons.refresh, size: 20),
        ),
        IconButton(
          tooltip: 'Delete source',
          onPressed: _operations.busy
              ? null
              : () => _operations.run(() => d.delete(s.id)),
          icon: const Icon(Icons.delete_outline, size: 20),
        ),
      ],
    ),
  );
}
