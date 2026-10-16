import 'audio_devices.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'domain.dart';
import 'recording.dart';
import 'store.dart';
import 'graph_labels.dart';
import 'graph_layout.dart';
import 'graph_clusters.dart';
import 'graph_persistence.dart';
import 'model_setup.dart';
import 'speech_models.dart';
import 'google_auth.dart';
import 'google_connections.dart';
import 'generated/rag_service.pb.dart';
import 'package:grpc/grpc.dart';

/// Application operations shared by the desktop and external clients.
/// This object, its database, and its capture/model handles belong to one owner.
class Application {
  final Domain domain;
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
  Future<void>? _stopping;
  bool _closed = false;
  bool _modelBusy = false;
  bool get modelBusy => _modelBusy || domain.restoring;
  final GoogleAuth? _auth;
  Application(this.domain, {GoogleAuth? auth}) : _auth = auth;
  String? _signInOwner;
  late final GoogleAuth googleAuth =
      _auth ?? GoogleAuth(Directory('${File(store.path).parent.path}/google'));
  late final GoogleConnections google = GoogleConnections(domain, googleAuth);
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
    _googleTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(maintainGoogle()),
    );
  }

  Future<void> maintainGoogle() async {
    if (_googleBusy || !googleAuth.connected) return;
    _googleBusy = true;
    try {
      await google.reminders(DateTime.now(), (message) async {
        await platformNotification('Open Foresight', message);
      });
      final hours =
          int.tryParse(store.preference('googleRefreshHours', '4')) ?? 4;
      if (!domain.sourcesPaused &&
          DateTime.now().millisecondsSinceEpoch -
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
    'meeting_id': recordingMeeting,
    'active': recording != null,
    'finishing': recording?.finishing ?? false,
    'paused': recording?.paused ?? false,
    'began': recordingBegan?.millisecondsSinceEpoch,
    'elapsed_ms': recordingBegan == null
        ? 0
        : (_recordingPausedAt ?? DateTime.now())
                  .difference(recordingBegan!)
                  .inMilliseconds -
              _recordingPausedMs,
    'state': recordingState,
    'samples': recording?.sampleCounts ?? <int>[],
    'peaks': recording?.peakVolumes ?? <double>[],
    'last_audio': recording?.lastAudioActivity.millisecondsSinceEpoch,
    'provisional': Map.of(provisionalTranscript),
    'volumes': recording?.currentVolumes ?? <double>[],
  };

  Future<Object?> call(
    String method,
    Map<String, dynamic> a, {
    bool Function()? current,
  }) async {
    if (_closed) throw StateError('Application closed');
    if (current != null && !current()) throw StateError('Operation cancelled');
    if (method.startsWith('models.') &&
        (modelBusy ||
            domain.generator?.generating == true ||
            recording != null)) {
      throw StateError(
        'Model configuration is busy while generation or recording is active',
      );
    }
    final modelOperation = method.startsWith('models.');
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
            'capture': captureState,
            'sources_paused': domain.sourcesPaused,
            'helper': domain.helper.snapshot?.toProto3Json(),
            'generation': generationState,
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
          return {'id': await importUrl(a['url'] as String, current: current)};
        case 'sources.import_directory':
          await importDirectory(a['path'] as String, current: current);
          return null;
        case 'sources.refresh':
          await reimport(current: current);
          return null;
        case 'sources.import_file':
          return {'id': await importFile(a['path'] as String)};
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
          final allowed = store.sourceSummaries
              .where((s) => s['state'] == 'indexed')
              .map((s) => s['id'] as String)
              .toList();
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
              allowedDocumentIds: allowed,
            ),
          );
          return result.chunks.map((c) {
            final source = _source(c.documentId);
            return {
              'id': c.documentId,
              'text': c.text,
              'score': c.relevanceScore,
              'title': source['title'],
              'revision': source['revision'],
            };
          }).toList();
        case 'answer':
          return {
            'text': await domain
                .askInConversation(
                  a['question'] as String,
                  a['conversation'] as String? ?? 'desktop',
                  meetingId: a['meeting_id'] as int?,
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
          store.setPreference(a['key'] as String, a['value'] as String);
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
            'transcript': store.rows(
              'SELECT * FROM transcript WHERE meeting_id=? ORDER BY id',
              [id],
            ),
            'artifacts': store.rows(
              'SELECT * FROM artifacts WHERE meeting_id=? ORDER BY id',
              [id],
            ),
          };
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
          await googleAuth.disconnect();
          for (final source in store.sources) {
            await domain.delete(source['id'] as String);
          }
          store.db.execute('BEGIN IMMEDIATE');
          try {
            for (final table in [
              'google_sources',
              'google_folders',
              'calendar_events',
              'meeting_answers',
              'meeting_notes',
              'artifacts',
              'transcript',
              'meeting_details',
              'meetings',
              'answers',
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
          return null;
        case 'meetings.notes':
          _meeting(a['id'] as int);
          store.saveMeetingNotes(a['id'] as int, a['body'] as String);
          _scheduleEnhance(a['id'] as int);
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
          await indexMeeting(id);
          return null;
        case 'meetings.index':
          await indexMeeting(a['id'] as int);
          return null;
        case 'meetings.generate':
          await generateMeeting(a['id'] as int, a['kind'] as String);
          return null;
        case 'meetings.enhance':
          await enhanceNotes(a['id'] as int);
          return null;
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
          store.editArtifact(a['id'] as int, a['text'] as String);
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
          await store.register(
            a['kind'] as String,
            a['path'] as String,
            a['runtime'] as String? ?? '',
            backend: a['backend'] as String? ?? 'llama_cpp',
            expectedDigest: a['digest'] as String?,
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

  Future<String> importFile(String path) async {
    await domain.waitForSourceWork();
    final file = File(path).absolute;
    final (text, provenance) = await Parser().extract(file.path);
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
      modifiedAtMs: (await file.stat()).modified.millisecondsSinceEpoch,
      sourceUri: uri,
    );
    await domain.index(id);
    return id;
  }

  Future<String> importUrl(String value, {bool Function()? current}) async {
    await domain.waitForSourceWork();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty)
      throw StateError('Enter an HTTP or HTTPS URL.');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final response = await (await client.getUrl(
        uri,
      )).close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw StateError('URL returned HTTP ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (current != null && !current())
          throw StateError('Operation cancelled');
        bytes.addAll(chunk);
        if (bytes.length > 5 * 1024 * 1024)
          throw StateError('Page exceeds 5 MB.');
      }
      var text = utf8.decode(bytes);
      if (response.headers.contentType?.mimeType == 'text/html') {
        text = text
            .replaceAll(
              RegExp(
                r'<(script|style)\b[^>]*>[\s\S]*?</\1>',
                caseSensitive: false,
              ),
              '',
            )
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      } else if (!(response.headers.contentType?.mimeType.startsWith('text/') ??
          false)) {
        throw StateError(
          'URL must contain HTML or plain text. Add binary documents as files.',
        );
      }
      if (text.isEmpty) throw StateError('No readable text found.');
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
    } finally {
      client.close(force: true);
    }
  }

  Future<void> importDirectory(String path, {bool Function()? current}) async {
    final files = Directory(path)
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
      if (current != null && !current())
        throw StateError('Operation cancelled');
      try {
        await importFile(file.path);
      } catch (e) {
        failures.add('${file.path.split('/').last}: $e');
      }
    }
    if (failures.isNotEmpty)
      throw StateError(
        'Imported ${files.length - failures.length} files. ${failures.join('\n')}',
      );
  }

  Future<void> reimport({bool Function()? current}) async {
    final failures = <String>[];
    for (final s in store.sources) {
      if (current != null && !current())
        throw StateError('Operation cancelled');
      final path = (s['provenance'] as String).split('; ').last;
      try {
        if (path.startsWith('url:')) {
          await importUrl(path.substring(4));
        } else if (File(path).existsSync()) {
          await importFile(path);
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
              '[${t['source']} ${t['start_ms']}–${t['end_ms']} ms] ${t['text']}',
        )
        .join('\n');
    if (text.trim().isEmpty) return;
    final source = store.importText(
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

  Future<void> generateMeeting(int id, String kind) async {
    if (![
      'summary',
      'actions',
      'action_items',
      'questions',
      'enhanced_notes',
    ].contains(kind))
      throw ArgumentError('Unsupported artifact kind');
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
      'Produce $kind from this transcript only. Use ${store.preference('noteStyle', 'Standard') == 'Concise' ? 'brief phrases' : 'complete sentences'}. Do not invent details.\n${boundUtf8(text, 2800)}',
    );
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
  }) async {
    if (modelBusy) throw StateError('Model configuration is busy');
    final generator = domain.generator;
    if (generator == null) throw StateError('Generation model unavailable');
    var result = '', status = 'failed', failure = '';
    await for (final event in generator.generate(
      '$prefix-${DateTime.now().microsecondsSinceEpoch}',
      prompt,
      maxOutputTokens: maxTokens,
    )) {
      if (event['type'] == 'delta') result += event['text'] as String;
      if (event['type'] == 'done') status = event['status'] as String;
      if (event['type'] == 'error') failure = event['message'].toString();
    }
    if (status != 'completed') throw StateError('Generation $status: $failure');
    return result;
  }

  void _scheduleEnhance(int id) {
    _enhance.remove(id)?.cancel();
    if (store.preference('liveEnhance', 'true') != 'true') return;
    _enhance[id] = Timer(
      const Duration(seconds: 2),
      () => unawaited(
        enhanceNotes(id, deferWhenBusy: true).catchError((Object e) {
          recordingState = 'Note enhancement: $e';
          changed();
        }),
      ),
    );
  }

  Future<void> enhanceNotes(int id, {bool deferWhenBusy = false}) async {
    if (domain.generator?.generating == true) {
      if (deferWhenBusy) {
        _scheduleEnhaseRetry(id);
        return;
      }
      throw StateError('Generation already in progress');
    }
    final notes = store.rows(
      'SELECT body,revision FROM meeting_notes WHERE meeting_id=?',
      [id],
    ).firstOrNull;
    if (notes == null || (notes['body'] as String).trim().isEmpty) return;
    final transcript = store
        .rows(
          'SELECT text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
          [id],
        )
        .map((t) => t['text'])
        .join('\n');
    if (domain.generator == null || transcript.isEmpty) return;
    final revision = _meeting(id)['revision'] as int;
    final result = await _generate(
      'notes',
      'Enrich each shorthand note using only the transcript below. Preserve the user names and spelling. Do not add unsupported details. Write ${store.preference('noteStyle', 'Standard') == 'Concise' ? 'brief phrases' : 'complete sentences'}, one bullet per note. Notes:\n${boundUtf8(notes['body'] as String, 1500)}\nTranscript:\n${boundUtf8(transcript, 2800)}',
      maxTokens: 512,
    );
    final current = store.rows(
      'SELECT revision FROM meeting_notes WHERE meeting_id=?',
      [id],
    ).firstOrNull;
    if (current?['revision'] != notes['revision']) return;
    store.artifact(
      id,
      'enhanced_notes',
      result,
      _digest,
      inputRevision: revision,
    );
    changed();
  }

  void _scheduleEnhaseRetry(int id) {
    _enhance.remove(id)?.cancel();
    _enhance[id] = Timer(
      const Duration(seconds: 3),
      () => _scheduleEnhance(id),
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
        _scheduleEnhance(id);
        _liveIndex?.cancel();
        _liveIndex = Timer(
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
      );
    } catch (_) {
      active.dispose();
      rethrow;
    }
    recording = active;
    recordingMeeting = id;
    recordingBegan = DateTime.now();
    _recordingPausedAt = null;
    _recordingPausedMs = 0;
    store.db.execute("UPDATE meetings SET state='recording' WHERE id=?", [id]);
    _inactivity = Timer.periodic(const Duration(seconds: 5), (_) {
      final minutes =
          double.tryParse(store.preference('inactivity', '15')) ?? 15;
      if (minutes > 0 &&
          !active.paused &&
          !active.finishing &&
          DateTime.now().difference(active.lastAudioActivity).inSeconds >=
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
    _recordingPausedAt ??= DateTime.now();
    provisionalTranscript.clear();
    store.db.execute("UPDATE meetings SET state='paused' WHERE id=?", [
      recordingMeeting,
    ]);
    changed();
  }

  void resumeRecording([int? id]) {
    _activeRecording(id).resume();
    if (_recordingPausedAt != null) {
      _recordingPausedMs += DateTime.now()
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
    var status = 'failed';
    store.db.execute("UPDATE meetings SET state='transcribing' WHERE id=?", [
      id,
    ]);
    changed();
    try {
      await active.stop();
      status = 'transcribed';
      await indexMeeting(id);
      status = recordingState.startsWith('No speech') ? 'empty' : 'completed';
    } finally {
      recording = null;
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
    try {
      await googleAuth.close();
      if (recording != null) await stopRecording();
    } finally {
      await changes.close();
    }
  }
}
