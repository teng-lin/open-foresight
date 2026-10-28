import 'dart:convert';
import 'audio_profile_backups.dart';
import 'recording_media.dart';

const audioBackupUsage = '''
Usage: foresight-service --audio-backup-create=NEW_DIRECTORY
       foresight-service --audio-backup-inspect=BACKUP_DIRECTORY
       foresight-service --audio-backup-restore=BACKUP_DIRECTORY --new-profile=NEW_DIRECTORY

Audio backups contain the database and current usable recording files. Installed
binaries/models, migration rollback snapshots and user-owned exported files are
excluded. Stop capture, playback and workers before creating a backup; startup
must finish authorized capture recovery first. Backups are private, user-owned
copies outside the managed profile and are not erased when the original meeting
is deleted. Restore validates the complete copy and publishes a NEW profile into
an absent directory. It never replaces the active profile. Select the restored
profile explicitly with FORESIGHT_DATA. Missing originals cannot be recreated;
any already unavailable audio is counted in the backup report.''';

bool isAudioBackupInvocation(List<String> arguments) => arguments.any(
  (a) => a.startsWith('--audio-backup-') || a.startsWith('--new-profile'),
);

final class AudioBackupCommand {
  const AudioBackupCommand._(this.mode, this.path, [this.newProfile]);
  final String mode, path;
  final String? newProfile;
  static AudioBackupCommand? parse(List<String> arguments, StringSink error) {
    final options = <String, String>{};
    for (final argument in arguments) {
      final match = RegExp(r'^--([a-z-]+)=(.+)$').firstMatch(argument);
      if (match == null ||
          options.containsKey(match[1]) ||
          match[2]!.contains('\u0000')) {
        error.writeln(audioBackupUsage);
        return null;
      }
      options[match[1]!] = match[2]!;
    }
    switch (options.keys.toList()..sort()) {
      case ['audio-backup-create']:
        return AudioBackupCommand._('create', options['audio-backup-create']!);
      case ['audio-backup-inspect']:
        return AudioBackupCommand._(
          'inspect',
          options['audio-backup-inspect']!,
        );
      case ['audio-backup-restore', 'new-profile']:
        return AudioBackupCommand._(
          'restore',
          options['audio-backup-restore']!,
          options['new-profile']!,
        );
    }
    error.writeln(audioBackupUsage);
    return null;
  }
}

/// The entrypoint acquires profile ownership and supplies actual capture and
/// worker quiescence, preserving the barrier until use settles. Parsing does no
/// runtime/profile/bootstrap work. Inspection/new-profile restore need no live
/// profile and cannot replace one.
typedef WithAudioBackupOwner =
    Future<AudioProfileBackup> Function(
      Future<AudioProfileBackup> Function(
        RecordingMedia media,
        bool Function() quiesced,
        bool Function() current,
      )
      use,
    );
Future<int> runAudioBackupCommand(
  AudioBackupCommand command, {
  required AudioProfileBackups backups,
  required bool Function() current,
  required StringSink out,
  required StringSink err,
  WithAudioBackupOwner? withOwner,
}) async {
  try {
    switch (command.mode) {
      case 'create':
        if (withOwner == null) {
          throw StateError(
            'Audio backup creation requires an offline/quiesced media owner',
          );
        }
        final result = await withOwner(
          (media, quiesced, ownerCurrent) => backups.create(
            media: media,
            authorizedDestination: command.path,
            quiesced: quiesced,
            current: () => current() && ownerCurrent(),
          ),
        );
        out.writeln(
          jsonEncode({'backup_directory': result.path, ...result.manifest}),
        );
      case 'inspect':
        final result = await backups.inspect(command.path, current: current);
        out.writeln(
          jsonEncode({'backup_directory': result.path, ...result.manifest}),
        );
      default:
        final result = await backups.restoreToNewProfile(
          backupDirectory: command.path,
          authorizedAbsentProfile: command.newProfile!,
          current: current,
        );
        out.writeln(
          jsonEncode({
            'new_profile': result.profilePath,
            'backup_id': result.source.manifest['backup_id'],
            'representations': result.source.representationCount,
            'missing_audio_chunks': result.source.missingAudioChunks,
            'select_with': 'FORESIGHT_DATA',
          }),
        );
    }
    return 0;
  } on StateError catch (error) {
    err.writeln(error.message);
    return 1;
  } on ArgumentError catch (error) {
    err.writeln(error.message);
    return 1;
  } on Exception catch (error) {
    err.writeln(error);
    return 1;
  }
}
