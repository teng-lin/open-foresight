import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../audio_models.dart';
import '../recording_capture.dart';
import '../store.dart';
import 'audio_storage_binding.dart';
import 'audio_store.dart';
import 'backup_files.dart';

final class MediaOwnerContended extends StateError {
  MediaOwnerContended() : super('Previous audio workers have not exited');
}

/// Service-owned media admission after exclusive profile ownership. Neither a
/// restored SQLite row nor a surviving filename can authorize recording bytes.
/// The caller closes this owner before releasing the profile lock/database.
final class RecordingMedia {
  RecordingMedia._(
    this.store,
    this.binding,
    this.ownerGeneration,
    this._ownerLease,
  ) {
    audio = AudioStore(
      store.db,
      workspaceEpoch: () => store.workspaceEpoch,
      mediaGeneration: () => _closed ? null : _generation,
    );
  }

  static RecordingMedia open(Store store, {required String ownerGeneration}) {
    if (store.path == ':memory:') {
      throw ArgumentError('Recording media requires a persistent profile');
    }
    final binding = AudioStorageBinding(
      p.dirname(store.path),
      databaseName: p.basename(store.path),
    );
    late final RecordingMedia owner;
    try {
      owner = RecordingMedia._(
        store,
        binding,
        ownerGeneration,
        _acquireOwnerLease(store),
      );
    } catch (_) {
      binding.close();
      rethrow;
    }
    try {
      // Exclusive ownership proves previous process readers are no longer live.
      owner.audio.recoverLeases(ownerGeneration);
      final previous = binding.read();
      var generation = owner.audio.storageGeneration;
      if (!binding.matches(generation)) {
        final hasHistory = store.db
            .select('SELECT 1 FROM recording_sessions LIMIT 1')
            .isNotEmpty;
        if (previous != null || hasHistory) {
          generation = owner.audio.rotateStorageGeneration(metadataOnly: true);
        }
        binding.bind(
          generation: generation,
          expectedDatabaseIdentity: binding.databaseIdentity,
          replace: previous != null,
        );
      }
      owner._generation = generation;
      return owner;
    } catch (_) {
      owner.close();
      rethrow;
    }
  }

  /// Wait only for real kernel contention, including a CLOEXEC description
  /// briefly inherited by a concurrent child before exec. Neither time nor a
  /// retry authorizes recovery: only an acquired flock reaches [open]'s reads.
  static Future<RecordingMedia> acquire(
    Store store, {
    required String ownerGeneration,
    Duration timeout = const Duration(seconds: 3),
    bool Function()? current,
  }) async {
    if (timeout.isNegative || timeout > const Duration(seconds: 3)) {
      throw ArgumentError.value(timeout, 'timeout');
    }
    final elapsed = Stopwatch()..start();
    var attempted = false;
    while (true) {
      if (current?.call() == false) {
        throw StateError('Audio media acquisition cancelled');
      }
      if (attempted && elapsed.elapsed >= timeout) throw MediaOwnerContended();
      attempted = true;
      try {
        final owner = open(store, ownerGeneration: ownerGeneration);
        try {
          if (current?.call() == false) {
            throw StateError('Audio media acquisition cancelled');
          }
          return owner;
        } catch (_) {
          owner.close();
          rethrow;
        }
      } on MediaOwnerContended {
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) rethrow;
        await Future<void>.delayed(
          remaining < const Duration(milliseconds: 10)
              ? remaining
              : const Duration(milliseconds: 10),
        );
      }
    }
  }

  final Store store;
  final AudioStorageBinding binding;
  final String ownerGeneration;
  final BackupFile _ownerLease;
  late final AudioStore audio;
  String? _generation;
  bool _closed = false;
  final _publications = <Future<AudioChunk>, String>{};
  final _reads = <Future<Int16List>, String>{};

  static BackupFile _acquireOwnerLease(Store store) {
    final profile = BackupDirectory(
      p.dirname(store.path),
      create: false,
      private: false,
    );
    BackupDirectory? control;
    BackupFile? lease;
    try {
      control = profile.child('recording-control');
      lease = control.openOrCreate('media-owner.lock');
      if (lease.size != 0) throw StateError('Invalid audio owner lease');
      if (!lease.tryExclusiveLeaseChecked()) throw MediaOwnerContended();
      final acquired = lease;
      lease = null;
      return acquired;
    } finally {
      lease?.close();
      control?.close();
      profile.close();
    }
  }

  /// Internal native capability, never a wire value. Child workers receive a
  /// duplicate of this SAME locked open-file description only after verified
  /// bootstrap. Closing the service's FD cannot release an inherited child FD.
  /// Never call LOCK_UN: the lock ends when the last real owner closes its FD.
  int get ownerLockDescriptor {
    _check();
    return _ownerLease.descriptor;
  }

  void _check() {
    if (_closed ||
        _generation != audio.storageGeneration ||
        !binding.matches(_generation!)) {
      throw StateError('Recording media authority changed');
    }
  }

  /// Service-only synchronous authority check before admitting background work
  /// or changing recovery metadata. Includes the independent physical DB bind.
  void ensureAvailable() => _check();

  /// A metadata-only restore permits fresh capture in its newly bound generation
  /// while all old sessions and representations remain unavailable.
  void admitNewCapture() {
    _check();
    audio.admitNewRecordingStorage();
  }

  String sessionDirectory(String sessionId) {
    _check();
    final session = audio.session(sessionId);
    if (session == null ||
        session.storageGeneration != _generation ||
        session.workspaceEpoch != store.workspaceEpoch ||
        !audio.mediaAdmitted) {
      throw StateError('Recording session is unavailable');
    }
    final profile = BackupDirectory(
      p.dirname(store.path),
      create: false,
      private: false,
    );
    BackupDirectory? recordings, generation, directory;
    try {
      recordings = profile.child('recordings');
      generation = recordings.child(session.storageGeneration);
      directory = generation.child(session.id);
      // Persist the hierarchy before native intent creation can admit frames.
      directory.sync();
      generation.sync();
      recordings.sync();
      profile.sync();
      return directory.path;
    } finally {
      directory?.close();
      generation?.close();
      recordings?.close();
      profile.close();
    }
  }

  List<AudioChunkPublication> preallocate({
    required AudioSpan span,
    required AudioSource source,
    required int firstSequence,
    int count = 16,
  }) {
    _check();
    if (count < 1 || count > 64) throw ArgumentError.value(count, 'count');
    sessionDirectory(span.sessionId);
    return audio.transaction(
      () => List.generate(count, (index) {
        final id = AudioStore.newIdentity();
        return audio.preallocateChunk(
          sessionId: span.sessionId,
          spanId: span.id,
          source: source,
          sequence: firstSequence + index,
          relativePath: 'recordings/$_generation/${span.sessionId}/$id.wav',
          id: id,
        );
      }),
    );
  }

  /// Filesystem validation and hashing run outside the service event loop. The
  /// final transaction rechecks generation/publication authority after the await.
  /// Replayed identical notices are harmless; changed immutable bytes fail closed.
  Future<AudioChunk> publish(RecordingChunkNotice notice) {
    _check();
    late final Future<AudioChunk> work;
    work = _publish(notice).whenComplete(() => _publications.remove(work));
    _publications[work] = notice.sessionId;
    // Keep the original failure available to the owner without letting a
    // concurrent shutdown fence produce an unhandled asynchronous error.
    work.ignore();
    return work;
  }

  /// After fencing new admissions, join real filesystem readers before a
  /// session erasure, workspace clear, profile shutdown or generation rotation.
  Future<void> fencePublications({String? sessionId}) async {
    while (true) {
      final pending = <Future<Object?>>[
        ..._publications.entries
            .where((entry) => sessionId == null || entry.value == sessionId)
            .map((entry) => entry.key),
        ..._reads.entries
            .where((entry) => sessionId == null || entry.value == sessionId)
            .map((entry) => entry.key),
      ];
      if (pending.isEmpty) return;
      await Future.wait(
        pending.map(
          (work) =>
              work.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ),
      );
    }
  }

  Future<AudioChunk> _publish(RecordingChunkNotice notice) async {
    _check();
    final authority = audio.publication(notice.chunkId);
    final span = authority == null ? null : audio.span(authority.spanId);
    if (authority == null ||
        span == null ||
        span.sessionId != authority.sessionId ||
        authority.sessionId != notice.sessionId ||
        authority.storageGeneration != notice.generation ||
        authority.source != notice.source ||
        authority.sequence != notice.sequence ||
        span.ordinal != notice.span ||
        authority.relativePath !=
            'recordings/${notice.generation}/${notice.sessionId}/${notice.chunkId}.wav' ||
        !notice.contentsSynced ||
        !notice.directorySynced) {
      throw StateError(
        'Recording publication has no matching durable authority',
      );
    }
    final directory = p.dirname(store.path);
    final databaseName = p.basename(store.path);
    final expectedDatabaseIdentity = binding.databaseIdentity;
    final digest = await Isolate.run(
      () => _validatePublication(
        directory,
        databaseName,
        expectedDatabaseIdentity,
        notice,
      ),
    );
    _check();
    return audio.publishPreallocatedChunk(
      notice.chunkId,
      publicationToken: authority.publicationToken,
      sampleStart: notice.sourceSample,
      sampleCount: notice.frames,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: notice.captureStartUs,
      captureEndUs: notice.captureEndUs,
      byteLength: notice.byteLength,
      sha256: digest,
      interrupted: notice.interrupted,
      gapBefore: notice.gapBefore,
    );
  }

  /// One bounded canonical raw window. The reader pins the representation until
  /// the isolate has returned and verified the exact bytes against its manifest.
  /// Missing/purged raw audio never silently falls back to lossy ASR input.
  Future<Int16List> readPcm(
    AudioChunk chunk, {
    required int frameOffset,
    required int frameCount,
  }) {
    _check();
    late final Future<Int16List> work;
    work = _readPcm(
      chunk,
      frameOffset,
      frameCount,
    ).whenComplete(() => _reads.remove(work));
    _reads[work] = chunk.sessionId;
    work.ignore();
    return work;
  }

  Future<Int16List> _readPcm(AudioChunk chunk, int offset, int count) async {
    if (offset < 0 ||
        count < 1 ||
        count > 240000 ||
        offset + count > chunk.sampleCount ||
        chunk.sampleRate != 48000 ||
        chunk.channels != 1 ||
        chunk.byteLength != 196 + chunk.sampleCount * 2 ||
        chunk.storageGeneration != _generation ||
        chunk.relativePath !=
            'recordings/$_generation/${chunk.sessionId}/${chunk.id}.wav') {
      throw ArgumentError('Invalid canonical recording PCM window');
    }
    final representation = audio
        .usableRepresentations(chunk.id)
        .where(
          (value) =>
              value.id == '${chunk.id}.raw' && value.sha256 == chunk.sha256,
        )
        .firstOrNull;
    if (representation == null) {
      throw StateError('Lossless recording input is unavailable');
    }
    final reference = audio.acquireReference(
      representation.id,
      ownerGeneration: ownerGeneration,
      purpose: 'pcm:${AudioStore.newIdentity()}',
    );
    try {
      final profile = p.dirname(store.path);
      final database = p.basename(store.path);
      final identity = binding.databaseIdentity;
      final result = await Isolate.run(
        () => _readPcmWindow(profile, database, identity, chunk, offset, count),
      );
      _check();
      return result;
    } finally {
      audio.releaseReference(reference);
    }
  }

  void close() {
    if (_closed) return;
    if (_publications.isNotEmpty || _reads.isNotEmpty) {
      throw StateError(
        'Join recording publication readers before closing media',
      );
    }
    _closed = true;
    _generation = null;
    _ownerLease.close();
    binding.close();
  }
}

String _validatePublication(
  String profilePath,
  String databaseName,
  String expectedDatabaseIdentity,
  RecordingChunkNotice notice,
) {
  final binding = AudioStorageBinding(profilePath, databaseName: databaseName);
  BackupDirectory? profile, recordings, generation, session;
  BackupFile? file;
  try {
    if (!binding.matches(notice.generation) ||
        binding.databaseIdentity != expectedDatabaseIdentity) {
      throw StateError('Recording media binding changed before validation');
    }
    profile = BackupDirectory(profilePath, create: false, private: false);
    recordings = profile.child('recordings', create: false);
    generation = recordings.child(notice.generation, create: false);
    session = generation.child(notice.sessionId, create: false);
    file = session.open('${notice.chunkId}.wav');
    if (file.size != notice.byteLength) {
      throw const FormatException('Recording extent changed');
    }
    final bytes = file.readSmall(notice.byteLength);
    if (bytes.length != notice.byteLength) {
      throw const FormatException('Truncated recording header');
    }
    validateRecordingWavHeader(Uint8List.sublistView(bytes, 0, 196), notice);
    final digest = crypto.sha256.convert(bytes).toString();
    if (file.size != notice.byteLength ||
        session.metadata('${notice.chunkId}.wav').identity != file.identity ||
        !binding.matches(notice.generation) ||
        binding.databaseIdentity != expectedDatabaseIdentity) {
      throw StateError('Recording changed during validation');
    }
    return digest;
  } finally {
    file?.close();
    session?.close();
    generation?.close();
    recordings?.close();
    profile?.close();
    binding.close();
  }
}

Int16List _readPcmWindow(
  String profilePath,
  String databaseName,
  String expectedDatabaseIdentity,
  AudioChunk chunk,
  int offset,
  int count,
) {
  final binding = AudioStorageBinding(profilePath, databaseName: databaseName);
  BackupDirectory? profile, recordings, generation, session;
  BackupFile? file;
  try {
    if (!binding.matches(chunk.storageGeneration) ||
        binding.databaseIdentity != expectedDatabaseIdentity) {
      throw StateError('Recording authority changed before read');
    }
    profile = BackupDirectory(profilePath, create: false, private: false);
    recordings = profile.child('recordings', create: false);
    generation = recordings.child(chunk.storageGeneration, create: false);
    session = generation.child(chunk.sessionId, create: false);
    file = session.open('${chunk.id}.wav');
    final bytes = file.readSmall(chunk.byteLength!);
    if (bytes.length != chunk.byteLength ||
        crypto.sha256.convert(bytes).toString() != chunk.sha256 ||
        session.metadata('${chunk.id}.wav').identity != file.identity) {
      throw const FormatException('Recording bytes disagree with manifest');
    }
    final result = Int16List(count);
    final data = ByteData.sublistView(bytes);
    for (var frame = 0; frame < count; frame++) {
      result[frame] = data.getInt16(196 + (offset + frame) * 2, Endian.little);
    }
    return result;
  } finally {
    file?.close();
    session?.close();
    generation?.close();
    recordings?.close();
    profile?.close();
    binding.close();
  }
}

/// Exact native recording-wav-v1 header, including its private fsid identity.
/// This is deliberately distinct from ordinary 44-byte WAV and headerless PCM.
void validateRecordingWavHeader(Uint8List header, RecordingChunkNotice notice) {
  if (header.length != 196) {
    throw const FormatException('Invalid recording header length');
  }
  final data = ByteData.sublistView(header);
  String text(int offset, int length) =>
      ascii.decode(header.sublist(offset, offset + length));
  int u16(int offset) => data.getUint16(offset, Endian.little);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  int u64(int offset) => data.getUint64(offset, Endian.little);
  if (text(0, 4) != 'RIFF' ||
      u32(4) != notice.byteLength - 8 ||
      text(8, 8) != 'WAVEfmt ' ||
      u32(16) != 16 ||
      u16(20) != 1 ||
      u16(22) != 1 ||
      u32(24) != 48000 ||
      u32(28) != 96000 ||
      u16(32) != 2 ||
      u16(34) != 16 ||
      text(36, 4) != 'fsid' ||
      u32(40) != 144 ||
      text(44, 36) != notice.sessionId ||
      text(80, 36) != notice.generation ||
      text(116, 36) != notice.chunkId ||
      u32(152) !=
          (notice.source.index |
              (notice.interrupted ? 0x80000000 : 0) |
              (notice.gapBefore ? 0x40000000 : 0)) ||
      u64(156) != notice.sequence ||
      u64(164) != notice.span ||
      u64(172) != notice.sourceSample ||
      data.getInt64(180, Endian.little) != notice.captureStartUs ||
      text(188, 4) != 'data' ||
      u32(192) != notice.frames * 2) {
    throw const FormatException(
      'Recording header disagrees with publication authority',
    );
  }
}
