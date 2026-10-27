import 'dart:async';
import 'dart:ffi';

import 'package:path/path.dart' as p;

import '../audio_models.dart';
import '../audio_presentation.dart';
import '../native_lifetime.dart';
import '../persistence/audio_export_destinations.dart';
import '../persistence/audio_export_media.dart';
import '../persistence/audio_media_erasure.dart';
import '../persistence/audio_profile_backups.dart';
import '../persistence/audio_backup_policy.dart';
import '../persistence/audio_queries.dart';
import '../persistence/audio_work_queries.dart';
import '../persistence/audio_store.dart';
import '../persistence/audio_transform_media.dart';
import '../persistence/recording_media.dart';
import '../persistence/read_schema_guard.dart';
import '../platform_services.dart';
import '../recording_playback.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'audio_application_port.dart';
import 'audio_playback_source.dart';
import 'audio_saved_work.dart';
import 'audio_storage_headroom.dart';
import 'audio_startup_recovery.dart';
import 'audio_transform_scheduler.dart';
import 'native_audio_media.dart';
import 'recording_audio_work.dart';
import 'saved_audio_player.dart';

/// One service owns this graph, its independent storage binding and all actual
/// native reader fences. Startup reconciles before binding capture or activating
/// workers. Capture never drains ASR; model/clear/shutdown barriers do join it.
final class MeetingAudioRuntime
    implements
        AudioApplicationPort,
        AudioApplicationLifecycle,
        RecordingAudioWorkPort,
        RecordingAudioAdmission {
  MeetingAudioRuntime({
    required this.store,
    required this.bindings,
    required this.executable,
    required bool assemblySupported,
    required this.configuration,
    this.runtimeDirectory,
    required this.changed,
    required this.committed,
    required this.captureActivity,
    required this.captureOwned,
    required this.bindCapture,
    required this.nowMs,
    this.recoverAudio,
  }) : _assemblyRequested = assemblySupported;
  final Store store;
  final NativeLibrary bindings;
  final AudioMediaExecutable? executable;
  final RuntimeConfiguration configuration;

  /// The actual adopted service runtime, which can differ from configuration.
  final String? runtimeDirectory;
  final void Function() changed;
  final void Function(AudioResultCommit) committed;
  final AudioCaptureActivity Function() captureActivity;
  final bool Function() captureOwned;
  final void Function(RecordingMedia, RecordingAudioWorkPort) bindCapture;
  final int Function() nowMs;

  /// Service-owned controlled recovery seam; never read from RPC/configuration.
  final RecoverAudioBatch? recoverAudio;
  final bool _assemblyRequested;
  final _clock = Stopwatch()..start();
  late RecordingMedia media;
  late AudioSavedWork saved;
  late AudioCompressionMedia compression;
  late AudioExportDestinations destinations;
  late AudioExportMedia exports;
  late AudioTransformScheduler transforms;
  late SavedAudioPlayer player;
  late AudioMediaErasure erasure;
  bool _initialized = false, _active = false, _closed = false, _fatal = false;
  bool _maintenance = false, _captureBlocked = false, _quiescent = false;
  bool _modelsSuspended = false,
      _savedSuspended = false,
      _playbackStarting = false;
  bool assemblySupported = false;
  Timer? _timer;
  Future<void>? _initializing, _background, _closing;
  Future<Object?>? _maintenanceWork;
  String lastError = '';
  AudioStorageHeadroom? _storageHeadroom;

  Future<void> initialize() => _initializing ??= () async {
    // Publish the original image's cleanup obligation before opening raw media
    // descriptors. An idle graph still owns an inherited-reader fencing lock;
    // unexpected isolate death must require restart rather than admit a peer.
    await bindings.prepareAdmission();
    if (_closed) throw StateError('Audio startup cancelled');
    await _openComponents();
    await AudioStartupRecovery(
      media: media,
      bindings: bindings,
      current: () => !_closed,
      nowMs: nowMs,
      recover: recoverAudio,
    ).run();
    if (_closed) throw StateError('Audio startup cancelled');
    _active = true;
    bindCapture(media, this);
    if (_closed) throw StateError('Audio startup cancelled');
    saved.activate();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _wake());
    _wake();
  }();
  Future<void> _openComponents() async {
    final acquired = await RecordingMedia.acquire(
      store,
      ownerGeneration: AudioStore.newIdentity(),
      current: () => !_closed,
    );
    if (_closed) {
      acquired.close();
      throw StateError('Audio startup cancelled');
    }
    media = acquired;
    _storageHeadroom = AudioStorageHeadroom(
      directory: p.join(p.dirname(store.path), 'recordings'),
      scope: () => '${store.workspaceEpoch}:${media.audio.storageGeneration}',
      nowUs: () => _clock.elapsedMicroseconds,
      changed: _notify,
    );
    try {
      assemblySupported =
          _assemblyRequested &&
          executable != null &&
          [
            'fs_owned_media_input_poll',
            'fs_owned_media_input_reply',
            'fs_pcm_output_version',
            'fs_owned_pcm_output_create_async',
            'fs_owned_pcm_output_push',
            'fs_owned_pcm_output_poll',
            'fs_owned_pcm_output_pause_flush_async',
            'fs_owned_pcm_output_resume_async',
            'fs_pcm_output_finish_async',
            'fs_pcm_output_retire',
          ].every(bindings.library.providesSymbol);
      if (assemblySupported) {
        assemblySupported =
            bindings.library.lookupFunction<Int32 Function(), int Function()>(
              'fs_pcm_output_version',
            )() ==
            1;
      }
      saved = AudioSavedWork(
        media: media,
        bindings: bindings,
        configuration: configuration,
        changed: _notify,
        committed: committed,
        nowMs: nowMs,
      );
      compression = AudioCompressionMedia(
        media: media,
        startWorker:
            ({
              required lease,
              required input,
              required inputDescriptor,
              required outputDescriptor,
              required ownerLockDescriptor,
              required current,
            }) {
              final selected = executable;
              if (selected == null) {
                throw const AudioTransformBlocked('audio_codec_unavailable');
              }
              return NativeAudioCompressionWorker(
                bindings: bindings,
                executable: selected,
              ).start(
                lease: lease,
                input: input,
                inputDescriptor: inputDescriptor,
                outputDescriptor: outputDescriptor,
                ownerLockDescriptor: ownerLockDescriptor,
                current: current,
              );
            },
      );
      destinations = AudioExportDestinations(
        media: media,
        now: () => _clock.elapsed,
        forbiddenRoots: [
          if (configuration.installationRoot case final root?) root,
        ],
      );
      exports = AudioExportMedia(
        media: media,
        destinations: destinations,
        startWorker:
            ({
              required lease,
              required manifest,
              required outputDescriptor,
              required current,
            }) {
              final selected = executable;
              if (selected == null) {
                throw const AudioTransformBlocked('audio_codec_unavailable');
              }
              return NativeAudioAssemblyWorker(
                bindings: bindings,
                executable: selected,
              ).start(
                lease: lease,
                manifest: manifest,
                outputDescriptor: outputDescriptor,
                current: current,
              );
            },
      );
      transforms = AudioTransformScheduler(
        store: media.audio,
        ownerGeneration: media.ownerGeneration,
        prepare: (lease, current) => executable == null
            ? Future.error(
                const AudioTransformBlocked('audio_codec_unavailable'),
              )
            : switch (lease.job.kind) {
                AudioTransformKind.compression => compression.prepare(
                  lease,
                  current,
                ),
                AudioTransformKind.export => exports.prepare(lease, current),
                AudioTransformKind.playback => Future.error(
                  const AudioTransformBlocked('Playback is service-owned'),
                ),
              },
        nowMs: nowMs,
        committed: (_) => _notify(),
        changed: _notify,
      );
      player = SavedAudioPlayer(
        openSource: (session, current) async {
          _check(current);
          return NativeAudioPlaybackSource.open(
            media: media,
            bindings: bindings,
            executable: executable!,
            sessionId: session,
          );
        },
        openOutput: (generation, current) => NativePcmOutput.start(
          bindings: bindings,
          generation: generation,
          current: current,
        ),
        changed: _notify,
      );
      erasure = AudioMediaErasure(
        media: media,
        sessionQuiesced: (session) =>
            captureActivity().activeSessionId != session &&
            !saved.restartRequired &&
            !transforms.restartRequired &&
            !player.restartRequired,
      );
      _savedSuspended = false;
      _initialized = true;
    } catch (_) {
      // Component constructors admit no native work; failed setup can safely
      // release its unopened media graph instead of stranding the profile lock.
      media.close();
      rethrow;
    }
  }

  void _notify() {
    try {
      changed();
    } catch (_) {
      /* Presentation does not own work. */
    }
  }

  void _check(bool Function() current, {bool allowMaintenance = false}) {
    if (!_active || _closed || _fatal || _restartRequired || !current()) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Saved audio is unavailable in this service session',
      );
    }
    if (_maintenance && !allowMaintenance) {
      throw RpcError(RpcErrorCode.busy, 'Audio maintenance is running');
    }
    media.ensureAvailable();
    bindings.checkAvailable();
  }

  bool get _restartRequired =>
      _initialized &&
      (bindings.restartRequired ||
          saved.restartRequired ||
          transforms.restartRequired ||
          player.restartRequired);

  // A quarantined worker must not hide the retained recording or its fault.
  // This read admits no native work and still verifies the physical DB binding.
  void _checkRead(bool Function() current) {
    if (!_active || _closed || !current()) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Saved audio is unavailable in this service session',
      );
    }
    if (_maintenance) {
      throw RpcError(RpcErrorCode.busy, 'Audio maintenance is running');
    }
    media.ensureAvailable();
  }

  AudioSession _session(String id, {bool live = false}) {
    final session = media.audio.session(id);
    if (session == null ||
        session.workspaceEpoch != store.workspaceEpoch ||
        (live &&
            (!media.audio.mediaAdmitted ||
                session.storageGeneration != media.audio.storageGeneration))) {
      throw RpcError(RpcErrorCode.notFound, 'Recording is unavailable');
    }
    return session;
  }

  @override
  bool get busy {
    if (!_initialized || _closed) return false;
    if (_maintenance ||
        _background != null ||
        (_storageHeadroom?.busy ?? false) ||
        saved.busy ||
        transforms.busy ||
        player.busy) {
      return true;
    }
    if (_fatal) return false;
    try {
      return media.audio.nextPendingJob(nowMs: nowMs()) != null ||
          media.audio.nextSegmentation() != null ||
          media.audio.nextPendingTransformJob(nowMs: nowMs()) != null;
    } on IncompatibleReadSchema catch (error) {
      // Lifetime observation must still settle requests and join actual owners
      // after schema reads retire. Pending rows grant no new work authority.
      // The in-flight checks above remain authoritative until their real exit.
      _fatal = true;
      lastError = error.toString();
      return false;
    }
  }

  void _wake() {
    if (!_fatal && _restartRequired) {
      _fatal = true;
      _notify();
    }
    if (!_active || _closed || _maintenance || _fatal || _background != null) {
      return;
    }
    final work = _backgroundTurn();
    _background = work;
    work
        .catchError((Object _) {
          lastError = 'Saved audio processing needs attention';
          _notify();
        })
        .whenComplete(() => _background = null)
        .ignore();
  }

  Future<void> _backgroundTurn() async {
    await Future<void>.value();
    if (_closed || _maintenance || _fatal) return;
    media.ensureAvailable();
    compression.admitPending(limit: 16);
    // An unrelated new capture must not starve an already authorized deletion.
    await erasure.drain(current: () => !_closed && !_maintenance, limit: 4);
    if (_closed || _maintenance) return;
    if (captureOwned() || player.busy || _playbackStarting) {
      await transforms.suspend();
      return;
    }
    if (transforms.suspended) transforms.resume();
    transforms.runOne().catchError((Object _) {
      lastError = 'Saved audio conversion needs attention';
      _notify();
    }).ignore();
    await compression.purgeReady(limit: 4);
  }

  @override
  Future<void> prepareForCapture() async {
    _check(() => true, allowMaintenance: !_captureBlocked);
    if (_captureBlocked) {
      throw RpcError(RpcErrorCode.busy, 'Audio storage is changing');
    }
    if (_maintenance) await _maintenanceWork;
    _check(() => true);
    await transforms.suspend();
    await player.stop(clearSelection: true);
    await compression.fencePurges();
    _check(() => true);
  }

  @override
  void prepareSpan(
    AudioSpan span, {
    required String modelRevision,
    required Map<AudioSource, int> sourceStarts,
  }) {
    _check(() => !_captureBlocked, allowMaintenance: true);
    saved.prepareSpan(
      span,
      modelRevision: modelRevision,
      sourceStarts: sourceStarts,
    );
  }

  @override
  void published(AudioChunk chunk) => saved.published(chunk);
  @override
  void spanSealed(AudioSpan span) => saved.spanSealed(span);
  @override
  void captureStopped(AudioSession session) {
    saved.captureStopped(session);
    _wake();
  }

  @override
  Future<AudioMeetingReadPage> readMeeting(
    int meetingId, {
    String afterSessionId = '',
    int limit = 32,
    required bool Function() current,
  }) async {
    _checkRead(current);
    final available = !_fatal && !_restartRequired;
    final queries = AudioQueries(media.audio), activity = captureActivity();
    final sessions = queries.sessions(
      meetingId,
      afterId: afterSessionId,
      limit: limit,
      activity: activity,
      playbackSupported: available && assemblySupported,
      exportFormats: available && assemblySupported
          ? const [MeetingAudioExportFormat.opus, MeetingAudioExportFormat.mp3]
          : const [],
      allowDeleteRecordings: available,
      allowRetentionChanges: available,
      allowRetryTranscription: available,
      allowRetryCompression: available && executable != null,
    );
    final playing = player.sessionId;
    final owns =
        playing != null && media.audio.session(playing)?.meetingId == meetingId;
    return AudioMeetingReadPage(
      meeting: queries.meeting(
        meetingId,
        activity: activity,
        estimatedRemainingRecordingUs: available && media.audio.mediaAdmitted
            ? _storageHeadroom?.estimatedRemainingRecordingUs
            : null,
      ),
      sessions: sessions,
      nextAfterId: sessions.length == limit ? sessions.last.id : null,
      serviceError: !available
          ? 'Saved audio processing stopped unexpectedly. Restart the app to continue.'
          : lastError.isNotEmpty
          ? lastError
          : saved.lastError.isNotEmpty
          ? saved.lastError
          : executable == null && sessions.isNotEmpty
          ? 'Audio conversion is unavailable in this installation.'
          : '',
      playbackSessionId: owns ? playing : null,
      playback: owns ? player.presentation : const AudioPlaybackPresentation(),
    );
  }

  @override
  Future<AudioTranscriptSeekTarget?> transcriptTarget(
    int transcriptId, {
    required bool Function() current,
  }) async {
    _check(current);
    return assemblySupported
        ? AudioQueries(media.audio).transcriptSeekTarget(transcriptId)
        : null;
  }

  void _playable(String session, bool Function() current) {
    _check(current);
    _session(session, live: true);
    if (!assemblySupported) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Saved audio playback is unavailable in this installation',
      );
    }
    if (captureOwned()) {
      throw RpcError(
        RpcErrorCode.busy,
        'Finish meeting capture before playing saved audio',
      );
    }
  }

  @override
  Future<void> play(
    String sessionId, {
    required bool Function() current,
  }) async {
    _playable(sessionId, current);
    _playbackStarting = true;
    try {
      await transforms.suspend();
      _playable(sessionId, current);
      await player.play(sessionId, current: current);
    } finally {
      _playbackStarting = false;
      _wake();
    }
  }

  @override
  Future<void> pauseAudio(
    String sessionId, {
    required bool Function() current,
  }) async {
    _check(current);
    await player.pause(sessionId, current: current);
    _wake();
  }

  @override
  Future<void> seek(
    String sessionId,
    int playbackUs, {
    required bool Function() current,
  }) => _seek(sessionId, playbackUs, exactFrame: false, current: current);

  Future<void> _seek(
    String sessionId,
    int position, {
    required bool exactFrame,
    required bool Function() current,
  }) async {
    _playable(sessionId, current);
    _playbackStarting = true;
    try {
      await transforms.suspend();
      _playable(sessionId, current);
      if (exactFrame) {
        await player.seekFrame(sessionId, position, current: current);
      } else {
        await player.seek(sessionId, position, current: current);
      }
    } finally {
      _playbackStarting = false;
      _wake();
    }
  }

  @override
  Future<void> seekTranscript(
    String sessionId,
    int transcriptId, {
    required bool Function() current,
  }) async {
    final target = await transcriptTarget(transcriptId, current: current);
    if (target == null || target.sessionId != sessionId) {
      throw RpcError(RpcErrorCode.notFound, 'Transcript audio is unavailable');
    }
    if (target.playbackFrame case final frame?) {
      await _seek(sessionId, frame, exactFrame: true, current: current);
    } else {
      await seek(sessionId, target.playbackUs, current: current);
    }
  }

  void _exportable(String session, bool Function() current) {
    _check(current);
    _session(session, live: true);
    if (!assemblySupported) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Saved audio export is unavailable in this installation',
      );
    }
  }

  @override
  Future<AudioExportDestinationGrant> authorizeExportDestination({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String outputPath,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  }) async {
    _exportable(sessionId, current);
    if (format == MeetingAudioExportFormat.wav) {
      throw RpcError(RpcErrorCode.invalidArgument, 'Choose Opus or MP3');
    }
    return destinations.authorize(
      sessionId: sessionId,
      callerIdentity: callerIdentity,
      workspaceEpoch: workspaceEpoch,
      format: format,
      outputPath: outputPath,
      overwrite: overwrite,
      allowIncomplete: allowIncomplete,
      current: current,
    );
  }

  @override
  Future<AudioExportJobReceipt> export({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String destinationToken,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  }) async {
    _exportable(sessionId, current);
    if (format == MeetingAudioExportFormat.wav) {
      throw RpcError(RpcErrorCode.invalidArgument, 'Choose Opus or MP3');
    }
    final destination = destinations.consume(
      token: destinationToken,
      sessionId: sessionId,
      callerIdentity: callerIdentity,
      workspaceEpoch: workspaceEpoch,
      format: format,
      overwrite: overwrite,
      allowIncomplete: allowIncomplete,
      current: current,
    );
    var admitted = false;
    AudioTransformJob? job;
    try {
      job = media.audio.createExportJob(
        sessionId: sessionId,
        codec: format.name,
        container: format == MeetingAudioExportFormat.opus ? 'ogg' : 'mp3',
        settingsRevision: 'shared-assembly-v1',
        settings: {
          ...destination.frozenJobSettings,
          'mix_gain': 'half-per-source-v1',
        },
        allowIncomplete: allowIncomplete,
      );
      destination.bindJob(job, current: () => _active && !_closed && !_fatal);
      admitted = true;
      _wake();
      _notify();
      return AudioExportJobReceipt(job.id);
    } finally {
      if (!admitted) {
        destination.markWorkerClosed();
        destination.close();
        if (job != null) media.audio.abandonTransformJob(job.id);
      }
    }
  }

  @override
  Future<void> cancelExport(
    String sessionId, {
    required bool Function() current,
  }) async {
    _check(current);
    _session(sessionId);
    var after = '';
    while (true) {
      final page = AudioWorkQueries(
        media.audio,
      ).unfinishedExports(sessionId, afterId: after);
      if (page.isEmpty) break;
      for (final id in page) {
        _check(current);
        await transforms.cancel(id);
        final destination = destinations.leaseForJob(id);
        if (destination != null) {
          destination.markWorkerClosed();
          try {
            destination.abort();
          } finally {
            destination.close();
          }
        }
      }
      after = page.last;
      await Future<void>.delayed(Duration.zero);
    }
    _notify();
  }

  @override
  void invalidateCaller(Object caller) {
    if (_initialized) destinations.invalidateCaller(caller);
  }

  @override
  Future<void> retryTranscription(
    String sessionId, {
    required bool Function() current,
  }) => _retry(sessionId, transcription: true, current: current);

  @override
  Future<void> retryCompression(
    String sessionId, {
    required bool Function() current,
  }) => _retry(sessionId, transcription: false, current: current);

  Future<void> _retry(
    String sessionId, {
    required bool transcription,
    required bool Function() current,
  }) async {
    _check(current);
    _session(sessionId, live: true);
    var after = '';
    while (true) {
      final page = transcription
          ? AudioWorkQueries(
              media.audio,
            ).retryableTranscription(sessionId, afterId: after)
          : AudioWorkQueries(
              media.audio,
            ).retryableCompression(sessionId, afterId: after);
      if (page.isEmpty) break;
      for (final id in page) {
        _check(current);
        if (transcription) {
          media.audio.retryJob(id);
        } else {
          media.audio.retryTransformJob(id);
        }
      }
      after = page.last;
      await Future<void>.delayed(Duration.zero);
    }
    saved.wake();
    _wake();
    _notify();
  }

  Future<T> _maintain<T>(
    Future<T> Function() use, {
    required bool blockCapture,
    required bool Function() current,
  }) {
    _check(current);
    if (_modelsSuspended) {
      return Future.error(
        RpcError(RpcErrorCode.busy, 'Audio model configuration is running'),
      );
    }
    if (blockCapture && captureOwned()) {
      return Future.error(
        RpcError(
          RpcErrorCode.busy,
          'Finish recording before changing audio storage',
        ),
      );
    }
    _maintenance = true;
    _captureBlocked = blockCapture;
    final work = Future<T>.sync(use).whenComplete(() {
      _maintenance = false;
      _captureBlocked = false;
      _quiescent = false;
      if (!_closed && !_fatal) {
        if (_savedSuspended && !_modelsSuspended) {
          saved.resume();
          _savedSuspended = false;
        }
        _wake();
      }
    });
    _maintenanceWork = work;
    work.ignore();
    return work;
  }

  Future<void> _joinBackground() async {
    try {
      await _background;
    } catch (_) {
      // The actual background owner has settled. A refused unrelated erasure
      // remains durable and reported; it cannot prevent targeted maintenance.
      // Worker/publication ownership is still joined independently below.
    }
  }

  Future<void> _pauseAll() async {
    await _joinBackground();
    _savedSuspended = true;
    try {
      await Future.wait([
        saved.suspend(),
        transforms.suspend(),
        player.stop(clearSelection: true),
        compression.fencePurges(),
        erasure.fence(),
      ]);
      await media.fencePublications();
      _quiescent = !captureOwned();
      if (!_quiescent) throw StateError('Capture ownership has not retired');
    } catch (_) {
      _fatal = true;
      rethrow;
    }
  }

  @override
  Future<void> deleteRecording(
    String sessionId, {
    required bool Function() current,
  }) => _maintain(
    () async {
      final session = _session(sessionId);
      if (!session.captureState.terminal) {
        throw RpcError(
          RpcErrorCode.busy,
          'Finish recording before deleting its audio',
        );
      }
      await _pauseAll();
      _check(current, allowMaintenance: true);
      _session(sessionId);
      destinations.closeBoundLeases(
        discardUnpublished: true,
        sessionId: sessionId,
      );
      media.audio.tombstoneSession(sessionId);
      await erasure.eraseSession(
        sessionId,
        session.storageGeneration,
        current: () => !_closed && current(),
      );
      _notify();
    },
    blockCapture: true,
    current: current,
  );
  @override
  Future<void> setRetainLossless(
    String sessionId,
    bool value, {
    required bool Function() current,
  }) => _maintain(
    () async {
      _session(sessionId, live: true);
      // Persist before awaiting a purge already in flight. Every later phase
      // rechecks this flag; bytes already removed cannot be recreated.
      media.audio.setRetainLossless(sessionId, value);
      await _joinBackground();
      await transforms.suspend();
      await compression.fencePurges();
      _check(current, allowMaintenance: true);
      if (value) {
        var after = '';
        while (true) {
          final page = await compression.restoreRetainedOriginals(
            sessionId,
            afterId: after,
            quiesced: () => _maintenance && !transforms.busy,
            current: () => !_closed && current(),
          );
          if (page.nextAfterId == null) break;
          after = page.nextAfterId!;
        }
      }
      _notify();
    },
    blockCapture: false,
    current: current,
  );
  @override
  Future<void> suspendForModelChange() async {
    _check(() => true);
    _modelsSuspended = true;
    try {
      await saved.suspend();
      _savedSuspended = true;
    } catch (_) {
      _fatal = true;
      rethrow;
    }
  }

  @override
  Future<void> resumeAfterModelChange() async {
    _modelsSuspended = false;
    if (!_closed && !_fatal && !_maintenance && _savedSuspended) {
      saved.resume();
      _savedSuspended = false;
    }
  }

  @override
  Future<void> clearWorkspace(Future<void> Function() clear) => _maintain(
    () async {
      await _pauseAll();
      final epoch = store.workspaceEpoch,
          generation = media.audio.storageGeneration;
      Object? failure;
      StackTrace? trace;
      try {
        await clear();
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      // Workspace clear can commit before account/file cleanup fails. A
      // committed rotation must never resume old bindings or model readers.
      final rotated =
          epoch != store.workspaceEpoch ||
          generation != media.audio.storageGeneration;
      if (rotated || failure == null) {
        try {
          await _closeComponents(discardUnpublished: true);
        } catch (error, stack) {
          failure ??= error;
          trace ??= stack;
        }
        try {
          if (!_initialized && !_closed) {
            await _openComponents();
            bindCapture(media, this);
            saved.activate();
            _active = true;
          } else if (_initialized) {
            throw StateError('Previous audio ownership could not be released');
          }
        } catch (error, stack) {
          _fatal = true;
          failure ??= error;
          trace ??= stack;
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
    },
    blockCapture: true,
    current: () => !_closed,
  );
  Future<AudioProfileBackup> backup(
    String destination, {
    required bool Function() current,
  }) => _maintain(
    () async {
      await _pauseAll();
      return AudioProfileBackups(
        forbiddenRoots: audioBackupForbiddenRoots(
          configuration: configuration,
          profileDirectory: p.dirname(store.path),
          runtimeDirectory: runtimeDirectory,
        ),
      ).create(
        media: media,
        authorizedDestination: destination,
        quiesced: () => _maintenance && _quiescent && !captureOwned(),
        current: () => !_closed && current(),
      );
    },
    blockCapture: true,
    current: current,
  );
  Future<void> _closeComponents({bool discardUnpublished = false}) async {
    await Future.wait([
      if (_storageHeadroom case final storage?) storage.close(),
      saved.close(),
      transforms.close(),
      player.close(),
      compression.fencePurges(),
      erasure.fence(),
    ]);
    await media.fencePublications();
    if (captureOwned() ||
        bindings.restartRequired ||
        saved.restartRequired ||
        transforms.restartRequired ||
        player.restartRequired) {
      throw StateError('Audio ownership is unconfirmed; restart the service');
    }
    Object? cleanupFailure;
    StackTrace? cleanupStack;
    try {
      destinations.closeBoundLeases(discardUnpublished: discardUnpublished);
    } catch (error, stack) {
      // An actual-close refusal keeps the media lock. An external staging
      // conflict has already closed all descriptor owners while preserving its
      // uncertain bytes, so a committed workspace rotation can still rebind.
      if (destinations.boundLeaseCount != 0) rethrow;
      cleanupFailure = error;
      cleanupStack = stack;
    }
    destinations.close();
    _storageHeadroom = null;
    media.close();
    _initialized = false;
    if (cleanupFailure != null) {
      Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
    _closed = true;
    _active = false;
    _captureBlocked = true;
    _timer?.cancel();
    _timer = null;
    // Recovery has its own native join/retirement owner. It is not yet in
    // media.fencePublications while reconciling, so join startup explicitly.
    try {
      await _initializing;
    } catch (_) {
      /* Startup cancellation still leaves actual cleanup owners to join. */
    }
    try {
      await _maintenanceWork;
    } catch (_) {
      /* Still join every remaining owner. */
    }
    try {
      await _background;
    } catch (_) {
      /* Still join every remaining owner. */
    }
    if (_initialized) await _closeComponents();
  }();
}
