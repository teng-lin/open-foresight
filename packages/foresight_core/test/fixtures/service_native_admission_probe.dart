// Each probe owns a fresh OS process: quarantining the real native mapping
// must never contaminate other test isolates in the test runner's process.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/application_service.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service_ownership.dart';

import '../sql_support_test_bootstrap.dart';

Future<void> main(List<String> args) async {
  bootstrapSqlSupportFixture();
  final mode = args[0], native = args[2];
  final profile = ProfilePaths('${args[1]}/d', '${args[1]}/r');
  final image = DynamicLibrary.open(native);
  final configuration = RuntimeConfiguration({
    'FORESIGHT_HELPER': '',
    if (mode != 'unselected') 'FORESIGHT_NATIVE': native,
  });
  if (mode != 'unselected') {
    // Configure once before quarantine to exercise the cached-environment path.
    configureProfileRuntime(profile.data, configuration: configuration);
  }
  if (mode == 'quarantined') {
    image.lookupFunction<Void Function(), void Function()>(
      'fs_lifetime_quarantine',
    )();
  }
  var started = false, restarted = false;
  String? failure;
  ApplicationService? service;
  try {
    service = await ApplicationService.start(
      profile,
      configuration: configuration,
    );
    started = true;
    await service.close();
    await service.closed;
    service = null;
    service = await ApplicationService.start(
      profile,
      configuration: configuration,
    );
    restarted = true;
  } catch (error) {
    failure = error.toString();
  } finally {
    await service?.close();
    await service?.closed;
  }
  print(
    jsonEncode({
      'started': started,
      'restarted': restarted,
      'failure': failure,
      'local_owner': hasLocalServiceOwner(profile.data),
      'media_opened': Directory(
        '${profile.data}/recording-control',
      ).existsSync(),
      'native_admission': image
          .lookupFunction<Int32 Function(), int Function()>(
            'fs_lifetime_admission',
          )(),
    }),
  );
}
