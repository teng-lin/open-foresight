import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/recording_playback.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Map<String, dynamic> snapshot() => {
  'version': 1,
  'generation': 1,
  'ready': true,
  'paused': true,
  'stopped': false,
  'queued_frames': 0,
  'rendered_frames': 0,
  'underruns': 0,
  'buffering': false,
  'start_token': 11,
  'error': null,
};

// ABI/lifetime fixture only: no device is opened and no RT/backend correctness
// is inferred from it. Native PCM queue/AV offline/PipeWire tests cover those.
void main() {
  late File compiled;
  late NativeLibrary bindings;
  late DynamicLibrary fixture;
  var serial = 0;
  void set(String name, int value) =>
      fixture.lookupFunction<Void Function(Int32), void Function(int)>(
        'fixture_$name',
      )(value);
  int count(String name) => fixture
      .lookupFunction<Int32 Function(), int Function()>('fixture_$name')();

  setUpAll(() async {
    final root = createTestTempDirectorySync('pcm-output-protocol-');
    final source = File('${root.path}/fixture.cpp')
      ..writeAsStringSync(r'''
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
extern "C" {
static int version=1, start_state=1, finish_state=1, retire_state=1;
static int created, released, token_releases, queued, stopped, paused=1;
static int last_left, last_right;
static uint64_t generation=1;
int fs_abi_version() { return 1; }
int fs_lifetime_version() { return 2; }
int fs_lifetime_admission() { return 1; }
void fs_lifetime_quarantine() {}
int fs_owner_release(uint64_t) { ++released; return 0; }
int fs_operation_release(uint64_t) { ++token_releases; return 0; }
int fs_operation_status(uint64_t token) {
 return token==11?start_state:token==20?finish_state:token==30?retire_state:1;
}
#define REQUEST(name) uint64_t name(uint64_t) { return 20; }
REQUEST(fs_engine_probe_async) REQUEST(fs_engine_retire)
REQUEST(fs_conversation_retire) REQUEST(fs_speech_retire)
REQUEST(fs_speech_join_async) REQUEST(fs_capture_finish_async)
REQUEST(fs_capture_retire)
#define SYMBOL(name) void name() {}
SYMBOL(fs_owned_engine_create) SYMBOL(fs_owned_conversation_create)
SYMBOL(fs_owned_speech_create) SYMBOL(fs_owned_capture_start)
SYMBOL(fs_owned_engine_state) SYMBOL(fs_owned_event_poll)
SYMBOL(fs_owned_generate_options) SYMBOL(fs_owned_generate_tools)
SYMBOL(fs_owned_generation_tool_reply) SYMBOL(fs_owned_generation_cancel)
SYMBOL(fs_owned_speech_push) SYMBOL(fs_owned_speech_finish)
SYMBOL(fs_owned_speech_cancel) SYMBOL(fs_owned_capture_set_echo_cancellation)
void fs_string_free(char *text) { free(text); }
int fs_pcm_output_version() { return version; }
uint64_t fs_owned_pcm_output_create_async(const char *) { ++created; return 1; }
int fs_owned_pcm_output_push(uint64_t,uint64_t gen,const int16_t *pcm,size_t frames) {
 if (stopped || gen!=generation) return -2;
 const auto available=static_cast<size_t>(76800-queued);
 const auto accepted=frames<available?frames:available;
 if(accepted) { last_left=pcm[0]; last_right=pcm[accepted*2-1]; }
 queued+=static_cast<int>(accepted);
 return static_cast<int>(accepted);
}
char *fs_owned_pcm_output_poll(uint64_t) {
 char text[1024];
 snprintf(text,sizeof(text),"{\"version\":1,\"generation\":%llu,\"ready\":%s,\"paused\":%s,\"stopped\":%s,\"queued_frames\":%d,\"rendered_frames\":0,\"underruns\":0,\"buffering\":false,\"start_token\":11,\"error\":%s}",
 static_cast<unsigned long long>(generation), start_state==1?"true":"false",paused?"true":"false",stopped?"true":"false",queued,start_state==2?"\"backend_unavailable\"":"null");
 return strdup(text);
}
uint64_t fs_owned_pcm_output_pause_flush_async(uint64_t,uint64_t gen) {
 generation=gen; queued=0; paused=1; return 40;
}
uint64_t fs_owned_pcm_output_resume_async(uint64_t,uint64_t) { paused=0; return 41; }
uint64_t fs_pcm_output_finish_async(uint64_t) { stopped=1; if(start_state==0)start_state=2; return 20; }
uint64_t fs_pcm_output_retire(uint64_t) { return 30; }
#define SET(name,field) void fixture_##name(int value) { field=value; }
SET(version,version) SET(start,start_state) SET(finish,finish_state)
SET(retire,retire_state) SET(queue,queued)
int fixture_created(){return created;}
int fixture_released(){return released;}
int fixture_tokens(){return token_releases;}
int fixture_left(){return last_left;}
int fixture_right(){return last_right;}
}
''');
    compiled = File(
      '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}',
    );
    await buildCachedNativeFixture(source: source.path, output: compiled.path);
  });
  setUp(() {
    final copy = compiled.copySync('${compiled.path}.${serial++}');
    fixture = DynamicLibrary.open(copy.path);
    bindings = NativeLibrary(fixture);
  });

  Future<NativePcmOutput> open() =>
      NativePcmOutput.start(bindings: bindings, current: () => true);

  test('output metadata bounds independent atomic observations', () {
    expect(PcmOutputSnapshot.fromJson(snapshot()).queuedFrames, 0);
    for (final key in [
      'queued_frames',
      'rendered_frames',
      'underruns',
      'start_token',
    ]) {
      expect(
        () => PcmOutputSnapshot.fromJson({...snapshot(), key: -1}),
        throwsFormatException,
      );
    }
    expect(
      () => PcmOutputSnapshot.fromJson({...snapshot(), 'queued_frames': 76801}),
      throwsFormatException,
    );
    expect(
      () => PcmOutputSnapshot.fromJson({...snapshot(), 'ready': 1}),
      throwsFormatException,
    );
    expect(
      () => PcmOutputSnapshot.fromJson({...snapshot(), 'error': 'x' * 257}),
      throwsFormatException,
    );
    expect(
      () => PcmOutputSnapshot.fromJson({...snapshot(), 'error': 1}),
      throwsFormatException,
    );
  });
  test('unsupported output feature cannot create a native owner', () async {
    set('version', 0);
    await expectLater(open(), throwsStateError);
    expect(count('created'), 0);
  });
  test(
    'cancelled admission after prepare cannot create a native owner',
    () async {
      final prepared = Completer<void>(), gate = Completer<void>();
      NativeLibrary.beforeAdmission = (_, _) {
        prepared.complete();
        return gate.future;
      };
      addTearDown(() => NativeLibrary.beforeAdmission = null);
      var current = true;
      final opening = NativePcmOutput.start(
        bindings: bindings,
        current: () => current,
      );
      final refusal = expectLater(opening, throwsA(anything));
      await prepared.future;
      current = false;
      gate.complete();
      await refusal;
      expect(count('created'), 0);
    },
  );
  test(
    'stereo prefix copy and seek generation fence retain unaccepted PCM',
    () async {
      final output = await open();
      addTearDown(output.close);
      final pcm = Int16List.fromList([-10, 20, -30, 40]);
      set('queue', 76799);
      expect(output.push(pcm, generation: 1), 1);
      expect(count('left'), -10);
      expect(count('right'), 20);
      expect(pcm, [-10, 20, -30, 40]);
      expect(output.push(pcm, generation: 1), 0);
      final flush = output.pauseFlush(2);
      expect(output.push(pcm, generation: 1), -2);
      await flush;
      expect(output.generation, 2);
      expect(output.push(pcm, generation: 1), -2);
      expect(output.push(pcm, generation: 2), 2);
      await output.resume();
      expect(output.snapshot().paused, isFalse);
      await expectLater(output.pauseFlush(2), throwsArgumentError);
    },
  );
  test('invalid PCM never crosses native pointer ABI', () async {
    final output = await open();
    addTearDown(output.close);
    for (final length in [0, 1, 9602]) {
      expect(
        () => output.push(Int16List(length), generation: 1),
        throwsArgumentError,
      );
    }
  });
  test('known backend startup failure retires the owned resource', () async {
    set('start', 2);
    await expectLater(open(), throwsStateError);
    expect(count('created'), 1);
    expect(count('released'), 1);
    expect(bindings.restartRequired, isFalse);
  });
  test(
    'cancellation while starting requests force stop before ready acknowledgement',
    () async {
      set('start', 0);
      var current = true;
      final opening = NativePcmOutput.start(
        bindings: bindings,
        current: () => current,
      );
      final refusal = expectLater(opening, throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      current = false;
      await refusal;
      expect(count('released'), 1);
    },
  );
  test(
    'close is coalesced and waits actual retirement before owner release',
    () async {
      final output = await open();
      set('retire', 0);
      final closing = output.close();
      expect(output.close(), same(closing));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(count('released'), 0);
      expect(output.push(Int16List(2), generation: 1), -2);
      set('retire', 1);
      await closing;
      expect(count('released'), 1);
      expect(output.snapshot, throwsStateError);
    },
  );
}
