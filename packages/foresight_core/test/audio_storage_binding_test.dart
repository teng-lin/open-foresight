import 'dart:io';

import 'package:foresight_core/src/persistence/audio_storage_binding.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  const first = 'e9152e50-9562-4e99-9dcb-a03b342ab75c';
  const next = '636fe16a-7977-4d85-9785-7d8f5f2e83b9';
  late Directory profile;

  setUp(() {
    profile = createTestTempDirectorySync('audio-binding-');
    File('${profile.path}/application.db').writeAsStringSync('database');
  });

  AudioStorageBinding open() {
    final binding = AudioStorageBinding(profile.path);
    addTearDown(binding.close);
    return binding;
  }

  test('same database survives restart and ordinary writes', () {
    final binding = open();
    expect(binding.read(), isNull);
    expect(binding.matches(first), isFalse);
    final identity = binding.databaseIdentity;
    binding.bind(generation: first, expectedDatabaseIdentity: identity);
    binding.bind(generation: first, expectedDatabaseIdentity: identity);
    binding.close();
    File('${profile.path}/application.db').writeAsStringSync('ordinary writes');
    final restarted = open();
    expect(restarted.databaseIdentity, identity);
    expect(restarted.matches(first), isTrue);
    expect(restarted.matches(next), isFalse);
  });

  test('restored copy cannot reuse a rewound database generation', () {
    final binding = open();
    final oldIdentity = binding.databaseIdentity;
    binding.bind(generation: first, expectedDatabaseIdentity: oldIdentity);
    // A restore copy is created while the original inode still exists.
    final copy = File('${profile.path}/restore-copy.db')
      ..writeAsStringSync('snapshot');
    copy.renameSync('${profile.path}/application.db');
    expect(binding.databaseIdentity, isNot(oldIdentity));
    expect(binding.matches(first), isFalse);
    expect(
      () => binding.bind(
        generation: first,
        expectedDatabaseIdentity: oldIdentity,
      ),
      throwsStateError,
    );
    expect(
      () => binding.bind(
        generation: next,
        expectedDatabaseIdentity: binding.databaseIdentity,
      ),
      throwsStateError,
    );
    binding.bind(
      generation: next,
      expectedDatabaseIdentity: binding.databaseIdentity,
      replace: true,
    );
    expect(binding.matches(first), isFalse);
    expect(binding.matches(next), isTrue);
  });

  test(
    'malformed and oversized bindings fail closed instead of overwriting',
    () {
      final binding = open();
      binding.bind(
        generation: first,
        expectedDatabaseIdentity: binding.databaseIdentity,
      );
      final file = File(
        '${profile.path}/recording-control/storage-binding.json',
      );
      for (final malformed in [
        '{}',
        'not json',
        '{"format":1,"database_identity":"1:2","generation":"bad"}',
        'x' * 4097,
      ]) {
        file.writeAsStringSync(malformed);
        expect(binding.read, throwsA(anything));
        expect(
          () => binding.bind(
            generation: first,
            expectedDatabaseIdentity: binding.databaseIdentity,
            replace: true,
          ),
          throwsA(anything),
        );
        expect(file.readAsStringSync(), malformed);
      }
    },
  );

  test('symlink control file cannot redirect reads or publication', () {
    final binding = open();
    final destination = File('${profile.path}/unrelated')
      ..writeAsStringSync('keep');
    Link(
      '${profile.path}/recording-control/storage-binding.json',
    ).createSync(destination.path);
    expect(binding.read, throwsStateError);
    expect(
      () => binding.bind(
        generation: first,
        expectedDatabaseIdentity: binding.databaseIdentity,
        replace: true,
      ),
      throwsStateError,
    );
    expect(destination.readAsStringSync(), 'keep');
  });

  test(
    'only explicit valid generation updates and owned database names bind',
    () {
      final binding = open();
      expect(
        () => binding.bind(
          generation: '../escape',
          expectedDatabaseIdentity: binding.databaseIdentity,
        ),
        throwsArgumentError,
      );
      expect(
        () => AudioStorageBinding(
          profile.path,
          databaseName: '../application.db',
        ),
        throwsArgumentError,
      );
      binding.bind(
        generation: 'a' * 32,
        expectedDatabaseIdentity: binding.databaseIdentity,
      );
      expect(binding.matches('a' * 32), isTrue);
      binding.bind(
        generation: next,
        expectedDatabaseIdentity: binding.databaseIdentity,
        replace: true,
      );
      expect(binding.matches(next), isTrue);
      binding.close();
      expect(binding.read, throwsStateError);
      expect(() => binding.databaseIdentity, throwsStateError);
      expect(
        () => binding.bind(generation: next, expectedDatabaseIdentity: '0:0'),
        throwsStateError,
      );
    },
  );
}
