import 'dart:convert';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../audio_models.dart';
import '../audio_presentation.dart';
import 'audio_store.dart';
import 'backup_files.dart';
import 'recording_media.dart';

final class AudioExportConflict implements Exception {
  const AudioExportConflict(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// One process owns this broker. Tokens are never restored; an already admitted
/// job recovers only its exact private receipt under the independently bound
/// recording generation. Caller identities are actual service objects, not RPC.
final class AudioExportDestinations {
  AudioExportDestinations({
    required this.media,
    required this.now,
    Iterable<String> forbiddenRoots = const [],
    this.capacity = 64,
    this.publicationObserver,
    this.lifetime = const Duration(minutes: 15),
  }) : forbiddenRoots = List.unmodifiable(
         [
           p.dirname(media.store.path),
           ...forbiddenRoots,
         ].map((path) => p.normalize(p.absolute(path))),
       ) {
    if (capacity < 1 ||
        capacity > 256 ||
        lifetime <= Duration.zero ||
        lifetime > const Duration(hours: 1)) {
      throw ArgumentError('Invalid export grant limits');
    }
  }
  final RecordingMedia media;
  final Duration Function() now;
  final List<String> forbiddenRoots;
  final int capacity;
  final Duration lifetime;

  /// Service-owned fault/observation port; never decoded from an RPC request.
  final void Function(String phase)? publicationObserver;
  final _grants = <String, _DestinationGrant>{};
  final _leases = <String, AudioExportDestinationLease>{};
  final _knownClosedJobs = <String>{};
  AudioExportDestinationLease? leaseForJob(String jobId) => _leases[jobId];
  int get boundLeaseCount => _leases.length;
  bool _closed = false;
  Duration _lastInstant = Duration.zero;
  Duration _instant() {
    final value = now();
    if (value > _lastInstant) _lastInstant = value;
    return _lastInstant;
  }

  AudioStore get _audio => media.audio;

  void _check(
    String sessionId,
    String epoch,
    String generation,
    bool Function() current,
  ) {
    final session = _audio.session(sessionId);
    if (_closed ||
        !current() ||
        !_audio.mediaAdmitted ||
        !media.binding.matches(generation) ||
        _audio.storageGeneration != generation ||
        _audio.workspaceEpoch() != epoch ||
        session == null ||
        session.workspaceEpoch != epoch ||
        session.storageGeneration != generation ||
        _audio.db.select(
          'SELECT 1 FROM audio_erasure_intents WHERE session_id=?',
          [sessionId],
        ).isNotEmpty) {
      throw const AudioExportConflict('Recording export authority changed');
    }
  }

  void expire() {
    final instant = _instant();
    for (final entry in _grants.entries.toList()) {
      final grant = entry.value;
      if (instant >= grant.expires ||
          _audio.workspaceEpoch() != grant.epoch ||
          _audio.storageGeneration != grant.generation ||
          !grant.current()) {
        _grants.remove(entry.key);
        grant.close();
      }
    }
  }

  void invalidateCaller(Object caller) {
    for (final entry in _grants.entries.toList()) {
      if (identical(entry.value.caller, caller)) {
        _grants.remove(entry.key);
        entry.value.close();
      }
    }
  }

  AudioExportDestinationGrant authorize({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String outputPath,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  }) {
    expire();
    final generation = _audio.storageGeneration;
    _check(sessionId, workspaceEpoch, generation, current);
    final session = _audio.session(sessionId)!;
    if (!session.captureState.terminal ||
        _audio.db.select(
          'SELECT 1 FROM recording_spans WHERE session_id=? AND capture_end_us IS NULL LIMIT 1',
          [sessionId],
        ).isNotEmpty) {
      throw const AudioExportConflict('Finish recording before saving audio');
    }
    if (_grants.length >= capacity) {
      throw const AudioExportConflict('Too many pending save destinations');
    }
    if (!p.isAbsolute(outputPath) ||
        p.normalize(outputPath) != outputPath ||
        outputPath.contains('\u0000') ||
        outputPath.length > 4096 ||
        p.basename(outputPath) == '.' ||
        p.basename(outputPath) == '..') {
      throw const AudioExportConflict('Choose an absolute save destination');
    }
    for (final root in forbiddenRoots) {
      if (outputPath == root || p.isWithin(root, outputPath)) {
        throw const AudioExportConflict(
          'Application storage cannot be an export destination',
        );
      }
    }
    final directory = BackupDirectory(
      p.dirname(outputPath),
      create: false,
      private: false,
    );
    BackupFile? original;
    try {
      directory.verifyAnchor();
      if (directory.localFileSystem == ScopedLocalFileSystem.unsupported) {
        throw const AudioExportConflict(
          'This save destination does not support safe publication',
        );
      }
      final name = p.basename(outputPath);
      ScopedFileMetadata? target;
      if (directory.entryExists(name)) {
        target = directory.metadata(name, private: false);
        if (!overwrite) {
          throw const AudioExportConflict(
            'Replacing an existing file requires explicit consent',
          );
        }
        original = directory.open(name, private: false, readOnly: true);
        if (original.identity != target.identity) {
          throw const AudioExportConflict('The selected output changed');
        }
      }
      _check(sessionId, workspaceEpoch, generation, current);
      final id = AudioStore.newIdentity();
      _grants[id] = _DestinationGrant(
        token: id,
        sessionId: sessionId,
        caller: callerIdentity,
        epoch: workspaceEpoch,
        generation: generation,
        format: format,
        overwrite: overwrite,
        allowIncomplete: allowIncomplete,
        directory: directory,
        name: name,
        target: target,
        original: original,
        expires: _instant() + lifetime,
        current: current,
      );
      return AudioExportDestinationGrant(id);
    } catch (_) {
      original?.close();
      directory.close();
      rethrow;
    }
  }

  /// Removing the token precedes validation: every attempt consumes it. No
  /// duplicate or mismatched request can retain a usable output capability.
  AudioExportDestinationLease consume({
    required String token,
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  }) {
    expire();
    final grant = _grants.remove(token);
    if (grant == null) {
      throw const AudioExportConflict(
        'The save destination expired or was already used',
      );
    }
    try {
      _check(sessionId, workspaceEpoch, grant.generation, current);
      if (!identical(grant.caller, callerIdentity) ||
          grant.sessionId != sessionId ||
          grant.epoch != workspaceEpoch ||
          grant.format != format ||
          grant.overwrite != overwrite ||
          grant.allowIncomplete != allowIncomplete) {
        throw const AudioExportConflict(
          'The save request does not match its destination grant',
        );
      }
      grant.verify();
      return AudioExportDestinationLease._(this, grant, current);
    } catch (_) {
      grant.close();
      rethrow;
    }
  }

  /// Startup passes a job from the current DB manifest, never a scanned path.
  /// RecordingMedia.open already owns the inherited-worker exit lock.
  Future<AudioExportDestinationLease> recover(
    AudioTransformJob job, {
    required bool Function() current,
  }) async {
    final epoch = _audio.workspaceEpoch(),
        generation = _audio.storageGeneration;
    _check(job.sessionId, epoch, generation, current);
    final actual = _audio.transformJob(job.id);
    if (actual == null ||
        actual.inputIdentity != job.inputIdentity ||
        actual.sessionId != job.sessionId ||
        actual.kind != AudioTransformKind.export ||
        job.kind != AudioTransformKind.export) {
      throw const AudioExportConflict(
        'Export recovery has no current job authority',
      );
    }
    final receipts = BackupDirectory(
      media.sessionDirectory(job.sessionId),
      create: false,
    );
    BackupDirectory? directory, stage;
    BackupFile? output, original;
    try {
      final file = receipts.open(
        '${job.id}.export-publication.json',
        readOnly: true,
      );
      late final Map<String, Object?> receipt;
      try {
        receipt = Map<String, Object?>.from(
          jsonDecode(utf8.decode(file.readSmall(16384))) as Map,
        );
      } finally {
        file.close();
      }
      if (receipt['format'] != 1 ||
          receipt['job'] != job.id ||
          receipt['input_identity'] != job.inputIdentity ||
          receipt['session'] != job.sessionId ||
          receipt['epoch'] != epoch ||
          receipt['generation'] != generation) {
        throw const AudioExportConflict(
          'Export receipt does not match current recording authority',
        );
      }
      if (receipt['owner_generation'] == media.ownerGeneration &&
          !_knownClosedJobs.contains(job.id) &&
          actual.state != AudioJobState.completed) {
        throw const AudioExportConflict(
          'Current-process export ownership has not been fenced',
        );
      }
      final frozen = jsonDecode(actual.settings) as Map;
      if (frozen['destination_grant'] != receipt['grant'] ||
          frozen['destination_format'] != receipt['output_format'] ||
          frozen['destination_overwrite'] != receipt['overwrite'] ||
          frozen['destination_allow_incomplete'] !=
              receipt['allow_incomplete']) {
        throw const AudioExportConflict(
          'Export receipt does not match frozen grant choices',
        );
      }
      final path = receipt['directory'] as String,
          name = receipt['name'] as String,
          child = receipt['stage_directory'] as String;
      if (!p.isAbsolute(path) ||
          p.normalize(path) != path ||
          p.basename(name) != name ||
          p.basename(child) != child ||
          !child.startsWith('.foresight-audio-')) {
        throw const AudioExportConflict('Invalid export receipt paths');
      }
      for (final root in forbiddenRoots) {
        if (path == root || p.isWithin(root, path)) {
          throw const AudioExportConflict(
            'Export receipt targets application storage',
          );
        }
      }
      directory = BackupDirectory(path, create: false, private: false);
      if (directory.identity != receipt['directory_identity']) {
        throw const AudioExportConflict(
          'Export output directory changed after restart',
        );
      }
      final state = receipt['state'] as String;
      if (directory.entryExists(child)) {
        stage = BackupDirectory(p.join(path, child), create: false);
        if (stage.identity != receipt['stage_directory_identity']) {
          throw const AudioExportConflict(
            'Export staging directory changed after restart',
          );
        }
      } else if (state != 'committed') {
        throw const AudioExportConflict(
          'Unfinished export staging directory is missing',
        );
      }
      final targetIdentity = receipt['target_identity'] as String?;
      ScopedFileMetadata? target;
      if (targetIdentity != null) {
        target = (
          identity: targetIdentity,
          mode: 0,
          uid: 0,
          links: 1,
          size: receipt['target_size'] as int,
          modifiedMillis: receipt['target_modified_ms'] as int,
        );
      }
      if (!const [
        'authorized',
        'publication_pending',
        'published',
        'committed',
      ].contains(state)) {
        throw const AudioExportConflict('Export receipt is not resumable');
      }
      final targetNow = directory.entryExists(name)
          ? directory.metadata(name, private: false)
          : null;
      final stageNow = stage != null && stage.entryExists('audio.partial')
          ? stage.metadata('audio.partial', private: false)
          : null;
      final newIdentity = receipt['stage_identity'] as String;
      final published =
          targetNow?.identity == newIdentity &&
          (targetIdentity == null
              ? stageNow == null
              : stageNow?.identity == targetIdentity ||
                    (state == 'committed' && stageNow == null));
      if (published) {
        if (state == 'authorized') {
          throw const AudioExportConflict(
            'An unvalidated output cannot be recovered',
          );
        }
        await Isolate.run(
          () => _verifyNamedExportBytes(
            path,
            name,
            newIdentity,
            receipt['sha256'] as String,
            receipt['byte_length'] as int,
          ),
        );
        _check(job.sessionId, epoch, generation, current);
        directory.verifyAnchor();
        stage?.verifyAnchor();
        output = directory.open(name, private: false, readOnly: true);
        if (output.identity != newIdentity) {
          throw const AudioExportConflict(
            'Published export changed during recovery',
          );
        }
      } else {
        if (state == 'published' ||
            state == 'committed' ||
            stageNow?.identity != newIdentity ||
            targetNow?.identity != targetIdentity) {
          throw const AudioExportConflict(
            'Export publication identities are uncertain; files retained',
          );
        }
        output = stage!.open('audio.partial');
        if (targetIdentity != null) {
          original = directory.open(name, private: false, readOnly: true);
        }
      }
      final grant = _DestinationGrant(
        token: receipt['grant'] as String,
        sessionId: job.sessionId,
        caller: Object(),
        epoch: epoch,
        generation: generation,
        format: MeetingAudioExportFormat.values.byName(
          receipt['output_format'] as String,
        ),
        overwrite: receipt['overwrite'] as bool,
        allowIncomplete: receipt['allow_incomplete'] as bool,
        directory: directory,
        name: name,
        target: target,
        original: original,
        expires: Duration.zero,
        current: current,
      );
      final lease = AudioExportDestinationLease._(this, grant, current)
        .._job = job
        .._jobCurrent = current
        .._stage = stage
        .._receipts = receipts
        .._output = output
        .._receipt = receipt
        .._workerClosed = true;
      _knownClosedJobs.add(job.id);
      receipt['owner_generation'] = media.ownerGeneration;
      _leases[job.id] = lease;
      if (published) {
        receipt['state'] = state == 'committed' ? 'committed' : 'published';
        receipt['published_identity'] = newIdentity;
        lease._recoveredArtifact = lease._artifact();
      }
      // Ownership must become durable before a resumed worker can start. A
      // second same-process recovery must still require its actual exit fence.
      lease._writeReceipt();
      return lease;
    } catch (_) {
      output?.close();
      original?.close();
      stage?.close();
      directory?.close();
      receipts.close();
      rethrow;
    }
  }

  /// Call only after scheduler/player admission and actual workers are fenced.
  /// Unclaimed queued jobs have never exposed their output descriptor. Claimed
  /// jobs require explicit real-close evidence even if their result is ready.
  /// Ordinary shutdown preserves receipts/staging for exact startup recovery;
  /// destructive operations discard only proved, unvalidated authorized staging.
  /// Published, validated or uncertain output/displaced files are retained.
  void closeBoundLeases({bool discardUnpublished = false, String? sessionId}) {
    final selected = _leases.values
        .where(
          (lease) => sessionId == null || lease._grant.sessionId == sessionId,
        )
        .toList();
    // Refuse the whole operation before releasing even an unrelated queued FD.
    if (selected.any((lease) => lease._fence != null && !lease._workerClosed)) {
      throw const AudioExportConflict(
        'Join actual export worker exit before closing destinations',
      );
    }
    Object? failure;
    StackTrace? trace;
    for (final lease in selected) {
      if (lease._fence == null) lease.markWorkerClosed();
      try {
        if (discardUnpublished &&
            !lease.hasValidatedOutput &&
            lease._receipt?['state'] == 'authorized') {
          lease.abort();
        }
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      } finally {
        lease.close();
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final grant in _grants.values) {
      grant.close();
    }
    _grants.clear();
  }
}

final class _DestinationGrant {
  _DestinationGrant({
    required this.token,
    required this.sessionId,
    required this.caller,
    required this.epoch,
    required this.generation,
    required this.format,
    required this.overwrite,
    required this.allowIncomplete,
    required this.directory,
    required this.name,
    required this.target,
    required this.original,
    required this.expires,
    required this.current,
  });
  final String token, sessionId, epoch, generation, name;
  final Object caller;
  final MeetingAudioExportFormat format;
  final bool overwrite, allowIncomplete;
  final BackupDirectory directory;
  final ScopedFileMetadata? target;
  final BackupFile? original;
  final Duration expires;
  final bool Function() current;
  bool _closed = false;
  void verify() {
    directory.verifyAnchor();
    if (target case final expected?) {
      final actual = directory.metadata(name, private: false);
      if (actual.identity != expected.identity ||
          actual.size != expected.size ||
          actual.modifiedMillis != expected.modifiedMillis ||
          original?.identity != expected.identity) {
        throw const AudioExportConflict('The selected output changed');
      }
    } else if (directory.entryExists(name)) {
      throw const AudioExportConflict(
        'A file appeared at the chosen destination',
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    original?.close();
    directory.close();
  }
}

/// A consumed grant becomes durable job authority only at bindJob. Keep all
/// borrowed descriptors until actual worker exit; a result alone is insufficient.
final class AudioExportDestinationLease {
  AudioExportDestinationLease._(this._broker, this._grant, this._current);
  final AudioExportDestinations _broker;
  final _DestinationGrant _grant;
  final bool Function() _current;
  bool Function()? _jobCurrent;
  AudioTransformLease? _fence;
  BackupDirectory? _stage, _receipts;
  BackupFile? _output;
  AudioTransformJob? _job;
  Map<String, Object?>? _receipt;
  bool _closed = false, _workerClosed = false;
  Map<String, Object?>? _recoveredArtifact;
  Map<String, Object?>? get recoveredArtifact => _recoveredArtifact;
  bool get hasValidatedOutput => _receipt?['sha256'] is String;
  String get receiptId =>
      _job?.id ?? (throw StateError('Export is not bound to a job'));
  int get outputDescriptor {
    _check();
    if (_fence == null || _workerClosed || _receipt?['state'] != 'authorized') {
      throw const AudioExportConflict('Export worker lease is not attached');
    }
    return _output?.descriptor ??
        (throw StateError('Export output is not prepared'));
  }

  void _check() {
    if (_closed) {
      throw const AudioExportConflict('Export destination is closed');
    }
    if (_job == null && _broker._instant() >= _grant.expires) {
      throw const AudioExportConflict(
        'Save destination expired before job admission',
      );
    }
    _broker._check(
      _grant.sessionId,
      _grant.epoch,
      _grant.generation,
      _job == null ? _current : (_jobCurrent ?? () => true),
    );
    if (_job case final job?) {
      final actual = _broker._audio.transformJob(job.id);
      if (actual == null ||
          actual.inputIdentity != job.inputIdentity ||
          actual.state == AudioJobState.abandoned) {
        throw const AudioExportConflict('Export job authority changed');
      }
      if (_fence case final fence?) {
        if (actual.state != AudioJobState.completed &&
            (actual.state != AudioJobState.running ||
                actual.leaseGeneration != fence.leaseGeneration ||
                actual.ownerGeneration != fence.ownerGeneration)) {
          throw const AudioExportConflict('Export worker lease changed');
        }
      }
    }
    _grant.directory.verifyAnchor();
    _stage?.verifyAnchor();
    _receipts?.verifyAnchor();
  }

  Map<String, Object?> get frozenJobSettings => {
    'destination_grant': _grant.token,
    'destination_format': _grant.format.name,
    'destination_overwrite': _grant.overwrite,
    'destination_allow_incomplete': _grant.allowIncomplete,
  };

  void bindJob(AudioTransformJob job, {bool Function()? current}) {
    _check();
    _grant.verify();
    final actual = _broker._audio.transformJob(job.id);
    if (_job != null ||
        actual == null ||
        job.kind != AudioTransformKind.export ||
        job.sessionId != _grant.sessionId ||
        actual.inputIdentity != job.inputIdentity ||
        actual.kind != AudioTransformKind.export ||
        actual.sessionId != _grant.sessionId) {
      throw const AudioExportConflict(
        'Export job does not match the authorized recording',
      );
    }
    final frozen = jsonDecode(actual.settings) as Map;
    if (frozenJobSettings.entries.any(
      (entry) => frozen[entry.key] != entry.value,
    )) {
      throw const AudioExportConflict(
        'The job does not freeze this exact destination grant',
      );
    }
    _job = actual;
    _jobCurrent = current;
    final child = '.foresight-audio-${AudioStore.newIdentity()}';
    if (_grant.directory.entryExists(child)) {
      throw const AudioExportConflict('Output staging identity collided');
    }
    final stage = _stage = _grant.directory.child(child);
    final output = _output = stage.open('audio.partial', create: true);
    output.sync();
    stage.sync();
    _grant.directory.sync();
    _receipts = BackupDirectory(
      _broker.media.sessionDirectory(job.sessionId),
      create: false,
    );
    _receipt = {
      'format': 1,
      'grant': _grant.token,
      'owner_generation': _broker.media.ownerGeneration,
      'job': job.id,
      'input_identity': job.inputIdentity,
      'session': job.sessionId,
      'epoch': _grant.epoch,
      'generation': _grant.generation,
      'output_format': _grant.format.name,
      'overwrite': _grant.overwrite,
      'allow_incomplete': _grant.allowIncomplete,
      'directory': _grant.directory.path,
      'directory_identity': _grant.directory.identity,
      'name': _grant.name,
      'target_identity': _grant.target?.identity,
      'target_size': _grant.target?.size,
      'target_modified_ms': _grant.target?.modifiedMillis,
      'stage_directory': child,
      'stage_directory_identity': stage.identity,
      'stage_identity': output.identity,
      'state': 'authorized',
    };
    _writeReceipt();
    _broker._leases[job.id] = this;
  }

  bool get current {
    try {
      _check();
      return true;
    } catch (_) {
      return false;
    }
  }

  void fenceTo(AudioTransformLease lease) {
    if (_job?.id != lease.job.id ||
        _job?.inputIdentity != lease.job.inputIdentity) {
      throw const AudioExportConflict('Export lease does not match bound job');
    }
    _fence = lease;
    _check();
  }

  /// A restarted authorized job may rerun only after exclusive startup owner
  /// recovery. A validated/published artifact is reconciled instead of rewritten.
  void beginWorker() {
    _check();
    if (_receipt?['state'] != 'authorized' ||
        _stage!.metadata('audio.partial').identity !=
            _receipt!['stage_identity']) {
      throw const AudioExportConflict('Export output cannot be restarted');
    }
    _grant.verify();
    _output!.truncateTo(0);
    _workerClosed = false;
    _broker._knownClosedJobs.remove(receiptId);
  }

  Future<Map<String, Object?>> publishValidated() async {
    if (_recoveredArtifact case final artifact?) {
      _check();
      final actual = _grant.directory.metadata(_grant.name, private: false);
      if (actual.identity != _receipt!['published_identity'] ||
          actual.size != _receipt!['byte_length']) {
        throw const AudioExportConflict(
          'Published export changed before manifest commit',
        );
      }
      final path = _grant.directory.path,
          name = _grant.name,
          identity = _receipt!['published_identity'] as String,
          digest = _receipt!['sha256'] as String,
          size = _receipt!['byte_length'] as int;
      await Isolate.run(
        () => _verifyNamedExportBytes(path, name, identity, digest, size),
      );
      _check();
      return artifact;
    }
    final receipt = _receipt!;
    return publish(
      sha256: receipt['sha256'] as String,
      byteLength: receipt['byte_length'] as int,
      frames: receipt['frames'] as int,
    );
  }

  Map<String, Object?> _artifact() => {
    'validated': true,
    'sha256': _receipt!['sha256'],
    'byte_length': _receipt!['byte_length'],
    'frames': _receipt!['frames'],
    'output_identity': _receipt!['published_identity'],
    'receipt_id': receiptId,
  };

  /// Cancellation only discards our exact unpublished inode after actual exit.
  /// Any uncertain exchange retains its files for explicit receipt recovery.
  void abort() {
    if (!_workerClosed) {
      throw const AudioExportConflict(
        'Cannot discard output before actual worker exit',
      );
    }
    final stage = _stage;
    if (stage == null) return;
    stage.verifyAnchor();
    if (!stage.entryExists('audio.partial')) return;
    final value = stage.metadata('audio.partial', private: false);
    if (value.identity != (_receipt?['stage_identity'] ?? _output?.identity)) {
      throw const AudioExportConflict(
        'Output publication is uncertain; staged bytes retained',
      );
    }
    stage.remove('audio.partial', expectedIdentity: value.identity);
    stage.sync();
    if (_receipt != null) _receipt!['state'] = 'cancelled';
    try {
      if (_receipt != null) _writeReceipt();
    } catch (_) {
      /* Exact unpublished inode was still ours. */
    }
    _grant.directory.removeEmptyChild(stage);
    stage.close();
    _stage = null;
  }

  void resetForRetry() {
    if (!_workerClosed || _receipt?['state'] != 'authorized') {
      throw const AudioExportConflict('Only closed unpublished work can retry');
    }
    _check();
    _grant.verify();
    if (_stage!.metadata('audio.partial').identity !=
        _receipt!['stage_identity']) {
      throw const AudioExportConflict('Export staging identity changed');
    }
    _output!.truncateTo(0);
    _output!.sync();
  }

  void markWorkerClosed() {
    _workerClosed = true;
    if (_job != null) _broker._knownClosedJobs.add(receiptId);
  }

  void _writeReceipt() {
    final directory = _receipts!, name = '$receiptId.export-publication.json';
    final temporary = '${AudioStore.newIdentity()}.receipt.partial';
    final file = directory.open(temporary, create: true);
    try {
      file.write(utf8.encode(jsonEncode(_receipt)));
      file.sync();
    } finally {
      file.close();
    }
    if (directory.entryExists(name)) {
      directory.replace(temporary, name);
      directory.sync();
    } else {
      directory.publish(temporary, name);
    }
  }

  /// [sha256] and frame validation originate in the verified fixed codec worker.
  /// Independently hashing the exact staged inode binds that result to bytes.
  Future<Map<String, Object?>> publish({
    required String sha256,
    required int byteLength,
    required int frames,
  }) async {
    _check();
    if (_fence == null ||
        !_workerClosed ||
        _receipt == null ||
        byteLength < 1 ||
        frames < 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const AudioExportConflict(
        'Export output is not validated and closed',
      );
    }
    _output!.sync();
    final path = _stage!.path, identity = _output!.identity;
    await Isolate.run(
      () => _verifyExportBytes(path, identity, sha256, byteLength),
    );
    _check();
    _grant.verify();
    if (_stage!.metadata('audio.partial').identity != identity) {
      throw const AudioExportConflict('Export staging identity changed');
    }
    _receipt!.addAll({
      'state': 'publication_pending',
      'sha256': sha256,
      'byte_length': byteLength,
      'frames': frames,
    });
    _writeReceipt();
    // With replacement the displaced inode survives in our private directory.
    // Never use a check-then-rename overwrite that could unlink unrelated bytes.
    _broker.publicationObserver?.call('before_exchange');
    _stage!.renameInto(
      'audio.partial',
      _grant.directory,
      _grant.name,
      exchange: _grant.target != null,
      toPrivate: false,
    );
    _broker.publicationObserver?.call('after_exchange');
    final published = _grant.directory.metadata(_grant.name);
    if (published.identity != identity) {
      throw const AudioExportConflict('Published output identity is uncertain');
    }
    if (_grant.target case final target?) {
      final displaced = _stage!.metadata('audio.partial', private: false);
      if (displaced.identity != target.identity) {
        // No deletion on mismatch. Rollback only while both names still retain
        // the identities just observed; otherwise the durable receipt wins.
        if (_grant.directory.metadata(_grant.name).identity == identity &&
            _stage!.metadata('audio.partial', private: false).identity ==
                displaced.identity) {
          _stage!.renameInto(
            'audio.partial',
            _grant.directory,
            _grant.name,
            exchange: true,
            fromPrivate: false,
            toPrivate: true,
          );
        }
        throw const AudioExportConflict(
          'The output changed during publication; original bytes were retained',
        );
      }
    }
    _receipt!['state'] = 'published';
    _receipt!['published_identity'] = published.identity;
    _writeReceipt();
    _recoveredArtifact = _artifact();
    return {
      'validated': true,
      'sha256': sha256,
      'byte_length': byteLength,
      'frames': frames,
      'output_identity': published.identity,
      'receipt_id': receiptId,
    };
  }

  /// Call after the database result commit. Never erase a staged entry whose
  /// identity is uncertain, including a swapped destination during rollback.
  void committed() {
    _check();
    if (!const ['published', 'committed'].contains(_receipt?['state']) ||
        _broker._audio.transformJob(receiptId)?.state !=
            AudioJobState.completed) {
      throw const AudioExportConflict('Export manifest is not committed');
    }
    final output = _grant.directory.metadata(_grant.name, private: false);
    if (output.identity != _receipt!['published_identity'] ||
        output.size != _receipt!['byte_length']) {
      throw const AudioExportConflict(
        'Published output changed; displaced bytes retained',
      );
    }
    if (_receipt!['state'] != 'committed') {
      _receipt!['state'] = 'committed';
      _writeReceipt();
    }
    final stage = _stage;
    if (stage == null) return;
    if (_grant.target case final target?) {
      if (stage.entryExists('audio.partial')) {
        final actual = _stage!.metadata('audio.partial', private: false);
        if (actual.identity != target.identity) {
          throw const AudioExportConflict(
            'Displaced output identity changed; bytes retained',
          );
        }
        _removeDisplacedExact(stage, target.identity);
      }
    }
    _grant.directory.removeEmptyChild(stage);
    stage.close();
    _stage = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_job != null && identical(_broker._leases[receiptId], this)) {
      _broker._leases.remove(receiptId);
    }
    _output?.close();
    _stage?.close();
    _receipts?.close();
    _grant.close();
  }
}

void _verifyExportBytes(
  String path,
  String identity,
  String sha256,
  int bytes,
) {
  final directory = BackupDirectory(path, create: false);
  try {
    final file = directory.open('audio.partial', readOnly: true);
    try {
      if (file.identity != identity ||
          file.size != bytes ||
          file.digest() != sha256 ||
          directory.metadata('audio.partial').identity != identity ||
          file.size != bytes) {
        throw const AudioExportConflict(
          'Export bytes do not match the verified codec result',
        );
      }
    } finally {
      file.close();
    }
    directory.verifyAnchor();
  } finally {
    directory.close();
  }
}

void _removeDisplacedExact(BackupDirectory directory, String identity) {
  // Deletion is confined to the unpredictable name in our verified private
  // staging directory, with no other legitimate writers. Revalidation before
  // unlink is not an atomic defence against arbitrary same-UID staging writes.
  directory.verifyAnchor();
  directory.remove('audio.partial', private: false, expectedIdentity: identity);
  directory.sync();
}

void _verifyNamedExportBytes(
  String path,
  String name,
  String identity,
  String sha256,
  int bytes,
) {
  final directory = BackupDirectory(path, create: false, private: false);
  try {
    final file = directory.open(name, private: false, readOnly: true);
    try {
      if (file.identity != identity ||
          file.size != bytes ||
          file.digest() != sha256 ||
          directory.metadata(name, private: false).identity != identity ||
          file.size != bytes) {
        throw const AudioExportConflict('Published export bytes changed');
      }
    } finally {
      file.close();
    }
    directory.verifyAnchor();
  } finally {
    directory.close();
  }
}
