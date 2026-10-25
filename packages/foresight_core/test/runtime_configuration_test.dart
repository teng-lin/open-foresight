import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/src/application_services/service_runtime_ports.dart';
import 'package:foresight_core/src/audio_devices.dart';
import 'package:foresight_core/src/dedicated_query_terms.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/runtime_execution_policy.dart';
import 'package:foresight_core/src/service_ownership.dart';
import 'package:foresight_core/src/service_startup.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

File _script(Directory directory, String name, String body) {
  final file = File('${directory.path}/$name')
    ..writeAsStringSync('#!/bin/sh\n$body\n');
  expect(Process.runSync('/bin/chmod', ['700', file.path]).exitCode, 0);
  return file;
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('runtime-configuration-');
    final previous = runtimeConfiguration;
    addTearDown(() => installRuntimeConfiguration(previous));
  });

  group('snapshots', () {
    test('construction copies the caller map and exposes no mutation', () {
      final source = {'FORESIGHT_HELPER': '/bundle/helper'};
      final configuration = RuntimeConfiguration(
        source,
        linuxBundleRoot: '/bundle',
      );
      source['FORESIGHT_HELPER'] = '/elsewhere/helper';
      source['FORESIGHT_NATIVE'] = '/elsewhere/native.so';
      expect(configuration.environment, {'FORESIGHT_HELPER': '/bundle/helper'});
      expect(
        () => configuration.environment['FORESIGHT_HELPER'] = '/x',
        throwsUnsupportedError,
      );
      expect(
        () => configuration.environment.remove('FORESIGHT_HELPER'),
        throwsUnsupportedError,
      );
      expect(configuration.environment.clear, throwsUnsupportedError);
      expect(
        () => configuration.environment.putIfAbsent('FORESIGHT_X', () => ''),
        throwsUnsupportedError,
      );
      expect(configuration['FORESIGHT_HELPER'], '/bundle/helper');
      expect(configuration.linuxBundleRoot, '/bundle');
    });

    test('the installed boundary snapshot rejects mutation', () {
      installRuntimeConfiguration(RuntimeConfiguration({'FORESIGHT_X': 'a'}));
      expect(
        () => runtimeConfiguration.environment['FORESIGHT_X'] = 'b',
        throwsUnsupportedError,
      );
      expect(runtimeConfiguration['FORESIGHT_X'], 'a');
    });

    test('defaults never replace explicit values and keep the bundle root', () {
      final explicit = RuntimeConfiguration({
        'FORESIGHT_LITERT_CACHE': '/explicit/cache',
      }, linuxBundleRoot: '/bundle');
      final profiled = explicit.withProfileRuntime('/profile');
      expect(profiled.environment, {
        'FORESIGHT_LITERT_CACHE': '/explicit/cache',
        'PYTHONPYCACHEPREFIX': '/profile/cache/python',
      });
      expect(profiled.linuxBundleRoot, '/bundle');
      expect(
        explicit.environment,
        {'FORESIGHT_LITERT_CACHE': '/explicit/cache'},
        reason: 'derivation leaves the original snapshot unchanged',
      );
      expect(identical(profiled.withProfileRuntime('/other'), profiled), true);
      expect(
        () => profiled.environment['PYTHONPYCACHEPREFIX'] = '/x',
        throwsUnsupportedError,
      );
    });

    test('overrides replace or remove entries in a new snapshot', () {
      final base = RuntimeConfiguration({
        'FORESIGHT_A': 'a',
        'FORESIGHT_B': 'b',
      }, linuxBundleRoot: '/bundle');
      final changed = base.withOverrides({
        'FORESIGHT_A': null,
        'FORESIGHT_C': 'c',
      });
      expect(changed.environment, {'FORESIGHT_B': 'b', 'FORESIGHT_C': 'c'});
      expect(changed.linuxBundleRoot, '/bundle');
      expect(base.environment, {'FORESIGHT_A': 'a', 'FORESIGHT_B': 'b'});
    });

    test('installation roots are canonical and absent without a root', () {
      final link = Link('${root.path}/install-link')..createSync(root.path);
      expect(
        RuntimeConfiguration({
          'FORESIGHT_INSTALL_ROOT': link.path,
        }).installationRoot,
        canonicalProfilePath(root.path),
      );
      expect(RuntimeConfiguration({}).installationRoot, isNull);
    });

    test('service profile ownership adds caches only for native runtimes', () {
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      final storageOnly = RuntimeConfiguration({'FORESIGHT_X': 'x'});
      expect(
        identical(
          profileServiceConfiguration(profile, storageOnly),
          storageOnly,
        ),
        isTrue,
      );
      final native = RuntimeConfiguration({
        'FORESIGHT_NATIVE': '/bundle/native.so',
        'PYTHONPYCACHEPREFIX': '/explicit/python',
      });
      final owned = profileServiceConfiguration(profile, native);
      expect(owned.environment, {
        'FORESIGHT_NATIVE': '/bundle/native.so',
        'PYTHONPYCACHEPREFIX': '/explicit/python',
        'FORESIGHT_LITERT_CACHE': '${profile.data}/cache/litert',
      });
      expect(native.environment, hasLength(2));
    });
  });

  group('isolate transport', () {
    test('an exact snapshot crosses isolates and stays immutable', () async {
      final snapshot = RuntimeConfiguration({
        'FORESIGHT_HELPER': '/bundle/helper',
        'FORESIGHT_NATIVE': '/bundle/native.so',
      }, linuxBundleRoot: '/bundle');
      final (previous, environment, bundle, rejected) = await Isolate.run(() {
        // A fresh isolate has no installed snapshot; installing one must not
        // resolve the process environment first.
        final previous = installRuntimeConfiguration(snapshot);
        var rejected = false;
        try {
          runtimeConfiguration.environment['FORESIGHT_HELPER'] = '/x';
        } on UnsupportedError {
          rejected = true;
        }
        return (
          previous,
          Map.of(runtimeConfiguration.environment),
          runtimeConfiguration.linuxBundleRoot,
          rejected,
        );
      });
      expect(previous, isNull);
      expect(environment, snapshot.environment);
      expect(bundle, '/bundle');
      expect(rejected, isTrue);
    });

    test('a worker snapshot is independent of the sender boundary', () async {
      final snapshot = RuntimeConfiguration({'FORESIGHT_X': 'worker'});
      installRuntimeConfiguration(RuntimeConfiguration({'FORESIGHT_X': 'own'}));
      final seen = await Isolate.run(() {
        installRuntimeConfiguration(snapshot);
        return runtimeConfiguration['FORESIGHT_X'];
      });
      expect(seen, 'worker');
      expect(runtimeConfiguration['FORESIGHT_X'], 'own');
    });

    test('service worker snapshots keep the transported environment', () {
      final configuration = RuntimeConfiguration.serviceWorker({
        'FORESIGHT_X': 'x',
      });
      expect(configuration.environment, {'FORESIGHT_X': 'x'});
      installServiceWorkerEnvironment({'FORESIGHT_X': 'x'});
      expect(runtimeConfiguration.environment, configuration.environment);
      expect(
        runtimeConfiguration.linuxBundleRoot,
        configuration.linuxBundleRoot,
      );
    });
  });

  group('injected consumers ignore the boundary snapshot', () {
    test('query terms use the owner configuration', () {
      installRuntimeConfiguration(
        RuntimeConfiguration({
          'FORESIGHT_QUERY_TERMS_URL': 'https://boundary.example/terms',
        }),
      );
      final owned = RuntimeConfiguration({
        'FORESIGHT_QUERY_TERMS_URL': 'https://owner.example/terms',
      });
      expect(
        dedicatedQueryTermsUri(configuration: owned),
        Uri.parse('https://owner.example/terms'),
      );
      expect(
        dedicatedQueryTermsUri(configuration: RuntimeConfiguration({})),
        isNull,
      );
      expect(
        dedicatedQueryTermsUri(),
        Uri.parse('https://boundary.example/terms'),
      );
    });

    test('Mac audio discovery launches the owner adapter', () async {
      installRuntimeConfiguration(
        RuntimeConfiguration({'FORESIGHT_AUDIO_DEVICES': '/boundary/adapter'}),
      );
      final launched = <String>[];
      final devices = await audioDevices(
        macOS: true,
        configuration: RuntimeConfiguration({
          'FORESIGHT_AUDIO_DEVICES': '/owner/adapter',
        }),
        runProcess: (executable, arguments) async {
          launched.add(executable);
          return ProcessResult(0, 0, jsonEncode([]), '');
        },
      );
      expect(devices, isEmpty);
      expect(launched, ['/owner/adapter']);
      await expectLater(
        audioDevices(
          macOS: true,
          configuration: RuntimeConfiguration({}),
          runProcess: (executable, _) async {
            launched.add(executable);
            return ProcessResult(0, 0, '[]', '');
          },
        ),
        throwsStateError,
      );
      expect(launched, ['/owner/adapter']);
    });

    test('Mac document extraction runs the owner parser', () async {
      final owner = _script(root, 'owner-parser', 'echo owner text');
      final boundary = _script(root, 'boundary-parser', 'echo boundary text');
      installRuntimeConfiguration(
        RuntimeConfiguration({'FORESIGHT_FILE_PARSER': boundary.path}),
      );
      final document = File('${root.path}/document.pdf')
        ..writeAsStringSync('%PDF-fixture');
      final (text, provenance) = await Parser(
        macOS: true,
        configuration: RuntimeConfiguration({
          'FORESIGHT_FILE_PARSER': owner.path,
        }),
      ).extract(document.path);
      expect(text.trim(), 'owner text');
      expect(provenance, 'PDFKit (macOS adapter)');
      await expectLater(
        Parser(
          macOS: true,
          configuration: RuntimeConfiguration({}),
        ).extract(document.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('extractor is unavailable'),
          ),
        ),
      );
      final (boundaryText, _) = await Parser(
        macOS: true,
      ).extract(document.path);
      expect(boundaryText.trim(), 'boundary text');
    });

    test('installed runtime containment uses the owner root only', () {
      final installed = Directory('${root.path}/installed')..createSync();
      final inside = File('${installed.path}/runner')..writeAsStringSync('');
      final outside = File('${root.path}/outside')..writeAsStringSync('');
      final owned = RuntimeConfiguration({
        'FORESIGHT_INSTALL_ROOT': installed.path,
      });
      installRuntimeConfiguration(RuntimeConfiguration({}));
      expect(requireInstalledRuntime(outside.path), outside.path);
      expect(
        requireInstalledRuntime(inside.path, configuration: owned),
        inside.resolveSymbolicLinksSync(),
      );
      expect(
        () => requireInstalledRuntime(outside.path, configuration: owned),
        throwsA(isA<RpcError>()),
      );
      // An owner without an installation root never inherits the boundary's.
      installRuntimeConfiguration(owned);
      expect(
        requireInstalledRuntime(
          outside.path,
          configuration: RuntimeConfiguration({}),
        ),
        outside.path,
      );
    });

    test('a launch lease is read from the service snapshot', () {
      final runtime = Directory('${root.path}/run')..createSync();
      final profile = ProfilePaths('${root.path}/data', runtime.path);
      final lease = '${profile.runtime}/startup-fixture.json';
      final owned = RuntimeConfiguration({'FORESIGHT_STARTUP_STATUS': lease});
      installRuntimeConfiguration(RuntimeConfiguration({}));
      expect(serviceLaunchLeaseWithdrawn(profile), isFalse);
      expect(
        serviceLaunchLeaseWithdrawn(profile, configuration: owned),
        isTrue,
      );
      File(lease).writeAsStringSync('{}');
      expect(
        serviceLaunchLeaseWithdrawn(profile, configuration: owned),
        isFalse,
      );
    });

    test('the helper launches the executable of its owner', () async {
      final launched = File('${root.path}/launched');
      final owner = _script(
        root,
        'owner-helper',
        'echo owner >> "${launched.path}"',
      );
      final boundary = _script(
        root,
        'boundary-helper',
        'echo boundary >> "${launched.path}"',
      );
      installRuntimeConfiguration(
        RuntimeConfiguration({'FORESIGHT_HELPER': boundary.path}),
      );
      final runtime = createTestTempDirectorySync('of-rc-helper-');
      final helper = Helper(
        '${runtime.path}/helper.sock',
        '${root.path}/helper-data',
        startupProbeTimeout: const Duration(milliseconds: 50),
        configuration: RuntimeConfiguration({'FORESIGHT_HELPER': owner.path}),
      );
      addTearDown(helper.close);
      final startup = helper.start();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!launched.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await helper.close();
      await startup.timeout(const Duration(seconds: 10));
      expect(launched.readAsLinesSync().toSet(), {'owner'});
    });

    test('a domain keeps one snapshot for all of its ports', () async {
      final store = Store('${root.path}/application.db');
      final helper = Helper(
        '${root.path}/helper.sock',
        '${root.path}/helper-data',
        manageProcess: false,
      );
      final owned = RuntimeConfiguration({
        'FORESIGHT_NATIVE': '/owner/native.so',
      });
      final domain = Domain(store, helper, configuration: owned);
      final direct = Domain(store, helper);
      final boundary = runtimeConfiguration;
      addTearDown(() async {
        domain.close();
        direct.close();
        await helper.close();
        store.close();
      });
      installRuntimeConfiguration(
        RuntimeConfiguration({'FORESIGHT_NATIVE': '/later/native.so'}),
      );
      for (final RuntimeConfigurationPort port in <RuntimeConfigurationPort>[
        domain,
        domain as RecordingWorkspace,
        domain as ModelWorkspace,
      ]) {
        expect(identical(port.configuration, owned), isTrue);
      }
      expect(domain.configuration.nativeLibrary, '/owner/native.so');
      // Direct construction captures the boundary once, not on each read.
      expect(identical(direct.configuration, boundary), isTrue);
    });
  });
}
