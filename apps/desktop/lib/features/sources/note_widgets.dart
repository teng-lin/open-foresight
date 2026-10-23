part of 'sources_controller.dart';

extension _NoteWidgets on SourcesController {
  Future<void> _featureOpenNote(NoteSummary note) => _loadNoteBody(
    note.id,
    note.title,
    resetEditor: noteId != note.id || noteBodyReady,
  );

  Future<void> _loadNoteBody(
    int id,
    String title, {
    required bool resetEditor,
  }) async {
    if (!mounted) return;
    final owner = _noteLoadOwner = FeatureRequestIdentity.capture(d);
    final generation = ++noteEditorGeneration;
    final preserveBody =
        !resetEditor && _noteDraftRevision != _noteBodyLoadRevision;
    setState(() {
      newNoteKey.reset();
      noteId = id;
      noteLoading = true;
      _acceptedNoteBody = null;
      _noteLoadError = '';
      if (resetEditor) {
        noteTitle.text = title;
        noteBody.clear();
        noteBaseline = (title, '');
        _noteBodyLoadRevision = _noteDraftRevision;
      }
    });
    final draftRevision = _noteDraftRevision;
    bool current() =>
        owner.isCurrent(d, alive: mounted) &&
        generation == noteEditorGeneration &&
        noteId == id;
    try {
      final body = await d.store.read(StoreReadQueries.noteBody(id));
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
        if (!preserveBody && _noteDraftRevision == draftRevision) {
          noteBody.text = savedBody;
          _noteBodyLoadRevision = _noteDraftRevision;
        }
        noteBaseline = (title, savedBody);
        _acceptedNoteBody = (id, generation);
      });
    } catch (failure) {
      if (current()) {
        setState(() => _noteLoadError = failure.toString());
        rethrow;
      }
    } finally {
      // Settlement releases this editor's loading state even if its owner was
      // retired. The body remains unaccepted; a newer selection/load owns its
      // own loading flag and is never cleared by this completion.
      if (mounted && generation == noteEditorGeneration && noteId == id)
        setState(() => noteLoading = false);
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
                  _acceptedNoteBody = null;
                  _noteLoadError = '';
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
            _noteLoadStatus(),
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
              onPressed: noteLoading || !noteBodyReady
                  ? null
                  : () {
                      // A callback built before a session/epoch replacement must
                      // not treat its accepted body as current after replacement.
                      if (!mounted || noteLoading || !noteBodyReady) return;
                      unawaited(
                        _operations.run(() async {
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
                          Map<String, dynamic> scoped(
                            Map<String, dynamic> args,
                          ) => {
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
                            _acceptedNoteBody = (id, noteEditorGeneration);
                            _noteLoadOwner = identity;
                            _noteLoadError = '';
                            if (noteBody.text == note['body'])
                              _noteBodyLoadRevision = _noteDraftRevision;
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
                      );
                    },
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _noteLoadStatus() {
    final id = noteId;
    if (id == null || noteLoading || noteBodyReady)
      return const SizedBox.shrink();
    final current = _noteLoadOwner?.isCurrent(d, alive: mounted) ?? false;
    return ListTile(
      title: Text(
        current && _noteLoadError.isNotEmpty
            ? _noteLoadError
            : 'Reload this note before saving.',
      ),
      trailing: TextButton(
        onPressed: () {
          if (!mounted || noteId != id || noteLoading || noteBodyReady) return;
          unawaited(
            _loadNoteBody(
              id,
              noteBaseline.$1,
              resetEditor: false,
            ).catchError(_operations.reportAsyncError),
          );
        },
        child: const Text('Retry loading note'),
      ),
    );
  }
}
