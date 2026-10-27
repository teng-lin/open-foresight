import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_assembly_manifest.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

// Real filesystem/SQLite authority and manifest wire tests. Source bytes here
// are synthetic extents; actual codec WAV/Opus validation has separate tests.
void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late RecordingMedia media;
  late AudioSession session;
  late BackupDirectory directory;
  late AudioTransformLease lease;
  late AudioChunk first;
  late String stagedName;
  var current = true;
  AudioChunk chunk(
    AudioSpan span,
    AudioSource source,
    int sequence,
    int start, {
    int frames = 4800,
    bool gap = false,
  }) {
    final authority = media
        .preallocate(
          span: span,
          source: source,
          firstSequence: sequence,
          count: 1,
        )
        .single;
    final bytes = Uint8List(196 + frames * 2);
    final file = directory.open('${authority.id}.wav', create: true);
    try {
      file.write(bytes);
      file.sync();
    } finally {
      file.close();
    }
    return media.audio.publishPreallocatedChunk(
      authority.id,
      publicationToken: authority.publicationToken,
      sampleStart: sequence * 4800,
      sampleCount: frames,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: start,
      captureEndUs: start + frames * 1000000 ~/ 48000,
      byteLength: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
      gapBefore: gap,
    );
  }

  AudioTransformLease claim({String preferred = 'pcm_s16le'}) {
    final job = media.audio.createExportJob(
      sessionId: session.id,
      codec: 'mp3',
      container: 'mp3',
      settingsRevision: 'assembly-test-v1',
      settings: {'nonce': AudioStore.newIdentity()},
      preferredInputCodec: preferred,
    );
    return media.audio.claimTransformJob(
      job.id,
      ownerGeneration: media.ownerGeneration,
      nowMs: 0,
    )!;
  }

  setUp(() {
    current = true;
    final root = createTestTempDirectorySync('audio-manifest-');
    store = Store('${root.path}/application.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    session = media.audio.createSession(
      meetingId: store.meeting('Assembly'),
      startedWallMs: 0,
    );
    directory = BackupDirectory(
      media.sessionDirectory(session.id),
      create: false,
    );
    final one = media.audio.startSpan(
      session.id,
      captureStartUs: 1000000,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    first = chunk(one, AudioSource.microphone, 0, 1000000);
    chunk(one, AudioSource.playback, 0, 1050000, gap: true);
    media.audio.closeSpan(one.id, captureEndUs: 1200000, reason: 'pause');
    final two = media.audio.startSpan(
      session.id,
      captureStartUs: 10000000,
      playbackStartUs: 200000,
      wallAnchorMs: 0,
    );
    chunk(two, AudioSource.microphone, 1, 10025000, gap: true);
    media.audio.closeSpan(two.id, captureEndUs: 10200000, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 0,
    );
    lease = claim();
    addTearDown(() {
      directory.close();
      media.close();
      store.close();
    });
  });
  Future<AudioAssemblyManifest> manifest({
    AudioMediaOperation op = AudioMediaOperation.assembleMp3,
    int start = 0,
    int count = 0,
  }) {
    stagedName = '${AudioStore.newIdentity()}.manifest';
    return AudioAssemblyManifest.create(
      media: media,
      lease: lease,
      directory: directory,
      name: stagedName,
      operation: op,
      current: () => current,
      startFrame: start,
      frameCount: count,
    );
  }

  AudioMediaInputRequest request(
    AudioAssemblyManifest m,
    List<int> indices, {
    String? sha,
  }) => AudioMediaInputRequest.fromJson({
    'version': 1,
    'sequence': 1,
    'manifest_sha256': sha ?? m.sha256,
    'indices': indices,
  });
  Uint8List row(AudioAssemblyManifest m, int index) {
    final bytes = Uint8List(384);
    expect(m.file.readAt(bytes, 256 + 384 * index), 384);
    return bytes;
  }

  test(
    'wire uses one compact timeline, source gaps and frozen input permutation',
    () async {
      final m = await manifest();
      addTearDown(m.close);
      expect(m.rows, 3);
      expect(m.timelineFrames, 19200);
      expect(m.file.digest(), m.sha256);
      final h = Uint8List(256);
      expect(m.file.readAt(h, 0), 256);
      final d = ByteData.sublistView(h);
      expect(ascii.decode(h.sublist(0, 8)), 'FSAMF001');
      expect(d.getUint32(20, Endian.little), 2);
      expect(d.getUint32(24, Endian.little), 1);
      expect(d.getUint64(148, Endian.little), 19200);
      final a = ByteData.sublistView(row(m, 0)),
          b = ByteData.sublistView(row(m, 1)),
          c = ByteData.sublistView(row(m, 2));
      expect(
        [
          a.getUint64(16, Endian.little),
          b.getUint64(16, Endian.little),
          c.getUint64(16, Endian.little),
        ],
        [0, 10800, 2400],
      );
      expect(
        [
          a.getUint32(380, Endian.little),
          b.getUint32(380, Endian.little),
          c.getUint32(380, Endian.little),
        ],
        [0, 2, 1],
      );
      expect(c.getUint32(12, Endian.little), 0x40000001);
      final page = m.inputs(request(m, [0, 2]));
      expect(page.descriptors.length, 2);
      expect(
        page.descriptors.every(
          (fd) => BackupFile.inspectDescriptorIdentity(fd) != null,
        ),
        isTrue,
      );
      page.close();
      expect(
        page.descriptors.every(
          (fd) => BackupFile.inspectDescriptorIdentity(fd) == null,
        ),
        isTrue,
      );
    },
  );
  test(
    'retained Opus uses representation length SHA and exact published filename',
    () async {
      final id = '${AudioStore.newIdentity()}.opus',
          bytes = Uint8List.fromList([1, 2, 3, 4]);
      final file = directory.open(id, create: true);
      try {
        file.write(bytes);
        file.sync();
      } finally {
        file.close();
      }
      final sha = crypto.sha256.convert(bytes).toString();
      media.audio.publishRepresentation(
        AudioRepresentation(
          id: id,
          chunkId: first.id,
          codec: 'opus',
          container: 'ogg',
          settingsRevision: 'ogg-opus-mono-v1',
          relativePath:
              'recordings/${session.storageGeneration}/${session.id}/$id',
          byteLength: bytes.length,
          sha256: sha,
          decodedSamples: first.sampleCount,
          state: AudioRepresentationState.published,
          preSkip: 312,
          validated: true,
        ),
      );
      lease = claim(preferred: 'opus');
      final m = await manifest(op: AudioMediaOperation.assembleOpus);
      addTearDown(m.close);
      final bytesRow = row(m, 0), d = ByteData.sublistView(bytesRow);
      expect(d.getUint32(8, Endian.little), 2);
      expect(d.getUint64(40, Endian.little), bytes.length);
      expect(ascii.decode(bytesRow.sublist(280, 344)), sha);
      expect(d.getUint32(36, Endian.little), 312);
      final page = m.inputs(request(m, [0]));
      page.close();
    },
  );
  test(
    'bounded PCM range is carried exactly and oversize ranges refused',
    () async {
      final m = await manifest(
        op: AudioMediaOperation.assemblePcm,
        start: 100,
        count: 10000,
      );
      addTearDown(m.close);
      final header = Uint8List(256);
      m.file.readAt(header, 0);
      final d = ByteData.sublistView(header);
      expect(d.getUint64(156, Endian.little), 100);
      expect(d.getUint32(164, Endian.little), 10000);
      await expectLater(
        manifest(
          op: AudioMediaOperation.assemblePcm,
          start: 18000,
          count: 2000,
        ),
        throwsStateError,
      );
      await expectLater(
        manifest(op: AudioMediaOperation.assemblePcm, count: 240001),
        throwsStateError,
      );
    },
  );
  test(
    'pager refuses wrong manifest, out of range, stale lease and closed owner',
    () async {
      final m = await manifest();
      addTearDown(m.close);
      expect(() => m.inputs(request(m, [0], sha: 'a' * 64)), throwsStateError);
      expect(() => m.inputs(request(m, [3])), throwsStateError);
      media.audio.interruptTransformJob(lease, error: 'test');
      expect(() => m.inputs(request(m, [0])), throwsStateError);
      m.close();
      expect(() => m.inputs(request(m, [0])), throwsStateError);
    },
  );
  test('changed manifest row cannot substitute another frozen input', () async {
    final m = await manifest();
    addTearDown(m.close);
    final writable = directory.open(stagedName);
    final bytes = row(m, 2);
    ByteData.sublistView(bytes).setUint32(0, 0, Endian.little);
    writable.writeAt(bytes, 256);
    writable.close();
    expect(() => m.inputs(request(m, [0])), throwsStateError);
  });
  test(
    'changed representation path and truncated source fail closed',
    () async {
      final m = await manifest();
      addTearDown(m.close);
      store.db.execute(
        'UPDATE audio_representations SET relative_path=? WHERE id=?',
        ['/outside.wav', '${first.id}.raw'],
      );
      expect(() => m.inputs(request(m, [0])), throwsStateError);
      store.db.execute(
        'UPDATE audio_representations SET relative_path=? WHERE id=?',
        [first.relativePath, '${first.id}.raw'],
      );
      final writable = directory.open('${first.id}.wav');
      writable.truncateTo(1);
      writable.close();
      expect(() => m.inputs(request(m, [0])), throwsStateError);
    },
  );
  test(
    'cancellation during paged materialization removes only its own staged manifest',
    () async {
      final work = manifest();
      scheduleMicrotask(() => current = false);
      await expectLater(work, throwsStateError);
      expect(directory.entryExists(stagedName), isFalse);
    },
  );
  test(
    'more than one SQL page keeps physical row indices and descriptor lookup',
    () async {
      directory.close();
      session = media.audio.createSession(
        meetingId: store.meeting('Many chunks'),
        startedWallMs: 0,
      );
      directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      final span = media.audio.startSpan(
        session.id,
        captureStartUs: 0,
        playbackStartUs: 0,
        wallAnchorMs: 0,
      );
      for (var i = 0; i < 141; i++) {
        chunk(span, AudioSource.microphone, i, i * 100000);
      }
      media.audio.closeSpan(span.id, captureEndUs: 14100000, reason: 'stop');
      media.audio.setCaptureState(
        session.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 0,
      );
      lease = claim();
      final m = await manifest();
      addTearDown(m.close);
      expect(m.rows, 141);
      expect(m.file.size, 256 + 384 * 141);
      final tail = ByteData.sublistView(row(m, 140));
      expect(tail.getUint32(0, Endian.little), 140);
      expect(tail.getUint32(380, Endian.little), 140);
      expect(tail.getUint64(16, Endian.little), 140 * 4800);
      final page = m.inputs(request(m, [140]));
      page.close();
    },
  );
  test(
    'overlapping source chunks are refused instead of silently overwriting samples',
    () async {
      store.db.execute(
        'UPDATE audio_chunks SET capture_start_us=?,capture_end_us=? WHERE id=?',
        [1000000, 1100000, first.id],
      );
      final second = store.db
          .select(
            "SELECT id FROM audio_chunks WHERE source='microphone' AND sequence=1",
          )
          .single['id'];
      store.db.execute(
        'UPDATE audio_chunks SET span_id=?,capture_start_us=?,capture_end_us=? WHERE id=?',
        [first.spanId, 1050000, 1150000, second],
      );
      await expectLater(manifest(), throwsStateError);
    },
  );
  test(
    'pager refuses frozen sample geometry altered after manifest creation',
    () async {
      final m = await manifest();
      addTearDown(m.close);
      store.db.execute(
        'UPDATE audio_transform_inputs SET playback_start_frame=playback_start_frame+1 WHERE job_id=? AND position=0',
        [lease.job.id],
      );
      expect(
        () => m.inputs(request(m, [0])),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('Frozen acquired audio geometry changed'),
          ),
        ),
      );
    },
  );
}
