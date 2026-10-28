import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/audio_transform_scheduler.dart';
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_transform_media.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_profile_backups.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart'
    show SqliteException;
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late RecordingMedia media;
  late AudioProfileBackups backups;
  late AudioSession session;
  late AudioChunk chunk;
  late Uint8List originalBytes;
  late String destination, restored;
  var quiesced = true, current = true;
  setUp(() {
    final temporary = createTestTempDirectorySync('audio-backup-');
    root = Directory('${temporary.path}/private');
    privateDirectory(root.path);
    expect(root.statSync().mode & 0x1ff, 0x1c0);
    final base = BackupDirectory(root.path, create: false);
    final profile = base.child('source');
    store = Store('${profile.path}/app.db');
    profile.close();
    base.close();
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    session = media.audio.createSession(
      meetingId: store.meeting('Saved audio'),
      startedWallMs: 0,
    );
    final span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final p = media
        .preallocate(
          span: span,
          source: AudioSource.microphone,
          firstSequence: 0,
          count: 1,
        )
        .single;
    final bytes = Uint8List(216),
        directory = BackupDirectory(
          media.sessionDirectory(session.id),
          create: false,
        );
    final header = ByteData.sublistView(bytes);
    void text(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, ascii.encode(value));
    text(0, 'RIFF');
    header.setUint32(4, 208, Endian.little);
    text(8, 'WAVEfmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 48000, Endian.little);
    header.setUint32(28, 96000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    text(36, 'fsid');
    header.setUint32(40, 144, Endian.little);
    text(44, session.id);
    text(80, session.storageGeneration);
    text(116, p.id);
    header.setUint64(164, span.ordinal, Endian.little);
    text(188, 'data');
    header.setUint32(192, 20, Endian.little);
    originalBytes = bytes;
    directory.open('${p.id}.wav', create: true)
      ..write(bytes)
      ..sync()
      ..close();
    directory.sync();
    directory.close();
    chunk = media.audio.publishPreallocatedChunk(
      p.id,
      publicationToken: p.publicationToken,
      sampleStart: 0,
      sampleCount: 10,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 208,
      byteLength: 216,
      sha256: sha256.convert(bytes).toString(),
    );
    media.audio.closeSpan(span.id, captureEndUs: 208, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 1,
    );
    destination = '${root.path}/backup';
    restored = '${root.path}/restored';
    backups = AudioProfileBackups();
    quiesced = current = true;
    addTearDown(() {
      media.close();
      store.close();
    });
  });
  Future<AudioProfileBackup> create() => backups.create(
    media: media,
    authorizedDestination: destination,
    quiesced: () => quiesced,
    current: () => current,
  );
  int pins() =>
      store.db
              .select('SELECT COUNT(*) AS n FROM audio_media_references')
              .single['n']
          as int;
  test(
    'complete backup copies DB plus pinned audio and new-profile restore binds exact copied media',
    () async {
      final backup = await create();
      expect(backup.representationCount, 1);
      expect(backup.mediaBytes, 216);
      expect(pins(), 0);
      final verified = await backups.inspect(destination, current: () => true);
      expect(verified.manifest, backup.manifest);
      final result = await backups.restoreToNewProfile(
        backupDirectory: destination,
        authorizedAbsentProfile: restored,
        current: () => true,
      );
      expect(result.profilePath, restored);
      final copy = Store('$restored/application.db');
      final owner = RecordingMedia.open(
        copy,
        ownerGeneration: AudioStore.newIdentity(),
      );
      try {
        expect(owner.audio.storageGeneration, session.storageGeneration);
        expect(owner.audio.mediaAdmitted, true);
        expect(copy.workspaceEpoch, store.workspaceEpoch);
        expect(owner.audio.usableRepresentations(chunk.id), hasLength(1));
        expect(
          owner.audio.db.select('SELECT 1 FROM audio_media_references'),
          isEmpty,
        );
        expect(
          File(
            '${owner.sessionDirectory(session.id)}/${chunk.id}.wav',
          ).readAsBytesSync(),
          originalBytes,
        );
        expect(media.audio.usableRepresentations(chunk.id), hasLength(1));
      } finally {
        owner.close();
        copy.close();
      }
    },
  );
  test(
    'capture barrier and active readers refuse snapshot before copying',
    () async {
      quiesced = false;
      await expectLater(create(), throwsStateError);
      expect(Directory(destination).existsSync(), false);
      quiesced = true;
      final ref = media.audio.acquireReference(
        '${chunk.id}.raw',
        ownerGeneration: media.ownerGeneration,
        purpose: 'player',
      );
      await expectLater(create(), throwsStateError);
      expect(pins(), 1);
      media.audio.releaseReference(ref);
      expect((await create()).representationCount, 1);
    },
  );
  test(
    'pins survive asynchronous copy and cancellation prevents final publication',
    () async {
      final work = create();
      expect(pins(), 1);
      expect(
        () => media.audio.tombstoneSession(session.id),
        throwsA(isA<SqliteException>()),
      );
      current = false;
      await expectLater(
        work,
        throwsA(
          isA<AudioBackupIncomplete>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
      expect(pins(), 0);
      expect(Directory(destination).existsSync(), false);
    },
  );
  test(
    'inventory and copies page past a long meetings first 128 chunks',
    () async {
      final session = media.audio.createSession(
        meetingId: store.meeting('Long meeting'),
        startedWallMs: 1,
      );
      final span = media.audio.startSpan(
        session.id,
        captureStartUs: 0,
        playbackStartUs: 0,
        wallAnchorMs: 1,
      );
      final directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      for (var i = 1; i < 140; i++) {
        final id = AudioStore.newIdentity(),
            p = media.audio.preallocateChunk(
              sessionId: session.id,
              spanId: span.id,
              source: AudioSource.microphone,
              sequence: i,
              id: id,
              relativePath:
                  'recordings/${session.storageGeneration}/${session.id}/$id.wav',
            );
        final bytes = Uint8List.fromList(originalBytes),
            data = ByteData.sublistView(bytes);
        bytes.setRange(44, 80, ascii.encode(session.id));
        bytes.setRange(116, 152, ascii.encode(id));
        data.setUint64(156, i, Endian.little);
        data.setUint64(164, span.ordinal, Endian.little);
        data.setUint64(172, i * 10, Endian.little);
        data.setUint64(180, i * 208, Endian.little);
        directory.open('$id.wav', create: true)
          ..write(bytes)
          ..close();
        media.audio.publishPreallocatedChunk(
          id,
          publicationToken: p.publicationToken,
          sampleStart: i * 10,
          sampleCount: 10,
          sampleRate: 48000,
          channels: 1,
          captureStartUs: i * 208,
          captureEndUs: (i + 1) * 208,
          byteLength: 216,
          sha256: sha256.convert(bytes).toString(),
        );
      }
      directory.sync();
      directory.close();
      media.audio.closeSpan(span.id, captureEndUs: 140 * 208, reason: 'stop');
      media.audio.setCaptureState(
        session.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 30,
      );
      expect((await create()).representationCount, 140);
      expect(
        (await backups.inspect(
          destination,
          current: () => true,
        )).representationCount,
        140,
      );
      expect(pins(), 0);
    },
  );
  test(
    'retention recovery must finish before a backup omits a remaining original',
    () async {
      media.audio.setRetainLossless(session.id, true);
      store.db.execute(
        "UPDATE audio_representations SET state='superseded_pending_purge' WHERE chunk_id=?",
        [chunk.id],
      );
      await expectLater(create(), throwsStateError);
      expect(pins(), 0);
      expect(Directory(destination).existsSync(), false);
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        true,
      );
    },
  );
  test(
    'changed source preserves pins until copy exits then refuses a valid backup publication',
    () async {
      final file = File(
        '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
      ).openSync(mode: FileMode.writeOnlyAppend);
      file.writeByteSync(1);
      file.closeSync();
      await expectLater(
        create(),
        throwsA(
          isA<AudioBackupIncomplete>()
              .having((e) => e.cause, 'cause', isA<FormatException>())
              .having(
                (e) => Directory(e.stagingDirectory).existsSync(),
                'disclosed partial copy',
                true,
              ),
        ),
      );
      expect(pins(), 0);
      expect(Directory(destination).existsSync(), false);
    },
  );
  test(
    'damaged payload refuses inspection and cannot publish a restored profile',
    () async {
      await create();
      final path = '$destination/${chunk.relativePath}';
      final file = File(path).openSync(mode: FileMode.writeOnlyAppend);
      file.writeByteSync(1);
      file.closeSync();
      await expectLater(
        backups.inspect(destination, current: () => true),
        throwsFormatException,
      );
      await expectLater(
        backups.restoreToNewProfile(
          backupDirectory: destination,
          authorizedAbsentProfile: restored,
          current: () => true,
        ),
        throwsFormatException,
      );
      expect(Directory(restored).existsSync(), false);
    },
  );
  test(
    'rewritten inventory cannot name files outside snapshot manifest',
    () async {
      await create();
      final inventory = File('$destination/media-manifest.jsonl');
      final row = jsonDecode(inventory.readAsStringSync()) as Map;
      row['path'] = '../outside';
      inventory.writeAsStringSync('${jsonEncode(row)}\n');
      final header = File('$destination/backup.json'),
          manifest = jsonDecode(header.readAsStringSync()) as Map;
      manifest['inventory_sha256'] = sha256
          .convert(inventory.readAsBytesSync())
          .toString();
      header.writeAsStringSync(jsonEncode(manifest));
      await expectLater(
        backups.inspect(destination, current: () => true),
        throwsFormatException,
      );
    },
  );
  test(
    'new-profile restore never replaces an existing or symlinked destination',
    () async {
      await create();
      final parent = BackupDirectory(root.path, create: false),
          existing = parent.child('restored');
      existing.open('keep', create: true)
        ..write([7])
        ..close();
      existing.close();
      parent.close();
      await expectLater(
        backups.restoreToNewProfile(
          backupDirectory: destination,
          authorizedAbsentProfile: restored,
          current: () => true,
        ),
        throwsStateError,
      );
      expect(File('$restored/keep').readAsBytesSync(), [7]);
      Link('${root.path}/link').createSync(restored);
      await expectLater(
        backups.restoreToNewProfile(
          backupDirectory: destination,
          authorizedAbsentProfile: '${root.path}/link/new',
          current: () => true,
        ),
        throwsStateError,
      );
    },
  );
  test('new-profile restore blocks prior external export grants', () async {
    final job = media.audio.createExportJob(
      sessionId: session.id,
      codec: 'mp3',
      container: 'mp3',
      settingsRevision: 'test-export',
      settings: const {'destination_grant': 'original-destination'},
    );
    await create();
    await backups.restoreToNewProfile(
      backupDirectory: destination,
      authorizedAbsentProfile: restored,
      current: () => true,
    );
    final copy = Store('$restored/application.db'),
        owner = RecordingMedia.open(
          copy,
          ownerGeneration: AudioStore.newIdentity(),
        );
    try {
      final actual = owner.audio.transformJob(job.id)!;
      expect(actual.state, AudioJobState.blocked);
      expect(actual.error, 'backup_restore_requires_new_destination');
    } finally {
      owner.close();
      copy.close();
    }
    expect(media.audio.transformJob(job.id)!.state, AudioJobState.pending);
  });
  test(
    'cancellation and forbidden profile roots never publish a backup',
    () async {
      current = false;
      await expectLater(create(), throwsStateError);
      expect(pins(), 0);
      current = true;
      await expectLater(
        backups.create(
          media: media,
          authorizedDestination: '${File(store.path).parent.path}/backup',
          quiesced: () => true,
          current: () => true,
        ),
        throwsStateError,
      );
      expect(pins(), 0);
      expect(Directory(destination).existsSync(), false);
    },
  );
  test(
    'real retained Opus remains decodable after complete new-profile restore',
    () async {
      final env = Platform.environment;
      final bindings = NativeLibrary(
        DynamicLibrary.open(env['FORESIGHT_NATIVE_LIBRARY']!),
      );
      final worker = NativeAudioCompressionWorker(
        bindings: bindings,
        executable: AudioMediaExecutable(
          path: env['FORESIGHT_TEST_MEDIA_WORKER']!,
          sha256: env['FORESIGHT_TEST_MEDIA_SHA256']!,
          buildId: env['FORESIGHT_TEST_MEDIA_BUILD_ID']!,
          macosCdHash: env['FORESIGHT_TEST_MEDIA_CDHASH'] ?? '',
        ),
      );
      final compression = AudioCompressionMedia(
        media: media,
        startWorker: worker.start,
      );
      compression.admitPending();
      final scheduler = AudioTransformScheduler(
        store: media.audio,
        ownerGeneration: media.ownerGeneration,
        prepare: compression.prepare,
        nowMs: () => 0,
        committed: (_) {},
        changed: () {},
      );
      await scheduler.runOne();
      await scheduler.close();
      expect(
        media.audio
            .usableRepresentations(chunk.id)
            .where((r) => r.codec == 'opus'),
        hasLength(1),
      );
      expect((await create()).representationCount, 2);
      await backups.restoreToNewProfile(
        backupDirectory: destination,
        authorizedAbsentProfile: restored,
        current: () => true,
      );
      final copy = Store('$restored/application.db'),
          owner = RecordingMedia.open(
            copy,
            ownerGeneration: AudioStore.newIdentity(),
          );
      final retained = owner.audio
          .usableRepresentations(chunk.id)
          .singleWhere((r) => r.codec == 'opus');
      final directory = BackupDirectory(
        owner.sessionDirectory(session.id),
        create: false,
      );
      final input = directory.open(
            retained.relativePath.split('/').last,
            readOnly: true,
          ),
          output = directory.open('decoded', create: true);
      try {
        final task = await NativeAudioMediaTask.start(
          bindings: bindings,
          executable: worker.executable,
          request: AudioMediaRequest(
            operation: AudioMediaOperation.decodePcm,
            sessionId: session.id,
            jobId: AudioStore.newIdentity(),
            epoch: 1,
            inputSha256: retained.sha256,
            sourceFrames: 10,
            startFrame: 0,
            frameCount: 10,
          ),
          inputDescriptor: input.descriptor,
          outputDescriptor: output.descriptor,
          ownerLockDescriptor: owner.ownerLockDescriptor,
          current: () => true,
        );
        try {
          expect((await task.result).frames, 10);
        } finally {
          await task.closed;
        }
        expect(output.readSmall(20), everyElement(0));
      } finally {
        output.close();
        input.close();
        directory.close();
        owner.close();
        copy.close();
      }
    },
    skip:
        Platform.environment['FORESIGHT_TEST_MEDIA_WORKER'] == null ||
            Platform.environment['FORESIGHT_TEST_MEDIA_SHA256'] == null ||
            Platform.environment['FORESIGHT_NATIVE_LIBRARY'] == null
        ? 'Requires verified fixed worker/native pair for real retained audio restore'
        : false,
  );
}
