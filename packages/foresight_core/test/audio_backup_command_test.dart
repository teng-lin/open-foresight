import 'package:foresight_core/src/persistence/audio_backup_command.dart';
import 'package:foresight_core/src/persistence/audio_profile_backups.dart';
import 'package:test/test.dart';

void main() {
  test(
    'explicit create inspect and absent-new-profile restore parse without runtime',
    () {
      final err = StringBuffer();
      final create = AudioBackupCommand.parse([
        '--audio-backup-create=/chosen/new',
      ], err)!;
      expect(create.mode, 'create');
      expect(create.path, '/chosen/new');
      final inspect = AudioBackupCommand.parse([
        '--audio-backup-inspect=/chosen/backup',
      ], err)!;
      expect(inspect.mode, 'inspect');
      final restore = AudioBackupCommand.parse([
        '--new-profile=/chosen/new',
        '--audio-backup-restore=/chosen/backup',
      ], err)!;
      expect(restore.mode, 'restore');
      expect(restore.newProfile, '/chosen/new');
      expect(err.isEmpty, true);
      expect(isAudioBackupInvocation(['--audio-backup-inspect=x']), true);
    },
  );
  test(
    'duplicates incomplete restore and other commands are refused before profile access',
    () {
      for (final args in [
        <String>[],
        ['--audio-backup-create='],
        ['--audio-backup-create=x', '--audio-backup-create=y'],
        ['--audio-backup-restore=x'],
        ['--new-profile=x'],
        ['--restore-activate=x'],
        ['--audio-backup-inspect=x\u0000y'],
      ]) {
        final error = StringBuffer();
        expect(AudioBackupCommand.parse(args, error), null);
        expect(error.toString(), contains('NEW profile'));
      }
    },
  );
  test(
    'creation runner cannot claim a backup without actual quiesced ownership',
    () async {
      final command = AudioBackupCommand.parse([
        '--audio-backup-create=/chosen/new',
      ], StringBuffer())!;
      final out = StringBuffer(), err = StringBuffer();
      expect(
        await runAudioBackupCommand(
          command,
          backups: AudioProfileBackups(),
          current: () => true,
          out: out,
          err: err,
        ),
        1,
      );
      expect(out.isEmpty, true);
      expect(
        err.toString(),
        contains('requires an offline/quiesced media owner'),
      );
    },
  );
}
