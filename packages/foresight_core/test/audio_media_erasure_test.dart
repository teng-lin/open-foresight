import 'dart:io';
import 'package:foresight_core/src/persistence/audio_media_erasure.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late RecordingMedia media;
  late AudioMediaErasure erasure;
  late String id, generation, path;
  var quiesced = true;
  setUp(() {
    final root = createTestTempDirectorySync('audio-erasure-');
    store = Store('${root.path}/application.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    final session = media.audio.createSession(
      meetingId: store.meeting('Meeting'),
      startedWallMs: 0,
    );
    id = session.id;
    generation = session.storageGeneration;
    path = media.sessionDirectory(id);
    quiesced = true;
    erasure = AudioMediaErasure(media: media, sessionQuiesced: (_) => quiesced);
    addTearDown(() async {
      await erasure.fence();
      media.close();
      store.close();
    });
  });
  void file(String name) {
    final d = BackupDirectory(path, create: false);
    final f = d.open(name, create: true);
    f.write([1, 2]);
    f.close();
    d.close();
  }

  bool pending() => media.audio.pendingErasures().any((r) => r.sessionId == id);
  test(
    'targeted erasure finishes 173 files despite 20 unrelated older unsafe tombstones',
    () async {
      final older = <String>[];
      final profile = BackupDirectory(
        File(store.path).parent.path,
        create: false,
        private: false,
      );
      final generations = profile.child('recordings');
      final oldGeneration = generations.child(generation);
      try {
        for (var i = 0; i < 20; i++) {
          final oldId =
              '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
          older.add(oldId);
          store.db.execute(
            'INSERT INTO audio_erasure_intents(session_id,generation,created) VALUES(?,?,0)',
            [oldId, generation],
          );
          final directory = oldGeneration.child(oldId);
          directory.child('unsafe-subdirectory').close();
          directory.close();
        }
      } finally {
        oldGeneration.close();
        generations.close();
        profile.close();
      }
      for (var i = 0; i < 173; i++) {
        file('$i.wav');
      }
      media.audio.tombstoneSession(id);
      final refused = erasure.drain(current: () => true, limit: 1);
      final refusal = expectLater(refused, throwsStateError);
      final target = erasure.eraseSession(id, generation, current: () => true);
      await refusal;
      final progress = await target;
      expect(progress.filesRemoved, 173);
      expect(progress.sessionsCompleted, 1);
      expect(pending(), false);
      expect(Directory(path).existsSync(), false);
      expect(
        store.db
            .select('SELECT session_id FROM audio_erasure_intents')
            .map((r) => r['session_id']),
        unorderedEquals(older),
      );
      expect(
        (await erasure.eraseSession(
          id,
          generation,
          current: () => true,
        )).sessionsCompleted,
        0,
      );
    },
  );
  test(
    'targeted erasure joins a batch and its fence covers the complete target',
    () async {
      for (var i = 0; i < 149; i++) {
        file('$i.wav');
      }
      media.audio.tombstoneSession(id);
      final first = erasure.drain(current: () => true, filesPerSession: 1);
      final target = erasure.eraseSession(
        id,
        generation,
        current: () => true,
        filesPerBatch: 7,
      );
      await erasure.fence();
      expect((await first).filesRemoved, 1);
      expect((await target).filesRemoved, 148);
      expect(pending(), false);
    },
  );
  test(
    'targeted erasure cancellation preserves intent and can resume',
    () async {
      for (var i = 0; i < 151; i++) {
        file('$i.wav');
      }
      media.audio.tombstoneSession(id);
      var checks = 0;
      await expectLater(
        erasure.eraseSession(
          id,
          generation,
          filesPerBatch: 5,
          current: () => ++checks < 5,
        ),
        throwsStateError,
      );
      expect(pending(), true);
      expect(Directory(path).listSync(), isNotEmpty);
      await erasure.eraseSession(id, generation, current: () => true);
      expect(pending(), false);
    },
  );
  test(
    'targeted erasure refuses extant, wrong generation and unsafe files',
    () async {
      await expectLater(
        erasure.eraseSession(id, generation, current: () => true),
        throwsStateError,
      );
      final outside = File('${File(store.path).parent.path}/outside')
        ..writeAsStringSync('keep');
      Link('$path/unsafe').createSync(outside.path);
      media.audio.tombstoneSession(id);
      await expectLater(
        erasure.eraseSession(id, AudioStore.newIdentity(), current: () => true),
        throwsStateError,
      );
      await expectLater(
        erasure.eraseSession(id, generation, current: () => true),
        throwsStateError,
      );
      expect(outside.readAsStringSync(), 'keep');
      expect(pending(), true);
      quiesced = false;
      await expectLater(
        erasure.eraseSession(id, generation, current: () => true),
        throwsStateError,
      );
      quiesced = true;
      expect(
        () => erasure.eraseSession(
          id,
          generation,
          current: () => true,
          filesPerBatch: 0,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'delete intent survives bounded batches and completes only after directory removal',
    () async {
      for (var i = 0; i < 5; i++) {
        file('$i.wav');
      }
      media.audio.tombstoneSession(id);
      expect(pending(), true);
      expect(
        (await erasure.drain(
          current: () => true,
          filesPerSession: 2,
        )).sessionsCompleted,
        0,
      );
      expect(Directory(path).listSync(), hasLength(3));
      expect(pending(), true);
      await erasure.drain(current: () => true, filesPerSession: 2);
      expect(
        (await erasure.drain(
          current: () => true,
          filesPerSession: 2,
        )).sessionsCompleted,
        1,
      );
      expect(Directory(path).existsSync(), false);
      expect(pending(), false);
      expect((await erasure.drain(current: () => true)).sessionsCompleted, 0);
    },
  );
  test(
    'service capture fence and request cancellation prevent disk removal',
    () async {
      file('raw.wav');
      media.audio.tombstoneSession(id);
      quiesced = false;
      expect((await erasure.drain(current: () => true)).filesRemoved, 0);
      quiesced = true;
      expect((await erasure.drain(current: () => false)).filesRemoved, 0);
      expect(File('$path/raw.wav').existsSync(), true);
      expect(pending(), true);
    },
  );
  test(
    'symlink refuses erasure without following or removing its target',
    () async {
      final outside = File('${File(store.path).parent.path}/outside');
      outside.writeAsStringSync('keep');
      Link('$path/unexpected').createSync(outside.path);
      media.audio.tombstoneSession(id);
      await expectLater(erasure.drain(current: () => true), throwsStateError);
      expect(outside.readAsStringSync(), 'keep');
      expect(Link('$path/unexpected').existsSync(), true);
      expect(pending(), true);
    },
  );
  test('public entries and subdirectories preserve tombstone', () async {
    file('public');
    expect(Process.runSync('/bin/chmod', ['644', '$path/public']).exitCode, 0);
    media.audio.tombstoneSession(id);
    await expectLater(erasure.drain(current: () => true), throwsStateError);
    expect(pending(), true);
    expect(Process.runSync('/bin/chmod', ['600', '$path/public']).exitCode, 0);
    Directory('$path/subdir').createSync();
    await expectLater(erasure.drain(current: () => true), throwsStateError);
    expect(Directory('$path/subdir').existsSync(), true);
    expect(pending(), true);
  });
  test('directory symlink swap never erases an outside subtree', () async {
    file('owned');
    final aside = '$path.displaced';
    Directory(path).renameSync(aside);
    final outside = Directory('${File(store.path).parent.path}/outside')
      ..createSync();
    File('${outside.path}/keep').writeAsStringSync('keep');
    Link(path).createSync(outside.path);
    media.audio.tombstoneSession(id);
    await expectLater(erasure.drain(current: () => true), throwsStateError);
    expect(File('${outside.path}/keep').readAsStringSync(), 'keep');
    expect(File('$aside/owned').existsSync(), true);
    expect(pending(), true);
  });
  test(
    'restart after directory unlink completes durable tombstone idempotently',
    () async {
      file('owned');
      media.audio.tombstoneSession(id);
      Directory(path).deleteSync(recursive: true);
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      erasure = AudioMediaErasure(media: media, sessionQuiesced: (_) => true);
      expect((await erasure.drain(current: () => true)).sessionsCompleted, 1);
      expect(pending(), false);
    },
  );
  test(
    'old-generation managed data can be erased without touching new capture',
    () async {
      file('old');
      media.audio.rotateStorageGeneration();
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      media.admitNewCapture();
      final fresh = media.audio.createSession(
        meetingId: store.meeting('New'),
        startedWallMs: 1,
      );
      final freshPath = media.sessionDirectory(fresh.id),
          d = BackupDirectory(media.sessionDirectory(fresh.id), create: false);
      d.open('new', create: true)
        ..write([3])
        ..close();
      d.close();
      erasure = AudioMediaErasure(media: media, sessionQuiesced: (_) => true);
      expect((await erasure.drain(current: () => true)).sessionsCompleted, 1);
      expect(File('$freshPath/new').existsSync(), true);
      expect(Directory(path).existsSync(), false);
      expect(media.audio.storageGeneration, isNot(generation));
    },
  );
  test(
    'metadata-only admission still allows explicit deletion of quarantined audio',
    () async {
      file('old');
      media.audio.rotateStorageGeneration(metadataOnly: true);
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      expect(media.audio.mediaAdmitted, false);
      media.audio.tombstoneSession(id);
      erasure = AudioMediaErasure(media: media, sessionQuiesced: (_) => true);
      expect((await erasure.drain(current: () => true)).sessionsCompleted, 1);
      expect(Directory(path).existsSync(), false);
    },
  );
  test(
    'unrelated user-owned exported final file is outside managed erasure',
    () async {
      file('receipt');
      final exported = File('${File(store.path).parent.path}/user-export.mp3')
        ..writeAsStringSync('export');
      media.audio.tombstoneSession(id);
      await erasure.drain(current: () => true);
      expect(exported.readAsStringSync(), 'export');
    },
  );
}
