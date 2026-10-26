import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/service_frontend.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public worker carrier captures actual Helper once across async/global edits',
    () async {
      final previous = runtimeConfiguration;
      final boundary = RuntimeConfiguration({
        'FORESIGHT_HELPER': '/legacy/helper',
      });
      installRuntimeConfiguration(boundary);
      final installed = runtimeConfiguration;
      final legacy = Helper(
        '/unused/legacy.sock',
        '/unused/legacy',
        manageProcess: false,
      );
      Helper? owned;
      try {
        final carrier = {
          'FORESIGHT_HELPER': '/owner/helper',
          'opaque-entry': 'unchanged',
        };
        final captured =
            await runApplicationWorkerConfiguration<
              Future<RuntimeConfiguration>
            >(carrier, () async {
              expect(runtimeConfiguration, same(installed));
              await Future<void>.delayed(Duration.zero);
              owned = Helper(
                '/unused/owner.sock',
                '/unused/owner',
                manageProcess: false,
              );
              final captured = currentOwnerRuntimeSnapshot!;
              expect(owned!.configuration, same(captured));
              carrier['FORESIGHT_HELPER'] = '/changed/carrier';
              installRuntimeConfiguration(
                RuntimeConfiguration({'FORESIGHT_HELPER': '/later/global'}),
              );
              expect(owned!.configuration['FORESIGHT_HELPER'], '/owner/helper');
              return captured;
            });
        expect(currentOwnerRuntimeSnapshot, isNull);
        expect(captured['opaque-entry'], 'unchanged');
        expect(owned!.configuration['FORESIGHT_HELPER'], '/owner/helper');
        expect(legacy.configuration['FORESIGHT_HELPER'], '/later/global');
        expect(
          () => captured.environment['FORESIGHT_HELPER'] = '/mutated/snapshot',
          throwsUnsupportedError,
        );
      } finally {
        await owned?.channel.shutdown();
        await legacy.channel.shutdown();
        installRuntimeConfiguration(previous);
      }
    },
  );
}
