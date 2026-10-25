import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

// Protocol-only fixture: it owns no application resource/worker. Real native
// join/destruction and lost acknowledgement are covered by native_owned_handles.
void main() {
  late DynamicLibrary fixture;
  late void Function(int) status, admission, release;
  late int Function() released, ownersReleased;
  late File compiled;
  var fixtureNumber = 0;
  setUpAll(() async {
    final root = createTestTempDirectorySync('lifetime-protocol-');
    final source = File('${root.path}/fixture.c')
      ..writeAsStringSync(r'''
#include <stdint.h>
static int state, admitted = 1, release_ok = 1, releases, owner_releases;
int fs_abi_version(void) { return 1; }
int fs_lifetime_version(void) { return 2; }
void fixture_status(int value) { state = value; }
void fixture_admission(int value) { admitted = value; }
void fixture_release(int value) { release_ok = value; }
int fixture_releases(void) { return releases; }
int fixture_owner_releases(void) { return owner_releases; }
void fixture_reset(void) { state = 0; admitted = release_ok = 1; releases = 0; }
#define REQUEST(name) uint64_t name(uint64_t ignored) { return admitted ? 42 : 0; }
REQUEST(fs_engine_probe_async)
REQUEST(fs_engine_retire)
REQUEST(fs_conversation_retire)
REQUEST(fs_speech_retire)
REQUEST(fs_speech_join_async)
REQUEST(fs_capture_finish_async)
REQUEST(fs_capture_retire)
int fs_operation_status(uint64_t ignored) { return state; }
int fs_operation_release(uint64_t ignored) { releases++; return release_ok ? 0 : -1; }
int fs_owner_release(uint64_t ignored) { owner_releases++; return release_ok ? 0 : -1; }
// Capability-only symbols: these tests never call creation or inference.
#define SYMBOL(name) void name(void) {}
SYMBOL(fs_owned_engine_create)
SYMBOL(fs_owned_conversation_create)
SYMBOL(fs_owned_speech_create)
SYMBOL(fs_owned_capture_start)
SYMBOL(fs_owned_engine_state)
SYMBOL(fs_owned_event_poll)
SYMBOL(fs_owned_generate_options)
SYMBOL(fs_owned_generate_tools)
SYMBOL(fs_owned_generation_tool_reply)
SYMBOL(fs_owned_generation_cancel)
SYMBOL(fs_owned_speech_push)
SYMBOL(fs_owned_speech_finish)
SYMBOL(fs_owned_speech_cancel)
SYMBOL(fs_owned_capture_set_echo_cancellation)
''');
    final library = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final built = await Process.run('cc', [
      Platform.isMacOS ? '-dynamiclib' : '-shared',
      '-fPIC',
      source.path,
      '-o',
      library,
    ]);
    expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
    compiled = File(library);
  });
  setUp(() {
    // Each test gets a distinct native mapping. An unconfirmed mapping must
    // remain refused for the process lifetime; fixture reset cannot erase it.
    final copy = compiled.copySync('${compiled.path}.${fixtureNumber++}');
    fixture = DynamicLibrary.open(copy.path);
    status = fixture.lookupFunction<Void Function(Int32), void Function(int)>(
      'fixture_status',
    );
    admission = fixture
        .lookupFunction<Void Function(Int32), void Function(int)>(
          'fixture_admission',
        );
    release = fixture.lookupFunction<Void Function(Int32), void Function(int)>(
      'fixture_release',
    );
    released = fixture.lookupFunction<Int32 Function(), int Function()>(
      'fixture_releases',
    );
    ownersReleased = fixture.lookupFunction<Int32 Function(), int Function()>(
      'fixture_owner_releases',
    );
  });
  setUp(
    () => fixture.lookupFunction<Void Function(), void Function()>(
      'fixture_reset',
    )(),
  );
  const handle = 1;
  test(
    'coalesced native token remains pending and releases once after completion',
    () async {
      final lifetime = NativeLibrary(fixture).lifetime;
      final first = lifetime.request('fs_engine_probe_async', handle);
      final second = lifetime.request('fs_engine_probe_async', handle);
      expect(second, same(first));
      var complete = false;
      final observed = first.then((value) {
        complete = true;
        return value;
      });
      try {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(complete, isFalse);
        expect(released(), 0);
        status(1);
        expect(await observed, 1);
        expect(await second, 1);
        expect(released(), 1);
      } finally {
        status(1);
        await first;
      }
    },
  );
  test(
    'unconfirmed status never publishes completion or releases ownership',
    () async {
      status(-1);
      await expectLater(
        NativeLibrary(fixture).lifetime.request('fs_engine_retire', handle),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'unconfirmed',
            contains('unconfirmed'),
          ),
        ),
      );
      expect(released(), 0);
    },
  );
  test(
    'refused admission does not poll or release a nonexistent operation',
    () async {
      admission(0);
      await expectLater(
        NativeLibrary(fixture).lifetime.request('fs_engine_retire', handle),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'refusal',
            contains('not admitted'),
          ),
        ),
      );
      expect(released(), 0);
    },
  );
  test(
    'failed release cannot become a successful ownership acknowledgement',
    () async {
      status(1);
      release(0);
      await expectLater(
        NativeLibrary(fixture).lifetime.request('fs_engine_retire', handle),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'release',
            contains('unconfirmed'),
          ),
        ),
      );
      expect(released(), 0);
      expect(ownersReleased(), 1);
    },
  );
  test(
    'failed retirement retains ownership instead of acknowledging destruction',
    () async {
      status(2);
      await expectLater(
        NativeLibrary(fixture).lifetime.retire('fs_engine_retire', handle),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'retirement',
            contains('unconfirmed'),
          ),
        ),
      );
      expect(released(), 0);
      expect(ownersReleased(), 0);
    },
  );
  test('successful retirement uses owner acknowledgement only', () async {
    status(1);
    await NativeLibrary(fixture).lifetime.retire('fs_engine_retire', handle);
    expect(ownersReleased(), 1);
    expect(released(), 0);
  });
  test(
    'known failed probe releases its result and permits new admission',
    () async {
      status(2);
      final lifetime = NativeLibrary(fixture).lifetime;
      expect(await lifetime.request('fs_engine_probe_async', handle), 2);
      lifetime.ensureAdmission();
      expect(released(), 1);
      expect(ownersReleased(), 0);
    },
  );
  test(
    'unconfirmed completion poisons shared mapping admission but permits cleanup',
    () async {
      status(3);
      final lifetime = NativeLibrary(fixture).lifetime;
      await expectLater(
        lifetime.request('fs_speech_join_async', handle),
        throwsStateError,
      );
      final replacement = NativeLibrary(fixture).lifetime;
      expect(replacement, same(lifetime));
      expect(replacement.ensureAdmission, throwsStateError);
      expect(
        () => replacement.request('fs_engine_probe_async', handle),
        throwsStateError,
      );
      expect(released(), 0);
      status(1);
      await replacement.retire('fs_speech_retire', handle);
      expect(ownersReleased(), 1);
      expect(replacement.ensureAdmission, throwsStateError);
    },
  );
  test(
    'refused capacity does not spin or prevent existing owner cleanup',
    () async {
      admission(0);
      final lifetime = NativeLibrary(fixture).lifetime;
      await expectLater(
        lifetime.request('fs_engine_probe_async', handle),
        throwsStateError,
      );
      lifetime.ensureAdmission();
      admission(1);
      status(1);
      await lifetime.retire('fs_engine_retire', handle);
      expect(ownersReleased(), 1);
    },
  );
}
