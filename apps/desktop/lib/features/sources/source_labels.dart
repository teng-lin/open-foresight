part of 'sources_controller.dart';

extension _SourceLabels on SourcesController {
  List<String> _featureSourceLabels(SourceSummary s) => s.labels;

  Future<void> _featurePutDocumentLabel(DocumentLabel label) async {
    await d.command(Operation.labelsPut, {
      'id': label.documentId,
      'name': label.name,
      'source': label.source,
      'color': label.colorHex,
      'rationale': label.rationale,
    });
  }

  Future<bool> _featureSaveGraphLayout(
    String identity,
    List<SourceSummary> sources,
    Map<String, List<double>> vectors,
    Map<String, GraphPoint> points, {
    String? labelSet,
    List<GraphCluster> clusters = const [],
  }) async {
    return await d.command(Operation.graphSave, {
          'identity': identity,
          'sources': graphSourceArguments(sources),
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

  Future<void> _featureAddSelectedGraphLabel(String id, String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    await putDocumentLabel(
      DocumentLabel(
        id,
        name,
        'user_defined',
        allocateGraphLabelColor(name, _reads.labels),
      ),
    );
    graphLabelInput.clear();
    await autoAssignOrganizationLabel(name);
  }

  Future<void> _featureRemoveSelectedGraphLabel(String id, String name) async {
    final source = _reads.sources.where((row) => row.id == id).single;
    await d.command(Operation.labelsSet, {
      'id': id,
      'labels': sourceLabels(source).where((label) => label != name).toList(),
    });
    await d.command(Operation.graphAcknowledge);
    if (mounted) update(() {});
  }

  Future<void> _featureCreateOrganizationLabel() async {
    final input = TextEditingController();
    final name = await _dialogs.showInputDialog<String>(
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
      await _operations.run(() => autoAssignOrganizationLabel(name));
  }

  Future<void> _featureAutoAssignOrganizationLabel(String name) async {
    await d.command(Operation.labelsAutoAssign, {'name': name});
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

  Future<void> _featureDeleteOrganizationLabel(String name) async {
    final confirmed = await _dialogs.showInputDialog<bool>(
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
        update(() {
          if (labelFilter == name) labelFilter = '';
        });
    }
  }

  Future<void> _featureEditLabels(SourceSummary? s) async {
    // The sources belong to the workspace of the rows on screen.
    if (!_dialogs.rowsAreCurrent()) return;
    final epoch = d.workspaceEpoch;
    final input = TextEditingController(
      text: s == null ? '' : sourceLabels(s).join(', '),
    );
    final ok = await _dialogs.showInputDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text(s == null ? 'Add label to sources' : 'Labels · ${s.title}'),
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
        'id': row.id,
        'labels': s == null
            ? {...sourceLabels(row), ...values}.toList()
            : values,
        if (epoch != null) 'workspace_epoch': epoch,
      });
    }
    if (mounted) update(() {});
  }
}
