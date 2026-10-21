import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

class FileDiscoverySheet extends StatefulWidget {
  final List<String> initialFolders;
  final Set<String> excludedPaths;
  final Future<String?> Function() pickFolder;
  final bool folderImport;
  const FileDiscoverySheet({
    super.key,
    required this.initialFolders,
    required this.excludedPaths,
    required this.pickFolder,
    this.folderImport = false,
  });
  @override
  State<FileDiscoverySheet> createState() => _FileDiscoverySheetState();
}

class _FileDiscoverySheetState extends State<FileDiscoverySheet> {
  late final folders = widget.initialFolders.toSet();
  final selected = <String>{};
  LocalFileDiscovery? scanner;
  LocalFileScan? result;
  bool scanning = false;
  int examined = 0, found = 0, generation = 0;
  String query = '', error = '';
  @override
  void initState() {
    super.initState();
    // This task catches failures and publishes them in the view state.
    // ignore: discarded_futures
    if (folders.isNotEmpty) scan();
  }

  @override
  void dispose() {
    scanner?.cancel();
    super.dispose();
  }

  Future<void> scan() async {
    scanner?.cancel();
    final token = ++generation;
    final current = LocalFileDiscovery();
    scanner = current;
    setState(() {
      scanning = true;
      result = null;
      selected.clear();
      error = '';
      examined = found = 0;
    });
    try {
      final next = await current.scan(
        folders.toList(),
        excludedPaths: widget.excludedPaths,
        progress: (count, total) {
          if (mounted && token == generation)
            setState(() {
              examined = count;
              found = total;
            });
        },
      );
      if (mounted && token == generation)
        setState(() {
          result = next;
          if (widget.folderImport)
            selected.addAll(next.files.map((file) => file.path));
          scanning = false;
        });
    } catch (e) {
      if (mounted && token == generation)
        setState(() {
          error = e.toString();
          scanning = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = (result?.files ?? <DiscoveredLocalFile>[])
        .where((f) => f.path.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: Text(
        widget.folderImport
            ? 'Review folder import'
            : 'Find files on this computer',
      ),
      content: SizedBox(
        width: 700,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (widget.folderImport) ...folders.map(Text.new),
                if (!widget.folderImport)
                  for (final folder in folders)
                    InputChip(
                      label: Text(folder),
                      onDeleted: () {
                        setState(() => folders.remove(folder));
                        // This task catches failures and publishes them in the view state.
                        // ignore: discarded_futures
                        scan();
                      },
                    ),
                if (!widget.folderImport)
                  ActionChip(
                    label: const Text('Add folder'),
                    avatar: const Icon(Icons.add, size: 18),
                    onPressed: () async {
                      final folder = await widget.pickFolder();
                      if (folder != null && mounted) {
                        setState(() => folders.add(folder));
                        await scan();
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search file names…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 12),
            if (scanning) ...[
              const LinearProgressIndicator(),
              Text('Scanning: $examined entries, $found supported files'),
            ] else if (result != null)
              Text(
                '${result!.files.length} files found · ${result!.alreadyImported} already imported',
              ),
            if (result?.truncated == true)
              const Text(
                'Scan limit reached. Choose a smaller folder to find more files.',
              ),
            if (result?.unavailableFolders.isNotEmpty == true)
              Text(
                '${result!.unavailableFolders.length} folders could not be read.',
              ),
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: Colors.red)),
            if (!scanning && visible.isNotEmpty)
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(
                      () => selected.addAll(visible.map((f) => f.path)),
                    ),
                    child: const Text('Select all shown'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => selected.clear()),
                    child: const Text('Clear selection'),
                  ),
                  Text('${selected.length} selected'),
                ],
              ),
            Expanded(
              child: scanning
                  ? const SizedBox.shrink()
                  : visible.isEmpty
                  ? Center(
                      child: Text(
                        folders.isEmpty
                            ? 'Choose a folder to find local files.'
                            : 'No matching new files.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final file = visible[index];
                        return CheckboxListTile(
                          value: selected.contains(file.path),
                          onChanged: (value) => setState(() {
                            if (value == true)
                              selected.add(file.path);
                            else
                              selected.remove(file.path);
                          }),
                          title: Text(file.name),
                          subtitle: Text('${file.path}\n${file.bytes} bytes'),
                          isThreeLine: true,
                        );
                      },
                    ),
            ),
            const Text(
              'Find supported local files in chosen folders. File contents are read only when imported.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            scanner?.cancel();
            generation++;
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: scanning || selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected.toList()),
          child: Text('Import selected (${selected.length})'),
        ),
      ],
    );
  }
}
