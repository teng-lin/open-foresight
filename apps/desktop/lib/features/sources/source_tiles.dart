import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import '../../desktop_visuals.dart';

class SourceCells extends StatelessWidget {
  final SourceSummary? source;
  final IconData? icon;
  final Color? color;
  final String imported, changed, labels;
  final bool ascending;
  final VoidCallback? onSort, onEditLabels, onIndex, onDelete;
  const SourceCells({
    super.key,
    this.source,
    this.icon,
    this.color,
    this.imported = '',
    this.changed = '',
    this.labels = '',
    required this.ascending,
    this.onSort,
    this.onEditLabels,
    this.onIndex,
    this.onDelete,
  });
  @override
  Widget build(BuildContext context) {
    final source = this.source;
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
                  child: Icon(icon, size: 20, color: color),
                ),
        ),
        Expanded(
          flex: 2,
          child: header
              ? InkWell(
                  onTap: onSort,
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
              header ? 'Imported' : imported,
              color: const Color(0xff999999),
            ),
          ),
          Expanded(
            child: cell(
              header ? 'Last changed' : changed,
              color: const Color(0xff999999),
            ),
          ),
        ],
        Expanded(
          child: header
              ? cell('Labels')
              : Row(
                  children: [
                    Expanded(child: cell(labels)),
                    IconButton(
                      tooltip: 'Edit labels',
                      onPressed: onEditLabels,
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
                        onPressed: onIndex,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: IconButton(
                        tooltip: 'Delete source',
                        onPressed: onDelete,
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
}

class SourceRow extends StatelessWidget {
  final SourceSummary source;
  final Widget cells;
  final VoidCallback onOpen;
  const SourceRow({
    super.key,
    required this.source,
    required this.cells,
    required this.onOpen,
  });
  @override
  Widget build(BuildContext context) {
    final showState = source.state != 'indexed' || source.error != '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: DesktopVisuals.sourceRowPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cells,
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
}

class SourceCard extends StatelessWidget {
  final SourceSummary s;
  final IconData icon;
  final Color color;
  final String labels;
  final VoidCallback onOpen;
  final VoidCallback? onEditLabels, onIndex, onDelete;
  const SourceCard({
    super.key,
    required this.s,
    required this.icon,
    required this.color,
    required this.labels,
    required this.onOpen,
    this.onEditLabels,
    this.onIndex,
    this.onDelete,
  });
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: color),
    title: Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
    subtitle: Text(
      '${s.state}${labels.isEmpty ? '' : ' · $labels'}${s.error == '' ? '' : ' · ${s.error}'}',
    ),
    onTap: onOpen,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Edit labels',
          onPressed: onEditLabels,
          icon: const Icon(Icons.label_outline, size: 18),
        ),
        IconButton(
          tooltip: 'Index / retry',
          onPressed: onIndex,
          icon: const Icon(Icons.refresh, size: 20),
        ),
        IconButton(
          tooltip: 'Delete source',
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, size: 20),
        ),
      ],
    ),
  );
}
