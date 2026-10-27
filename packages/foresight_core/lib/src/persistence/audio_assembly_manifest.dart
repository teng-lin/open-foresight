import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../application_services/native_audio_media.dart';
import '../audio_models.dart';
import 'audio_playback_timeline.dart';
import 'backup_files.dart';
import 'recording_media.dart';

/// The fixed FSAMF001 wire format. SQLite's frozen job inputs and the actual
/// transform lease remain authoritative; no path supplied by a worker is used.
final class AudioAssemblyManifest {
  AudioAssemblyManifest._(
    this.media,
    this.lease,
    this.file,
    this.sha256,
    this.timelineFrames,
    this.rows,
    this.current,
    this._rowDigests,
  );
  final RecordingMedia media;
  final AudioTransformLease lease;
  final BackupFile file;
  final String sha256;
  final int timelineFrames, rows;
  final bool Function() current;
  // Fixed hashes only, at most 4 MiB; no decoded audio or chunk metadata list.
  final Uint8List _rowDigests;
  bool _closed = false;
  int get descriptor => file.descriptor;
  static const headerBytes = 256, rowBytes = 384, maximumRows = 131072;
  static const maximumFrames = 48000 * 86400;

  static void _check(
    RecordingMedia media,
    AudioTransformLease lease,
    bool Function() current,
  ) {
    media.ensureAvailable();
    final job = media.audio.transformJob(lease.job.id);
    final session = media.audio.session(lease.job.sessionId);
    if (!current() ||
        lease.ownerGeneration != media.ownerGeneration ||
        !media.audio.mediaAdmitted ||
        job?.state != AudioJobState.running ||
        job?.ownerGeneration != lease.ownerGeneration ||
        job?.leaseGeneration != lease.leaseGeneration ||
        job?.inputIdentity != lease.job.inputIdentity ||
        session?.storageGeneration != media.audio.storageGeneration ||
        session?.workspaceEpoch != media.store.workspaceEpoch ||
        media.audio.db.select(
          'SELECT 1 FROM audio_erasure_intents WHERE session_id=?',
          [lease.job.sessionId],
        ).isNotEmpty) {
      throw StateError('Audio assembly authority changed');
    }
  }

  /// Writes bounded row pages and hashes bytes as they are written. It never
  /// constructs an entire meeting's chunk list or decoded audio in Dart.
  /// The private destination is service-owned staging, not an export path.
  static Future<AudioAssemblyManifest> create({
    required RecordingMedia media,
    required AudioTransformLease lease,
    required BackupDirectory directory,
    required String name,
    required AudioMediaOperation operation,
    required bool Function() current,
    int startFrame = 0,
    int frameCount = 0,
    int sourceMask = 3,
  }) async {
    _check(media, lease, current);
    if (!operation.assembly || sourceMask < 1 || sourceMask > 3) {
      throw ArgumentError('Invalid audio assembly operation');
    }
    final db = media.audio.db;
    final counts = db.select(
      'SELECT c.source,COUNT(*) AS n FROM audio_transform_inputs i JOIN audio_representations r ON r.id=i.representation_id JOIN audio_chunks c ON c.id=r.chunk_id WHERE i.job_id=? GROUP BY c.source',
      [lease.job.id],
    );
    var microphone = 0, playback = 0;
    for (final row in counts) {
      switch (row['source']) {
        case 'microphone':
          microphone = row['n'] as int;
        case 'playback':
          playback = row['n'] as int;
        default:
          throw StateError('Invalid frozen audio source');
      }
    }
    final total = microphone + playback;
    final positions = db.select(
      'SELECT MIN(position) AS first,MAX(position) AS last FROM audio_transform_inputs WHERE job_id=?',
      [lease.job.id],
    ).single;
    final frames = AudioPlaybackTimeline.frozenFrames(lease.job.settings);
    if (total < 1 ||
        positions['first'] != 0 ||
        positions['last'] != total - 1 ||
        total > maximumRows ||
        frames < 1 ||
        frames > maximumFrames ||
        db.select(
          'SELECT 1 FROM recording_spans WHERE session_id=? AND capture_end_us IS NULL LIMIT 1',
          [lease.job.sessionId],
        ).isNotEmpty ||
        (operation == AudioMediaOperation.assemblePcm
            ? startFrame < 0 ||
                  frameCount < 1 ||
                  frameCount > 240000 ||
                  startFrame + frameCount > frames
            : startFrame != 0 || frameCount != 0)) {
      throw StateError('Recording exceeds the bounded audio assembly range');
    }
    final header = Uint8List(headerBytes);
    _text(header, 0, 8, 'FSAMF001');
    // ByteData views must share the actual written bytes.
    final data = ByteData.sublistView(header);
    for (final entry in {
      8: 1,
      12: headerBytes,
      16: rowBytes,
      20: microphone,
      24: playback,
      28: operation.index,
      164: frameCount,
      168: sourceMask,
      172: 48000,
      176: 1,
      180: 1,
    }.entries) {
      data.setUint32(entry.key, entry.value, Endian.little);
    }
    _uuid(header, 32, lease.job.sessionId);
    _uuid(header, 68, lease.job.id);
    _uuid(header, 104, media.audio.storageGeneration);
    data.setUint64(140, lease.leaseGeneration, Endian.little);
    data.setUint64(148, frames, Endian.little);
    data.setUint64(156, startFrame, Endian.little);
    _sha(header, 184, lease.job.inputIdentity);
    final output = directory.open(name, create: true);
    var keep = false;
    try {
      final digest = _Digest();
      final rowDigests = Uint8List(total * 32);
      final hash = crypto.sha256.startChunkedConversion(digest);
      output.write(header);
      hash.add(header);
      var index = 0, afterSource = '', afterOrdinal = -1, afterSequence = -1;
      final ends = [0, 0];
      while (true) {
        _check(media, lease, current);
        final page = db.select(
          '$_rowSelect WHERE i.job_id=? AND (c.source>? OR (c.source=? AND (s.ordinal>? OR (s.ordinal=? AND c.sequence>?)))) ORDER BY c.source,s.ordinal,c.sequence LIMIT 128',
          [
            lease.job.id,
            afterSource,
            afterSource,
            afterOrdinal,
            afterOrdinal,
            afterSequence,
          ],
        );
        if (page.isEmpty) break;
        for (final row in page) {
          final bytes = _row(row, index, media, lease.job.sessionId, frames);
          final view = ByteData.sublistView(bytes);
          final source = view.getUint32(4, Endian.little),
              start = view.getUint64(16, Endian.little);
          if (index >= total || start < ends[source]) {
            throw StateError('Frozen audio sources overlap or changed');
          }
          ends[source] = start + view.getUint32(28, Endian.little);
          output.write(bytes);
          hash.add(bytes);
          rowDigests.setRange(
            index * 32,
            (index + 1) * 32,
            crypto.sha256.convert(bytes).bytes,
          );
          index++;
        }
        afterSource = page.last['source'] as String;
        afterOrdinal = page.last['ordinal'] as int;
        afterSequence = page.last['sequence'] as int;
        await Future<void>.delayed(Duration.zero);
      }
      hash.close();
      _check(media, lease, current);
      if (index != total || output.size != headerBytes + rowBytes * total) {
        throw StateError('Frozen audio input count changed');
      }
      output.sync();
      directory.sync();
      final identity = output.identity;
      output.close();
      final input = directory.open(name, readOnly: true);
      if (input.identity != identity) {
        input.close();
        throw StateError('Audio manifest identity changed');
      }
      keep = true;
      return AudioAssemblyManifest._(
        media,
        lease,
        input,
        digest.value!.toString(),
        frames,
        total,
        current,
        rowDigests,
      );
    } finally {
      output.close();
      if (!keep && directory.entryExists(name)) {
        directory.remove(name, expectedIdentity: output.identity);
      }
    }
  }

  static const _rowSelect =
      '''SELECT i.position,i.playback_start_frame,i.playback_frame_count,i.playback_geometry_sha256,r.id AS representation_id,r.codec,r.container,r.settings_revision,r.relative_path AS representation_path,r.byte_length AS representation_bytes,r.sha256 AS representation_sha,r.decoded_samples,r.pre_skip,r.validated,r.state AS representation_state,c.*,s.ordinal,s.capture_start_us AS span_start,s.capture_end_us AS span_end,s.playback_start_us,s.playback_end_us FROM audio_transform_inputs i JOIN audio_representations r ON r.id=i.representation_id JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_spans s ON s.id=c.span_id''';

  static Uint8List _row(
    Map<String, Object?> row,
    int index,
    RecordingMedia media,
    String sessionId,
    int frames,
  ) {
    final raw =
        row['codec'] == 'pcm_s16le' &&
        row['container'] == 'wav' &&
        row['settings_revision'] == 'recording-wav-v1';
    final opus =
        row['codec'] == 'opus' &&
        row['container'] == 'ogg' &&
        row['settings_revision'] == 'ogg-opus-mono-v1';
    final source = AudioSource.values.byName(row['source'] as String).index;
    final decoded = row['decoded_samples'] as int,
        size = row['representation_bytes'] as int;
    final start = row['playback_start_frame'] as int?,
        take = row['playback_frame_count'] as int?;
    if ((!raw && !opus) ||
        row['session_id'] != sessionId ||
        row['storage_generation'] != media.audio.storageGeneration ||
        row['state'] != 'published' ||
        row['representation_state'] != 'published' ||
        row['validated'] != 1 ||
        row['sample_rate'] != 48000 ||
        row['channels'] != 1 ||
        row['span_end'] == null ||
        row['playback_end_us'] == null ||
        decoded != row['sample_count'] ||
        decoded < 1 ||
        decoded > 240000 ||
        start == null ||
        start < 0 ||
        take == null ||
        take != decoded ||
        start + take > frames ||
        (raw
            ? size != 196 + 2 * decoded || row['pre_skip'] != 0
            : size < 1 || size > 131072) ||
        (row['pre_skip'] as int) < 0 ||
        (row['pre_skip'] as int) > 65535 ||
        (row['position'] as int) < 0 ||
        (row['position'] as int) >= maximumRows) {
      throw StateError('Unsupported or inconsistent frozen audio input');
    }
    if (row['playback_geometry_sha256'] !=
        AudioPlaybackTimeline.chunkIdentity(row, start, take)) {
      throw StateError('Frozen acquired audio geometry changed');
    }
    final bytes = Uint8List(rowBytes);
    final b = ByteData.sublistView(bytes);
    for (final entry in {
      0: index,
      4: source,
      8: raw ? 1 : 2,
      12:
          source |
          (row['gap_before'] == 1 ? 0x40000000 : 0) |
          (row['interrupted'] == 1 ? 0x80000000 : 0),
      24: 0,
      28: take,
      32: decoded,
      36: row['pre_skip'] as int,
      380: row['position'] as int,
    }.entries) {
      b.setUint32(entry.key, entry.value, Endian.little);
    }
    for (final entry in {
      16: start,
      40: size,
      48: row['sample_start'] as int,
      56: row['sequence'] as int,
      64: row['ordinal'] as int,
    }.entries) {
      if (entry.value < 0) throw StateError('Invalid audio identity counter');
      b.setUint64(entry.key, entry.value, Endian.little);
    }
    b.setInt64(72, row['capture_start_us'] as int, Endian.little);
    _uuid(bytes, 80, row['id'] as String);
    _uuid(bytes, 116, media.audio.storageGeneration);
    _text(
      bytes,
      152,
      128,
      row['representation_id'] as String,
      terminated: true,
    );
    _sha(bytes, 280, row['representation_sha'] as String);
    _uuid(bytes, 344, row['span_id'] as String);
    return bytes;
  }

  /// Synchronous and bounded: at most two protected descriptors. The native
  /// reply duplicates them before this page closes; worker SHA/format checks
  /// validate the immutable source snapshot before decoding.
  AudioMediaInputPage inputs(AudioMediaInputRequest request) {
    _check(media, lease, current);
    if (_closed ||
        request.manifestSha256 != sha256 ||
        request.indices.any((i) => i < 0 || i >= rows)) {
      throw StateError('Audio input page does not belong to this manifest');
    }
    final files = <BackupFile>[];
    try {
      for (final index in request.indices) {
        final bytes = Uint8List(rowBytes);
        if (file.readAt(bytes, headerBytes + rowBytes * index) != rowBytes) {
          throw StateError('Audio manifest is truncated');
        }
        final hash = crypto.sha256.convert(bytes).bytes;
        for (var i = 0; i < 32; i++) {
          if (hash[i] != _rowDigests[index * 32 + i]) {
            throw StateError('Audio manifest row changed');
          }
        }
        final position = ByteData.sublistView(
          bytes,
        ).getUint32(380, Endian.little);
        final row = media.audio.db.select(
          '$_rowSelect WHERE i.job_id=? AND i.position=?',
          [lease.job.id, position],
        ).single;
        if (media.audio.db.select(
          'SELECT 1 FROM audio_media_references WHERE id=? AND representation_id=? AND owner_generation=? AND purpose=?',
          [
            '${lease.job.id}:${lease.leaseGeneration}:$position',
            row['representation_id'],
            lease.ownerGeneration,
            'transform:${lease.job.id}:${lease.leaseGeneration}',
          ],
        ).isEmpty) {
          throw StateError('Audio assembly reader reference is missing');
        }
        final expected = _row(
          row,
          index,
          media,
          lease.job.sessionId,
          timelineFrames,
        );
        for (var i = 0; i < rowBytes; i++) {
          if (bytes[i] != expected[i]) {
            throw StateError('Frozen audio input changed');
          }
        }
        final chunkId = row['id'] as String,
            representationId = row['representation_id'] as String;
        final path = row['representation_path'] as String;
        final name = path.split('/').last;
        final expectedName = row['codec'] == 'pcm_s16le'
            ? '$chunkId.wav'
            : representationId;
        if (row['codec'] == 'opus' &&
            !RegExp(r'^[0-9a-f-]{36}\.opus$').hasMatch(expectedName)) {
          throw StateError('Audio retained representation name is invalid');
        }
        if (name != expectedName ||
            path !=
                'recordings/${media.audio.storageGeneration}/${lease.job.sessionId}/$name') {
          throw StateError('Audio input path is not owned');
        }
        final directory = BackupDirectory(
          media.sessionDirectory(lease.job.sessionId),
          create: false,
        );
        try {
          final source = directory.open(name, readOnly: true);
          files.add(source);
          if (source.size != row['representation_bytes']) {
            throw StateError('Audio input extent changed');
          }
        } finally {
          directory.close();
        }
      }
      return AudioMediaInputPage(
        List.unmodifiable(files.map((file) => file.descriptor)),
        () {
          for (final file in files) {
            file.close();
          }
        },
      );
    } catch (_) {
      for (final file in files) {
        file.close();
      }
      rethrow;
    }
  }

  void close() {
    _closed = true;
    file.close();
  }

  static void _uuid(Uint8List bytes, int offset, String value) {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value)) {
      throw StateError('Invalid audio UUID');
    }
    _text(bytes, offset, 36, value);
  }

  static void _sha(Uint8List bytes, int offset, String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw StateError('Invalid frozen audio SHA');
    }
    _text(bytes, offset, 64, value);
  }

  static void _text(
    Uint8List bytes,
    int offset,
    int width,
    String value, {
    bool terminated = false,
  }) {
    if (value.isEmpty ||
        value.length > (terminated ? width - 1 : width) ||
        value.runes.any((c) => c < 33 || c > 126 || c == 47 || c == 92)) {
      throw StateError('Invalid frozen audio identifier');
    }
    bytes.setRange(offset, offset + value.length, ascii.encode(value));
  }
}

final class _Digest implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest result) => value = result;
  @override
  void close() {}
}
