import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../application_services/audio_transform_scheduler.dart';
import '../application_services/native_audio_media.dart';
import '../audio_models.dart';
import '../native_lifetime.dart';
import '../recording_capture.dart';
import 'audio_store.dart';
import 'backup_files.dart';
import 'recording_media.dart';

const audioOpusSettingsRevision = 'ogg-opus-mono-v1';
const audioOpusSettings = <String, Object?>{
  'sample_rate_hz': 48000,
  'channels': 1,
  'bitrate_bps': 32000,
  'complexity': 5,
  'frame_duration_ms': 20,
  'vbr': true,
  'application': 'audio',
  'encoder': 'libopusenc',
  'encoder_version': '0.3',
  'opus_version': '1.6.1',
};

/// Real fixed-codec capability, supplied by verified installation composition.
/// This factory receives owned descriptors and no caller-selected executable.
final class NativeAudioCompressionWorker {
  NativeAudioCompressionWorker({
    required this.bindings,
    required this.executable,
  });
  final NativeLibrary bindings;
  final AudioMediaExecutable executable;

  Future<AudioTransformExecution> start({
    required AudioTransformLease lease,
    required AudioRepresentation input,
    required int inputDescriptor,
    required int outputDescriptor,
    required int ownerLockDescriptor,
    required bool Function() current,
  }) async {
    final task = await NativeAudioMediaTask.start(
      bindings: bindings,
      executable: executable,
      request: AudioMediaRequest(
        operation: AudioMediaOperation.encodeRecordingWav,
        sessionId: lease.job.sessionId,
        jobId: lease.job.id,
        epoch: lease.leaseGeneration,
        inputSha256: input.sha256,
        sourceFrames: input.decodedSamples,
      ),
      inputDescriptor: inputDescriptor,
      outputDescriptor: outputDescriptor,
      ownerLockDescriptor: ownerLockDescriptor,
      current: current,
    );
    if (!current()) {
      try {
        task.cancel();
      } catch (_) {
        /* Return the real exit owner. */
      }
    }
    return _NativeCompressionExecution(task, executable);
  }
}

final class _NativeCompressionExecution implements AudioTransformExecution {
  _NativeCompressionExecution(this.task, this.executable);
  final NativeAudioMediaTask task;
  final AudioMediaExecutable executable;
  @override
  Future<AudioEncodedResult> get result => task.result.then(
    (r) => AudioEncodedResult(
      sha256: r.outputSha256,
      byteLength: r.outputBytes,
      frames: r.frames,
      preSkip: r.preSkip,
      finalGranule: r.finalGranule,
      workerBuildId: executable.buildId,
      workerSha256: executable.sha256,
    ),
  );
  @override
  Future<void> get closed => task.closed;
  @override
  void cancel() => task.cancel();
}

typedef AudioCompressionStart =
    Future<AudioTransformExecution> Function({
      required AudioTransformLease lease,
      required AudioRepresentation input,
      required int inputDescriptor,
      required int outputDescriptor,
      required int ownerLockDescriptor,
      required bool Function() current,
    });

/// Managed compressed output publication. All paths come from current DB
/// manifests inside the private session directory, never an RPC argument.
final class AudioCompressionMedia {
  AudioCompressionMedia({
    required this.media,
    required this.startWorker,
    this.publicationObserver,
    bool Function(String sessionId)? retainLossless,
  }) : retainLossless = retainLossless ?? media.audio.retainLossless;
  final RecordingMedia media;
  final AudioCompressionStart startWorker;
  final bool Function(String sessionId) retainLossless;

  /// Service-owned fault fixture; never decoded from a client request.
  final void Function(String phase)? publicationObserver;
  final _knownClosed = <String>{};
  String _afterRepresentation = '';
  String _afterPurge = '';
  Future<int>? _purges;
  final _mediaReads = <Future<dynamic>>{};
  AudioStore get store => media.audio;

  /// Run after ASR/cursor changes too: compression may still have live input
  /// dependencies. The service joins [fencePurges] before media deletion/close.
  Future<int> purgeReady({int limit = 16}) {
    if (limit < 1 || limit > 128) throw ArgumentError.value(limit, 'limit');
    if (_purges case final work?) return work;
    late final Future<int> work;
    work = _purgeReady(limit).whenComplete(() => _purges = null);
    _purges = work;
    work.ignore();
    return work;
  }

  Future<void> fencePurges() async {
    Object? failure;
    StackTrace? trace;
    try {
      await _purges;
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    while (_mediaReads.isNotEmpty) {
      try {
        await Future.wait(List<Future<dynamic>>.from(_mediaReads));
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  Future<T> _track<T>(Future<T> source) {
    late final Future<T> work;
    work = source.whenComplete(() => _mediaReads.remove(work));
    _mediaReads.add(work);
    work.ignore();
    return work;
  }

  /// Set the durable keep flag first, then fence actual purge/scheduler owners
  /// before calling. Each bounded page verifies raw SHA and WAV identity before
  /// withdrawing its pending purge fence. No absent original is recreated.
  Future<({int restored, String? nextAfterId})> restoreRetainedOriginals(
    String sessionId, {
    String afterId = '',
    int limit = 64,
    required bool Function() quiesced,
    required bool Function() current,
  }) {
    if (limit < 1 || limit > 128) throw ArgumentError.value(limit, 'limit');
    return _track(
      _restoreRetainedOriginals(sessionId, afterId, limit, quiesced, current),
    );
  }

  Future<({int restored, String? nextAfterId})> _restoreRetainedOriginals(
    String sessionId,
    String afterId,
    int limit,
    bool Function() quiesced,
    bool Function() current,
  ) async {
    void check() {
      if (!current() || !quiesced() || !store.retainLossless(sessionId)) {
        throw StateError(
          'Hold the lossless retention fence through validation',
        );
      }
      media.sessionDirectory(sessionId);
    }

    check();
    final rows = store.db
        .select(
          "SELECT r.* FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id WHERE c.session_id=? AND r.id>? AND r.codec='pcm_s16le' AND r.state='superseded_pending_purge' ORDER BY r.id LIMIT ?",
          [sessionId, afterId, limit],
        )
        .map((r) => AudioRepresentation.fromRow(r))
        .toList();
    var restored = 0;
    for (final raw in rows) {
      check();
      final chunk = store.chunk(raw.chunkId)!;
      if (raw.relativePath !=
          'recordings/${chunk.storageGeneration}/$sessionId/${chunk.id}.wav') {
        throw StateError('Lossless original is outside its owned directory');
      }
      final retained = store.usableRepresentations(chunk.id).firstOrNull;
      if (retained == null) {
        throw StateError('Pending lossless cleanup has no retained owner');
      }
      final reference = store.acquireReference(
        retained.id,
        ownerGeneration: media.ownerGeneration,
        purpose: 'restore-retained-original',
      );
      BackupDirectory? directory;
      try {
        directory = BackupDirectory(
          media.sessionDirectory(sessionId),
          create: false,
        );
        final name = '${chunk.id}.wav';
        if (!directory.entryExists(name)) {
          store.completePurge(raw.id);
          continue;
        }
        final ordinal =
            store.db.select('SELECT ordinal FROM recording_spans WHERE id=?', [
                  chunk.spanId,
                ]).single['ordinal']
                as int;
        final identity = await _validateRawOffThread(
          directory.path,
          raw,
          chunk,
          ordinal,
        );
        check();
        directory.verifyAnchor();
        if (directory.metadata(name).identity != identity) {
          throw StateError('Lossless original changed during validation');
        }
        store.cancelRawPurge(raw.id, verifiedSha256: raw.sha256);
        restored++;
      } finally {
        directory?.close();
        store.releaseReference(reference);
      }
    }
    return (
      restored: restored,
      nextAfterId: rows.length == limit ? rows.last.id : null,
    );
  }

  Future<int> _purgeReady(int limit) async {
    if (!store.mediaAdmitted) return 0;
    List<Map<String, Object?>> page(String after) => store.db
        .select(
          "SELECT r.* FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_sessions s ON s.id=c.session_id WHERE r.id>? AND r.codec='pcm_s16le' AND r.state IN ('published','superseded_pending_purge') AND s.storage_generation=? AND s.workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) AND EXISTS(SELECT 1 FROM audio_representations k WHERE k.chunk_id=c.id AND k.codec='opus' AND k.state='published' AND k.validated=1) ORDER BY r.id LIMIT ?",
          [after, store.storageGeneration, store.workspaceEpoch(), limit],
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    var rows = page(_afterPurge);
    if (rows.isEmpty && _afterPurge.isNotEmpty) {
      _afterPurge = '';
      rows = page('');
    }
    var completed = 0;
    for (final row in rows) {
      final raw = AudioRepresentation.fromRow(row);
      _afterPurge = raw.id;
      final sessionId = store.chunk(raw.chunkId)?.sessionId;
      if (sessionId == null || retainLossless(sessionId)) continue;
      if (raw.state == AudioRepresentationState.supersededPendingPurge ||
          store.beginRawPurge(raw.chunkId) != null) {
        await _purge(raw);
        if (store
            .representations(raw.chunkId)
            .any(
              (r) =>
                  r.id == raw.id && r.state == AudioRepresentationState.purged,
            )) {
          completed++;
        }
      }
    }
    return completed;
  }

  Future<void> _purge(AudioRepresentation raw) => _track(_purgeOwned(raw));
  Future<void> _purgeOwned(AudioRepresentation raw) async {
    final chunk = store.chunk(raw.chunkId);
    if (chunk == null ||
        raw.relativePath !=
            'recordings/${chunk.storageGeneration}/${chunk.sessionId}/${chunk.id}.wav') {
      throw StateError('Raw purge path is not owned');
    }
    final directory = BackupDirectory(
      media.sessionDirectory(chunk.sessionId),
      create: false,
    );
    String? retainedReference;
    try {
      final retained = store
          .usableRepresentations(chunk.id)
          .where((r) => r.codec == 'opus' && r.container == 'ogg')
          .firstOrNull;
      if (retained == null ||
          !RegExp(
            r'^[0-9a-f-]{36}\.opus$',
          ).hasMatch(retained.relativePath.split('/').last) ||
          retained.relativePath !=
              'recordings/${chunk.storageGeneration}/${chunk.sessionId}/${retained.relativePath.split('/').last}') {
        throw StateError('No owned retained representation permits raw purge');
      }
      retainedReference = store.acquireReference(
        retained.id,
        ownerGeneration: media.ownerGeneration,
        purpose: 'raw-purge-validation',
      );
      final retainedName = retained.relativePath.split('/').last,
          retainedPath = directory.path;
      await Isolate.run(
        () => _verifyRetained(retainedPath, retainedName, retained),
      );
      media.sessionDirectory(chunk.sessionId);
      if (retainLossless(chunk.sessionId)) return;
      if (!store
          .usableRepresentations(chunk.id)
          .any((r) => r.id == retained.id && r.sha256 == retained.sha256)) {
        throw StateError('Retained media changed before raw purge');
      }
      final name = '${chunk.id}.wav';
      if (directory.entryExists(name)) {
        final ordinal =
                store.db.select(
                      'SELECT ordinal FROM recording_spans WHERE id=?',
                      [chunk.spanId],
                    ).single['ordinal']
                    as int,
            path = directory.path;
        final identity = await Isolate.run(
          () => _validateCompressionInput(path, raw, chunk, ordinal),
        );
        media.sessionDirectory(chunk.sessionId);
        if (retainLossless(chunk.sessionId)) return;
        final current = store
            .representations(chunk.id)
            .singleWhere((r) => r.id == raw.id);
        if (current.state != AudioRepresentationState.supersededPendingPurge) {
          throw StateError('Raw purge authority changed');
        }
        directory.remove(name, expectedIdentity: identity);
        directory.sync();
      }
      media.sessionDirectory(chunk.sessionId);
      store.completePurge(raw.id);
    } finally {
      if (retainedReference != null) store.releaseReference(retainedReference);
      directory.close();
    }
  }

  /// Bounded, wraparound discovery. Frozen settings make repeated admission
  /// idempotent; pending transform dependencies prevent raw purge immediately.
  int admitPending({int limit = 64}) {
    if (limit < 1 || limit > 128) throw ArgumentError.value(limit, 'limit');
    if (!store.mediaAdmitted) return 0;
    List<Map<String, Object?>> page(String after) => store.db
        .select(
          "SELECT r.id,c.session_id FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_sessions s ON s.id=c.session_id WHERE r.id>? AND r.codec='pcm_s16le' AND r.container='wav' AND r.settings_revision='recording-wav-v1' AND r.state='published' AND r.validated=1 AND c.state='published' AND s.storage_generation=? AND s.workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) AND NOT EXISTS(SELECT 1 FROM audio_transform_jobs j JOIN audio_transform_inputs i ON i.job_id=j.id WHERE i.representation_id=r.id AND j.kind='compression' AND j.settings_revision=?) AND NOT EXISTS(SELECT 1 FROM audio_representations k WHERE k.chunk_id=c.id AND k.codec='opus' AND k.state='published' AND k.validated=1) ORDER BY r.id LIMIT ?",
          [
            after,
            store.storageGeneration,
            store.workspaceEpoch(),
            audioOpusSettingsRevision,
            limit,
          ],
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    var rows = page(_afterRepresentation);
    if (rows.isEmpty && _afterRepresentation.isNotEmpty) {
      _afterRepresentation = '';
      rows = page('');
    }
    for (final row in rows) {
      _afterRepresentation = row['id'] as String;
      store.createTransformJob(
        sessionId: row['session_id'] as String,
        kind: AudioTransformKind.compression,
        inputs: [row['id'] as String],
        codec: 'opus',
        container: 'ogg',
        settingsRevision: audioOpusSettingsRevision,
        settings: audioOpusSettings,
      );
    }
    return rows.length;
  }

  Future<AudioTransformOperation> prepare(
    AudioTransformLease lease,
    bool Function() current,
  ) async {
    if (lease.job.kind != AudioTransformKind.compression ||
        lease.job.codec != 'opus' ||
        lease.job.container != 'ogg' ||
        lease.job.settingsRevision != audioOpusSettingsRevision ||
        !_sameSettings(jsonDecode(lease.job.settings), audioOpusSettings)) {
      throw const AudioTransformBlocked('unsupported_compression_settings');
    }
    final inputs = store.transformInputs(lease.job.id, limit: 2);
    if (inputs.length != 1) {
      throw const AudioTransformBlocked('invalid_compression_input');
    }
    final input = inputs.single, chunk = store.chunk(inputs.single.chunkId);
    if (chunk == null ||
        input.codec != 'pcm_s16le' ||
        input.container != 'wav' ||
        input.settingsRevision != 'recording-wav-v1' ||
        input.relativePath !=
            'recordings/${chunk.storageGeneration}/${chunk.sessionId}/${chunk.id}.wav' ||
        chunk.sampleRate != 48000 ||
        chunk.channels != 1 ||
        chunk.sampleCount < 1 ||
        chunk.sampleCount > 240000 ||
        input.decodedSamples != chunk.sampleCount ||
        input.sha256 != chunk.sha256 ||
        input.byteLength != chunk.byteLength) {
      throw const AudioTransformBlocked('invalid_compression_input');
    }
    final row = store.db.select(
      'SELECT ordinal FROM recording_spans WHERE id=?',
      [chunk.spanId],
    ).single;
    final operation = _CompressionOperation(
      this,
      lease,
      input,
      chunk,
      row['ordinal'] as int,
      current,
    );
    try {
      await operation.prepare();
      return operation;
    } catch (_) {
      operation.close();
      rethrow;
    }
  }
}

bool _sameSettings(Object? a, Map<String, Object?> b) =>
    a is Map &&
    a.length == b.length &&
    b.entries.every((e) => a[e.key] == e.value);

final class _CompressionOperation implements AudioTransformOperation {
  _CompressionOperation(
    this.owner,
    this.lease,
    this.input,
    this.chunk,
    this.ordinal,
    this.admitted,
  );
  final AudioCompressionMedia owner;
  final AudioTransformLease lease;
  final AudioRepresentation input;
  final AudioChunk chunk;
  final int ordinal;
  final bool Function() admitted;
  BackupDirectory? _directory;
  BackupFile? _input, _output;
  Map<String, Object?>? _receipt;
  AudioEncodedResult? _validated;
  bool _workerClosed = true, _closed = false;
  String get _receiptName => '${lease.job.id}.compression-publication.json';
  String get _finalName => '${lease.job.id}.opus';
  String get _partialName => _receipt!['partial_name'] as String;
  @override
  bool get hasValidatedOutput => _validated != null;

  void _check({bool completed = false}) {
    if (_closed) throw StateError('Compression operation is closed');
    final store = owner.store, actual = store.transformJob(lease.job.id);
    if (!store.mediaAdmitted ||
        !owner.media.binding.matches(chunk.storageGeneration) ||
        chunk.storageGeneration != store.storageGeneration ||
        actual == null ||
        actual.inputIdentity != lease.job.inputIdentity ||
        (completed
            ? actual.state != AudioJobState.completed
            : actual.state != AudioJobState.running ||
                  actual.ownerGeneration != lease.ownerGeneration ||
                  actual.leaseGeneration != lease.leaseGeneration)) {
      throw StateError('Compression media authority changed');
    }
    owner.media.sessionDirectory(chunk.sessionId);
    _directory?.verifyAnchor();
  }

  Future<void> prepare() async {
    _check();
    if (!admitted()) throw StateError('Compression admission was cancelled');
    final directory = _directory = BackupDirectory(
      owner.media.sessionDirectory(this.chunk.sessionId),
      create: false,
    );
    final path = directory.path,
        input = this.input,
        chunk = this.chunk,
        ordinal = this.ordinal;
    final inputIdentity = await Isolate.run(
      () => _validateCompressionInput(path, input, chunk, ordinal),
    );
    _check();
    if (!admitted()) throw StateError('Compression admission was cancelled');
    _input = directory.open('${chunk.id}.wav', readOnly: true);
    if (_input!.identity != inputIdentity) {
      throw StateError('Compression input changed');
    }
    if (directory.entryExists(_receiptName)) {
      final file = directory.open(_receiptName, readOnly: true);
      try {
        _receipt = Map<String, Object?>.from(
          jsonDecode(utf8.decode(file.readSmall(16384))) as Map,
        );
      } finally {
        file.close();
      }
      final receipt = _receipt!;
      if (receipt['format'] != 1 ||
          receipt['job'] != lease.job.id ||
          receipt['input_identity'] != lease.job.inputIdentity ||
          receipt['generation'] != chunk.storageGeneration ||
          receipt['epoch'] != owner.store.workspaceEpoch() ||
          receipt['directory_identity'] != directory.identity ||
          receipt['partial_name'] is! String ||
          !RegExp(
            '^${lease.job.id}\\.[0-9a-f-]{36}\\.opus\\.partial\$',
          ).hasMatch(receipt['partial_name'] as String)) {
        throw const AudioTransformBlocked('invalid_compression_receipt');
      }
      if (receipt['owner_generation'] == owner.media.ownerGeneration &&
          !owner._knownClosed.contains(lease.job.id)) {
        throw const AudioTransformBlocked('compression_exit_unconfirmed');
      }
      if (const [
        'publication_pending',
        'published',
      ].contains(receipt['state'])) {
        _validated = _resultFromReceipt(receipt);
        final published = directory.entryExists(_finalName);
        final name = published ? _finalName : _partialName;
        if (directory.metadata(name).identity != receipt['output_identity']) {
          throw const AudioTransformBlocked('compression_publication_conflict');
        }
        final encoded = _validated!,
            identity = receipt['output_identity'] as String;
        await Isolate.run(() => _verifyEncoded(path, name, identity, encoded));
        _check();
        if (!admitted()) {
          throw StateError('Compression admission was cancelled');
        }
        _output = directory.open(name);
        receipt['state'] = published ? 'published' : 'publication_pending';
        receipt['owner_generation'] = owner.media.ownerGeneration;
        _writeReceipt();
        owner._knownClosed.add(lease.job.id);
        return;
      }
      if (receipt['state'] != 'authorized') {
        throw const AudioTransformBlocked('invalid_compression_receipt');
      }
      // Unvalidated crash bytes are never adopted. Remove only a receipt-bound
      // inode; a pre-identity crash orphan remains for session subtree deletion.
      if (directory.entryExists(_partialName) &&
          receipt['output_identity'] != null) {
        directory.remove(
          _partialName,
          expectedIdentity: receipt['output_identity'] as String,
        );
        directory.sync();
      }
    }
    if (directory.entryExists(_finalName)) {
      throw const AudioTransformBlocked('compression_publication_conflict');
    }
    _receipt = {
      'format': 1,
      'job': lease.job.id,
      'input_identity': lease.job.inputIdentity,
      'generation': chunk.storageGeneration,
      'epoch': owner.store.workspaceEpoch(),
      'directory_identity': directory.identity,
      'owner_generation': owner.media.ownerGeneration,
      'partial_name':
          '${lease.job.id}.${AudioStore.newIdentity()}.opus.partial',
      'state': 'authorized',
    };
    _writeReceipt();
    _output = directory.open(_partialName, create: true);
    _output!.sync();
    directory.sync();
    _receipt!['output_identity'] = _output!.identity;
    _writeReceipt();
    owner._knownClosed.add(lease.job.id);
  }

  @override
  Future<AudioTransformExecution> start() async {
    _check();
    if (!admitted() ||
        hasValidatedOutput ||
        _receipt!['state'] != 'authorized') {
      throw StateError('Compression start refused');
    }
    if (_directory!.metadata(_partialName).identity != _output!.identity) {
      throw StateError('Compression output changed');
    }
    _output!.truncateTo(0);
    _workerClosed = false;
    owner._knownClosed.remove(lease.job.id);
    try {
      final execution = await owner.startWorker(
        lease: lease,
        input: input,
        inputDescriptor: _input!.descriptor,
        outputDescriptor: _output!.descriptor,
        ownerLockDescriptor: owner.media.ownerLockDescriptor,
        current: () {
          try {
            _check();
            return admitted();
          } catch (_) {
            return false;
          }
        },
      );
      if (!admitted()) {
        try {
          execution.cancel();
        } catch (_) {
          /* Return the real exit owner. */
        }
      }
      return execution;
    } catch (_) {
      // The fixed start factory's failure contract retires every admitted owner.
      markWorkerClosed();
      rethrow;
    }
  }

  @override
  void markWorkerClosed() {
    _workerClosed = true;
    owner._knownClosed.add(lease.job.id);
  }

  @override
  Future<AudioTransformOutput> publish(AudioEncodedResult? result) async {
    _check();
    if (!_workerClosed || !admitted()) {
      throw StateError('Compression worker has not exited');
    }
    final encoded = result ?? _validated;
    if (encoded == null ||
        encoded.frames != chunk.sampleCount ||
        encoded.byteLength < 1 ||
        encoded.preSkip < 0 ||
        encoded.preSkip > 65535 ||
        encoded.finalGranule != encoded.frames + encoded.preSkip ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(encoded.sha256) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(encoded.workerBuildId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(encoded.workerSha256)) {
      throw const AudioTransformBlocked('invalid_compression_result');
    }
    final directory = _directory!;
    final path = directory.path;
    _output!.sync();
    final name = _receipt!['state'] == 'published' ? _finalName : _partialName;
    final identity = _receipt!['output_identity'] as String;
    await Isolate.run(() => _verifyEncoded(path, name, identity, encoded));
    _check();
    if (!admitted()) throw StateError('Compression publication cancelled');
    _validated = encoded;
    _receipt!.addAll({
      'state': name == _finalName ? 'published' : 'publication_pending',
      'sha256': encoded.sha256,
      'byte_length': encoded.byteLength,
      'frames': encoded.frames,
      'pre_skip': encoded.preSkip,
      'final_granule': encoded.finalGranule,
      'worker_build_id': encoded.workerBuildId,
      'worker_sha256': encoded.workerSha256,
    });
    _writeReceipt();
    if (name != _finalName) {
      owner.publicationObserver?.call('before_publish');
      directory.publish(_partialName, _finalName);
      owner.publicationObserver?.call('after_publish');
    }
    if (directory.metadata(_finalName).identity != identity) {
      throw StateError('Compressed output publication changed');
    }
    _receipt!['state'] = 'published';
    _writeReceipt();
    return AudioTransformOutput(
      representation: AudioRepresentation(
        id: '${lease.job.id}.opus',
        chunkId: chunk.id,
        codec: 'opus',
        container: 'ogg',
        settingsRevision: audioOpusSettingsRevision,
        relativePath:
            'recordings/${chunk.storageGeneration}/${chunk.sessionId}/$_finalName',
        byteLength: encoded.byteLength,
        sha256: encoded.sha256,
        decodedSamples: encoded.frames,
        preSkip: encoded.preSkip,
        state: AudioRepresentationState.published,
        validated: true,
      ),
      metadata: {
        'validated': true,
        'sha256': encoded.sha256,
        'byte_length': encoded.byteLength,
        'frames': encoded.frames,
        'pre_skip': encoded.preSkip,
        'final_granule': encoded.finalGranule,
        'worker_build_id': encoded.workerBuildId,
        'worker_sha256': encoded.workerSha256,
      },
    );
  }

  void _writeReceipt() {
    final directory = _directory!,
        temporary = '${AudioStore.newIdentity()}.compression-receipt.partial';
    final file = directory.open(temporary, create: true);
    try {
      file.write(utf8.encode(jsonEncode(_receipt)));
      file.sync();
    } finally {
      file.close();
    }
    if (directory.entryExists(_receiptName)) {
      directory.replace(temporary, _receiptName);
      directory.sync();
    } else {
      directory.publish(temporary, _receiptName);
    }
  }

  @override
  void resetForRetry() {
    if (!_workerClosed) throw StateError('Compression exit is unconfirmed');
    if (hasValidatedOutput) return;
    _check();
    if (_output == null) return;
    if (_directory!.metadata(_partialName).identity != _output!.identity) {
      throw StateError('Compression output changed');
    }
    _output!.truncateTo(0);
    _output!.sync();
  }

  @override
  void abort() {
    if (!_workerClosed) throw StateError('Compression exit is unconfirmed');
    if (hasValidatedOutput) return;
    _check();
    final directory = _directory!;
    if (directory.entryExists(_partialName)) {
      directory.remove(_partialName, expectedIdentity: _output!.identity);
    }
    _receipt!['state'] = 'cancelled';
    _writeReceipt();
    directory.sync();
  }

  @override
  Future<void> committed() async {
    _check(completed: true);
    _input?.close();
    _input = null;
    if (owner.retainLossless(chunk.sessionId)) return;
    final raw = owner.store.beginRawPurge(chunk.id);
    if (raw == null) return;
    await owner._purge(raw);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _input?.close();
    _output?.close();
    _directory?.close();
  }
}

AudioEncodedResult _resultFromReceipt(Map<String, Object?> receipt) =>
    AudioEncodedResult(
      sha256: receipt['sha256'] as String,
      byteLength: receipt['byte_length'] as int,
      frames: receipt['frames'] as int,
      preSkip: receipt['pre_skip'] as int,
      finalGranule: receipt['final_granule'] as int,
      workerBuildId: receipt['worker_build_id'] as String,
      workerSha256: receipt['worker_sha256'] as String,
    );

String _validateCompressionInput(
  String path,
  AudioRepresentation input,
  AudioChunk chunk,
  int ordinal,
) {
  final directory = BackupDirectory(path, create: false);
  BackupFile? file;
  try {
    file = directory.open('${chunk.id}.wav', readOnly: true);
    if (file.size != input.byteLength || file.digest() != input.sha256) {
      throw const FormatException('Compression input checksum changed');
    }
    final header = Uint8List(196);
    if (file.readAt(header, 0) != header.length) {
      throw const FormatException('Truncated recording input');
    }
    final notice = RecordingChunkNotice.fromJson({
      'chunk_id': chunk.id,
      'session_id': chunk.sessionId,
      'generation': chunk.storageGeneration,
      'source': chunk.source.index,
      'sequence': chunk.sequence,
      'span': ordinal,
      'source_sample': chunk.sampleStart,
      'frames': chunk.sampleCount,
      'capture_start_us': chunk.captureStartUs,
      'bytes': chunk.byteLength,
      'interrupted': chunk.interrupted,
      'gap_before': chunk.gapBefore,
      'contents_synced': true,
      'directory_synced': true,
      'sample_rate': 48000,
      'channels': 1,
      'relative_path': '${chunk.id}.wav',
    });
    validateRecordingWavHeader(header, notice);
    if (directory.metadata('${chunk.id}.wav').identity != file.identity ||
        file.size != input.byteLength) {
      throw StateError('Compression input identity changed');
    }
    directory.verifyAnchor();
    return file.identity;
  } finally {
    file?.close();
    directory.close();
  }
}

Future<String> _validateRawOffThread(
  String path,
  AudioRepresentation raw,
  AudioChunk chunk,
  int ordinal,
) => Isolate.run(() => _validateCompressionInput(path, raw, chunk, ordinal));

void _verifyEncoded(
  String path,
  String name,
  String identity,
  AudioEncodedResult encoded,
) {
  final directory = BackupDirectory(path, create: false);
  BackupFile? file;
  try {
    file = directory.open(name, readOnly: true);
    if (file.identity != identity ||
        file.size != encoded.byteLength ||
        file.digest() != encoded.sha256 ||
        directory.metadata(name).identity != identity ||
        file.size != encoded.byteLength) {
      throw const FormatException(
        'Compressed bytes disagree with verified codec result',
      );
    }
    directory.verifyAnchor();
  } finally {
    file?.close();
    directory.close();
  }
}

void _verifyRetained(String path, String name, AudioRepresentation retained) {
  final directory = BackupDirectory(path, create: false);
  BackupFile? file;
  try {
    file = directory.open(name, readOnly: true);
    if (file.size != retained.byteLength ||
        file.digest() != retained.sha256 ||
        directory.metadata(name).identity != file.identity ||
        file.size != retained.byteLength) {
      throw const FormatException(
        'Retained audio is unavailable; lossless source preserved',
      );
    }
    directory.verifyAnchor();
  } finally {
    file?.close();
    directory.close();
  }
}
