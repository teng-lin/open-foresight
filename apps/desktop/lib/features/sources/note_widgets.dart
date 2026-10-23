part of 'sources_controller.dart';

extension _NoteWidgets on SourcesController {
  Future<void> _featureOpenNote(NoteSummary note) async {
    final owner = _noteLoadOwner = FeatureRequestIdentity.capture(d);
    final generation = ++noteEditorGeneration;
    setState(() {
      newNoteKey.reset();
      noteId = note.id;
      noteLoading = true;
      noteTitle.text = note.title;
      noteBody.clear();
      noteBaseline = (note.title, '');
    });
    final draftRevision = _noteDraftRevision;
    bool current() =>
        owner.isCurrent(d, alive: mounted) &&
        generation == noteEditorGeneration &&
        noteId == note.id;
    try {
      final body = await d.store.read(StoreReadQueries.noteBody(note.id));
      if (!current()) return;
      if (body.error != null) throw body.error!;
      if (!body.current) {
        throw RpcError(
          RpcErrorCode.unavailable,
          'Note is refreshing; try again.',
        );
      }
      setState(() {
        final savedBody = body.value ?? '';
        if (_noteDraftRevision == draftRevision) noteBody.text = savedBody;
        noteBaseline = (note.title, savedBody);
      });
    } catch (_) {
      if (current()) rethrow;
    } finally {
      if (current()) setState(() => noteLoading = false);
    }
  }

  void _featureShowSource(String id) {
    final owner = FeatureRequestIdentity.capture(d);
    unawaited(
      sourceById(id).catchError((Object error) {
        if (owner.isCurrent(d, alive: mounted))
          _operations.reportAsyncError(error);
        return false;
      }),
    );
  }

  Widget _featureNotes() => Row(
    children: [
      SizedBox(
        width: 260,
        child: Column(
          children: [
            if (_reads.problem != null) Text(_reads.problem!),
            FilledButton(
              onPressed: () {
                setState(() {
                  noteEditorGeneration++;
                  noteId = null;
                  noteLoading = false;
                  noteBaseline = ('', '');
                  newNoteKey.reset();
                  noteTitle.clear();
                  noteBody.clear();
                });
              },
              child: const Text('New note'),
            ),
            Expanded(
              child: ListView(
                children: _reads.notes
                    .map(
                      (n) => ListTile(
                        title: Text(n.title),
                        subtitle: Text('Revision ${n.revision}'),
                        onTap: () => unawaited(
                          openNote(n).catchError(_operations.reportAsyncError),
                        ),
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
              controller: noteTitle,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            Expanded(
              child: TextField(
                controller: noteBody,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'Your editable note',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            FilledButton(
              onPressed: noteLoading
                  ? null
                  : () => _operations.run(() async {
                      // Every send names the workspace this save began in, and a
                      // reply that arrives after a reset is not shown: it names an
                      // ID the views have dropped.
                      final epoch = d.workspaceEpoch;
                      final identity = FeatureRequestIdentity.capture(d);
                      var originalId = noteId;
                      final editorGeneration = noteEditorGeneration;
                      bool current() =>
                          identity.isCurrent(d, alive: mounted) &&
                          noteId == originalId &&
                          noteEditorGeneration == editorGeneration;
                      Map<String, dynamic> scoped(Map<String, dynamic> args) =>
                          {
                            ...args,
                            if (epoch != null) 'workspace_epoch': epoch,
                          };
                      final note = {
                        'title': noteTitle.text,
                        'body': noteBody.text,
                      };
                      void saved(int id) => setState(() {
                        noteId = id;
                        noteBaseline = (note['title']!, note['body']!);
                      });
                      final id = noteId;
                      if (id != null) {
                        await d.command(
                          Operation.notesSave,
                          scoped({...note, 'id': id}),
                        );
                        if (current()) saved(id);
                        return;
                      }
                      final created =
                          await newNoteKey.run(
                                note,
                                (keyed) => d.command(
                                  Operation.notesSave,
                                  scoped(keyed),
                                ),
                                // Edited after an unconfirmed save: the first save
                                // is now known, so the edit updates that note.
                                amend: (first, edited) async {
                                  final id = (first as Map)['id'] as int;
                                  if (current()) {
                                    setState(() {
                                      originalId = id;
                                      noteId = id;
                                    });
                                  }
                                  return d.command(
                                    Operation.notesSave,
                                    scoped({...edited, 'id': id}),
                                  );
                                },
                              )
                              as Map;
                      if (current()) saved(created['id'] as int);
                    }),
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    ],
  );
}
