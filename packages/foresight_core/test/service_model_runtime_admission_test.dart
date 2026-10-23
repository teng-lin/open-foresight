import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  group(
    'installed service model runtime admission',
    () {
      late Directory directory;
      late String isolatedLibrary;
      setUpAll(() {
        // Test files run in Dart isolates in one process. The production native
        // library seals its environment process-wide; use a distinct loaded
        // image so another fixture's profile cannot freeze this file's cache.
        final nativeRoot = createTestTempDirectorySync('admission-native-');
        isolatedLibrary = File(library!)
            .copySync(
              '${nativeRoot.path}/${Platform.isMacOS ? 'native.dylib' : 'native.so'}',
            )
            .path;
      });
      setUp(() {
        directory = createTestTempDirectorySync('model-admission-');
        File('${directory.path}/asset').writeAsStringSync('fixture');
      });
      for (final selection in ['default', 'explicit', 'registration']) {
        test(
          'installed service maps legacy LiteRT $selection selection before admission',
          () async {
            final environment = Map.of(runtimeConfiguration.environment);
            addTearDown(
              () => runtimeConfiguration.environment
                ..clear()
                ..addAll(environment),
            );
            final outside = createTestTempDirectorySync('outside-runner-');
            final invoked = File('${outside.path}/invoked');
            final legacy = File('${outside.path}/legacy-python')
              ..writeAsStringSync('''#!/bin/sh
echo invoked > ${jsonEncode(invoked.path)}
exit 1
''');
            final report = File('${directory.path}/service-probe-paths');
            final worker = File('${directory.path}/bundled-worker')
              ..writeAsStringSync('''#!/usr/bin/env python3
import json,sys
with open(${jsonEncode(report.path)},'a') as output: output.write(sys.argv[0]+'\\n')
assert '--probe' in sys.argv
print(json.dumps({'native_stop_token_sequences':True}))
''');
            for (final file in [legacy, worker]) {
              expect(
                (await Process.run('/bin/chmod', ['700', file.path])).exitCode,
                0,
              );
            }
            final alias = Link('${directory.path}/bundled-alias')
              ..createSync(worker.path);
            runtimeConfiguration.environment.addAll({
              'FORESIGHT_INSTALL_ROOT': directory.path,
              'FORESIGHT_LITERT_RUNNER': alias.path,
              'FORESIGHT_NATIVE': isolatedLibrary,
              'FORESIGHT_HELPER': '',
            });
            final profile = ProfilePaths(
              '${directory.path}/profile',
              '${directory.path}/run',
            );
            final service = await ApplicationService.start(
              profile,
              desktopPeerVerifier: trustInProcessDesktop,
            );
            addTearDown(service.close);
            final desktop = await ServiceClient.connect(service.path);
            addTearDown(desktop.close);
            await desktop.call('security.attach_desktop', {
              'token': File(
                '${profile.data}/.desktop-capability',
              ).readAsStringSync(),
              'visible': true,
            });
            final model = '${directory.path}/asset';
            await desktop.call(
              selection == 'registration'
                  ? 'models.register'
                  : 'models.generation',
              {
                'path': model,
                'runtime': legacy.path,
                if (selection != 'default') 'backend': 'litert_lm',
                if (selection == 'registration') 'kind': 'generation',
              },
            );
            expect(
              service.domain.store.model('generation')!['runtime'],
              worker.resolveSymbolicLinksSync(),
            );
            expect(invoked.existsSync(), isFalse);
            if (selection != 'registration') {
              expect(report.readAsLinesSync(), [
                worker.resolveSymbolicLinksSync(),
              ]);
            }
            if (selection == 'default') {
              final denied = isA<RpcError>().having(
                (error) => error.code,
                'code',
                RpcErrorCode.denied,
              );
              final requests = [
                ('models.generation', {'backend': 'llama_cpp'}),
                ('models.register', {'kind': 'generation'}),
                ('models.register', {'kind': 'generation', 'backend': null}),
                (
                  'models.register',
                  {'kind': 'generation', 'backend': 'llama_cpp'},
                ),
                ('models.speech', {'digest': 'fixture'}),
                ('models.register', {'kind': 'speech'}),
                ('models.register', {'kind': 'query-detection'}),
              ];
              for (final (method, args) in requests) {
                await expectLater(
                  desktop.call(method, {
                    'path': model,
                    'runtime': legacy.path,
                    ...args,
                  }),
                  throwsA(denied),
                  reason: '$method $args must keep its executable restriction',
                );
              }
              final embedding = File(
                model,
              ).copySync('${directory.path}/embedding.litertlm');
              await desktop.call('models.register', {
                'kind': 'embedding',
                'path': embedding.path,
                'runtime': legacy.path,
              });
              expect(
                service.domain.store.model('embedding')!['runtime'],
                legacy.path,
                reason: 'Embedding runtime names data, not executable code',
              );
              expect(invoked.existsSync(), isFalse);
            }
          },
        );
      }
    },
    skip: library == null
        ? 'Requires a built FORESIGHT_NATIVE_LIBRARY and its process supervisor'
        : false,
  );
}
