import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/recording.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'unconfirmed recording cleanup refuses replacement before new physical admission',
    () async {
      final root = createTestTempDirectorySync('recording-unconfirmed-');
      final path = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
      await buildCachedNativeFixture(
        source: 'test/fixtures/recording_native_stub.cpp',
        output: path,
      );
      final lib = DynamicLibrary.open(path);
      final unconfirmed = lib
          .lookupFunction<Void Function(Int32), void Function(int)>(
            'fixture_unconfirmed_retirement',
          );
      final speechCreations = lib
          .lookupFunction<Int32 Function(), int Function()>(
            'fixture_speech_creations',
          );
      final captureCreations = lib
          .lookupFunction<Int32 Function(), int Function()>(
            'fixture_capture_creations',
          );
      final pending = lib.lookupFunction<Int32 Function(), int Function()>(
        'fixture_pending_retirements',
      );
      final model = File('${root.path}/model')
        ..writeAsStringSync('fixture only');
      final original = Recording(path, (_) {}, (_, _, _, _) {});
      await original.start('/usr/bin/true', model.path, playback: false);
      final owners = original.captures.toList();
      final replacement = Recording(path, (_) {}, (_, _, _, _) {});
      try {
        unconfirmed(1);
        original.dispose();
        await expectLater(original.closed, throwsStateError);
        expect(pending(), owners.length);
        final speeches = speechCreations(), captures = captureCreations();
        await expectLater(
          replacement.start('/usr/bin/true', model.path, playback: false),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'restart',
              contains('restart'),
            ),
          ),
        );
        expect(
          speechCreations(),
          speeches,
          reason: 'No replacement probe was created',
        );
        expect(
          captureCreations(),
          captures,
          reason: 'No replacement device was opened',
        );
        expect(replacement.captures, isEmpty);
        expect(replacement.speeches, isEmpty);
      } finally {
        // Explicit recovery only cleans the controlled fixture owner. The
        // production mapping remains refused; restarting an isolate cannot reset it.
        unconfirmed(0);
        for (final owner in owners) {
          await NativeLibrary(lib).lifetime.retire('fs_capture_retire', owner);
        }
        replacement.dispose();
        await replacement.closed;
        expect(pending(), 0);
      }
    },
  );
}
