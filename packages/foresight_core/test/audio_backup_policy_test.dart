import 'dart:io';
import 'dart:ffi';

import 'package:foresight_core/src/application_services/meeting_audio_runtime.dart';
import 'package:foresight_core/src/audio_presentation.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_backup_policy.dart';
import 'package:foresight_core/src/persistence/audio_profile_backups.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late RecordingMedia media;
  late AudioProfileBackups backups;
  late List<String> protected;
  setUp(() {
    root = createTestTempDirectorySync('audio-backup-policy-');
    protected = [
      for (final name in [
        'profile',
        'runtime',
        'installation',
        'litert',
        'python',
      ])
        (Directory('${root.path}/$name')..createSync()).path,
    ];
    store = Store('${protected[0]}/application.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    backups = AudioProfileBackups(
      forbiddenRoots: audioBackupForbiddenRoots(
        configuration: RuntimeConfiguration({
          ...runtimeConfiguration.environment,
          'FORESIGHT_INSTALL_ROOT': protected[2],
          'FORESIGHT_LITERT_CACHE': protected[3],
          'PYTHONPYCACHEPREFIX': protected[4],
        }),
        profileDirectory: protected[0],
        runtimeDirectory: protected[1],
      ),
    );
    addTearDown(() {
      media.close();
      store.close();
    });
  });
  Future<AudioProfileBackup> create(String destination) => backups.create(
    media: media,
    authorizedDestination: destination,
    quiesced: () => true,
    current: () => true,
  );
  test(
    'real backup refuses configured installation profile runtime and external caches before staging',
    () async {
      for (final directory in protected) {
        await expectLater(
          create('$directory/backup'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('separate backup'),
            ),
          ),
        );
        expect(Directory('$directory/backup').existsSync(), false);
        expect(
          Directory(
            directory,
          ).listSync().where((e) => e.path.contains('.foresight-backup-')),
          isEmpty,
        );
      }
      final backup = await create('${root.path}/permitted-backup');
      expect(backup.representationCount, 0);
    },
  );
  test(
    'new-profile restore applies owner configuration exclusions independently of source backup',
    () async {
      final backup = await create('${root.path}/permitted-backup');
      for (final directory in protected) {
        await expectLater(
          backups.restoreToNewProfile(
            backupDirectory: backup.path,
            authorizedAbsentProfile: '$directory/restored',
            current: () => true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('separate backup'),
            ),
          ),
        );
        expect(Directory('$directory/restored').existsSync(), false);
      }
      final result = await backups.restoreToNewProfile(
        backupDirectory: backup.path,
        authorizedAbsentProfile: '${root.path}/permitted-restored',
        current: () => true,
      );
      expect(result.profilePath, '${root.path}/permitted-restored');
    },
  );
  test(
    'concrete runtime backup protects caches and its actual adopted runtime',
    () async {
      media.close();
      final adopted = Directory('${root.path}/adopted-runtime')..createSync();
      final runtime = MeetingAudioRuntime(
        store: store,
        bindings: NativeLibrary(DynamicLibrary.process()),
        executable: null,
        assemblySupported: false,
        configuration: RuntimeConfiguration({
          ...runtimeConfiguration.environment,
          'FORESIGHT_LITERT_CACHE': protected[3],
          'FORESIGHT_RUNTIME': protected[1],
        }),
        runtimeDirectory: adopted.path,
        changed: () {},
        committed: (_) {},
        captureActivity: () => const AudioCaptureActivity(),
        captureOwned: () => false,
        bindCapture: (_, _) {},
        nowMs: () => 0,
      );
      addTearDown(runtime.close);
      await runtime.initialize();
      for (final directory in [protected[3], protected[1], adopted.path]) {
        await expectLater(
          runtime.backup('$directory/backup', current: () => true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('separate backup'),
            ),
          ),
        );
        expect(Directory('$directory/backup').existsSync(), false);
      }
    },
  );
}
