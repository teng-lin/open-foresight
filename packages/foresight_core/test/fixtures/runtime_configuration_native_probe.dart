// Profile native-selection probe, run in its own OS process.
//
// fs_set_runtime_environment applies setenv and is permanently sealed once the
// process starts its first native handle; after that only the exact current
// value is accepted (native/foresight_native.h). A fresh Dart isolate shares
// that process state, so each probe needs a fresh process with the qualified
// native/SQL environment inherited from the test runner.
//
// usage: dart test/fixtures/runtime_configuration_native_probe.dart <directory>
//            [explicit] [unscoped] [service] [seal-first]
// Prints one JSON line with the observed result.
import '../sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/application_service.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service_ownership.dart';

Future<void> main(List<String> arguments) async {
  final directory = arguments.first;
  final flags = arguments.skip(1).toSet();
  // Bootstrap SQLite before replacing configuration with native-only test scopes.
  if (flags.contains('service')) bootstrapSqlSupportFixture();
  final nativeLibrary = Platform.environment['FORESIGHT_NATIVE_LIBRARY']!;
  if (flags.contains('seal-first')) _sealWithFirstHandle(nativeLibrary);
  final result = await _nativeProfileSelection(
    directory,
    nativeLibrary,
    explicit: flags.contains('explicit'),
    scoped: !flags.contains('unscoped'),
    service: flags.contains('service'),
  );
  stdout.writeln(jsonEncode(result));
}

/// Starts a first handle of the real library, as another suite in a shared
/// test process would. Speech creation seals before validating its assets,
/// so missing paths seal without loading any model and return null.
void _sealWithFirstHandle(String nativeLibrary) {
  final create = DynamicLibrary.open(nativeLibrary)
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)
      >('fs_speech_create');
  final missing = '/nonexistent/runtime-configuration-seal'.toNativeUtf8();
  try {
    if (create(missing, missing) != nullptr) {
      throw StateError('Sealing probe unexpectedly created a speech handle');
    }
  } finally {
    calloc.free(missing);
  }
}

Future<Map<String, Object?>> _nativeProfileSelection(
  String directory,
  String nativeLibrary, {
  bool explicit = false,
  bool scoped = true,
  bool service = false,
}) async {
  final missing = '$directory/missing-legacy-native.so';
  installRuntimeConfiguration(
    RuntimeConfiguration({'FORESIGHT_NATIVE': missing}),
  );
  final owned = RuntimeConfiguration({'FORESIGHT_NATIVE': nativeLibrary});
  final profile = ProfilePaths('$directory/data', '$directory/run');
  Future<void> start() async {
    if (service) {
      final owner = await ApplicationService.start(
        profile,
        desktopPeerVerifier: (_) => false,
      );
      await owner.close();
    } else {
      final lock = await acquireServiceProfileLock(
        profile,
        launchWithdrawn: () => false,
        configuration: explicit ? owned : null,
      );
      await lock.unlock();
      await lock.close();
    }
  }

  try {
    await (scoped ? runWithRuntimeConfiguration(owned, start) : start());
    return {
      'ok': true,
      'legacyDefaults': runtimeConfiguration['FORESIGHT_LITERT_CACHE'],
      'ownerUnchanged': owned['FORESIGHT_LITERT_CACHE'] == null,
    };
  } on ArgumentError catch (error) {
    return {'ok': false, 'missingLegacyLibrary': '$error'.contains(missing)};
  } on StateError catch (error) {
    return {
      'ok': false,
      'sealedRefusal': '$error'.contains('Cannot configure native runtime'),
    };
  }
}
