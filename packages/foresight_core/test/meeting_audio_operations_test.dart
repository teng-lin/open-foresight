import 'dart:async';
import 'package:foresight_core/foresight_core.dart' show Store, Domain, Helper;
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/application_services/audio_application_port.dart';
import 'package:foresight_core/src/application_services/meeting_audio_operations.dart';
import 'package:foresight_core/src/persistence/audio_queries.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operation_descriptor.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

final class Port implements AudioApplicationPort {
  final calls = <Object>[];
  Completer<AudioMeetingReadPage>? reading;
  @override
  Future<void> retryTranscription(
    String id, {
    required bool Function() current,
  }) async {
    calls.add(['retry_transcription', id]);
  }

  @override
  Future<void> retryCompression(
    String id, {
    required bool Function() current,
  }) async {
    calls.add(['retry_compression', id]);
  }

  @override
  Future<void> deleteRecording(
    String id, {
    required bool Function() current,
  }) async {
    calls.add(['delete', id]);
  }

  @override
  Future<void> setRetainLossless(
    String id,
    bool value, {
    required bool Function() current,
  }) async {
    calls.add(['retain', id, value]);
  }

  @override
  Future<AudioMeetingReadPage> readMeeting(
    int meetingId, {
    String afterSessionId = '',
    int limit = 32,
    required bool Function() current,
  }) {
    calls.add(['read', meetingId, afterSessionId, limit]);
    return reading!.future;
  }

  @override
  Future<AudioTranscriptSeekTarget?> transcriptTarget(
    int id, {
    required bool Function() current,
  }) async => null;
  @override
  Future<void> play(String id, {required bool Function() current}) async {
    calls.add(['play', id]);
  }

  @override
  Future<void> pauseAudio(String id, {required bool Function() current}) async {
    calls.add(['pause', id]);
  }

  @override
  Future<void> seek(
    String id,
    int us, {
    required bool Function() current,
  }) async {
    calls.add(['seek', id, us]);
  }

  @override
  Future<void> seekTranscript(
    String id,
    int transcript, {
    required bool Function() current,
  }) async {
    calls.add(['text', id, transcript]);
  }

  @override
  Future<void> cancelExport(
    String id, {
    required bool Function() current,
  }) async {
    calls.add(['cancel', id]);
  }

  @override
  Future<AudioExportDestinationGrant> authorizeExportDestination({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String outputPath,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  }) async {
    calls.add([
      'grant',
      sessionId,
      callerIdentity,
      workspaceEpoch,
      format,
      outputPath,
      overwrite,
      allowIncomplete,
    ]);
    await Future<void>(() {});
    return const AudioExportDestinationGrant('opaque-grant');
  }

  @override
  Future<AudioExportJobReceipt> export({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String destinationToken,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  }) async {
    calls.add([
      'export',
      sessionId,
      callerIdentity,
      workspaceEpoch,
      format,
      destinationToken,
      overwrite,
      allowIncomplete,
    ]);
    return const AudioExportJobReceipt('job');
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Domain domain;
  late Application app;
  late Port port;
  setUp(() {
    final root = createTestTempDirectorySync('audio-operations-');
    domain = Domain(
      Store('${root.path}/app.db'),
      Helper('${root.path}/helper.sock', '${root.path}/helper'),
    );
    port = Port();
    app = Application(domain, recordingAudio: port);
    addTearDown(() async {
      await app.close();
      domain.close();
      await domain.drain();
      await domain.helper.close();
      domain.store.close();
    });
  });
  Future<Object?> call(
    Operation op,
    Map<String, dynamic> args, {
    Object? caller,
    bool Function()? current,
  }) => app.callRequest(
    decodeOperationRequest(op, {
      'workspace_epoch': domain.store.workspaceEpoch,
      ...args,
    }),
    callerIdentity: caller,
    current: current,
  );
  test(
    'missing runtime adapter returns honest history and refuses controls',
    () async {
      final operations = RecordingAudioOperations(
        port: null,
        metadata: AudioQueries(domain.store.audioStore),
        callerIdentity: () => Object(),
        workspaceEpoch: () => domain.store.workspaceEpoch,
      );
      final read = operations.handlers.singleWhere(
        (h) => h.operation == Operation.recordingsRead,
      );
      final value = await read.invoke(
        decodeOperationRequest(Operation.recordingsRead, {'meeting_id': 1}),
      );
      expect(AudioMeetingReadPage.fromWire(value).supported, false);
      final play = operations.handlers.singleWhere(
        (h) => h.operation == Operation.recordingsPlay,
      );
      await expectLater(
        play.invoke(
          decodeOperationRequest(Operation.recordingsPlay, {'session_id': 's'}),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            RpcErrorCode.unavailable,
          ),
        ),
      );
    },
  );

  test(
    'controls forward typed identities and sample-independent seek offsets',
    () async {
      await call(Operation.recordingsPlay, {'session_id': 'session'});
      await call(Operation.recordingsPauseAudio, {'session_id': 'session'});
      await call(Operation.recordingsSeek, {
        'session_id': 'session',
        'playback_us': 1250000,
      });
      await call(Operation.recordingsSeekTranscript, {
        'session_id': 'session',
        'transcript_id': 7,
      });
      await call(Operation.recordingsCancelExport, {'session_id': 'session'});
      await call(Operation.recordingsSetRetainLossless, {
        'session_id': 'other-session',
        'retain_lossless': true,
      });
      await call(Operation.recordingsDelete, {'session_id': 'other-session'});
      await call(Operation.recordingsRetryTranscription, {
        'session_id': 'asr-session',
      });
      await call(Operation.recordingsRetryCompression, {
        'session_id': 'compression-session',
      });
      expect(port.calls, [
        ['play', 'session'],
        ['pause', 'session'],
        ['seek', 'session', 1250000],
        ['text', 'session', 7],
        ['cancel', 'session'],
        ['retain', 'other-session', true],
        ['delete', 'other-session'],
        ['retry_transcription', 'asr-session'],
        ['retry_compression', 'compression-session'],
      ]);
      expect(
        await call(Operation.recordingsTranscriptTarget, {'transcript_id': 7}),
        isNull,
      );
    },
  );
  test(
    'export grant and consumption receive actual caller identity and epoch',
    () async {
      final callerA = Object(), callerB = Object();
      final args = {
        'session_id': 'session',
        'format': 'mp3',
        'output_path': '/chosen/output.mp3',
        'overwrite': true,
        'allow_incomplete': true,
        'caller_identity': 'forged',
      };
      await Future.wait([
        call(
          Operation.recordingsAuthorizeExportDestination,
          args,
          caller: callerA,
        ),
        call(
          Operation.recordingsAuthorizeExportDestination,
          args,
          caller: callerB,
        ),
      ]);
      expect((port.calls[0] as List)[2], same(callerA));
      expect((port.calls[1] as List)[2], same(callerB));
      expect((port.calls[0] as List).sublist(3), [
        domain.store.workspaceEpoch,
        MeetingAudioExportFormat.mp3,
        '/chosen/output.mp3',
        true,
        true,
      ]);
      final receipt = await call(Operation.recordingsExport, {
        'session_id': 'session',
        'format': 'mp3',
        'destination_token': 'opaque-grant',
        'overwrite': true,
        'allow_incomplete': true,
      }, caller: callerA);
      expect((port.calls.last as List)[2], same(callerA));
      expect(receipt, {'jobId': 'job'});
      expect(
        Operation.recordingsAuthorizeExportDestination.descriptor.capability,
        CapabilityPolicy.approvalHost,
      );
      expect(
        Operation.recordingsExport.descriptor.capability,
        CapabilityPolicy.approvalHost,
      );
    },
  );
  test('invalid requests and stale workspace never enter the port', () async {
    for (final value in [null, 0, 'true']) {
      expect(
        () => decodeOperationRequest(Operation.recordingsSetRetainLossless, {
          'session_id': 's',
          'retain_lossless': value,
        }),
        throwsA(isA<RpcError>()),
      );
    }
    expect(
      Operation
          .recordingsSetRetainLossless
          .descriptor
          .arguments
          .schemaJson['required'],
      contains('retain_lossless'),
    );
    for (final op in [
      Operation.recordingsDelete,
      Operation.recordingsSetRetainLossless,
      Operation.recordingsRetryTranscription,
      Operation.recordingsRetryCompression,
    ]) {
      expect(op.descriptor.capability, CapabilityPolicy.approvalHost);
      expect(op.descriptor.requiresHelper, false);
      expect(op.descriptor.modelGate, ModelGatePolicy.none);
      await expectLater(
        app.callRequest(
          decodeOperationRequest(op, {
            'session_id': 's',
            'retain_lossless': true,
          }),
        ),
        throwsA(isA<RpcError>()),
      );
      await expectLater(
        call(op, {
          'session_id': 'other-session',
          'retain_lossless': true,
          'workspace_epoch': 'old',
        }),
        throwsA(isA<RpcError>()),
      );
      await expectLater(
        call(op, {
          'session_id': 's',
          'retain_lossless': false,
        }, current: () => false),
        throwsA(isA<RpcError>()),
      );
    }
    expect(
      () => decodeOperationRequest(Operation.recordingsSeek, {
        'session_id': 's',
        'playback_us': -1,
      }),
      throwsA(isA<RpcError>()),
    );
    expect(
      () => decodeOperationRequest(Operation.recordingsRead, {
        'meeting_id': 1,
        'limit': 65,
      }),
      throwsA(isA<RpcError>()),
    );
    await expectLater(
      call(Operation.recordingsPlay, {
        'session_id': 's',
        'workspace_epoch': 'old',
      }),
      throwsA(isA<RpcError>()),
    );
    await expectLater(
      call(Operation.recordingsPlay, {'session_id': 's'}, current: () => false),
      throwsA(isA<RpcError>()),
    );
    await expectLater(
      app.callRequest(
        decodeOperationRequest(Operation.recordingsPlay, {'session_id': 's'}),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          RpcErrorCode.invalidArgument,
        ),
      ),
    );
    expect(port.calls, isEmpty);
  });
  test('late read is fenced and page wire remains typed', () async {
    port.reading = Completer<AudioMeetingReadPage>();
    var current = true;
    final read = call(Operation.recordingsRead, {
      'meeting_id': 1,
    }, current: () => current);
    final expectation = expectLater(
      read,
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
    );
    current = false;
    const meeting = AudioMeetingPresentation(
      meetingId: 1,
      sessionCount: 0,
      durationUs: 0,
      availability: MeetingAudioAvailability.none,
      retainedBytes: 0,
      stagingBytes: 0,
      sources: [],
      compression: AudioWorkPresentation(),
    );
    final page = AudioMeetingReadPage(
      meeting: meeting,
      sessions: const [],
      serviceError: 'Audio worker requires restart',
    );
    port.reading!.complete(page);
    await expectation;
    expect(AudioMeetingReadPage.fromWire(page.toMap()).meeting.meetingId, 1);
    expect(
      AudioMeetingReadPage.fromWire(page.toMap()).serviceError,
      'Audio worker requires restart',
    );
    final legacy = page.toMap()..remove('serviceError');
    expect(AudioMeetingReadPage.fromWire(legacy).serviceError, isEmpty);
    expect(
      AudioExportDestinationGrant.fromWire(
        const AudioExportDestinationGrant('t').toMap(),
      ).token,
      't',
    );
    expect(
      AudioExportJobReceipt.fromWire(
        const AudioExportJobReceipt('j').toMap(),
      ).jobId,
      'j',
    );
  });
}
