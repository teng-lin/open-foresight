part of 'sources_controller.dart';

extension _SourceActions on SourcesController {
  Future<void> _featureImportFolderPath(String path) => importDirectory(path);

  Future<void> _featureFindLocalFiles({List<String>? roots}) =>
      findFilesOnComputer(roots: roots);

  Future<void> _featureRefreshSources() => reimport();

  Future<void> _featureImportSourceUrl(String address) =>
      importAddress(address);

  Future<void> _featureImport() async {
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

  Future<void> _featureSource(Map<String, Object?> row) async {
    await sourceById(
      row['id'] as String,
      expectedRevision: row['revision'] as int?,
    );
  }

  Future<bool> _featureSourceById(String id, {int? expectedRevision}) async {
    final owner = FeatureRequestIdentity.capture(d);
    final dialogContext = context;
    final result = await d.store.read(StoreReadQueries.source(id));
    if (!owner.isCurrent(d, alive: mounted)) return false;
    if (result.error != null) throw result.error!;
    if (!result.current) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Source is refreshing; try again.',
      );
    }
    final source = result.value;
    if (source == null ||
        source.deleted ||
        (expectedRevision != null && source.revision != expectedRevision)) {
      return false;
    }
    if (!dialogContext.mounted) return false;
    await showDialog<void>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text('${source.title} · revision ${source.revision}'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(child: SelectableText(source.content)),
        ),
        actions: [
          TextButton(
            onPressed: _operations.busy
                ? null
                : () {
                    Navigator.pop(context);
                    unawaited(
                      editSource({
                        'id': source.id,
                        'title': source.title,
                        'content': source.content,
                        'mime': source.mime,
                        'provenance': source.provenance,
                        'revision': source.revision,
                      }).catchError(_operations.reportAsyncError),
                    );
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
    return true;
  }

  Future<void> _featureEditSource(Map<String, Object?> s) async {
    // The source ID belongs to the workspace of the rows on screen.
    if (!_dialogs.rowsAreCurrent()) return;
    final epoch = d.workspaceEpoch;
    final text = TextEditingController(text: s['content'] as String);
    final saved = await _dialogs.showInputDialog<bool>(
      builder: (context) => ServiceEditDialog(
        title: 'Edit ${s['title']}',
        controller: text,
        height: 400,
        saveLabel: 'Save and index',
        onSave: () async {
          await sourcesImportDescriptor.send(
            d,
            SourcesImportInput(
              title: s['title'] as String,
              text: text.text,
              mime: WireField(s['mime'] as String?),
              provenance: WireField(s['provenance'] as String?),
              id: WireField(s['id'] as String?),
              locallyEdited: WireField(true),
              index: WireField(false),
              envelope: ClientEnvelope(
                workspaceEpoch: epoch != null
                    ? WireField(epoch)
                    : const WireField.absent(),
              ),
            ),
          );
          await d.index(s['id'] as String);
        },
      ),
    );
    if (saved == true && mounted) setState(() {});
    text.dispose();
  }

  Future<void> _featureImportPath(String path) async {
    await sourcesImportFileDescriptor.send(
      d,
      SourcesImportFileInput(path: path),
    );
    if (mounted) update(() {});
  }

  Future<void> _featureFindFilesOnComputer({List<String>? roots}) async {
    final excluded = <String>{};
    for (final row in _reads.sources) {
      final uri = Uri.tryParse(row.sourceUri ?? '');
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
            LocalFileDiscovery.defaultFolders(
              _host.environment.homeDirectory ??
                  _host.environment.dataDirectory,
            ),
        excludedPaths: excluded,
        pickFolder: () => getDirectoryPath(),
      ),
    );
    if (!mounted || selected == null) return;
    await importSelectedPaths(selected);
  }

  Future<void> _featureImportSelectedPaths(List<String> selected) async {
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

  Future<void> _featureImportFolder() async {
    final path = await getDirectoryPath();
    if (!mounted || path == null) return;
    await reviewFolderImport(path);
  }

  Future<void> _featureReviewFolderImport(String path) async {
    final selected = await _dialogs.showInputDialog<List<String>>(
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

  Future<void> _featureImportDirectory(String path) async {
    await sourcesImportDirectoryDescriptor.send(
      d,
      SourcesImportDirectoryInput(path: path),
    );
  }

  Future<void> _featureReimport() async {
    await sourcesRefreshDescriptor.send(d, SourcesRefreshInput());
  }

  Future<void> _featureImportUrl() async {
    final input = TextEditingController();
    var allowPrivateNetwork = false;
    final accepted = await _dialogs.showInputDialog<bool>(
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

  Future<void> _featureImportAddress(
    String value, {
    bool allowPrivateNetwork = false,
  }) async {
    await sourcesImportUrlDescriptor.send(
      d,
      SourcesImportUrlInput(
        url: value,
        allowPrivateNetwork: allowPrivateNetwork
            ? WireField(true)
            : const WireField.absent(),
      ),
    );
  }
}
