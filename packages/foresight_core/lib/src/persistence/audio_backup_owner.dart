import 'dart:ffi';
import 'dart:io';

import '../application_services/audio_startup_recovery.dart';
import '../native_lifetime.dart';
import '../platform_services.dart';
import '../profile_paths.dart';
import '../service_ownership.dart';
import '../store.dart';
import 'audio_backup_command.dart';
import 'audio_profile_backups.dart';
import 'audio_store.dart';
import 'recording_media.dart';

// A failed actual retirement requires process exit. Preserve every owner until
// then; neither GC nor error reporting may release this profile for reuse.
final _heldOwners = <Object>[];

/// Offline creation has no service socket, capture device, model or codec
/// worker. Exclusive profile and inherited media ownership precede recovery;
/// its actual retirement precedes the first backup read.
Future<AudioProfileBackup> withOfflineAudioBackupOwner({
  required ProfilePaths profile,
  required RuntimeConfiguration configuration,
  required Future<AudioProfileBackup> Function(
    RecordingMedia media,
    bool Function() quiesced,
    bool Function() current,
  )
  use,
  required void Function() ownershipUnconfirmed,
}) async {
  if (hasLocalServiceOwner(canonicalProfilePath(profile.data))) {
    throw StateError(
      'Stop the application service before creating an audio backup',
    );
  }
  InstallationLock? installation;
  RandomAccessFile? lock;
  Store? store;
  RecordingMedia? media;
  NativeLibrary? bindings;
  void Function()? releaseLocal;
  var active = false;
  try {
    // Reserve synchronously before the first await or profile-lock FD. POSIX
    // locks belong to the process: closing a competing local descriptor would
    // drop an admitted owner's lock even when its media flock later refuses us.
    releaseLocal = retainLocalServiceOwner(profile.data);
    installation = acquireInstallationLock(configuration: configuration);
    lock = await acquireServiceProfileLock(
      profile,
      launchWithdrawn: () => false,
      configuration: configuration,
      // Recovery uses explicit media identities and descriptors, never model
      // caches. Do not rewrite an already sealed process model environment.
      configureNativeRuntime: false,
    );
    bindings = NativeLibrary(DynamicLibrary.open(configuration.nativeLibrary));
    bindings.library;
    await bindings.prepareAdmission();
    bindings.lifetime.ensureAdmission();
    store = Store(
      '${profile.data}/application.db',
      configuration: configuration,
    );
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    await AudioStartupRecovery(
      media: media,
      bindings: bindings,
      current: () => true,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    ).run();
    await media.fencePublications();
    bindings.checkAvailable();
    active = true;
    return await use(media, () => active, () => active);
  } finally {
    active = false;
    if (bindings?.restartRequired ?? false) {
      _heldOwners.add((
        installation,
        lock,
        store,
        media,
        bindings,
        releaseLocal,
      ));
      ownershipUnconfirmed();
    } else {
      try {
        await media?.fencePublications();
        media?.close();
        store?.close();
      } finally {
        releaseLocal?.call();
        lock?.closeSync();
        installation?.closeSync();
      }
    }
  }
}

/// The parser remains independent of runtime/profile access.
WithAudioBackupOwner offlineAudioBackupOwner({
  required ProfilePaths profile,
  required RuntimeConfiguration configuration,
  required void Function() ownershipUnconfirmed,
}) =>
    (use) => withOfflineAudioBackupOwner(
      profile: profile,
      configuration: configuration,
      use: use,
      ownershipUnconfirmed: ownershipUnconfirmed,
    );
