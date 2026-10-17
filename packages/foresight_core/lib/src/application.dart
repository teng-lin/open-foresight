import 'audio_devices.dart';
import 'agent_access.dart';
import 'web_import.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'domain.dart';
import 'recording.dart';
import 'meeting_speakers.dart';
import 'proactive_questions.dart';
import 'reference_query_detector.dart';
import 'dedicated_query_runtime.dart';
import 'encrypted_query_runtime.dart';
import 'dedicated_query_acquisition.dart';
import 'store.dart';
import 'graph_labels.dart';
import 'graph_layout.dart';
import 'graph_clusters.dart';
import 'graph_persistence.dart';
import 'model_setup.dart';
import 'speech_models.dart';
import 'reference_note_enhancement.dart';
import 'reference_note_enhancer.dart';
import 'reference_note_edit_mapping.dart';
import 'reference_note_live_plan.dart';
import 'reference_note_service_recovery.dart';
import 'native.dart';
import 'reference_note_transcript_cache.dart';
import 'reference_note_transcript_format.dart';
import 'reference_note_enhancement_chunking.dart';
import 'native_note_enhancement.dart';
import 'google_auth.dart';
import 'google_connections.dart';
import 'generated/rag_service.pb.dart';
import 'package:grpc/grpc.dart';

/// Application operations shared by the desktop and external clients.
/// This object, its database, and its capture/model handles belong to one owner.
class Application {
  final Domain domain;
  ImportPolicy? importPolicy;
  Store get store => domain.store;
  final changes = StreamController<void>.broadcast();
  Recording? recording;
  int? recordingMeeting;
  DateTime? recordingBegan;
  DateTime? _recordingPausedAt;
  int _recordingPausedMs = 0;
  String recordingState = '';
  final provisionalTranscript = <String, String>{};
  Timer? _liveIndex, _inactivity;
  final _enhance = <int, Timer>{};
  final _noteEnhancements = <int, _NoteEnhancement>{};
  final _noteEditMappings = <int, ReferenceNoteEditMapping>{};
  final _pendingNoteTargets = <int, Set<int>>{};
  late final ReferenceNoteTranscriptCache _noteTranscriptCache =
      ReferenceNoteTranscriptCache(
        computeEmbedding: _computeNoteEmbedding,
        currentIsLive: (id) => recordingMeeting == id && recording != null,
        loadSavedTranscript: (id) async => _noteTranscriptText(id),
      );

  Future<List<double>> _computeNoteEmbedding(String text) async {
    if (domain.helper.snapshot?.pipeline != 'ready') return [];
    final response = await domain.helper.client.computeEmbedding(
      ComputeEmbeddingRequest(text: text),
    );
    return response.embedding.toList();
  }

  String _noteTranscriptText(int id) => store
      .rows(
        'SELECT text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
        [id],
      )
      .map((row) => extractSavedTranscriptText(row['text'] as String).trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  Iterable<({String speaker, String text})> _liveNoteTranscriptSegments(
    int id,
  ) => store
      .rows(
        'SELECT text,source FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
        [id],
      )
      .map((row) {
        final speaker = MeetingSpeaker.fromSource(row['source'] as String);
        return (
          speaker: speaker == MeetingSpeaker.unknown ? '' : speaker.label,
          text: row['text'] as String,
        );
      });

  void _scheduleLiveNoteTranscriptEmbedding(int id) {
    if (_closed || recordingMeeting != id || recording == null) return;
    final text = formatLiveNoteTranscript(_liveNoteTranscriptSegments(id));
    if (text.isEmpty) return;
    unawaited(
      _noteTranscriptCache.schedule(id, text, isLive: true).catchError((
        Object e,
      ) {
        stderr.writeln('Live transcript embedding: $e');
      }),
    );
  }

  Future<List<EmbeddedNoteTranscriptChunk>> _embeddedNoteTranscript(
    int id,
    String transcript, {
    required bool isLive,
  }) async {
    if (isLive && recordingMeeting == id && recording != null) {
      final text = formatLiveNoteTranscript(_liveNoteTranscriptSegments(id));
      if (text.isNotEmpty) {
        await _noteTranscriptCache.schedule(id, text, isLive: true);
      }
    }
    final cached = await _noteTranscriptCache.getEmbeddedChunks(id);
    if (cached.isNotEmpty) return cached;
    final chunks = <EmbeddedNoteTranscriptChunk>[];
    for (final text in chunkNoteEnhancementTranscript(
      transcript,
      isLive: isLive,
    )) {
      chunks.add((text: text, embedding: await _computeNoteEmbedding(text)));
    }
    return chunks;
  }

  String _currentEnhancedNotes(int id) {
    final pending = _noteEnhancements[id];
    return pending != null && !pending.active && pending.status.isEmpty
        ? pending.body
        : store.meetingEnhancedNotes(id);
  }

  ReferenceNoteEditMapping _noteEditMapping(int id) =>
      _noteEditMappings.putIfAbsent(
        id,
        () => ReferenceNoteEditMapping.fromNotes(
          notes:
              store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
                    id,
                  ]).firstOrNull?['body']
                  as String? ??
              '',
          enhancedNotes: _currentEnhancedNotes(id),
        ),
      );

  void _restoreNoteMapping(int id, String notes, String enhancedNotes) {
    final mapping = _noteEditMapping(id);
    final restored = ReferenceNoteEditMapping.fromNotes(
      notes: notes,
      enhancedNotes: enhancedNotes,
    );
    mapping.accepted
      ..clear()
      ..addAll(restored.accepted);
    mapping.pairs
      ..clear()
      ..addAll(restored.pairs);
  }

  void _shorthandEdited(int id, String notes, String previousEnhanced) {
    if (_noteEnhancements[id]?.active == true) return;
    final mapping = _noteEditMapping(id);
    final replacement = mapping.syncShorthand(
      notes: notes,
      enhancedNotes: previousEnhanced,
    );
    if (replacement != null) {
      _noteEnhancements[id]?.saveTimer?.cancel();
      final draft = _NoteEnhancement(
        'note-edit-' + (++_noteEnhancementSerial).toString(),
        replacement,
      )..active = false;
      _noteEnhancements[id] = draft;
      _scheduleEnhancedDraft(id, draft);
    }
    mapping.updateStaleBullets(
      notes: notes,
      enhancedNotes: replacement ?? previousEnhanced,
    );
  }

  int _noteEnhancementSerial = 0;
  Future<void>? _stopping;
  bool _closed = false;
  bool _clearingWorkspace = false;
  bool _modelBusy = false;
  final _proactivePreparation = <String, Completer<void>>{};
  bool get modelBusy => _modelBusy || domain.restoring;
  late final ProactiveQuestions proactive = ProactiveQuestions(
    store: store,
    busy: () =>
        modelBusy ||
        domain.generator == null ||
        domain.generator!.generating ||
        domain.sourcesPaused,
    changed: changed,
    cancel: (request) {
      final preparation = _proactivePreparation[request];
      if (preparation != null && !preparation.isCompleted)
        preparation.complete();
      _queryRuntime?.cancel(request);
      domain.generator?.cancel(requestId: request);
    },
    detect: _detectQuestions,
    answer: (id, question, request) async {
      // Cancelling automatic work must not wait behind another client's index
      // request, or cancel that shared work. Only stop this answer's preparation.
      final cancelled = Completer<void>();
      _proactivePreparation[request] = cancelled;
      try {
        await Future.any<void>([
          indexMeeting(id),
          cancelled.future.then(
            (_) => throw StateError('Automatic answer cancelled'),
          ),
        ]);
        if (cancelled.isCompleted)
          throw StateError('Automatic answer cancelled');
        await Future.any<void>([
          domain
              .askInConversation(
                question,
                'meeting:$id',
                meetingId: id,
                requestId: request,
                current: () => !cancelled.isCompleted,
              )
              .drain<void>(),
          cancelled.future.then(
            (_) => throw StateError('Automatic answer cancelled'),
          ),
        ]);
        if (cancelled.isCompleted)
          throw StateError('Automatic answer cancelled');
        final saved = store.rows(
          'SELECT id FROM answers WHERE request_id=? ORDER BY id DESC LIMIT 1',
          [request],
        ).firstOrNull;
        if (saved == null) throw StateError('No answer was saved');
        return saved['id'] as int;
      } finally {
        _proactivePreparation.remove(request);
      }
    },
  );
  final GoogleAuth? _auth;
  QueryCompletionRuntime? _queryRuntime;
  DedicatedQueryAcquisition? _queryAcquisition;
  int _queryDownloadReceived = 0, _queryDownloadTotal = 0;
  String? _queryRegistration;
  final bool _providedQueryRuntime;

  Application(
    this.domain, {
    GoogleAuth? auth,
    QueryCompletionRuntime? queryRuntime,
  }) : _auth = auth,
       _queryRuntime = queryRuntime,
       _providedQueryRuntime = queryRuntime != null;

  Future<List<String>> _detectQuestions(String text, String request) async {
    if (!_providedQueryRuntime) {
      if (store.model(dedicatedQueryModelKind) == null) {
        await discoverDedicatedQueryModel(store, current: () => !_closed);
      }
      final model = store.model(dedicatedQueryModelKind);
      final worker = runtimeConfiguration['FORESIGHT_QUERY_WORKER'];
      if (model == null ||
          worker == null ||
          (model['backend'] != dedicatedQueryBackend &&
              model['backend'] != dedicatedEncryptedQueryBackend)) {
        await _queryRuntime?.close();
        _queryRuntime = null;
        _queryRegistration = null;
        throw StateError(
          'Dedicated question detector is not ready: register its model and runtime',
        );
      }
      final registration = jsonEncode([
        model['path'],
        model['digest'],
        model['runtime'],
        model['backend'],
        worker,
      ]);
      if (_queryRegistration != registration) {
        await _queryRuntime?.close();
        _queryRuntime = model['backend'] == dedicatedEncryptedQueryBackend
            ? EncryptedDedicatedQueryRuntime(
                python: model['runtime'] as String,
                worker: worker,
                encryptedModel: model['path'] as String,
                vaultRoot: File(model['path'] as String).parent,
              )
            : DedicatedQueryRuntime(
                python: model['runtime'] as String,
                worker: worker,
                model: model['path'] as String,
              );
        _queryRegistration = registration;
      }
    }
    if (!proactive.ownsRequest(request)) {
      throw StateError('Dedicated query detection cancelled');
    }
    return ReferenceQueryDetector(
      _queryRuntime!.complete,
    ).detect(text, request);
  }

  String? _signInOwner;
  late final GoogleAuth googleAuth =
      _auth ?? GoogleAuth(Directory('${File(store.path).parent.path}/google'));
  GoogleConnections? _google;
  GoogleConnections get google =>
      _google ??= GoogleConnections(domain, googleAuth);
  Timer? _googleTimer;
  bool _googleBusy = false;
  Map<String, Object?> get googleState => {
    'connected': googleAuth.connected,
    'syncing': _googleBusy || google.syncing,
    'email': googleAuth.email,
    'account': googleAuth.account,
    'configured': googleAuth.client != null,
    'signingIn': googleAuth.signingIn,
    'loadError': googleAuth.loadError,
    'lastRefresh': google.lastCompletedRefreshMs,
  };
  void startBackground() {
    google;
    proactive.restore();
    _googleTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(maintainGoogle()),
    );
  }

  Future<void> maintainGoogle() async {
    if (_googleBusy || !googleAuth.connected) return;
    _googleBusy = true;
    try {
      await google.reminders(domain.clock.now(), (message) async {
        await platformNotification('Open Foresight', message);
      });
      final hours =
          int.tryParse(store.preference('googleRefreshHours', '4')) ?? 4;
      if (!domain.sourcesPaused &&
          domain.clock.now().millisecondsSinceEpoch -
                  google.lastCompletedRefreshMs >=
              hours * 3600000)
        await google.refresh();
      changed();
    } catch (e) {
      stderr.writeln('Google maintenance: $e');
    } finally {
      _googleBusy = false;
    }
  }

  void changed() {
    if (!_closed) changes.add(null);
  }

  Map<String, dynamic>? get generationState => domain.generator == null
      ? null
      : {
          ...domain.generator!.effectiveState,
          'generating': domain.generator!.generating,
        };
  Map<String, Object?> get captureState => {
    'note_enhancements': {
      for (final entry in _noteEnhancements.entries)
        '${entry.key}': entry.value.state,
    },
    'meeting_id': recordingMeeting,
    'active': recording != null,
    'finishing': recording?.finishing ?? false,
    'paused': recording?.paused ?? false,
    'began': recordingBegan?.millisecondsSinceEpoch,
    'elapsed_ms': recordingBegan == null
        ? 0
        : (_recordingPausedAt ?? domain.clock.now())
                  .difference(recordingBegan!)
                  .inMilliseconds -
              _recordingPausedMs,
    'state': recordingState,
    'samples': recording?.sampleCounts ?? <int>[],
    'peaks': recording?.peakVolumes ?? <double>[],
    'last_audio': recording?.lastAudioActivity.millisecondsSinceEpoch,
    'provisional': Map.of(provisionalTranscript),
    'volumes': recording?.currentVolumes ?? <double>[],
    'proactive': proactive.state,
    'echo_cancellation':
        recording?.echoCancellationState ??
        {
          'requested': store.preference('echoCancellation', 'false') == 'true',
          'active': false,
        },
  };

  Future<Object?> call(
    String method,
    Map<String, dynamic> a, {
    bool Function()? current,
  }) async {
    if (_closed) throw StateError('Application closed');
    if (_clearingWorkspace) throw StateError('Workspace is being cleared');
    final generation = domain.workspaceGeneration;
    final callerCurrent = current;
    current = () =>
        generation == domain.workspaceGeneration &&
        (callerCurrent?.call() ?? true);
    if (!current()) throw StateError('Operation cancelled');
    if (method.startsWith('models.') &&
        method != 'models.cancel_query_acquisition' &&
        (modelBusy ||
            domain.generator?.generating == true ||
            _noteEnhancements.values.any((state) => state.active) ||
            recording != null)) {
      throw StateError(
        'Model configuration is busy while generation or recording is active',
      );
    }
    final modelOperation =
        method.startsWith('models.') &&
        method != 'models.cancel_query_acquisition';
    if (modelOperation) _modelBusy = true;
    try {
      switch (method) {
        case 'notifications.capabilities':
          return await notificationCapabilities();
        case 'notifications.request_permission':
          return await notificationCapabilities(requestPermission: true);
        case 'audio.capabilities':
          return audioCapabilities();
        case 'audio.request_system':
          return await requestSystemAudioPermission();
        case 'audio.request_microphone':
          return await requestMicrophonePermission();
        case 'status':
          return {
            'pid': pid,
            'application_api_version': 1,
            'installation_root': configuredInstallationRoot,
            'runtime_revision':
                runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'],
            'models_busy': modelBusy,
            'query_model_download': {
              'active': _queryAcquisition != null,
              'received': _queryDownloadReceived,
              'total': _queryDownloadTotal,
            },
            'capture': captureState,
            'sources_paused': domain.sourcesPaused,
            'helper': domain.helper.snapshot?.toProto3Json(),
            'helper_state': domain.helper.state,
            'generation': generationState,
            'web_search_available': domain.webSearchAvailable,
            'revision': store.dataRevision,
            'google': googleState,
          };
        case 'sources.list':
          return store.sourceSummaries;
        case 'sources.get':
          return _source(a['id'] as String);
        case 'sources.import':
          final id = store.importText(
            a['title'] as String,
            a['text'] as String,
            a['mime'] as String? ?? 'text/plain',
            a['provenance'] as String? ?? 'mcp',
            id: a['id'] as String?,
            modifiedAtMs: a['modifiedAtMs'] as int?,
            sourceUri: a['sourceUri'] as String?,
          );
          if (a['index'] != false) await domain.index(id);
          return {'id': id};
        case 'sources.import_url':
          return {
            'id': await importUrl(
              a['url'] as String,
              current: current,
              allowPrivateNetwork: a['allow_private_network'] == true,
            ),
          };
        case 'sources.import_directory':
          await importDirectory(a['path'] as String, current: current);
          return null;
        case 'sources.refresh':
          await reimport(
            current: current,
            allowPrivateNetwork: a['allow_private_network'] == true,
          );
          return null;
        case 'sources.import_file':
          return {
            'id': await importFile(a['path'] as String, current: current),
          };
        case 'sources.index':
          await domain.index(a['id'] as String);
          return null;
        case 'sources.delete':
          await domain.delete(a['id'] as String);
          return null;
        case 'sources.pause':
          domain.pauseSources();
          return null;
        case 'sources.resume':
          domain.resumeSources();
          return null;
        case 'sources.search':
          final allowed = {
            for (final source in store.sourceSummaries)
              if (source['state'] == 'indexed')
                source['id'] as String: source['revision'] as int,
          };
          if (allowed.isEmpty) return <Object>[];
          final limit = a['limit'] as int? ?? 10;
          if (limit < 1 || limit > 100)
            throw ArgumentError('limit must be 1–100');
          final result = await domain.helper.client.retrieveContext(
            RetrieveRequest(
              query: Query(textQuery: a['query'] as String),
              maxResults: limit,
              minSimilarityScore: 0,
              userId: 'local_user',
              allowedDocumentIds: allowed.keys,
            ),
          );
          if (!current()) throw StateError('Search cancelled');
          return [
            for (final chunk in result.chunks)
              if (allowed.containsKey(chunk.documentId))
                for (final source in store.rows(
                  "SELECT title,revision FROM sources WHERE id=? AND revision=? AND deleted=0 AND state='indexed'",
                  [chunk.documentId, allowed[chunk.documentId]],
                ))
                  {
                    'id': chunk.documentId,
                    'text': chunk.text,
                    'score': chunk.relevanceScore,
                    'title': source['title'],
                    'revision': source['revision'],
                  },
          ];
        case 'answer':
          return {
            'text':
                await (a['web_search'] == true
                        ? domain.askWithWebInConversation
                        : domain.askInConversation)(
                      a['question'] as String,
                      a['conversation'] as String? ?? 'desktop',
                      meetingId: a['meeting_id'] as int?,
                      requestId: a['requestId'] as String?,
                      current: current,
                    )
                    .last,
          };
        case 'google.status':
          return googleState;
        case 'google.configure':
          await googleAuth.configure(File(a['path'] as String));
          return googleState;
        case 'google.cancel_sign_in':
          googleAuth.cancelSignIn();
          return googleState;
        case 'google.disconnect':
          await googleAuth.disconnect();
          return googleState;
        case 'google.drive_files':
          return google.driveFiles(
            parent: a['parent'] as String?,
            query: a['query'] as String? ?? '',
            modifiedAfter: a['modifiedAfter'] == null
                ? null
                : DateTime.parse(a['modifiedAfter'] as String),
          );
        case 'google.import_file':
          await google.importDriveFile(a['id'] as String);
          return null;
        case 'google.import_folder':
          await google.importDriveFolder(a['id'] as String);
          return null;
        case 'google.import_year':
          await google.importLastYear();
          return null;
        case 'google.refresh':
          await google.refresh();
          return googleState;
        case 'google.calendar':
          await google.syncCalendar();
          return null;
        case 'google.attachments':
          await google.importAttachments(a['id'] as int);
          return null;
        case 'notes.list':
          return store.rows('SELECT * FROM notes ORDER BY id');
        case 'notes.save':
          store.saveNote(
            a['id'] as int?,
            a['title'] as String,
            a['body'] as String,
          );
          return {'id': a['id'] ?? store.db.lastInsertRowId};
        case 'preferences.set':
          if (a['key'] == 'echoCancellation') {
            final enabled = a['value'] == 'true';
            if (enabled && !Platform.isMacOS)
              throw StateError(
                'Native echo cancellation is available on macOS',
              );
            recording?.setEchoCancellation(enabled);
          }
          store.setPreference(a['key'] as String, a['value'] as String);
          if (a['key'] == 'proactiveAnswers') proactive.wake();
          return null;
        case 'meetings.list':
          return store.rows(
            'SELECT m.*,d.created,d.reminder FROM meetings m LEFT JOIN meeting_details d ON d.meeting_id=m.id ORDER BY m.id',
          );
        case 'meetings.create':
          return {'id': store.meeting(a['title'] as String)};
        case 'meetings.get':
          final id = a['id'] as int;
          return {
            'meeting': _meeting(id),
            'notes': store.rows(
              'SELECT * FROM meeting_notes WHERE meeting_id=?',
              [id],
            ),
            'transcript': store
                .rows(
                  'SELECT * FROM transcript WHERE meeting_id=? ORDER BY id',
                  [id],
                )
                .map(
                  (t) => {
                    ...t,
                    'speaker_id': MeetingSpeaker.fromSource(
                      t['source'] as String,
                    ).id,
                    'speaker_label': MeetingSpeaker.fromSource(
                      t['source'] as String,
                    ).label,
                  },
                )
                .toList(),
            'artifacts': store.rows(
              'SELECT * FROM artifacts WHERE meeting_id=? ORDER BY id',
              [id],
            ),
            'questions': store.rows(
              'SELECT * FROM meeting_questions WHERE meeting_id=? ORDER BY id',
              [id],
            ),
          };
        case 'meetings.retry_question':
          proactive.retry(a['id'] as int);
          return null;
        case 'meetings.retry_detection':
          final id = a['id'] as int;
          _meeting(id);
          proactive.notify(id);
          return null;
        case 'meetings.link_answer':
          store.db.execute(
            'INSERT OR IGNORE INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
            [a['id'], a['answer']],
          );
          return null;
        case 'workspace.clear':
          google;
          if (recording != null)
            throw StateError('Stop recording before clearing the workspace');
          for (final timer in _enhance.values) {
            timer.cancel();
          }
          _enhance.clear();
          for (final state in _noteEnhancements.values) {
            state.cancelRequested = true;
            state.saveTimer?.cancel();
          }
          _noteEnhancements.clear();
          _noteEditMappings.clear();
          _pendingNoteTargets.clear();
          _noteTranscriptCache.clear();
          _clearingWorkspace = true;
          final sourceIds = [
            for (final source in store.sources) source['id'] as String,
          ];
          domain.invalidateWorkspace();
          final reset = proactive.reset();
          try {
            store.db.execute('BEGIN IMMEDIATE');
            try {
              for (final table in [
                'google_sources',
                'google_folders',
                'calendar_events',
                'meeting_questions',
                'meeting_question_cursors',
                'meeting_answers',
                'meeting_notes',
                'artifacts',
                'transcript',
                'meeting_details',
                'meetings',
                'answers',
                'conversation_memory',
                'notes',
                'source_details',
                'document_labels',
                'document_clusters',
                'graph_documents',
                'graph_force_state',
                'graph_layouts',
                'sources',
              ]) {
                store.db.execute('DELETE FROM $table');
              }
              store.db.execute('COMMIT');
            } catch (_) {
              store.db.execute('ROLLBACK');
              rethrow;
            }
            domain.cleanupClearedSources(sourceIds);
            google.close();
            _google = null;
            // Local data and credentials are gone before remote cleanup completes.
            unawaited(googleAuth.forget());
          } finally {
            // Wait for cancelled background work before allowing IDs to be reused.
            try {
              await reset;
            } finally {
              _clearingWorkspace = false;
            }
          }
          return null;
        case 'meetings.notes':
          final noteId = a['id'] as int;
          _meeting(noteId);
          final oldNotes = store.rows(
            'SELECT body FROM meeting_notes WHERE meeting_id=?',
            [noteId],
          ).firstOrNull?['body'];
          final previousEnhanced = _currentEnhancedNotes(noteId);
          _noteEditMapping(noteId);
          store.saveMeetingNotes(
            a['id'] as int,
            a['body'] as String,
            lastManualEdit: a['last_manual_edit'] as int?,
          );
          if (oldNotes != a['body']) {
            _shorthandEdited(noteId, a['body'] as String, previousEnhanced);
          }
          if (oldNotes != a['body']) {
            _scheduleNoteEditEnhancement(
              noteId,
              oldNotes as String? ?? '',
              a['body'] as String,
            );
          }
          return null;
        case 'meetings.transcript':
          final id = a['id'] as int;
          _meeting(id);
          store.transcript(
            id,
            a['text'] as String,
            true,
            a['start'] as int? ?? 0,
            a['end'] as int? ?? 0,
            a['source'] as String? ?? 'imported',
          );
          if (recordingMeeting == id && recording != null) {
            _scheduleLiveNoteTranscriptEmbedding(id);
          } else {
            _noteTranscriptCache.invalidate(id);
          }
          await indexMeeting(id);
          return null;
        case 'meetings.index':
          await indexMeeting(a['id'] as int);
          return null;
        case 'meetings.generate':
          await generateMeeting(
            a['id'] as int,
            a['kind'] as String,
            requestId: a['requestId'] as String?,
            current: current,
          );
          return null;
        case 'meetings.enhance':
          await enhanceNotes(
            a['id'] as int,
            forceRegenerate: a['force_regenerate'] == true,
            requestId: a['requestId'] as String?,
            current: current,
          );
          return null;
        case 'meetings.cancel_enhance':
          final enhancement = _noteEnhancements[a['id'] as int];
          if (enhancement == null ||
              !enhancement.active ||
              enhancement.requestId != a['request_id'])
            return false;
          enhancement.cancelRequested = true;
          changed();
          return true;
        case 'meetings.start':
          await startRecording(a['id'] as int);
          return captureState;
        case 'meetings.stop':
          await stopRecording();
          return captureState;
        case 'meetings.pause':
          pauseRecording(a['id'] as int?);
          return captureState;
        case 'meetings.resume':
          resumeRecording(a['id'] as int?);
          return captureState;
        case 'artifacts.edit':
          final selectedBeforeEdit = store.rows(
            "SELECT selected.meeting_id,selected.edited,selected.generated FROM artifacts AS selected WHERE selected.id=? AND selected.kind='enhanced_notes' AND NOT EXISTS (SELECT 1 FROM artifacts AS newer WHERE newer.meeting_id=selected.meeting_id AND newer.kind=selected.kind AND newer.id>selected.id)",
            [a['id']],
          ).firstOrNull;
          if (selectedBeforeEdit != null) {
            _noteEditMapping(selectedBeforeEdit['meeting_id'] as int);
          }
          store.editArtifact(
            a['id'] as int,
            a['text'] as String,
            lastManualEdit: a['last_manual_edit'] as int?,
          );
          final editedEnhancement = store.rows(
            "SELECT selected.meeting_id FROM artifacts AS selected WHERE selected.id=? AND selected.kind='enhanced_notes' AND NOT EXISTS (SELECT 1 FROM artifacts AS newer WHERE newer.meeting_id=selected.meeting_id AND newer.kind=selected.kind AND newer.id>selected.id)",
            [a['id']],
          ).firstOrNull;
          if (editedEnhancement != null) {
            final meeting = editedEnhancement['meeting_id'] as int;
            final enhancement = _noteEnhancements[meeting];
            if (enhancement?.active != true &&
                (selectedBeforeEdit?['edited'] ??
                        selectedBeforeEdit?['generated']) !=
                    a['text']) {
              _noteEditMapping(meeting).updateStaleBullets(
                notes:
                    store.rows(
                          'SELECT body FROM meeting_notes WHERE meeting_id=?',
                          [meeting],
                        ).firstOrNull?['body']
                        as String? ??
                    '',
                enhancedNotes: a['text'] as String,
              );
            }
            if (enhancement != null) {
              enhancement.saveTimer?.cancel();
              enhancement.body = a['text'] as String;
              if (!enhancement.active) _noteEnhancements.remove(meeting);
            }
          }
          return null;
        case 'models.cancel_query_acquisition':
          await _queryAcquisition?.close();
          return null;
        case 'models.acquire_query':
          final acquisition = DedicatedQueryAcquisition.distribution(store);
          _queryAcquisition = acquisition;
          _queryDownloadReceived = _queryDownloadTotal = 0;
          changed();
          try {
            await acquisition.run(
              current: () => !_closed && (current == null || current()),
              onProgress: (received, total) {
                _queryDownloadReceived = received;
                _queryDownloadTotal = total;
                changed();
              },
            );
          } finally {
            _queryAcquisition = null;
            changed();
          }
          return null;
        case 'models.speech':
          await configureSpeech(
            store,
            File(a['path'] as String),
            a['runtime'] as String,
            a['digest'] as String,
            current: () => !_closed && (current?.call() ?? true),
          );
          return null;
        case 'models.register':
          if (a['kind'] == dedicatedQueryModelKind) {
            if (a['backend'] != null && a['backend'] != dedicatedQueryBackend)
              throw StateError('Unsupported dedicated question model backend');
            await configureDedicatedQuery(
              store,
              a['path'] as String,
              runtime: a['runtime'] as String?,
              expectedDigest: a['digest'] as String?,
              current: () => !_closed && (current?.call() ?? true),
            );
            return null;
          }
          await store.register(
            a['kind'] as String,
            a['path'] as String,
            a['runtime'] as String? ?? '',
            backend: a['backend'] as String? ?? 'llama_cpp',
            expectedDigest: a['digest'] as String?,
            modelType: a['model_type'] as int?,
            current: () => !_closed && (current?.call() ?? true),
          );
          return null;
        case 'models.generation':
          final candidate = await configureGeneration(
            store,
            runtimeConfiguration.nativeLibrary,
            a['path'] as String,
            a['runtime'] as String,
            backend: a['backend'] as String? ?? 'llama_cpp',
            modelType: a['model_type'] as int?,
            current: () => !_closed && (current?.call() ?? true),
          );
          domain.generator?.close();
          domain.generator = candidate;
          return null;
        case 'models.embedding':
          final result = await domain.helper.client.updateModelPaths(
            UpdateModelPathsRequest(
              embeddingModelPath: a['path'] as String,
              sentencePieceModelPath: a['runtime'] as String? ?? '',
              useGpu: a['gpu'] == true,
            ),
            options: CallOptions(timeout: const Duration(minutes: 30)),
          );
          if (!result.success) throw StateError(result.errorMessage);
          // The helper already adopted a new vector space, even if persisting
          // its registration below fails. Never reuse the previous vectors.
          _noteTranscriptCache.clear();
          await store.register(
            'embedding',
            a['path'] as String,
            a['runtime'] as String? ?? '',
            backend: a['gpu'] == true
                ? 'litert_lm_embedding_gpu'
                : (a['path'] as String).endsWith('.litertlm')
                ? 'litert_lm_embedding_cpu'
                : 'sentence_transformers_cpu',
            expectedDigest: a['digest'] as String?,
            current: () => !_closed && (current?.call() ?? true),
          );
          return null;
        case 'application.resume':
          await domain.helper.recover();
          await domain.resume();
          return null;
        case 'graph.embeddings':
          return domain.graphEmbeddings(
            (a['sources'] as List)
                .map((s) => Map<String, Object?>.from(s as Map))
                .toList(),
          );
        case 'labels.put':
          store.putDocumentLabel(
            DocumentLabel(
              a['id'] as String,
              a['name'] as String,
              a['source'] as String,
              a['color'] as String?,
              a['rationale'] as String?,
            ),
          );
          return null;
        case 'labels.set':
          store.labels(a['id'] as String, (a['labels'] as List).cast<String>());
          return null;
        case 'labels.cluster':
          store.saveLabelCluster(a['name'] as String);
          return null;
        case 'labels.delete':
          store.deleteOrganizationLabel(a['name'] as String);
          return null;
        case 'graph.invalidate':
          store.invalidateGraphOrganization();
          return null;
        case 'graph.acknowledge':
          store.acknowledgeGraphLabelRemoval();
          return null;
        case 'graph.save':
          return store.saveGraphLayout(
            a['identity'] as String,
            (a['sources'] as List)
                .map((s) => Map<String, Object?>.from(s as Map))
                .toList(),
            (a['vectors'] as Map).map(
              (k, v) => MapEntry(
                k as String,
                (v as List).map((x) => (x as num).toDouble()).toList(),
              ),
            ),
            (a['points'] as Map).map(
              (k, v) => MapEntry(
                k as String,
                GraphPoint(
                  (v[0] as num).toDouble(),
                  (v[1] as num).toDouble(),
                  (v[2] as num).toDouble(),
                ),
              ),
            ),
            labelSet: a['labelSet'] as String?,
            clusters: (a['clusters'] as List? ?? [])
                .map(
                  (c) =>
                      GraphCluster.fromRow(Map<String, Object?>.from(c as Map)),
                )
                .toList(),
          );
        default:
          throw ArgumentError('Unknown application operation: $method');
      }
    } finally {
      if (modelOperation) _modelBusy = false;
      if (!{
        'status',
        'audio.capabilities',
        'notifications.capabilities',
        'sources.list',
        'sources.get',
        'sources.search',
        'notes.list',
        'meetings.list',
        'meetings.get',
        'google.status',
        'google.drive_files',
        'graph.embeddings',
      }.contains(method))
        changed();
    }
  }

  Stream<Object?> signIn(String owner) async* {
    if (_signInOwner != null)
      throw StateError('Google sign-in is already open');
    _signInOwner = owner;
    final invitation = Completer<Uri>();
    final signedIn = googleAuth.signIn((uri) async {
      invitation.complete(uri);
      changed();
    });
    unawaited(
      signedIn.catchError((Object e, StackTrace st) {
        if (!invitation.isCompleted) invitation.completeError(e, st);
      }),
    );
    try {
      yield {'authorization_url': (await invitation.future).toString()};
      await signedIn;
      yield googleState;
    } finally {
      cancelSignIn(owner);
      await signedIn.catchError((Object _) {});
      if (_signInOwner == owner) _signInOwner = null;
      changed();
    }
  }

  void cancelSignIn(String owner) {
    if (_signInOwner == owner) googleAuth.cancelSignIn();
  }

  Map<String, Object?> _source(String id) {
    final rows = store.rows('SELECT * FROM sources WHERE id=? AND deleted=0', [
      id,
    ]);
    if (rows.isEmpty) throw StateError('Source not found: $id');
    return rows.single;
  }

  Map<String, Object?> _meeting(int id) {
    final rows = store.rows('SELECT * FROM meetings WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('Meeting not found: $id');
    return rows.single;
  }

  Future<String> importFile(String path, {bool Function()? current}) async {
    final generation = domain.workspaceGeneration;

    await domain.waitForSourceWork();
    domain.checkWorkspace(generation);
    final file = File(importPolicy?.validate(path) ?? path).absolute;
    if (FileSystemEntity.typeSync(file.path) != FileSystemEntityType.file ||
        file.lengthSync() > ImportPolicy.maxFileBytes) {
      throw StateError('Import requires a regular file no larger than 10 MiB');
    }
    final (text, provenance) = await Parser().extract(file.path);
    final modified = (await file.stat()).modified.millisecondsSinceEpoch;
    domain.checkWorkspace(generation);
    if (current != null && !current())
      throw StateError('Import cancelled or source changed');

    final uri = Uri.file(file.path).toString();
    final existing = store.sources
        .where((s) => s['source_uri'] == uri)
        .firstOrNull;
    final id = store.importText(
      file.uri.pathSegments.last,
      text,
      path.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'text/plain',
      '$provenance; ${file.path}',
      id: existing?['id'] as String?,
      modifiedAtMs: modified,
      sourceUri: uri,
    );
    await domain.index(id);
    return id;
  }

  Future<String> importUrl(
    String value, {
    bool Function()? current,
    bool allowPrivateNetwork = false,
  }) async {
    final generation = domain.workspaceGeneration;
    await domain.waitForSourceWork();
    domain.checkWorkspace(generation);
    final uri = webImportUri(value);
    final text = await WebPageImporter().fetch(
      uri,
      allowPrivateNetwork: allowPrivateNetwork,
      current: current,
    );
    domain.checkWorkspace(generation);
    if (current != null && !current()) throw StateError('Operation cancelled');
    final existing = store.sources
        .where((s) => s['provenance'] == 'url:$uri')
        .firstOrNull;
    final id = store.importText(
      uri.host + uri.path,
      text,
      'text/plain',
      'url:$uri',
      id: existing?['id'] as String?,
      sourceUri: uri.toString(),
    );
    await domain.index(id);
    return id;
  }

  Future<void> importDirectory(String path, {bool Function()? current}) async {
    final generation = domain.workspaceGeneration;
    final files = importPolicy != null
        ? (await importPolicy!.directoryFiles(path)).map(File.new).toList()
        : Directory(path)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where(
                (file) => RegExp(
                  r'\.(txt|md|pdf|rtf)$',
                  caseSensitive: false,
                ).hasMatch(file.path),
              )
              .toList();
    final failures = <String>[];
    for (final file in files) {
      domain.checkWorkspace(generation);
      if (current != null && !current())
        throw StateError('Operation cancelled');
      try {
        await importFile(file.path, current: current);
      } catch (e) {
        failures.add('${file.path.split('/').last}: $e');
      }
    }
    if (failures.isNotEmpty)
      throw StateError(
        'Imported ${files.length - failures.length} files. ${failures.join('\n')}',
      );
  }

  Future<void> reimport({
    bool Function()? current,
    bool allowPrivateNetwork = false,
  }) async {
    final generation = domain.workspaceGeneration;
    final failures = <String>[];
    for (final s in store.sources) {
      domain.checkWorkspace(generation);
      if (current != null && !current())
        throw StateError('Operation cancelled');
      if ((s['provenance'] as String).startsWith('user edit; ')) continue;
      bool sourceCurrent() =>
          (current?.call() ?? true) &&
          store.rows(
            'SELECT id FROM sources WHERE id=? AND revision=? AND deleted=0',
            [s['id'], s['revision']],
          ).isNotEmpty;
      final path = (s['provenance'] as String).split('; ').last;
      try {
        if (path.startsWith('url:')) {
          await importUrl(
            path.substring(4),
            current: sourceCurrent,
            allowPrivateNetwork: allowPrivateNetwork,
          );
        } else if (File(path).existsSync()) {
          await importFile(path, current: sourceCurrent);
        } else if (path.startsWith('/')) {
          throw StateError('Imported file is missing: $path');
        } else {
          await domain.index(s['id'] as String);
        }
      } catch (e) {
        failures.add('${s['title']}: $e');
      }
    }
    if (googleAuth.connected) {
      try {
        await google.refresh();
      } catch (e) {
        failures.add(e.toString());
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  }

  Future<void> indexMeeting(int id) async {
    _meeting(id);
    final text = store
        .rows(
          'SELECT * FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
          [id],
        )
        .map(
          (t) =>
              '[${MeetingSpeaker.fromSource(t['source'] as String).label} ${t['start_ms']}–${t['end_ms']} ms] ${t['text']}',
        )
        .join('\n');
    if (text.trim().isEmpty) return;
    final existing = store.rows(
      'SELECT content,state,deleted FROM sources WHERE id=?',
      ['meeting-$id'],
    ).firstOrNull;
    final unchanged = existing?['content'] == text && existing?['deleted'] == 0;
    if (unchanged && existing?['state'] == 'indexed') return;
    final source = unchanged
        ? 'meeting-$id'
        : store.importText(
            'Meeting $id transcript',
            text,
            'text/plain',
            'meeting:$id',
            id: 'meeting-$id',
          );
    final indexing = domain.index(source);
    if (domain.sourcesPaused) {
      unawaited(
        indexing.catchError((Object e) {
          recordingState = 'Meeting indexing: $e';
          changed();
        }),
      );
    } else {
      await indexing;
    }
  }

  Future<void> generateMeeting(
    int id,
    String kind, {
    String? requestId,
    bool Function()? current,
  }) async {
    final generation = domain.workspaceGeneration;
    if (current != null && !current()) throw StateError('Generation cancelled');

    if (![
      'summary',
      'actions',
      'action_items',
      'questions',
      'enhanced_notes',
    ].contains(kind))
      throw ArgumentError('Unsupported artifact kind');
    if (kind == 'enhanced_notes') {
      await enhanceNotes(id, requestId: requestId, current: current);
      return;
    }
    final meeting = _meeting(id);
    final text = store
        .rows(
          'SELECT text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
          [id],
        )
        .map((t) => t['text'])
        .join('\n');
    if (text.isEmpty) throw StateError('No final transcript');
    final result = await _generate(
      'meeting',
      'Produce $kind from this transcript only. Use ${store.preference('noteStyle', 'Standard') == 'Concise' ? 'brief phrases' : 'complete sentences'}. Do not invent details. $meetingSpeakerInstructions\n${boundUtf8(text, 2800)}',
      requestId: requestId,
      current: current,
    );
    domain.checkWorkspace(generation);
    if (current != null && !current()) throw StateError('Generation cancelled');

    store.artifact(
      id,
      kind,
      result,
      _digest,
      inputRevision: meeting['revision'] as int,
    );
  }

  String get _digest =>
      store
              .rows("SELECT digest FROM models WHERE kind='generation'")
              .firstOrNull?['digest']
          as String? ??
      'unknown';
  Future<String> _generate(
    String prefix,
    String prompt, {
    int maxTokens = 1024,
    String? requestId,
    Map<String, dynamic>? responseSchema,
    bool Function()? current,
    void Function(String text)? onText,
  }) async {
    final generation = domain.workspaceGeneration;
    await Future<void>.value();
    domain.checkWorkspace(generation);
    if (current != null && !current()) throw StateError('Generation cancelled');
    if (modelBusy) throw StateError('Model configuration is busy');
    final generator = domain.generator;
    if (generator == null) throw StateError('Generation model unavailable');
    var result = '', status = 'failed', failure = '';
    await for (final event in generator.generate(
      requestId ?? '$prefix-${domain.clock.now().microsecondsSinceEpoch}',
      prompt,
      responseSchema: responseSchema,
      maxOutputTokens: maxTokens,
    )) {
      domain.checkWorkspace(generation);
      if (current != null && !current())
        throw StateError('Generation cancelled');
      if (event['type'] == 'delta') {
        result += event['text'] as String;
        onText?.call(result);
      }
      if (event['type'] == 'done') status = event['status'] as String;
      if (event['type'] == 'error') failure = event['message'].toString();
    }
    domain.checkWorkspace(generation);
    if (current != null && !current()) throw StateError('Generation cancelled');

    if (status != 'completed') throw StateError('Generation $status: $failure');
    return result;
  }

  void _requestAutomaticNoteEnhancement(int id, {Set<int>? targets}) {
    unawaited(
      enhanceNotes(
        id,
        deferWhenBusy: true,
        isLive: true,
        targetBulletIndices: targets,
      ).catchError((Object error) {
        recordingState = 'Note enhancement: $error';
        changed();
      }),
    );
  }

  void _scheduleNoteEditEnhancement(int id, String previous, String notes) {
    if (_closed || store.preference('liveEnhance', 'true') != 'true') return;
    final mapping = _noteEditMapping(id);
    final targets = planNoteLiveEnhancementTargets(
      previousNotes: previous,
      notes: notes,
      hasEnhanceableScribbles: hasEnhanceableNoteScribbles(notes),
      lastSuccessfulShorthand: mapping.lastSuccessfulShorthand,
      staleIndices: mapping.staleIndices,
    );
    if (targets == null) {
      _scheduleEnhance(id);
    } else if (targets.isNotEmpty) {
      _enhance.remove(id)?.cancel();
      _requestAutomaticNoteEnhancement(id, targets: targets);
    }
  }

  void _scheduleEnhance(int id) {
    if (_closed) return;
    _enhance.remove(id)?.cancel();
    if (store.preference('liveEnhance', 'true') != 'true') return;
    _enhance[id] = domain.createTimer(const Duration(seconds: 30), () {
      _enhance.remove(id);
      if (_noteEnhancements.values.any((state) => state.active)) return;
      _requestAutomaticNoteEnhancement(id);
    });
  }

  Future<void> enhanceNotes(
    int id, {
    bool deferWhenBusy = false,
    bool isLive = false,
    bool forceRegenerate = false,
    Set<int>? targetBulletIndices,
    String? requestId,
    bool Function()? current,
  }) async {
    if (current != null && !current()) throw StateError('Generation cancelled');
    if (_closed) throw StateError('Application closed');
    if (domain.generator?.generating == true ||
        _noteEnhancements.values.any((state) => state.active)) {
      if (deferWhenBusy) {
        if (_noteEnhancements.values.any((state) => state.active)) {
          if (targetBulletIndices != null) {
            _pendingNoteTargets[id] = Set.of(targetBulletIndices);
          }
        } else {
          _scheduleEnhaseRetry(
            id,
            targetBulletIndices: targetBulletIndices,
            isLive: isLive,
          );
        }
        return;
      }
      throw StateError('Generation already in progress');
    }
    final notes = store.rows(
      'SELECT body,revision FROM meeting_notes WHERE meeting_id=?',
      [id],
    ).firstOrNull;
    if (notes == null ||
        (notes['body'] as String).trim().isEmpty ||
        (isLive && !hasEnhanceableNoteScribbles(notes['body'] as String)))
      return;
    final transcript = isLive
        ? _liveNoteTranscriptSegments(id)
              .map(
                (segment) => formatNoteTranscriptSegment(
                  speaker: segment.speaker,
                  text: segment.text,
                ),
              )
              .join('\n')
        : _noteTranscriptText(id);
    if (transcript.isEmpty) return;
    final revision = _meeting(id)['revision'] as int;
    final previousState = _noteEnhancements[id];
    previousState?.saveTimer?.cancel();
    final enhancement = _NoteEnhancement(
      requestId ??
          'notes-${domain.clock.now().microsecondsSinceEpoch}-${++_noteEnhancementSerial}',
      notes['body'] as String,
      current: current,
    );
    final previous =
        previousState != null &&
            !previousState.active &&
            (previousState.cancelRequested || previousState.status.isEmpty)
        ? previousState.body
        : store.meetingEnhancedNotes(id);
    final mapping = _noteEditMapping(id);
    _noteEnhancements[id] = enhancement;
    _scheduleEnhancedDraft(id, enhancement);
    changed();
    try {
      late NativeRuntime generator;
      var batch = 0;
      final prior = forceRegenerate
          ? null
          : Map<int, String>.of(mapping.accepted);
      if (forceRegenerate) mapping.accepted.clear();
      final producer = ReferenceNoteEnhancer(
        ensureReady: () async {
          if (modelBusy) throw StateError('Model configuration is busy');
          generator = await acquireNoteEnhancementService<NativeRuntime>(
            getService: domain.noteEnhancementService,
            isReady: (service) => service.loaded,
            abortAndReset: () async {
              stderr.writeln(
                'NotesEnhancer: LiteRT-LM service not ready, attempting reset and re-initialization...',
              );
              await domain.resetNoteEnhancementService();
            },
            unavailableError: () async => Exception(
              store.model('generation') != null
                  ? 'LiteRT-LM service is not ready. Please try again in a moment.'
                  : 'LiteRT-LM service is not ready: on-device inference model is not downloaded. Please check Settings -> Model Management.',
            ),
          );
          if (generator.effectiveState['tools'] == false) {
            throw StateError(
              'Note enhancement requires a native conversation runtime',
            );
          }
          if (_closed ||
              enhancement.cancelRequested ||
              !(current?.call() ?? true) ||
              !identical(_noteEnhancements[id], enhancement)) {
            throw StateError('Generation cancelled');
          }
        },
        loadEmbeddedTranscript: () =>
            _embeddedNoteTranscript(id, transcript, isLive: isLive),
        computeEmbedding: domain.helper.snapshot?.pipeline == 'ready'
            ? _computeNoteEmbedding
            : null,
        encodeStopTokens: domain.helper.snapshot?.tokenizerReady == true
            ? (text) async {
                final response = await domain.helper.client.encode(
                  EncodeRequest(text: text),
                );
                return response.tokens.toList();
              }
            : null,
        createConversation: (settings) async =>
            NativeNoteEnhancementConversation.create(
              runtime: generator,
              requestId: '${enhancement.requestId}-batch-${++batch}',
              settings: settings,
            ),
        logBatchError: (error, stack) {
          stderr.writeln('Note enhancement batch: $error');
        },
      );
      await for (final text in producer.enhance(
        notes: notes['body'] as String,
        existingEnhancedBullets: prior,
        targetBulletIndices: targetBulletIndices,
        isLive: isLive,
        updateExistingWithTranscript: !isLive && !forceRegenerate,
        concise: store.preference('noteStyle', 'Standard') == 'Concise',
        onActiveIndexChanged: (index) {
          enhancement.activeIndex = index;
          changed();
        },
      )) {
        if (_closed ||
            enhancement.cancelRequested ||
            !(current?.call() ?? true) ||
            !identical(_noteEnhancements[id], enhancement)) {
          throw StateError('Generation cancelled');
        }
        if (isNoteEnhancementStatus(text)) {
          enhancement.status = text;
        } else {
          enhancement.body = cleanNoteEnhancementTags(text);
          enhancement.status = '';
          _scheduleEnhancedDraft(id, enhancement);
        }
        changed();
      }
      if (_closed ||
          enhancement.cancelRequested ||
          !(current?.call() ?? true) ||
          !identical(_noteEnhancements[id], enhancement))
        throw StateError('Generation cancelled');
      enhancement.saveTimer?.cancel();
      store.artifact(
        id,
        'enhanced_notes',
        enhancement.body,
        _digest,
        inputRevision: revision,
      );
      mapping.captureSuccess(
        notes:
            store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
                  id,
                ]).firstOrNull?['body']
                as String? ??
            '',
        enhancedNotes: enhancement.body,
      );
      _noteEnhancements.remove(id);
      changed();
    } catch (error) {
      enhancement.active = false;
      if (!identical(_noteEnhancements[id], enhancement)) {
        enhancement.saveTimer?.cancel();
        return;
      }
      if (_closed || !(current?.call() ?? true)) {
        enhancement.saveTimer?.cancel();
        _noteEnhancements.remove(id);
        return;
      }
      if (enhancement.cancelRequested) {
        enhancement.body = formatEnhancedNotesWithSpacing(
          extractEnhancedNoteBullets(previous),
        );
        enhancement.status = '';
        _restoreNoteMapping(
          id,
          store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
                    id,
                  ]).firstOrNull?['body']
                  as String? ??
              '',
          enhancement.body,
        );
        _scheduleEnhancedDraft(id, enhancement);
        changed();
        return;
      }
      enhancement.status = error.toString();
      changed();
      rethrow;
    } finally {
      if (isLive &&
          !_closed &&
          identical(_noteEditMappings[id], mapping) &&
          store.preference('liveEnhance', 'true') == 'true') {
        if (_pendingNoteTargets.isNotEmpty) {
          final next = _pendingNoteTargets.entries.first;
          _pendingNoteTargets.remove(next.key);
          _requestAutomaticNoteEnhancement(next.key, targets: next.value);
        } else if (isLive) {
          final currentNotes =
              store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
                    id,
                  ]).firstOrNull?['body']
                  as String? ??
              '';
          if (currentNotes != notes['body'] &&
              hasEnhanceableNoteScribbles(currentNotes)) {
            _scheduleEnhance(id);
          }
        }
      }
    }
  }

  void _scheduleEnhancedDraft(int id, _NoteEnhancement enhancement) {
    if (_closed) return;
    enhancement.saveTimer?.cancel();
    enhancement.saveTimer = domain.createTimer(const Duration(seconds: 1), () {
      enhancement.saveTimer = null;
      if (_closed ||
          !(enhancement.current?.call() ?? true) ||
          !identical(_noteEnhancements[id], enhancement))
        return;
      try {
        store.saveMeetingEnhancedDraft(id, enhancement.body);
        if (!enhancement.active && enhancement.status.isEmpty)
          _noteEnhancements.remove(id);
      } catch (error) {
        enhancement.status = 'Unable to save enhanced notes: $error';
      }
      changed();
    });
  }

  void _scheduleEnhaseRetry(
    int id, {
    Set<int>? targetBulletIndices,
    bool isLive = false,
  }) {
    if (_closed) return;
    _enhance.remove(id)?.cancel();
    _enhance[id] = domain.createTimer(
      const Duration(seconds: 3),
      () => unawaited(
        enhanceNotes(
          id,
          deferWhenBusy: true,
          isLive: isLive,
          targetBulletIndices: targetBulletIndices,
        ).catchError((Object error) {
          recordingState = 'Note enhancement: $error';
          changed();
        }),
      ),
    );
  }

  Future<void> startRecording(int id) async {
    if (modelBusy) throw StateError('Model configuration is busy');
    _meeting(id);
    if (recording != null) throw StateError('A meeting is already recording');
    final speech = store.model('speech');
    if (speech == null)
      throw StateError('Register speech model and whisper.cpp runner first');
    provisionalTranscript.clear();
    final active = Recording(
      runtimeConfiguration.nativeLibrary,
      (state) {
        recordingState = state;
        changed();
      },
      (text, start, end, source) {
        store.transcript(
          id,
          text,
          true,
          start,
          end,
          '$source; captured-sample timeline (gaps excluded)',
        );
        provisionalTranscript.remove(source);
        proactive.clearInterim(id, source);
        proactive.notify(id);
        _scheduleLiveNoteTranscriptEmbedding(id);
        _scheduleEnhance(id);
        _liveIndex?.cancel();
        _liveIndex = domain.createTimer(
          const Duration(seconds: 1),
          () => unawaited(
            indexMeeting(id).catchError((Object e) {
              recordingState = 'Live indexing: $e';
              changed();
            }),
          ),
        );
        changed();
      },
      levels: changed,
      provisional: (text, start, end, source) {
        provisionalTranscript[source] = text;
        proactive.updateInterim(id, source, text);
        changed();
      },
      interruption: (event) {
        store.transcript(
          id,
          'Capture interruption: ${event['reason']}; ${event['discarded_bytes']} residual bytes discarded. Captured-sample transcript timing excludes the gap.',
          false,
          0,
          0,
          '${event['source']}-capture-interruption',
        );
        store.db.execute("UPDATE meetings SET state='interrupted' WHERE id=?", [
          id,
        ]);
        changed();
      },
    );
    try {
      active.start(
        speech['runtime'] as String,
        speech['path'] as String,
        microphoneTarget:
            runtimeConfiguration['FORESIGHT_MICROPHONE_TARGET'] ??
            store.preference('microphoneTarget', 'auto'),
        playbackTarget:
            runtimeConfiguration['FORESIGHT_PLAYBACK_TARGET'] ??
            store.preference('playbackTarget', 'auto'),
        echoCancellation:
            Platform.isMacOS &&
            store.preference('echoCancellation', 'false') == 'true',
      );
    } catch (_) {
      active.dispose();
      rethrow;
    }
    recording = active;
    proactive.begin(id);
    recordingMeeting = id;
    _scheduleLiveNoteTranscriptEmbedding(id);
    recordingBegan = domain.clock.now();
    _recordingPausedAt = null;
    _recordingPausedMs = 0;
    store.db.execute("UPDATE meetings SET state='recording' WHERE id=?", [id]);
    _inactivity = Timer.periodic(const Duration(seconds: 5), (_) {
      final minutes =
          double.tryParse(store.preference('inactivity', '15')) ?? 15;
      if (minutes > 0 &&
          !active.paused &&
          !active.finishing &&
          domain.clock.now().difference(active.lastAudioActivity).inSeconds >=
              minutes * 60) {
        unawaited(
          stopRecording().catchError((Object e) {
            recordingState = e.toString();
            changed();
          }),
        );
      }
    });
    changed();
  }

  Future<void> stopRecording() =>
      _stopping ??= _stopRecording().whenComplete(() => _stopping = null);

  Recording _activeRecording(int? id) {
    final active = recording;
    if (active == null || (id != null && id != recordingMeeting)) {
      throw StateError('No matching active recording');
    }
    if (active.finishing || _stopping != null) {
      throw StateError('Transcription is finalizing');
    }
    return active;
  }

  void pauseRecording([int? id]) {
    _activeRecording(id).pause();
    _recordingPausedAt ??= domain.clock.now();
    provisionalTranscript.clear();
    proactive.clearInterim(recordingMeeting!);
    store.db.execute("UPDATE meetings SET state='paused' WHERE id=?", [
      recordingMeeting,
    ]);
    changed();
  }

  void resumeRecording([int? id]) {
    _activeRecording(id).resume();
    if (_recordingPausedAt != null) {
      _recordingPausedMs += domain.clock
          .now()
          .difference(_recordingPausedAt!)
          .inMilliseconds;
      _recordingPausedAt = null;
    }
    store.db.execute("UPDATE meetings SET state='recording' WHERE id=?", [
      recordingMeeting,
    ]);
    changed();
  }

  Future<void> _stopRecording() async {
    final active = recording;
    final id = recordingMeeting;
    if (active == null || id == null) return;
    _liveIndex?.cancel();
    _inactivity?.cancel();
    var status = 'interrupted';
    Object? failure;
    store.db.execute("UPDATE meetings SET state='transcribing' WHERE id=?", [
      id,
    ]);
    changed();
    try {
      try {
        await active.stop();
      } catch (error) {
        failure = error;
        active.dispose();
        recordingState = 'Transcript retained after speech failure: $error';
      }
      // Already committed segments remain useful even if a later segment or
      // shutdown failed. Index them before publishing the recoverable state.
      await indexMeeting(id);
      status = failure != null || active.lastError.isNotEmpty
          ? 'interrupted'
          : recordingState.startsWith('No speech')
          ? 'empty'
          : 'completed';
    } finally {
      recording = null;
      provisionalTranscript.clear();
      proactive.clearInterim(id);
      store.db.execute('UPDATE meetings SET state=? WHERE id=?', [status, id]);
      changed();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _googleTimer?.cancel();
    google.close();
    _liveIndex?.cancel();
    _inactivity?.cancel();
    for (final timer in _enhance.values) {
      timer.cancel();
    }
    _enhance.clear();
    for (final enhancement in _noteEnhancements.values) {
      enhancement.saveTimer?.cancel();
      enhancement.cancelRequested = true;
    }
    final acquisition = _queryAcquisition;
    await acquisition?.close();
    if (acquisition != null) {
      try {
        await acquisition.done;
      } catch (_) {
        /* Owned setup was cancelled. */
      }
    }
    await proactive.close();
    await _queryRuntime?.close();
    try {
      await googleAuth.close();
      if (recording != null) await stopRecording();
    } finally {
      await changes.close();
    }
  }
}

class _NoteEnhancement {
  _NoteEnhancement(this.requestId, this.body, {this.current});
  final bool Function()? current;
  final String requestId;
  String body, status = '';
  bool active = true, cancelRequested = false;
  int? activeIndex;
  Timer? saveTimer;
  Map<String, Object?> get state => {
    'request_id': requestId,
    'body': body,
    'status': status,
    'active': active,
    'cancel_requested': cancelRequested,
    'active_index': activeIndex,
  };
}
