import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/src/application_service.dart';
import 'package:foresight_core/src/application_services/model_asset_acquisition.dart';
import 'package:foresight_core/src/application_services/service_runtime_ports.dart';
import 'package:foresight_core/src/audio_devices.dart';
import 'package:foresight_core/src/dedicated_query_terms.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/runtime_execution_policy.dart';
import 'package:foresight_core/src/service_idle_shutdown.dart';
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
      bootstrapSqlSupportFixture();
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
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('runtime-configuration-');
    final previous = runtimeConfiguration;
    addTearDown(() => installRuntimeConfiguration(previous));
  });

  group('profile native selection', () {
    Future<Map<String, Object?>> run({
      bool explicit = false,
      bool scoped = true,
      bool service = false,
    }) {
      final directory = root.path;
      final nativeLibrary = Platform.environment['FORESIGHT_NATIVE_LIBRARY']!;
      return Isolate.run(
        () => _nativeProfileSelection(
          directory,
          nativeLibrary,
          explicit: explicit,
          scoped: scoped,
          service: service,
        ),
      );
    }

    test('explicit snapshot wins over a missing legacy library', () async {
      final result = await run(explicit: true);
      expect(result['ok'], isTrue);
      expect(result['legacyDefaults'], isNull);
      expect(result['ownerUnchanged'], isTrue);
    });

    test(
      'scope selects native resources and preserves legacy defaults',
      () async {
        final result = await run();
        expect(result['ok'], isTrue);
        expect(result['legacyDefaults'], '${root.path}/data/cache/litert');
        expect(result['ownerUnchanged'], isTrue);
      },
    );

    test('default service uses its scoped native library', () async {
      final result = await run(service: true);
      expect(result['ok'], isTrue);
      expect(result['legacyDefaults'], '${root.path}/data/cache/litert');
    });

    test('without a scope a missing legacy library still fails', () async {
      final result = await run(scoped: false);
      expect(result['ok'], isFalse);
      expect(result['missingLegacyLibrary'], isTrue);
    });
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

    test('the legacy boundary stays editable; its snapshots do not', () {
      final installed = RuntimeConfiguration({'FORESIGHT_X': 'a'});
      installRuntimeConfiguration(installed);
      final captured = runtimeSnapshot();
      // Legacy callers keep editing the boundary in place.
      runtimeConfiguration.environment['FORESIGHT_X'] = 'b';
      runtimeConfiguration.environment['FORESIGHT_Y'] = 'y';
      expect(runtimeConfiguration['FORESIGHT_X'], 'b');
      expect(runtimeConfiguration.isSnapshot, isFalse);
      // Neither the installed snapshot nor a capture observes those edits.
      expect(installed.environment, {'FORESIGHT_X': 'a'});
      expect(captured.isSnapshot, isTrue);
      expect(captured.environment, {'FORESIGHT_X': 'a'});
      expect(
        () => captured.environment['FORESIGHT_X'] = 'c',
        throwsUnsupportedError,
      );
      expect(identical(captured.snapshot(), captured), isTrue);
      expect(identical(runtimeSnapshot(captured), captured), isTrue);
      // Derivations from the boundary are immutable copies too.
      final derived = runtimeConfiguration.withDefaults({'FORESIGHT_X': 'z'});
      expect(derived.isSnapshot, isTrue);
      expect(() => derived.environment.clear(), throwsUnsupportedError);
      expect(
        runtimeConfiguration.withOverrides({}).environment,
        isNot(same(runtimeConfiguration.environment)),
      );
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
      final (previous, environment, bundle, rejected, kept) = await Isolate.run(
        () {
          // A fresh isolate has no installed boundary; installing one must
          // not resolve the process environment first.
          final previous = installRuntimeConfiguration(snapshot);
          final environment = Map.of(runtimeConfiguration.environment);
          // The isolate's legacy boundary is an editable copy; the
          // transported snapshot itself still rejects writes.
          runtimeConfiguration.environment['FORESIGHT_HELPER'] = '/x';
          var rejected = false;
          try {
            snapshot.environment['FORESIGHT_HELPER'] = '/x';
          } on UnsupportedError {
            rejected = true;
          }
          return (
            previous,
            environment,
            runtimeConfiguration.linuxBundleRoot,
            rejected,
            Map.of(snapshot.environment),
          );
        },
      );
      expect(previous, isNull);
      expect(environment, snapshot.environment);
      expect(bundle, '/bundle');
      expect(rejected, isTrue);
      expect(kept, snapshot.environment);
    });

    test(
      'a worker receives the values captured before boundary edits',
      () async {
        installRuntimeConfiguration(
          RuntimeConfiguration({'FORESIGHT_HELPER': '/bundle/helper'}),
        );
        final captured = runtimeSnapshot();
        runtimeConfiguration.environment['FORESIGHT_HELPER'] = '/edited/helper';
        runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
        final (seen, rejected) = await Isolate.run(() {
          installRuntimeConfiguration(captured);
          var rejected = false;
          try {
            captured.environment.remove('FORESIGHT_HELPER');
          } on UnsupportedError {
            rejected = true;
          }
          return (runtimeConfiguration['FORESIGHT_HELPER'], rejected);
        });
        expect(seen, '/bundle/helper');
        expect(rejected, isTrue);
        expect(runtimeConfiguration['FORESIGHT_HELPER'], isNull);
      },
    );

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
      expect(configuration.isSnapshot, isTrue);
      final handoff = {'FORESIGHT_X': 'x'};
      installServiceWorkerEnvironment(handoff);
      handoff['FORESIGHT_X'] = 'changed';
      expect(runtimeConfiguration.environment, configuration.environment);
      // As before, the worker boundary is an editable copy of the handoff.
      expect(runtimeConfiguration.isSnapshot, isFalse);
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
      // Passing the editable boundary itself freezes it at construction.
      final captured = Parser(macOS: true, configuration: runtimeConfiguration);
      // A legacy direct construction keeps reading the boundary, as before.
      final legacy = Parser(macOS: true);
      runtimeConfiguration.environment['FORESIGHT_FILE_PARSER'] = owner.path;
      final (capturedText, _) = await captured.extract(document.path);
      expect(capturedText.trim(), 'boundary text');
      final (legacyText, _) = await legacy.extract(document.path);
      expect(legacyText.trim(), 'owner text');
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

    test('the helper launches the executable it captured', () async {
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
        RuntimeConfiguration({'FORESIGHT_HELPER': owner.path}),
      );
      final runtime = createTestTempDirectorySync('of-rc-helper-');
      // Even the editable boundary object itself is frozen on capture.
      final helper = Helper(
        '${runtime.path}/helper.sock',
        '${root.path}/helper-data',
        startupProbeTimeout: const Duration(milliseconds: 50),
        configuration: runtimeConfiguration,
      );
      addTearDown(helper.close);
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = boundary.path;
      expect(helper.configuration.isSnapshot, isTrue);
      expect(
        () => helper.configuration.environment['FORESIGHT_HELPER'] = '/x',
        throwsUnsupportedError,
      );
      final startup = helper.start();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!launched.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await helper.close();
      await startup.timeout(const Duration(seconds: 10));
      expect(launched.readAsLinesSync().toSet(), {'owner'});
    });

    test('a domain keeps its injected snapshot for all ports', () async {
      final store = Store('${root.path}/application.db');
      final helper = Helper(
        '${root.path}/helper.sock',
        '${root.path}/helper-data',
        manageProcess: false,
      );
      final owned = RuntimeConfiguration({
        'FORESIGHT_NATIVE': '/owner/native.so',
      });
      installRuntimeConfiguration(
        RuntimeConfiguration({'FORESIGHT_NATIVE': '/boundary/native.so'}),
      );
      final domain = Domain(store, helper, configuration: owned);
      final legacy = Domain(store, helper);
      final explicitBoundary = Domain(
        store,
        helper,
        configuration: runtimeConfiguration,
      );
      addTearDown(() async {
        domain.close();
        legacy.close();
        explicitBoundary.close();
        await helper.close();
        store.close();
      });
      final before = legacy.configuration;
      // Legacy fixture edits after capture reach no injected owner.
      runtimeConfiguration.environment['FORESIGHT_NATIVE'] = '/later/native.so';
      for (final RuntimeConfigurationPort port in <RuntimeConfigurationPort>[
        domain,
        domain as RecordingWorkspace,
        domain as ModelWorkspace,
      ]) {
        expect(identical(port.configuration, owned), isTrue);
      }
      expect(domain.configuration.nativeLibrary, '/owner/native.so');
      expect(
        explicitBoundary.configuration.nativeLibrary,
        '/boundary/native.so',
      );
      // A legacy direct construction follows the boundary, but every value
      // it hands out is an immutable snapshot that later edits cannot change.
      expect(legacy.configuration.nativeLibrary, '/later/native.so');
      expect(before.nativeLibrary, '/boundary/native.so');
      for (final snapshot in [
        domain.configuration,
        explicitBoundary.configuration,
        legacy.configuration,
        before,
      ]) {
        expect(snapshot.isSnapshot, isTrue);
        expect(
          () => snapshot.environment['FORESIGHT_NATIVE'] = '/x',
          throwsUnsupportedError,
        );
      }
      // Application-owned children read their owner's snapshot.
      final coordinator = ModelAssetAcquisitionCoordinator(
        store: store,
        changed: () {},
        ownerConfiguration: () => domain.configuration,
      );
      expect(identical(coordinator.configuration, owned), isTrue);
      expect(
        ModelAssetAcquisitionCoordinator(
          store: store,
          changed: () {},
          configuration: runtimeConfiguration,
          ownerConfiguration: () => domain.configuration,
        ).configuration.environment,
        {'FORESIGHT_NATIVE': '/later/native.so'},
      );
    });
  });

  group('owner scope', () {
    test('binds an immutable snapshot without touching the boundary', () {
      installRuntimeConfiguration(RuntimeConfiguration({'FORESIGHT_X': 'a'}));
      final boundary = runtimeConfiguration;
      expect(currentOwnerRuntimeSnapshot, isNull);
      final bound = runWithRuntimeConfiguration(boundary, () {
        // The editable boundary itself is frozen when bound.
        boundary.environment['FORESIGHT_X'] = 'edited';
        final bound = currentOwnerRuntimeSnapshot!;
        expect(identical(runtimeSnapshot(), bound), isTrue);
        expect(() => bound.environment.clear(), throwsUnsupportedError);
        return bound;
      });
      expect(bound.isSnapshot, isTrue);
      expect(bound.environment, {'FORESIGHT_X': 'a'});
      expect(currentOwnerRuntimeSnapshot, isNull);
      expect(identical(runtimeConfiguration, boundary), isTrue);
      expect(boundary.isSnapshot, isFalse);
      expect(boundary.environment, {'FORESIGHT_X': 'edited'});
    });

    test(
      'nested and concurrent scopes do not contaminate each other',
      () async {
        final outer = RuntimeConfiguration({'FORESIGHT_X': 'outer'});
        final inner = RuntimeConfiguration({'FORESIGHT_X': 'inner'});
        runWithRuntimeConfiguration(outer, () {
          expect(currentOwnerRuntimeSnapshot!['FORESIGHT_X'], 'outer');
          runWithRuntimeConfiguration(inner, () {
            expect(currentOwnerRuntimeSnapshot!['FORESIGHT_X'], 'inner');
          });
          expect(currentOwnerRuntimeSnapshot!['FORESIGHT_X'], 'outer');
        });
        final gate = Completer<void>();
        Future<List<String?>> observe(RuntimeConfiguration configuration) =>
            runWithRuntimeConfiguration(configuration, () async {
              final seen = [currentOwnerRuntimeSnapshot!['FORESIGHT_X']];
              await gate.future;
              seen.add(currentOwnerRuntimeSnapshot!['FORESIGHT_X']);
              final helper = Helper(
                '${root.path}/${configuration['FORESIGHT_X']}.sock',
                '${root.path}/helper-data',
                manageProcess: false,
              );
              seen.add(helper.configuration['FORESIGHT_X']);
              await helper.close();
              return seen;
            });
        final first = observe(outer), second = observe(inner);
        gate.complete();
        expect(await first, ['outer', 'outer', 'outer']);
        expect(await second, ['inner', 'inner', 'inner']);
        expect(currentOwnerRuntimeSnapshot, isNull);
      },
    );

    test(
      'owners built in scope keep it after exit and boundary edits',
      () async {
        installRuntimeConfiguration(
          RuntimeConfiguration({'FORESIGHT_NATIVE': '/boundary/native.so'}),
        );
        final scope = RuntimeConfiguration({
          'FORESIGHT_NATIVE': '/scope/native.so',
        });
        final store = Store('${root.path}/application.db');
        final legacyHelper = Helper(
          '${root.path}/legacy.sock',
          '${root.path}/helper-data',
          manageProcess: false,
        );
        final (
          domain,
          helper,
          guard,
          coordinator,
          legacySeen,
        ) = runWithRuntimeConfiguration(scope, () {
          final helper = Helper(
            '${root.path}/helper.sock',
            '${root.path}/helper-data',
            manageProcess: false,
          );
          final domain = Domain(store, helper);
          return (
            domain,
            helper,
            ServiceIdleShutdownGuard(
              helper: helper,
              recording: () => false,
              operationsBusy: () => false,
              backgroundBusy: () => false,
            ),
            ModelAssetAcquisitionCoordinator(store: store, changed: () {}),
            // A legacy owner built outside the scope is not redirected.
            legacyHelper.configuration.nativeLibrary,
          );
        });
        addTearDown(() async {
          domain.close();
          await helper.close();
          await legacyHelper.close();
          store.close();
        });
        expect(legacySeen, '/boundary/native.so');
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] =
            '/later/native.so';
        for (final configuration in [
          domain.configuration,
          (domain as RecordingWorkspace).configuration,
          helper.configuration,
          guard.configuration,
          coordinator.configuration,
        ]) {
          expect(configuration.isSnapshot, isTrue);
          expect(configuration.nativeLibrary, '/scope/native.so');
          expect(
            () => configuration.environment['FORESIGHT_NATIVE'] = '/x',
            throwsUnsupportedError,
          );
        }
        expect(identical(domain.configuration, domain.configuration), isTrue);
        // Outside the scope a legacy owner still reads the boundary at use.
        expect(legacyHelper.configuration.nativeLibrary, '/later/native.so');
        expect(scope.environment, {'FORESIGHT_NATIVE': '/scope/native.so'});
      },
    );

    test('a service started in scope captures once and keeps it', () async {
      // An editable copy of this isolate's boundary plus a probe entry.
      installRuntimeConfiguration(
        runtimeConfiguration.withOverrides({'FORESIGHT_RC_PROBE': 'boundary'}),
      );
      final boundary = runtimeConfiguration;
      final scope = runtimeSnapshot().withOverrides({
        'FORESIGHT_RC_PROBE': 'scope',
      });
      final profile = ProfilePaths('${root.path}/profile', '${root.path}/run');
      final service = await runWithRuntimeConfiguration(
        scope,
        () => ApplicationService.start(
          profile,
          desktopPeerVerifier: (_) => false,
        ),
      );
      addTearDown(service.close);
      expect(identical(runtimeConfiguration, boundary), isTrue);
      expect(boundary['FORESIGHT_RC_PROBE'], 'boundary');
      boundary.environment['FORESIGHT_RC_PROBE'] = 'later';
      final owned = service.domain.configuration;
      expect(owned.isSnapshot, isTrue);
      expect(owned['FORESIGHT_RC_PROBE'], 'scope');
      expect(identical(service.domain.configuration, owned), isTrue);
      expect(identical(service.domain.helper.configuration, owned), isTrue);
      expect(
        () => owned.environment['FORESIGHT_RC_PROBE'] = '/x',
        throwsUnsupportedError,
      );
    });

    test('a worker scope uses the worker boundary derivation', () {
      final handoff = {'FORESIGHT_X': 'x'};
      installServiceWorkerEnvironment(handoff);
      final bound = runWithRuntimeConfiguration(
        RuntimeConfiguration.serviceWorker(handoff),
        () => currentOwnerRuntimeSnapshot!,
      );
      expect(bound.environment, runtimeConfiguration.environment);
      expect(bound.linuxBundleRoot, runtimeConfiguration.linuxBundleRoot);
      expect(runtimeConfiguration.isSnapshot, isFalse);
      handoff['FORESIGHT_X'] = 'changed';
      expect(bound.environment, {'FORESIGHT_X': 'x'});
    });
  });
}
