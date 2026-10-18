import 'package:foresight_core/remote.dart' show ConnectedSources;
import 'package:flutter/material.dart';
import 'google_connections.dart';

class GoogleDrivePicker extends StatefulWidget {
  final ConnectedSources connection;
  final bool folder;
  const GoogleDrivePicker(this.connection, {super.key, this.folder = false});
  @override
  State<GoogleDrivePicker> createState() => _GoogleDrivePickerState();
}

class _GoogleDrivePickerState extends State<GoogleDrivePicker> {
  final search = TextEditingController();
  final selected = <String>{}, parents = <String>[];
  List<Map<String, dynamic>> files = [];
  bool loading = true;
  String error = '';
  int generation = 0;
  String? get parent =>
      parents.isEmpty ? (widget.folder ? 'root' : null) : parents.last;
  @override
  void initState() {
    super.initState();
    // This task catches failures and publishes them in the view state.
    // ignore: discarded_futures
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final request = ++generation;
    setState(() {
      files = [];
      loading = true;
      error = '';
    });
    try {
      final result = await widget.connection.driveFiles(
        parent: parent,
        query: search.text,
      );
      if (mounted && request == generation) setState(() => files = result);
    } catch (failure) {
      if (mounted && request == generation)
        setState(
          () => error = failure is StateError
              ? failure.message.toString()
              : failure.toString(),
        );
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.folder ? 'Import a Drive folder' : 'Add files from Drive',
    ),
    content: SizedBox(
      width: 720,
      height: 480,
      child: Column(
        children: [
          Row(
            children: [
              if (parents.isNotEmpty)
                IconButton(
                  tooltip: 'Parent folder',
                  onPressed: loading
                      ? null
                      : () {
                          parents.removeLast();
                          // This task catches failures and publishes them in the view state.
                          // ignore: discarded_futures
                          load();
                        },
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: TextField(
                  controller: search,
                  onSubmitted: (_) => load(),
                  decoration: const InputDecoration(
                    hintText: 'Search files in Google Drive',
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Search Drive',
                onPressed: loading ? null : load,
                icon: const Icon(Icons.search),
              ),
            ],
          ),
          if (loading) const LinearProgressIndicator(),
          if (error.isNotEmpty)
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Text(error, style: const TextStyle(color: Colors.red)),
                    TextButton(onPressed: load, child: const Text('Try again')),
                  ],
                ),
              ),
            ),
          if (!loading && error.isEmpty && files.isEmpty)
            const Expanded(child: Center(child: Text('No matching files.'))),
          if (error.isEmpty && (loading || files.isNotEmpty))
            Expanded(
              child: ListView(
                children: files.map((file) {
                  final folder =
                      file['mimeType'] == 'application/vnd.google-apps.folder';
                  final supported = GoogleConnections.supported(
                    file['mimeType'] as String,
                  );
                  return ListTile(
                    leading: folder
                        ? const Icon(Icons.folder_outlined)
                        : Checkbox(
                            value: selected.contains(file['id']),
                            onChanged: loading || widget.folder || !supported
                                ? null
                                : (checked) => setState(() {
                                    if (checked == true) {
                                      selected.add(file['id'] as String);
                                    } else {
                                      selected.remove(file['id']);
                                    }
                                  }),
                          ),
                    title: Text(file['name'] as String),
                    subtitle: Text(
                      folder
                          ? 'Folder'
                          : supported
                          ? file['mimeType'] as String
                          : 'Unsupported file type',
                    ),
                    trailing: folder ? const Icon(Icons.chevron_right) : null,
                    onTap: loading
                        ? null
                        : folder
                        ? () {
                            parents.add(file['id'] as String);
                            search.clear();
                            // This task catches failures and publishes them in the view state.
                            // ignore: discarded_futures
                            load();
                          }
                        : widget.folder || !supported
                        ? null
                        : () => setState(() {
                            if (!selected.add(file['id'] as String))
                              selected.remove(file['id']);
                          }),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            loading || error.isNotEmpty || !widget.folder && selected.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                widget.folder ? [parent!] : selected.toList(),
              ),
        child: Text(
          widget.folder
              ? 'Import this folder'
              : 'Import ${selected.length} files',
        ),
      ),
    ],
  );
}
