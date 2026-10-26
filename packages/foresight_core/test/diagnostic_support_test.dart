import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:foresight_core/desktop.dart' as desktop;
import 'package:foresight_core/desktop_bootstrap.dart' as bootstrap;
import 'package:foresight_core/src/diagnostic_support.dart';
import 'package:foresight_core/src/diagnostic_support_local.dart';
import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void _chmod(String mode, String path) {
  final result = Process.runSync('/bin/chmod', [mode, path]);
  expect(result.exitCode, 0, reason: 'chmod $mode');
}

/// A private profile directory resolved like ProfilePaths.resolve does.
Directory _profile(String prefix) {
  final directory = Directory(
    canonicalProfilePath(createTestTempDirectorySync(prefix).path),
  );
  _chmod('700', directory.path);
  return directory;
}

Directory _privateLogs(Directory profile) {
  final logs = Directory('${profile.path}/logs')..createSync();
  _chmod('700', logs.path);
  return logs;
}

final class _Opener {
  final uris = <Uri>[];
  Completer<void>? hold;
  Object? failure;
  Future<void> call(Uri uri) async {
    uris.add(uri);
    await hold?.future;
    final error = failure;
    if (error != null) throw error;
  }
}

final class _FailingSink implements DiagnosticSink {
  @override
  int get slot => 4;
  @override
  bool get failed => true;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) => true;
  @override
  bool append(Uint8List bytes) => false;
  @override
  void close() {}
}

DiagnosticSink? _failingSink(
  String profile,
  DiagnosticIdentity session,
  DiagnosticRole role,
) => _FailingSink();

final class _HealthySink implements DiagnosticSink {
  @override
  int get slot => 4;
  @override
  bool get failed => false;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) => true;
  @override
  bool append(Uint8List bytes) => true;
  @override
  void close() {}
}

DiagnosticSink? _healthySink(
  String profile,
  DiagnosticIdentity session,
  DiagnosticRole role,
) => _HealthySink();

DiagnosticSink? _noSlot(
  String profile,
  DiagnosticIdentity session,
  DiagnosticRole role,
) => null;

Set<String> _closure(File entry) {
  final visited = <String>{}, pending = [entry];
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    if (!visited.add(file.absolute.path)) continue;
    final unit = parseString(content: file.readAsStringSync()).unit;
    for (final directive in unit.directives.whereType<UriBasedDirective>()) {
      final uri = directive.uri.stringValue ?? '';
      if (uri.contains(':')) {
        visited.add(uri);
      } else {
        pending.add(File.fromUri(file.uri.resolve(uri)));
      }
    }
  }
  return visited;
}

Iterable<String> _exports(String path) =>
    parseString(content: File(path).readAsStringSync()).unit.directives
        .whereType<ExportDirective>()
        .map((directive) => directive.uri.stringValue ?? '');

void main() {
  group('unavailable default', () {
    test('reports unavailable and performs no effect', () async {
      const support = UnavailableDiagnosticSupport();
      final snapshot = support.snapshot();
      expect(snapshot.status, DiagnosticSupportStatus.unavailable);
      expect(snapshot.reason, DiagnosticSupportReason.unavailable);
      expect(snapshot.logsFolderKnown, isFalse);
      expect(
        await support.openLogsFolder(),
        DiagnosticFolderOpenResult.unavailable,
      );
    });

    test('an adapter without session or profile stays unavailable', () async {
      final opener = _Opener();
      final support = LocalDiagnosticSupport(openUri: opener.call);
      expect(support.snapshot().status, DiagnosticSupportStatus.unavailable);
      expect(
        await support.openLogsFolder(),
        DiagnosticFolderOpenResult.unavailable,
      );
      expect(opener.uris, isEmpty);
    });
  });

  group('logs folder', () {
    late _Opener opener;
    late LocalDiagnosticSupport support;
    setUp(() {
      opener = _Opener();
      support = LocalDiagnosticSupport(openUri: opener.call);
    });

    test('reveals the private canonical logs folder only on request', () async {
      final profile = _profile('support-open-');
      final logs = _privateLogs(profile);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      expect(opener.uris, isEmpty);
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.opened);
      expect(opener.uris, [Uri.file(logs.path)]);
    });

    test('a missing folder is reported and not created', () async {
      final profile = _profile('support-missing-');
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      expect(
        await support.openLogsFolder(),
        DiagnosticFolderOpenResult.missing,
      );
      expect(Directory('${profile.path}/logs').existsSync(), isFalse);
      expect(opener.uris, isEmpty);
    });

    test('a missing profile is reported as missing', () async {
      final parent = _profile('support-no-profile-');
      support.selectProfile(
        ProfilePaths('${parent.path}/absent', '${parent.path}/run'),
      );
      expect(
        await support.openLogsFolder(),
        DiagnosticFolderOpenResult.missing,
      );
      expect(Directory('${parent.path}/absent').existsSync(), isFalse);
      expect(opener.uris, isEmpty);
    });

    test('a symbolic link in place of the logs folder is refused', () async {
      final profile = _profile('support-link-');
      final elsewhere = _privateLogs(_profile('support-link-target-'));
      Link('${profile.path}/logs').createSync(elsewhere.path);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.unsafe);
      expect(opener.uris, isEmpty);
    });

    test('a profile replaced by a link after selection is refused', () async {
      final profile = _profile('support-swap-');
      _privateLogs(profile);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      final target = _profile('support-swap-target-');
      _privateLogs(target);
      profile.renameSync('${profile.path}-moved');
      Link(profile.path).createSync(target.path);
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.unsafe);
      expect(opener.uris, isEmpty);
    });

    test('a profile ancestor replaced by a link is refused', () async {
      final parent = _profile('support-ancestor-');
      final profile = Directory('${parent.path}/profile')..createSync();
      _chmod('700', profile.path);
      _privateLogs(profile);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      final target = _profile('support-ancestor-target-');
      _privateLogs(Directory('${target.path}/profile')..createSync());
      _chmod('700', '${target.path}/profile');
      parent.renameSync('${parent.path}-moved');
      Link(parent.path).createSync(target.path);
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.unsafe);
      expect(opener.uris, isEmpty);
    });

    test('an aliased profile path opens its canonical folder', () async {
      final profile = _profile('support-alias-');
      final logs = _privateLogs(profile);
      final alias = Link('${_profile('support-alias-link-').path}/profile')
        ..createSync(profile.path);
      support.selectProfile(ProfilePaths(alias.path, '${alias.path}/run'));
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.opened);
      expect(opener.uris, [Uri.file(logs.path)]);
    });

    test('a regular file in place of the folder is refused', () async {
      final profile = _profile('support-file-');
      File('${profile.path}/logs').writeAsStringSync('');
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.unsafe);
      expect(opener.uris, isEmpty);
    });

    for (final mode in ['750', '705', '755']) {
      test('a logs folder with mode $mode is refused', () async {
        final profile = _profile('support-mode-');
        final logs = _privateLogs(profile);
        _chmod(mode, logs.path);
        support.selectProfile(
          ProfilePaths(profile.path, '${profile.path}/run'),
        );
        expect(
          await support.openLogsFolder(),
          DiagnosticFolderOpenResult.unsafe,
        );
        expect(opener.uris, isEmpty);
      });
    }

    for (final mode in ['770', '707']) {
      test('a profile writable through mode $mode is refused', () async {
        final profile = _profile('support-profile-mode-');
        _privateLogs(profile);
        _chmod(mode, profile.path);
        support.selectProfile(
          ProfilePaths(profile.path, '${profile.path}/run'),
        );
        expect(
          await support.openLogsFolder(),
          DiagnosticFolderOpenResult.unsafe,
        );
        expect(opener.uris, isEmpty);
      });
    }

    test('a readable but not writable profile is accepted', () async {
      final profile = _profile('support-profile-readable-');
      _privateLogs(profile);
      _chmod('755', profile.path);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.opened);
    });

    test('opener failures stay closed and can be retried', () async {
      final profile = _profile('support-fail-');
      final logs = _privateLogs(profile);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      opener.failure = StateError('Could not open ${logs.uri}: vendor stderr');
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.failed);
      opener.failure = null;
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.opened);
      expect(opener.uris, hasLength(2));
    });

    test('concurrent requests share one opener invocation', () async {
      final profile = _profile('support-concurrent-');
      _privateLogs(profile);
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      opener.hold = Completer<void>();
      final first = support.openLogsFolder(), second = support.openLogsFolder();
      await eventually(() => opener.uris.isNotEmpty);
      opener.hold!.complete();
      expect(await Future.wait([first, second]), [
        DiagnosticFolderOpenResult.opened,
        DiagnosticFolderOpenResult.opened,
      ]);
      expect(opener.uris, hasLength(1));
      opener.hold = null;
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.opened);
      expect(opener.uris, hasLength(2));
    });

    test('the first profile selection wins', () async {
      final first = _profile('support-first-'), second = _profile('support-2-');
      final logs = _privateLogs(first);
      _privateLogs(second);
      support.selectProfile(ProfilePaths(first.path, '${first.path}/run'));
      support.selectProfile(ProfilePaths(second.path, '${second.path}/run'));
      expect(await support.openLogsFolder(), DiagnosticFolderOpenResult.opened);
      expect(opener.uris, [Uri.file(logs.path)]);
    });
  });

  group('health snapshot', () {
    Future<(LoggingSession, LocalDiagnosticSupport)> start({
      DiagnosticConfiguration configuration = const DiagnosticConfiguration(),
      DiagnosticSinkFactory? sinkFactory,
      String? profile,
    }) async {
      final session = await LoggingSession.startForTesting(
        configuration: configuration,
        profilePath: profile,
        sinkFactory: sinkFactory,
      );
      addTearDown(session.close);
      return (
        session,
        LocalDiagnosticSupport(openUri: _Opener().call)..attachSession(session),
      );
    }

    bool emitError(LoggingSession session) => session.producer.emit(
      DiagnosticEvent.runtimeFailed,
      DiagnosticComponent.logging,
    );

    test('off is a known local off report, also after close', () async {
      final (session, support) = await start(
        configuration: DiagnosticConfiguration.fromEnvironment(const {
          'FORESIGHT_LOG_LEVEL': 'off',
        }),
      );
      var snapshot = support.snapshot();
      expect(snapshot.status, DiagnosticSupportStatus.off);
      expect(snapshot.reason, DiagnosticSupportReason.off);
      expect(snapshot.level, DiagnosticSupportLevel.off);
      expect(snapshot.known, isTrue);
      expect(snapshot.ageMs, 0);
      expect(snapshot.storageConfigured, isFalse);
      expect(snapshot.logsFolderKnown, isFalse);
      await session.close();
      snapshot = support.snapshot();
      expect(snapshot.status, DiagnosticSupportStatus.off);
    });

    test(
      'an unconfigured enabled session is degraded, never healthy',
      () async {
        final profile = _profile('support-unconfigured-');
        final (session, support) = await start(profile: profile.path);
        // The initial session reason is healthy; it alone proves nothing.
        expect(session.health.reason, DiagnosticHealthReason.healthy);
        final snapshot = support.snapshot();
        expect(snapshot.reason, DiagnosticSupportReason.healthy);
        expect(snapshot.storageConfigured, isFalse);
        expect(snapshot.status, DiagnosticSupportStatus.degraded);
        expect(snapshot.slot, isNull);
        expect(snapshot.known, isTrue);
        expect(snapshot.stale, isFalse);
        expect(snapshot.ageMs, 0);
        expect(emitError(session), isTrue);
        await eventually(
          () =>
              support.snapshot().reason ==
              DiagnosticSupportReason.storageWorkerUnconfigured,
        );
        expect(support.snapshot().status, DiagnosticSupportStatus.degraded);
      },
    );

    test('configured storage without an admitted slot is starting', () async {
      final profile = _profile('support-starting-');
      final (session, support) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      final snapshot = support.snapshot();
      expect(snapshot.reason, DiagnosticSupportReason.healthy);
      expect(snapshot.storageConfigured, isTrue);
      expect(snapshot.slot, isNull);
      expect(snapshot.status, DiagnosticSupportStatus.starting);
      // A cold session with no warning, 100 records or five seconds of
      // running time admits no slot and keeps starting.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(support.snapshot().status, DiagnosticSupportStatus.starting);
      expect(support.snapshot().slot, isNull);
      expect(session.health.slot, isNull);
    });

    test('an admitted slot moves starting to healthy', () async {
      final profile = _profile('support-healthy-');
      final (session, support) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      expect(support.snapshot().status, DiagnosticSupportStatus.starting);
      expect(emitError(session), isTrue);
      await eventually(
        () => support.snapshot().status == DiagnosticSupportStatus.healthy,
      );
      final snapshot = support.snapshot();
      expect(snapshot.slot, 4);
      expect(snapshot.reason, DiagnosticSupportReason.healthy);
      expect(snapshot.storageConfigured, isTrue);
    });

    test('configured storage that admits no slot is degraded', () async {
      final profile = _profile('support-no-slot-');
      final (session, support) = await start(
        sinkFactory: _noSlot,
        profile: profile.path,
      );
      expect(support.snapshot().status, DiagnosticSupportStatus.starting);
      expect(emitError(session), isTrue);
      await eventually(
        () => support.snapshot().status == DiagnosticSupportStatus.degraded,
      );
      final snapshot = support.snapshot();
      expect(snapshot.storageConfigured, isTrue);
      expect(snapshot.slot, isNull);
      expect(snapshot.reason, isNot(DiagnosticSupportReason.healthy));
      expect(snapshot.reason, isNot(DiagnosticSupportReason.bootstrapOnly));
    });

    test('a failed sink is degraded with its own reason', () async {
      final profile = _profile('support-sink-');
      final (session, support) = await start(
        sinkFactory: _failingSink,
        profile: profile.path,
      );
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      expect(support.snapshot().logsFolderKnown, isTrue);
      expect(emitError(session), isTrue);
      await eventually(
        () => support.snapshot().status == DiagnosticSupportStatus.degraded,
      );
      final snapshot = support.snapshot();
      expect(snapshot.reason, DiagnosticSupportReason.sinkFailed);
      expect(snapshot.storageConfigured, isTrue);
      expect(snapshot.nativeReason, DiagnosticSupportNativeReason.unconfigured);
    });

    test('native degradation is reported apart from session status', () async {
      final profile = _profile('support-native-');
      final (session, support) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      expect(emitError(session), isTrue);
      await eventually(
        () => support.snapshot().status == DiagnosticSupportStatus.healthy,
      );
      // Injected into the session's own health record, as its native health
      // message would; no native library is loaded by this test.
      session.health
        ..nativeReason = NativeDiagnosticHealth.capacity
        ..nativeDropsExact = false;
      final snapshot = support.snapshot();
      expect(snapshot.status, DiagnosticSupportStatus.healthy);
      expect(snapshot.reason, DiagnosticSupportReason.healthy);
      expect(snapshot.nativeReason, DiagnosticSupportNativeReason.capacity);
      expect(snapshot.nativeDropsExact, isFalse);
    });

    test('close reports closing, then closed', () async {
      final profile = _profile('support-close-');
      final (session, support) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      expect(emitError(session), isTrue);
      await eventually(
        () => support.snapshot().status == DiagnosticSupportStatus.healthy,
      );
      final closing = session.close();
      expect(support.snapshot().status, DiagnosticSupportStatus.closing);
      await closing;
      final snapshot = support.snapshot();
      expect(snapshot.status, DiagnosticSupportStatus.closed);
      expect(snapshot.known, isTrue);
    });

    test('an unconfigured session closes as closed', () async {
      final (session, support) = await start();
      final closing = session.close();
      expect(support.snapshot().status, DiagnosticSupportStatus.closing);
      await closing;
      expect(support.snapshot().status, DiagnosticSupportStatus.closed);
    });

    test('a stale cached report keeps its values but is unknown', () async {
      final profile = _profile('support-stale-');
      final (session, _) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      expect(emitError(session), isTrue);
      await eventually(
        () => session.healthSnapshot.state == DiagnosticHealthState.healthy,
      );
      final report = session.healthSnapshot.toJson();
      final fresh = DiagnosticHealthSnapshot.tryParse({
        ...report,
        'ageMs': DiagnosticHealthSnapshot.staleAfterMs,
      });
      final stale = DiagnosticHealthSnapshot.tryParse({
        ...report,
        'ageMs': DiagnosticHealthSnapshot.staleAfterMs + 1,
        'stale': true,
        'state': DiagnosticHealthState.unknown.name,
      });
      expect(
        LocalDiagnosticSupport.fromHealth(fresh!).status,
        DiagnosticSupportStatus.healthy,
      );
      final snapshot = LocalDiagnosticSupport.fromHealth(stale!);
      expect(snapshot.status, DiagnosticSupportStatus.unknown);
      expect(snapshot.stale, isTrue);
      expect(snapshot.known, isTrue);
      expect(snapshot.ageMs, DiagnosticHealthSnapshot.staleAfterMs + 1);
      expect(snapshot.reason, DiagnosticSupportReason.healthy);
      expect(snapshot.slot, 4);
      expect(snapshot.admitted, report['admittedRecords']);
    });

    test('no report yet is unknown without an age', () {
      final snapshot = LocalDiagnosticSupport.fromHealth(
        const DiagnosticHealthSnapshot(),
      );
      expect(snapshot.status, DiagnosticSupportStatus.unknown);
      expect(snapshot.known, isFalse);
      expect(snapshot.ageMs, isNull);
      expect(snapshot.stale, isFalse);
      expect(snapshot.supportText, contains('age_ms: none'));
      expect(snapshot.supportText, contains('slot: none'));
    });

    test('every state, reason and native reason maps by name', () {
      for (final state in DiagnosticHealthState.values) {
        expect(
          LocalDiagnosticSupport.fromHealth(
            DiagnosticHealthSnapshot(state: state),
          ).status.name,
          state.name,
        );
      }
      for (final reason in DiagnosticHealthReason.values) {
        expect(
          LocalDiagnosticSupport.fromHealth(
            DiagnosticHealthSnapshot(reason: reason),
          ).reason.name,
          reason.name,
        );
      }
      for (final native in NativeDiagnosticHealth.values) {
        expect(
          LocalDiagnosticSupport.fromHealth(
            DiagnosticHealthSnapshot(nativeReason: native),
          ).nativeReason.name,
          native.name,
        );
      }
    });

    test('configuration, counters and slot are copied faithfully', () {
      final snapshot = LocalDiagnosticSupport.fromHealth(
        const DiagnosticHealthSnapshot(
          level: DiagnosticLevel.debug,
          transportTrace: true,
          invalidLevel: true,
          storageConfigured: true,
          known: true,
          ageMs: 7,
          state: DiagnosticHealthState.healthy,
          reason: DiagnosticHealthReason.healthy,
          nativeReason: NativeDiagnosticHealth.healthy,
          nativeDropsExact: true,
          admittedRecords: 1,
          droppedRecords: 2,
          rejectedRecords: 3,
          highWaterBytes: 4,
          highWaterRecords: 5,
          producerRegistrationRefused: 6,
          quarantinedProducers: 7,
          slot: 3,
        ),
        logsFolderKnown: true,
      );
      expect(
        [
          snapshot.level,
          snapshot.transportTrace,
          snapshot.invalidLevel,
          snapshot.storageConfigured,
          snapshot.known,
          snapshot.stale,
          snapshot.ageMs,
          snapshot.nativeReason,
          snapshot.nativeDropsExact,
          snapshot.admitted,
          snapshot.dropped,
          snapshot.rejected,
          snapshot.highWaterBytes,
          snapshot.highWaterRecords,
          snapshot.refusedProducers,
          snapshot.quarantinedProducers,
          snapshot.slot,
          snapshot.logsFolderKnown,
        ],
        [
          DiagnosticSupportLevel.debug,
          true,
          true,
          true,
          true,
          false,
          7,
          DiagnosticSupportNativeReason.healthy,
          true,
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          3,
          true,
        ],
      );
    });

    test('an invalid level and transport trace are reported', () async {
      for (final (environment, level, invalid, trace) in [
        (
          const {'FORESIGHT_LOG_LEVEL': 'loud'},
          DiagnosticSupportLevel.info,
          true,
          false,
        ),
        (
          const {'FORESIGHT_LOG_LEVEL': 'debug'},
          DiagnosticSupportLevel.debug,
          false,
          false,
        ),
        (
          const {'FORESIGHT_SERVICE_TRACE': '1'},
          DiagnosticSupportLevel.info,
          false,
          true,
        ),
      ]) {
        final (_, support) = await start(
          configuration: DiagnosticConfiguration.fromEnvironment(environment),
        );
        final snapshot = support.snapshot();
        expect(snapshot.level, level, reason: '$environment');
        expect(snapshot.invalidLevel, invalid, reason: '$environment');
        expect(snapshot.transportTrace, trace, reason: '$environment');
        expect(snapshot.status, DiagnosticSupportStatus.degraded);
      }
    });

    test('repeated reads allocate or register no producer', () async {
      final profile = _profile('support-reads-');
      final (session, support) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      final producers = session.retainedProducerCount,
          slots = session.retainedSlotCount;
      for (var i = 0; i < 1000; ++i) {
        support.snapshot();
      }
      expect(session.retainedProducerCount, producers);
      expect(session.retainedSlotCount, slots);
    });

    test('support text holds only closed fields', () async {
      final profile = _profile('support-text-');
      final (session, support) = await start(
        sinkFactory: _healthySink,
        profile: profile.path,
      );
      support.selectProfile(ProfilePaths(profile.path, '${profile.path}/run'));
      session.health.admitted = 0x7fffffff + 5;
      final text = support.snapshot().supportText;
      expect(text, isNot(contains('/')));
      expect(text, isNot(contains(profile.path.split('/').last)));
      expect(text, contains('host: desktop'));
      expect(text, contains('status: starting'));
      expect(text, contains('storage_configured: true'));
      expect(text, isNot(contains('supported')));
      expect(text, contains('logs_folder_known: true'));
      expect(text, contains('admitted: ${0x7fffffff}'));
      for (final line in text.split('\n')) {
        expect(line, matches(RegExp(r'^[a-z_]+: [A-Za-z0-9]+$')));
      }
    });

    test('the first attached session wins', () async {
      final first = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.off,
        ),
      );
      final second = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
      );
      addTearDown(first.close);
      addTearDown(second.close);
      final support = LocalDiagnosticSupport(openUri: _Opener().call)
        ..attachSession(first)
        ..attachSession(second);
      expect(support.snapshot().status, DiagnosticSupportStatus.off);
    });
  });

  group('curated boundary', () {
    final package = Directory.current.absolute.path;

    test('the desktop port imports nothing', () {
      final closure = _closure(
        File('$package/lib/src/diagnostic_support.dart'),
      );
      expect(closure, [endsWith('/src/diagnostic_support.dart')]);
    });

    test('each session level maps by name', () async {
      for (final level in DiagnosticLevel.values) {
        final session = await LoggingSession.startForTesting(
          configuration: DiagnosticConfiguration(level: level),
        );
        addTearDown(session.close);
        final snapshot = (LocalDiagnosticSupport(
          openUri: _Opener().call,
        )..attachSession(session)).snapshot();
        expect(snapshot.level.name, level.name);
      }
    });

    test('the adapter has no network, process or write capability', () {
      final source = File(
        '$package/lib/src/diagnostic_support_local.dart',
      ).readAsStringSync();
      for (final token in [
        'HttpClient',
        'Socket',
        'Process',
        'createSync',
        'writeAs',
        'openWrite',
        'delete',
        'rename',
        'session.producer',
        'reserveProducer',
        'session.selectProfile',
        'session.close',
        'create: true',
        '.remove(',
        '.replace(',
        '.publish(',
        '.open(',
        '.health.',
      ]) {
        expect(source, isNot(contains(token)), reason: token);
      }
    });

    test('features get the port; only startup gets the adapter', () {
      expect(
        _exports('$package/lib/desktop.dart'),
        contains('src/diagnostic_support.dart'),
      );
      expect(
        _exports('$package/lib/desktop.dart'),
        isNot(contains('src/diagnostic_support_local.dart')),
      );
      expect(
        _exports('$package/lib/desktop.dart'),
        isNot(contains('src/diagnostics/session.dart')),
      );
      expect(
        _exports('$package/lib/desktop_bootstrap.dart'),
        contains('src/diagnostic_support_local.dart'),
      );
      expect(
        bootstrap.LocalDiagnosticSupport.platform().openUri,
        desktop.openPlatformUri,
      );
      const desktop.DiagnosticSupportPort port =
          desktop.UnavailableDiagnosticSupport();
      final bootstrap.LocalDiagnosticSupport adapter =
          bootstrap.LocalDiagnosticSupport(openUri: (_) async {});
      expect(port, isA<desktop.DiagnosticSupportPort>());
      expect(adapter, isA<desktop.DiagnosticSupportPort>());
    });
  });
}
