import 'package:flutter/material.dart';
import 'google_connections.dart';

class GoogleDrivePicker extends StatefulWidget {
  final GoogleConnections connection;
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
  String? get parent =>
      parents.isEmpty ? (widget.folder ? 'root' : null) : parents.last;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await widget.connection.driveFiles(
        parent: parent,
        query: search.text,
      );
      if (mounted) setState(() => files = result);
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => loading = false);
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
            Text(error, style: const TextStyle(color: Colors.red)),
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
