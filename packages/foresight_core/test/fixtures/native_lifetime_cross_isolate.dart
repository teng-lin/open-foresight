import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/recording.dart';

Future<bool> replacementRefused(String path) => Isolate.run(() async {
  final replacement = NativeLibrary(DynamicLibrary.open(path)).lifetime;
  var admissionRefused = false, generationRefused = false;
  var captureRefused = false;
  try {
    replacement.ensureAdmission();
  } on StateError {
    admissionRefused = true;
  }
  final runtime = NativeRuntime(path);
  try {
    await runtime.load('/usr/bin/true', '/dev/null');
  } on StateError {
    generationRefused = true;
  } finally {
    runtime.close();
    await runtime.closed;
  }
  final recording = Recording(path, (_) {}, (_, _, _, _) {});
  try {
    await recording.start('/usr/bin/true', '/dev/null', playback: false);
  } on StateError {
    captureRefused = true;
  } finally {
    recording.dispose();
    await recording.closed;
  }
  return admissionRefused &&
      generationRefused &&
      captureRefused &&
      runtime.engine == 0 &&
      recording.captures.isEmpty &&
      recording.speeches.isEmpty;
});

Future<void> main(List<String> arguments) async {
  final path = arguments.single;
  final bindings = NativeLibrary(DynamicLibrary.open(path));
  final lifetime = bindings.lifetime;
  final create = bindings.library
      .lookupFunction<
        Uint64 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int, int)
      >('fs_owned_engine_create');
  final a = '/usr/bin/true'.toNativeUtf8(), b = '/dev/null'.toNativeUtf8();
  late final int owner;
  try {
    owner = create(a, b, 0, 0);
  } finally {
    calloc.free(a);
    calloc.free(b);
  }
  if (owner == 0) throw StateError('Control owner was not admitted');
  // The exact production export used for a lost acknowledgement. Native
  // status3 publication is separately controlled in native_owned_handles.
  bindings.library.lookupFunction<Void Function(), void Function()>(
    'fs_lifetime_quarantine',
  )();
  try {
    final refused = await replacementRefused(path);
    if (!refused) throw StateError('Fresh isolate bypassed native quarantine');
  } finally {
    // Quarantine never prevents actual release of the original physical owner.
    await lifetime.retire('fs_engine_retire', owner);
  }
  print(jsonEncode({'cross_isolate_refused': true, 'cleanup_joined': true}));
}
