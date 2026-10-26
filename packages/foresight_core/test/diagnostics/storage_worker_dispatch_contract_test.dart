import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_native.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_protocol.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const _build =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _canary = 'private-fixture-error-must-not-cross-control';
final _session = DiagnosticIdentity.parse('0123456789abcdef0123456789abcdef')!;
final _empty = Uint8List(0);

final class _Sink implements DiagnosticSink {
  @override
  int get slot => 4;
  @override
  bool failed = false;
  bool contend = false;
  int closes = 0;
  final classifications = <DiagnosticRole>[];
  final records = <Uint8List>[];
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) {
    classifications.add(role);
    return !contend && !failed;
  }

  @override
  bool append(Uint8List record) {
    records.add(Uint8List.fromList(record));
    return !failed;
  }

  @override
  void close() => ++closes;
}

DiagnosticStorageWorkerState _state(
  DiagnosticSinkFactory factory, {
  int? parentPid,
  String buildId = _build,
}) => DiagnosticStorageWorkerState.forTesting(
  parentPid: parentPid ?? pid,
  buildId: buildId,
  factory: factory,
);
DiagnosticWorkerReply _init(DiagnosticStorageWorkerState state) => state.handle(
  DiagnosticWorkerFrame.init,
  DiagnosticWorkerInit(
    profile: '/private/controlled-profile',
    session: _session,
    role: DiagnosticRole.candidate,
  ).encode(),
);
DiagnosticWorkerReply _classify(
  DiagnosticStorageWorkerState state,
  DiagnosticRole role,
) => state.handle(
  DiagnosticWorkerFrame.classify,
  DiagnosticWorkerClassification(
    role,
    error: false,
    genuineFailure: false,
  ).encode(),
);
void _closedReply(
  DiagnosticWorkerReply reply,
  DiagnosticWorkerResult result,
  DiagnosticHealthReason reason,
) {
  expect(reply.result, result);
  expect(reply.reason, reason);
  final bytes = reply.encode();
  expect(bytes, hasLength(4));
  expect(DiagnosticWorkerReply.decode(bytes).reason, reason);
  expect(String.fromCharCodes(bytes), isNot(contains(_canary)));
}

Uint8List _record() => Uint8List.fromList(
  utf8.encode(
    '${jsonEncode({'schema': 2, 'timestamp': '2026-10-26T00:00:00.000Z', 'sequence': 1, 'level': 'info', 'version': '0.1.3', 'revision': 'unknown', 'session': _session.value, 'pid': pid, 'producer': 'entrypoint:0:1', 'build_id': _build, 'event': DiagnosticEvent.serviceReady.wire, 'component': 'service', 'fields': <String, Object?>{}})}\n',
  ),
);

void main() {
  test(
    'uninitialized and repeated INIT cannot acquire or replace file authority',
    () {
      var admissions = 0;
      final state = _state((_, _, _) {
        admissions++;
        return _Sink();
      });
      _closedReply(
        state.handle(DiagnosticWorkerFrame.admit, _empty),
        DiagnosticWorkerResult.disabled,
        DiagnosticHealthReason.writerFailed,
      );
      _closedReply(
        _init(state),
        DiagnosticWorkerResult.disabled,
        DiagnosticHealthReason.writerFailed,
      );
      expect(admissions, 0);
      _closedReply(
        state.handle(DiagnosticWorkerFrame.retire, _empty),
        DiagnosticWorkerResult.ok,
        DiagnosticHealthReason.closed,
      );
      expect(state.retired, isTrue);
      expect(
        () => state.handle(DiagnosticWorkerFrame.health, _empty),
        throwsFormatException,
      );

      final repeated = _state((_, _, _) {
        admissions++;
        return _Sink();
      });
      expect(_init(repeated).result, DiagnosticWorkerResult.ok);
      _closedReply(
        _init(repeated),
        DiagnosticWorkerResult.disabled,
        DiagnosticHealthReason.writerFailed,
      );
      expect(
        repeated.handle(DiagnosticWorkerFrame.admit, _empty).result,
        DiagnosticWorkerResult.disabled,
      );
      expect(admissions, 0);
      repeated.handle(DiagnosticWorkerFrame.retire, _empty);
    },
  );

  test(
    'invalid parent or build identity refuses admission before the factory',
    () {
      var admissions = 0;
      for (final arguments in [
        (1, _build),
        (0x80000000, _build),
        (pid, 'A' * 64),
      ]) {
        final state = _state(
          (_, _, _) {
            admissions++;
            return _Sink();
          },
          parentPid: arguments.$1,
          buildId: arguments.$2,
        );
        _closedReply(
          _init(state),
          DiagnosticWorkerResult.disabled,
          DiagnosticHealthReason.writerFailed,
        );
        expect(
          state.handle(DiagnosticWorkerFrame.admit, _empty).result,
          DiagnosticWorkerResult.disabled,
        );
        state.handle(DiagnosticWorkerFrame.retire, _empty);
      }
      expect(admissions, 0);
    },
  );

  test(
    'factory failures remain closed retries and a later admission persists',
    () {
      final sink = _Sink();
      var attempts = 0;
      final state = _state((profile, identity, role) {
        expect(profile, '/private/controlled-profile');
        expect(identity.value, _session.value);
        expect(role, DiagnosticRole.candidate);
        switch (++attempts) {
          case 1:
            throw const DiagnosticStorageUnavailable(
              DiagnosticHealthReason.unsupportedFilesystem,
            );
          case 2:
            throw StateError(_canary);
          case 3:
            return null;
          default:
            return sink;
        }
      });
      expect(_init(state).result, DiagnosticWorkerResult.ok);
      _closedReply(
        state.handle(DiagnosticWorkerFrame.admit, _empty),
        DiagnosticWorkerResult.retry,
        DiagnosticHealthReason.unsupportedFilesystem,
      );
      _closedReply(
        state.handle(DiagnosticWorkerFrame.admit, _empty),
        DiagnosticWorkerResult.retry,
        DiagnosticHealthReason.storageUnavailable,
      );
      _closedReply(
        state.handle(DiagnosticWorkerFrame.admit, _empty),
        DiagnosticWorkerResult.retry,
        DiagnosticHealthReason.storageUnavailable,
      );
      _closedReply(
        state.handle(DiagnosticWorkerFrame.admit, _empty),
        DiagnosticWorkerResult.ok,
        DiagnosticHealthReason.healthy,
      );
      expect(
        _classify(state, DiagnosticRole.service).result,
        DiagnosticWorkerResult.ok,
      );
      expect(
        state.handle(DiagnosticWorkerFrame.append, _record()).result,
        DiagnosticWorkerResult.ok,
      );
      expect(sink.classifications, [DiagnosticRole.service]);
      expect(sink.records, hasLength(1));
      expect(jsonDecode(utf8.decode(sink.records.single))['sequence'], 1);
      expect(attempts, 4);
      state.handle(DiagnosticWorkerFrame.retire, _empty);
      expect(sink.closes, 1);
    },
  );

  test('admission has one owner and cannot allocate a second sink', () {
    final sink = _Sink();
    var admissions = 0;
    final state = _state((_, _, _) {
      admissions++;
      return sink;
    });
    _init(state);
    expect(
      state.handle(DiagnosticWorkerFrame.admit, _empty).result,
      DiagnosticWorkerResult.ok,
    );
    _closedReply(
      state.handle(DiagnosticWorkerFrame.admit, _empty),
      DiagnosticWorkerResult.disabled,
      DiagnosticHealthReason.writerFailed,
    );
    expect(admissions, 1);
    expect(sink.records, isEmpty);
    state.handle(DiagnosticWorkerFrame.retire, _empty);
    expect(sink.closes, 1);
  });

  test(
    'retry exhaustion is sticky and never calls the factory a sixth time',
    () {
      var attempts = 0;
      final state = _state((_, _, _) {
        attempts++;
        throw const DiagnosticStorageUnavailable(
          DiagnosticHealthReason.unsupportedFilesystem,
        );
      });
      _init(state);
      for (var attempt = 1; attempt <= 5; ++attempt) {
        _closedReply(
          state.handle(DiagnosticWorkerFrame.admit, _empty),
          attempt == 5
              ? DiagnosticWorkerResult.disabled
              : DiagnosticWorkerResult.retry,
          DiagnosticHealthReason.unsupportedFilesystem,
        );
      }
      _closedReply(
        state.handle(DiagnosticWorkerFrame.admit, _empty),
        DiagnosticWorkerResult.disabled,
        DiagnosticHealthReason.unsupportedFilesystem,
      );
      expect(attempts, 5);
      _closedReply(
        state.handle(DiagnosticWorkerFrame.retire, _empty),
        DiagnosticWorkerResult.ok,
        DiagnosticHealthReason.closed,
      );
    },
  );

  test(
    'classification cannot upgrade a candidate into another client role',
    () {
      for (final role in [DiagnosticRole.desktop, DiagnosticRole.mcp]) {
        final sink = _Sink();
        final state = _state((_, _, _) => sink);
        _init(state);
        state.handle(DiagnosticWorkerFrame.admit, _empty);
        _closedReply(
          _classify(state, role),
          DiagnosticWorkerResult.disabled,
          DiagnosticHealthReason.writerFailed,
        );
        expect(sink.classifications, isEmpty);
        expect(
          state.handle(DiagnosticWorkerFrame.append, _record()).result,
          DiagnosticWorkerResult.disabled,
        );
        expect(sink.records, isEmpty);
        state.handle(DiagnosticWorkerFrame.retire, _empty);
        expect(sink.closes, 1);
      }
    },
  );

  test(
    'contention never consumes a record and sink failure disables persistence',
    () {
      final sink = _Sink()..contend = true;
      final state = _state((_, _, _) => sink);
      _init(state);
      state.handle(DiagnosticWorkerFrame.admit, _empty);
      expect(
        _classify(state, DiagnosticRole.service).result,
        DiagnosticWorkerResult.retry,
      );
      expect(
        state.handle(DiagnosticWorkerFrame.append, _record()).result,
        DiagnosticWorkerResult.retry,
      );
      expect(sink.records, isEmpty);
      sink.contend = false;
      expect(
        _classify(state, DiagnosticRole.service).result,
        DiagnosticWorkerResult.ok,
      );
      expect(
        state.handle(DiagnosticWorkerFrame.append, _record()).result,
        DiagnosticWorkerResult.ok,
      );
      expect(sink.records, hasLength(1));
      sink.failed = true;
      _closedReply(
        _classify(state, DiagnosticRole.service),
        DiagnosticWorkerResult.disabled,
        DiagnosticHealthReason.sinkFailed,
      );
      expect(
        state.handle(DiagnosticWorkerFrame.append, _record()).result,
        DiagnosticWorkerResult.disabled,
      );
      expect(sink.records, hasLength(1));
      state.handle(DiagnosticWorkerFrame.retire, _empty);
      expect(sink.closes, 1);
    },
  );

  for (final mode in ['prepare', 'ack-exit']) {
    test(
      'native prepare bridge $mode joins actual writer and owner isolates',
      () async {
        final root = createTestTempDirectorySync('bridge-');
        final library =
            '${root.path}/owner.${Platform.isMacOS ? 'dylib' : 'so'}';
        await buildCachedNativeFixture(
          source: 'test/fixtures/diagnostics_owner_ffi.cpp',
          output: library,
        );
        final image = DynamicLibrary.open(library);
        final functions = DiagnosticNativeFunctions.fromImage(image);
        final spawnCalls = image
            .lookupFunction<Int32 Function(), int Function()>(
              'fs_diag_fixture_spawn_calls',
            );
        final appendCalls = image
            .lookupFunction<Int32 Function(), int Function()>(
              'fs_diag_fixture_append_calls',
            );
        final control = '${root.path}/barrier';
        final release = File('$control.release');
        NativeDiagnosticWorkerOwner? owner;
        DiagnosticStorageLaunchContext? launch;
        final logging = await LoggingSession.startForTesting(
          configuration: const DiagnosticConfiguration(),
          profilePath: '${root.path}/profile',
          workerFactory: (context) {
            launch = context;
            return owner = NativeDiagnosticWorkerOwner(
              context,
              functions,
              resolveCommand: () => DiagnosticStorageCommand(
                nativeId: _build,
                dartId: _build,
                catalogId: _build,
                arguments: [
                  '/fixture-launcher',
                  _build,
                  '$pid',
                  '/fixture-worker',
                  control,
                  mode,
                ],
              ),
            );
          },
        );
        addTearDown(() async {
          release.writeAsStringSync('release');
          await logging.close();
          if (launch != null) {
            await launch!.writerExited.timeout(const Duration(seconds: 5));
          }
          if (owner != null) {
            await eventually(
              () => owner!.snapshot.parentSettled,
              timeout: const Duration(seconds: 5),
            );
          }
        });
        expect(
          logging.producer.emit(
            DiagnosticEvent.runtimeFailed,
            DiagnosticComponent.logging,
          ),
          isTrue,
        );
        if (mode == 'prepare') {
          await eventually(
            () => File('$control.entered').existsSync(),
            timeout: const Duration(seconds: 5),
          );
          expect(release.existsSync(), isFalse);
          expect(spawnCalls(), 0);
          expect(owner!.snapshot.parentSettled, isFalse);
          final closed = await logging.close();
          expect(closed.writerExited, isFalse);
          expect(closed.ownerSettled, isFalse);
          expect(closed.requiresExplicitExit, isTrue);
          expect(appendCalls(), 0);
          expect(release.existsSync(), isFalse);
          release.writeAsStringSync('release');
          await launch!.writerExited.timeout(const Duration(seconds: 5));
          await eventually(
            () => owner!.snapshot.parentSettled,
            timeout: const Duration(seconds: 5),
          );
          expect(spawnCalls(), 0);
        } else {
          await eventually(
            () => appendCalls() == 1,
            timeout: const Duration(seconds: 5),
          );
          final closed = await logging.close();
          expect(closed.writerExited, isTrue);
          expect(closed.ownerSettled, isTrue);
          expect(closed.flushed, isTrue);
          expect(closed.requiresExplicitExit, isFalse);
          await launch!.writerExited.timeout(const Duration(seconds: 5));
          expect(owner!.snapshot.parentSettled, isTrue);
          expect(owner!.snapshot.childNotLive, isTrue);
          expect(spawnCalls(), 1);
        }
      },
    );
  }
}
