import 'dart:io';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Directory _privateRoot(String prefix) {
  final temporary = createTestTempDirectorySync(prefix);
  final root = Directory('${temporary.path}/private');
  privateDirectory(root.path);
  expect(root.statSync().mode & 0x1ff, 0x1c0);
  return root;
}

void main() {
  test(
    'completed private directory publishes atomically without replacing a profile',
    () {
      final root = _privateRoot('audio-publish-profile-');
      final parent = BackupDirectory(root.path, create: false),
          stage = parent.child('stage');
      addTearDown(parent.close);
      addTearDown(stage.close);
      stage.open('application.db', create: true)
        ..write([1, 2, 3])
        ..close();
      stage.sync();
      final published = parent.publishChild(stage, 'restored');
      addTearDown(published.close);
      expect(published.identity, stage.identity);
      expect(parent.entryExists('stage'), false);
      final next = parent.child('next');
      addTearDown(next.close);
      expect(() => parent.publishChild(next, 'restored'), throwsStateError);
      expect(parent.entryExists('next'), true);
      final file = published.open('application.db', readOnly: true);
      expect(file.readSmall(3), [1, 2, 3]);
      file.close();
    },
  );
  test(
    'receipt replacement does not enumerate the growing session directory',
    () {
      final root = _privateRoot('audio-receipt-lookup-');
      final directory = BackupDirectory(
        root.path,
        create: false,
        reader: (_, _, _) => throw StateError('Unexpected directory scan'),
      );
      addTearDown(directory.close);
      directory.open('receipt', create: true)
        ..write([1])
        ..close();
      directory.open('temporary', create: true)
        ..write([2])
        ..close();
      directory.replace('temporary', 'receipt');
      final file = directory.open('receipt', readOnly: true);
      expect(file.readSmall(1), [2]);
      file.close();
    },
  );
  test(
    'empty private child cleanup never recursively erases foreign contents',
    () {
      final root = _privateRoot('export-empty-child-');
      final directory = BackupDirectory(root.path, create: false);
      final child = directory.child('owned');
      addTearDown(child.close);
      addTearDown(directory.close);
      final file = child.open('data', create: true);
      file.write([7]);
      file.close();
      expect(() => directory.removeEmptyChild(child), throwsStateError);
      expect(
        () => child.remove('data', expectedIdentity: 'wrong'),
        throwsStateError,
      );
      expect(child.entryExists('data'), true);
      child.remove('data', expectedIdentity: child.metadata('data').identity);
      directory.removeEmptyChild(child);
      expect(directory.entryExists('owned'), false);
    },
  );

  test('anchored read-only media input cannot write or create', () {
    final root = _privateRoot('export-readonly-');
    final directory = BackupDirectory(root.path, create: false);
    addTearDown(directory.close);
    final output = directory.open('input', create: true);
    output.write([1, 2, 3]);
    output.close();
    final input = directory.open('input', readOnly: true);
    addTearDown(input.close);
    expect(input.readSmall(3), [1, 2, 3]);
    expect(() => input.write([9]), throwsStateError);
    expect(
      () => directory.open('new', create: true, readOnly: true),
      throwsArgumentError,
    );
    expect(directory.entryExists('new'), false);
  });

  test(
    'entry existence is descriptor-relative and never follows a final symlink',
    () {
      final root = _privateRoot('export-entry-');
      final directory = BackupDirectory(root.path, create: false);
      addTearDown(directory.close);
      expect(directory.entryExists('absent'), false);
      final file = directory.open('present', create: true);
      file.close();
      expect(directory.entryExists('present'), true);
      Link('${root.path}/link').createSync('${root.path}/absent');
      expect(directory.entryExists('link'), true);
      expect(() => directory.metadata('link'), throwsStateError);
      expect(() => directory.entryExists('../outside'), throwsStateError);
      expect(() => directory.entryExists('bad\u0000name'), throwsStateError);
      Directory('${root.path}/child').createSync();
      expect(directory.entryExists('child'), true);
      expect(() => directory.metadata('child'), throwsStateError);
      directory.close();
      expect(() => directory.entryExists('present'), throwsStateError);
    },
  );
}
