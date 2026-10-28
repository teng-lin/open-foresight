import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_backup_owner.dart';
import 'package:foresight_core/src/persistence/audio_profile_backups.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service_ownership.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'fixtures/durable_capture_routes.dart';
import 'sql_support_test_bootstrap.dart';

const _quarantinedOwner = r'''
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:foresight_core/src/persistence/audio_backup_owner.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service_ownership.dart';
Future<void> main(List<String> args) async {
  final image = DynamicLibrary.open(args[2]);
  image.lookupFunction<Void Function(), void Function()>(
    'fs_lifetime_quarantine',
  )();
  var unknown = false, entered = false;
  String? error;
  try {
    await withOfflineAudioBackupOwner(
      profile: ProfilePaths(args[0], args[1]),
      configuration: RuntimeConfiguration({'FORESIGHT_NATIVE': args[2]}),
      use: (_, _, _) async {
        entered = true;
        throw StateError('must not enter');
      },
      ownershipUnconfirmed: () => unknown = true,
    );
  } catch (failure) {
    error = failure.toString();
  }
  print(jsonEncode({
    'error': error, 'entered': entered, 'unknown': unknown,
    'held': hasLocalServiceOwner(args[0]),
    'database_created': File('${args[0]}/application.db').existsSync(),
  }));
  await stdin.first;
}
''';

void main() {
  bootstrapSqlSupportFixture();
  final native = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  final needsNative = native == null
      ? 'Requires a freshly built native library for actual offline recovery'
      : false;
  late Directory root;
  late ProfilePaths profile;
  late RuntimeConfiguration configuration;
  late String sessionId;
  var unknown = false;
  late String serviceKernel;

  setUpAll(() async {
    if (native == null) return;
    final build = createTestTempDirectorySync('audio-backup-cli-');
    serviceKernel = '${build.path}/service.dill';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '-DFORESIGHT_DIAGNOSTIC_TEST_CONTEXT=true',
      '-DFORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR=${Directory.current.parent.parent.path}',
      '-DFORESIGHT_DIAGNOSTIC_BUILD_ROOT=${File(native).parent.parent.path}',
      'bin/service.dart',
      '-o',
      serviceKernel,
    ]).timeout(const Duration(seconds: 30));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  setUp(() {
    root = createTestTempDirectorySync('audio-backup-owner-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    configuration = RuntimeConfiguration({
      ...runtimeConfiguration.environment,
      if (native != null) 'FORESIGHT_NATIVE': native,
    });
    unknown = false;
  });

  Future<AudioProfileBackup> owned(
    Future<AudioProfileBackup> Function(
      RecordingMedia,
      bool Function(),
      bool Function(),
    )
    use,
  ) => withOfflineAudioBackupOwner(
    profile: profile,
    configuration: configuration,
    use: use,
    ownershipUnconfirmed: () => unknown = true,
  );

  void interruptedAudio() {
    final store = Store('${profile.data}/application.db');
    final media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    try {
      media.admitNewCapture();
      final session = media.audio.createSession(
        meetingId: store.meeting('Synthetic interrupted backup'),
        startedWallMs: 0,
      );
      sessionId = session.id;
      final span = media.audio.startSpan(
        session.id,
        captureStartUs: 0,
        playbackStartUs: 0,
        wallAnchorMs: 0,
      );
      final routes = media.preallocate(
        span: span,
        source: AudioSource.microphone,
        firstSequence: 0,
        count: 1,
      );
      // Valid native-recoverable WAV bytes, deliberately no SQL publication.
      CaptureRouteFixture(
        media,
        AudioSource.microphone,
        span.ordinal,
        0,
        routes,
      ).audio(0, voiced: true);
      // Recovery requires the native writer's separately synced adoption
      // authority, in addition to SQL preallocation and the WAV identity.
      final directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      try {
        final wav = directory.open('${routes.single.id}.wav', readOnly: true);
        late Uint8List header;
        try {
          header = Uint8List(196);
          expect(wav.readAt(header, 0), 196);
        } finally {
          wav.close();
        }
        final data = ByteData.sublistView(header);
        data.setUint32(4, 188, Endian.little);
        data.setUint32(192, 0, Endian.little);
        final intent = directory.open(
          '${routes.single.id}.intent',
          create: true,
        );
        try {
          intent.write(header);
          intent.sync();
        } finally {
          intent.close();
        }
        directory.sync();
      } finally {
        directory.close();
      }
    } finally {
      media.close();
      store.close();
    }
  }

  test(
    'actual native quarantine refuses backup and holds its lock until process exit',
    () async {
      final probe = File('${root.path}/quarantined_owner.dart')
        ..writeAsStringSync(_quarantinedOwner);
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        probe.path,
        profile.data,
        profile.runtime,
        native!,
      ]);
      final errors = child.stderr.transform(utf8.decoder).join();
      final output = StreamIterator(
        child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(
          await output.moveNext().timeout(const Duration(seconds: 30)),
          true,
        );
        final state = jsonDecode(output.current) as Map<String, dynamic>;
        expect(state['error'], contains('Native ownership is unconfirmed'));
        expect(state['entered'], false);
        expect(state['unknown'], true);
        expect(state['held'], true);
        expect(state['database_created'], false);
        final lock = File(
          '${profile.data}/.application.lock',
        ).openSync(mode: FileMode.append);
        try {
          expect(
            () => lock.lockSync(FileLock.exclusive),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          lock.closeSync();
        }
        child.stdin.writeln('exit');
        await child.stdin.close();
        expect(
          await child.exitCode.timeout(const Duration(seconds: 30)),
          0,
          reason: await errors,
        );
        final released = File(
          '${profile.data}/.application.lock',
        ).openSync(mode: FileMode.append);
        try {
          released.lockSync(FileLock.exclusive);
        } finally {
          released.closeSync();
        }
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await output.cancel();
        await errors;
      }
    },
    skip: needsNative,
  );

  test(
    'offline backup does not rewrite a sealed native model environment',
    () async {
      final image = DynamicLibrary.open(native!);
      final seal = image
          .lookupFunction<
            Uint64 Function(Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>)
          >('fs_owned_speech_create');
      // Invalid assets seal configuration without creating a model or worker.
      expect(seal(nullptr, nullptr), 0);
      final getenv = DynamicLibrary.process()
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('getenv');
      final key = 'FORESIGHT_LITERT_CACHE'.toNativeUtf8();
      String? cache() {
        final value = getenv(key);
        return value == nullptr ? null : value.toDartString();
      }

      try {
        final before = cache();
        configuration = configuration.withOverrides({
          'FORESIGHT_LITERT_CACHE': '${profile.data}/must-not-configure',
        });
        final backup = await owned(
          (media, quiesced, current) => AudioProfileBackups().create(
            media: media,
            authorizedDestination: '${root.path}/sealed-backup',
            quiesced: quiesced,
            current: current,
          ),
        );
        expect(backup.representationCount, 0);
        expect(cache(), before);
        expect(hasLocalServiceOwner(profile.data), false);
      } finally {
        calloc.free(key);
      }
    },
    skip: needsNative,
  );

  test(
    'frontend native admission failure precedes storage and releases known owners',
    () async {
      final previous = NativeLibrary.beforeAdmission;
      var called = false;
      NativeLibrary.beforeAdmission = (_, _) async {
        called = true;
        throw StateError('frontend admission refused');
      };
      try {
        await expectLater(
          owned((_, _, _) async => throw StateError('consumer must not enter')),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'reason',
              'frontend admission refused',
            ),
          ),
        );
        expect(called, true);
        expect(File('${profile.data}/application.db').existsSync(), false);
        expect(hasLocalServiceOwner(profile.data), false);
        expect(unknown, false);
      } finally {
        NativeLibrary.beforeAdmission = previous;
      }
    },
    skip: needsNative,
  );

  test(
    'offline backup recovers an actual unpublished synthetic WAV before copying',
    () async {
      interruptedAudio();
      late bool Function() stillCurrent;
      final backup = await owned((media, quiesced, current) async {
        stillCurrent = current;
        expect(hasLocalServiceOwner(profile.data), true);
        expect(quiesced(), true);
        expect(
          media.audio.session(sessionId)!.captureState,
          AudioCaptureState.interrupted,
        );
        expect(media.audio.chunks(sessionId), hasLength(1));
        return AudioProfileBackups().create(
          media: media,
          authorizedDestination: '${root.path}/backup',
          quiesced: quiesced,
          current: current,
        );
      });
      expect(backup.representationCount, 1);
      expect(backup.mediaBytes, greaterThan(196));
      expect(stillCurrent(), false);
      expect(hasLocalServiceOwner(profile.data), false);
      expect(unknown, false);
      final verified = await AudioProfileBackups().inspect(
        backup.path,
        current: () => true,
      );
      expect(verified.representationCount, 1);
    },
    skip: needsNative,
  );

  test(
    'a second local backup refuses without dropping the current profile owner',
    () async {
      await owned((media, quiesced, current) async {
        await expectLater(
          owned((_, _, _) async => throw StateError('must not enter')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('Stop the application service'),
            ),
          ),
        );
        expect(hasLocalServiceOwner(profile.data), true);
        expect(current(), true);
        return AudioProfileBackups().create(
          media: media,
          authorizedDestination: '${root.path}/backup',
          quiesced: quiesced,
          current: current,
        );
      });
      expect(hasLocalServiceOwner(profile.data), false);
      expect(unknown, false);
    },
    skip: needsNative,
  );

  test(
    'same-turn backup admission cannot close a second POSIX descriptor under its owner',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final first = owned((media, quiesced, current) async {
        entered.complete();
        await release.future;
        return AudioProfileBackups().create(
          media: media,
          authorizedDestination: '${root.path}/first-backup',
          quiesced: quiesced,
          current: current,
        );
      });
      final second = owned(
        (_, _, _) async => throw StateError('second consumer must never enter'),
      );
      final secondFailure = second.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      try {
        await entered.future;
        final refusal = await secondFailure;
        final probe = File('${root.path}/posix_probe.dart')
          ..writeAsStringSync(
            "import 'dart:io'; void main(List<String> args) { final fd=File(args.single).openSync(mode:FileMode.append); try { fd.lockSync(FileLock.exclusive); stdout.write('acquired'); } on FileSystemException { stdout.write('contended'); } finally { fd.closeSync(); } }",
          );
        final checked = await Process.run(Platform.resolvedExecutable, [
          probe.path,
          '${profile.data}/.application.lock',
        ]).timeout(const Duration(seconds: 30));
        expect(
          checked.exitCode,
          0,
          reason: '${checked.stdout}\n${checked.stderr}',
        );
        expect(
          checked.stdout,
          'contended',
          reason:
              'A second admission must not drop the first process-owned POSIX lock',
        );
        expect(
          refusal,
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('Stop the application service'),
          ),
        );
        expect(hasLocalServiceOwner(profile.data), true);
      } finally {
        release.complete();
        await first;
      }
      expect(hasLocalServiceOwner(profile.data), false);
    },
    skip: needsNative,
  );
  for (final failure in ['installation', 'native']) {
    test(
      '$failure admission failure releases the synchronous local ownership reservation',
      () async {
        final original = configuration;
        if (failure == 'installation') {
          final install = '${root.path}/installation';
          privateDirectory(install);
          File(
            '$install/.installation-maintenance',
          ).writeAsStringSync('maintenance');
          configuration = configuration.withOverrides({
            'FORESIGHT_INSTALL_ROOT': install,
          });
        } else {
          configuration = configuration.withOverrides({
            'FORESIGHT_NATIVE': '${root.path}/absent-native-library',
          });
        }
        await expectLater(
          owned((_, _, _) async => throw StateError('consumer must not enter')),
          throwsA(
            failure == 'installation'
                ? isA<StateError>()
                : isA<ArgumentError>(),
          ),
        );
        expect(hasLocalServiceOwner(profile.data), false);
        expect(unknown, false);
        configuration = original;
        final backup = await owned(
          (media, quiesced, current) => AudioProfileBackups().create(
            media: media,
            authorizedDestination: '${root.path}/after-failure',
            quiesced: quiesced,
            current: current,
          ),
        );
        expect(backup.representationCount, 0);
        expect(hasLocalServiceOwner(profile.data), false);
      },
      skip: needsNative,
    );
  }
  test(
    'failed backup consumer releases known owners for the next actual backup',
    () async {
      await expectLater(
        owned((_, _, _) async => throw StateError('consumer failed')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'consumer failed',
          ),
        ),
      );
      expect(hasLocalServiceOwner(profile.data), false);
      final backup = await owned(
        (media, quiesced, current) => AudioProfileBackups().create(
          media: media,
          authorizedDestination: '${root.path}/backup',
          quiesced: quiesced,
          current: current,
        ),
      );
      expect(backup.representationCount, 0);
      expect(unknown, false);
    },
    skip: needsNative,
  );

  test(
    'actual source CLI rejects mixed backup arguments before runtime or profile access',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/service.dart',
          '--audio-backup-create=${root.path}/backup',
          '--stop',
        ],
        environment: {'FORESIGHT_DATA': '${root.path}/never-opened'},
      ).timeout(const Duration(seconds: 30));
      expect(result.exitCode, 64, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('NEW profile'));
      expect(Directory('${root.path}/never-opened').existsSync(), false);
    },
  );

  test(
    'actual once-compiled JIT CLI creates inspects and restores recovered audio',
    () async {
      interruptedAudio();
      Future<Map<String, dynamic>> cli(List<String> arguments) async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          [serviceKernel, ...arguments],
          environment: {
            'FORESIGHT_DATA': profile.data,
            'FORESIGHT_RUNTIME': profile.runtime,
            'FORESIGHT_NATIVE': native!,
          },
        ).timeout(const Duration(seconds: 60));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        return jsonDecode(result.stdout as String) as Map<String, dynamic>;
      }

      final backup = '${root.path}/cli-backup';
      final created = await cli(['--audio-backup-create=$backup']);
      expect(created['representations'], 1);
      final inspected = await cli(['--audio-backup-inspect=$backup']);
      expect(inspected, created);
      final restored = await cli([
        '--audio-backup-restore=$backup',
        '--new-profile=${root.path}/restored',
      ]);
      expect(restored['representations'], 1);
      expect(restored['new_profile'], '${root.path}/restored');
      final store = Store('${root.path}/restored/application.db');
      final media = RecordingMedia.open(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      try {
        final chunk = media.audio.chunks(sessionId).single;
        final pcm = await media.readPcm(
          chunk,
          frameOffset: 0,
          frameCount: 4800,
        );
        expect(pcm, everyElement(411));
      } finally {
        media.close();
        store.close();
      }
    },
    skip: needsNative,
  );
}
