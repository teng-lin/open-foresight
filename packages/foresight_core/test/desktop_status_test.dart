import 'dart:convert';

import 'package:foresight_core/desktop.dart';
import 'package:test/test.dart';

void main() {
  test(
    'v1 capture snapshot decodes progress and isolates mutable wire data',
    () {
      final pending = [3];
      final errors = {'3': 'detector unavailable'};
      final run = <String, Object?>{
        'phase': 'synthesizing',
        'preview': 'provisional body',
        'completed': 2,
        'total': 4,
        'active': true,
        'cancelled': false,
        'error': '',
      };
      final value = CapturePresentation.fromWire({
        'meeting_id': 3,
        'active': true,
        'finishing': false,
        'paused': true,
        'began': 1000,
        'elapsed_ms': 2400,
        'state': 'capturing',
        'samples': [48, 96],
        'peaks': [1, 0.5],
        'volumes': [0.1, 0],
        'last_audio': 3300,
        'provisional': {'microphone': 'draft transcript'},
        'echo_cancellation': {
          'requested': true,
          'active': false,
          'pending': true,
          'restart_required': true,
          'fallback_status': 7,
        },
        'proactive': {
          'enabled': true,
          'running': true,
          'active_meeting': 3,
          'pending_meetings': pending,
          'errors': errors,
          'queued_answers': 2,
          'oldest_queue_age_ms': 700,
          'stage': 'answering',
        },
        'question_detector': {
          'configured': true,
          'ready': false,
          'backend': 'portable',
          'output_policy': 'unicode-v2',
        },
        'meeting_summaries': {'3': run},
        'meeting_workflows': {'3:preparation': run},
        'note_enhancements': {
          '3': {
            'request_id': 'enhance-3',
            'body': 'draft notes',
            'status': 'streaming',
            'active': true,
            'cancel_requested': true,
            'active_index': 2,
          },
        },
        'future_field': {'ignored': true},
      });
      pending.clear();
      errors.clear();
      run['preview'] = 'newer preview';
      expect(value.meetingId, 3);
      expect(value.active, isTrue);
      expect(value.finishing, isFalse);
      expect(value.paused, isTrue);
      expect(value.beganMilliseconds, 1000);
      expect(value.elapsedMilliseconds, 2400);
      expect(value.lastAudioMilliseconds, 3300);
      expect(value.state, 'capturing');
      expect(value.samples, [48, 96]);
      expect(value.peaks, [1.0, 0.5]);
      expect(value.volumes, [0.1, 0.0]);
      expect(value.provisional['microphone'], 'draft transcript');
      final echo = value.echoCancellation;
      expect(echo.requested, isTrue);
      expect(echo.active, isFalse);
      expect(echo.pending, isTrue);
      expect(echo.restartRequired, isTrue);
      expect(echo.fallbackStatus, 7);
      final proactive = value.proactive;
      expect(proactive.enabled, isTrue);
      expect(proactive.running, isTrue);
      expect(proactive.activeMeeting, 3);
      expect(proactive.pendingMeetings, [3]);
      expect(proactive.errors['3'], 'detector unavailable');
      expect(proactive.queuedAnswers, 2);
      expect(proactive.oldestQueueAgeMs, 700);
      expect(proactive.stage, 'answering');
      expect(value.questionDetector.configured, isTrue);
      expect(value.questionDetector.ready, isFalse);
      expect(value.questionDetector.backend, 'portable');
      expect(value.questionDetector.outputPolicy, 'unicode-v2');
      for (final progress in [
        value.summary(3)!,
        value.workflow(3, 'preparation')!,
      ]) {
        expect(progress.preview, 'provisional body');
        expect(progress.phase, 'synthesizing');
        expect(progress.completed, 2);
        expect(progress.total, 4);
        expect(progress.active, isTrue);
        expect(progress.cancelled, isFalse);
        expect(progress.error, isEmpty);
      }
      final notes = value.noteEnhancement(3)!;
      expect(notes.requestId, 'enhance-3');
      expect(notes.body, 'draft notes');
      expect(notes.status, 'streaming');
      expect(notes.active, isTrue);
      expect(notes.cancelRequested, isTrue);
      expect(notes.activeIndex, 2);
      expect(value.summary(4), isNull);
      expect(value.workflow(3, 'actions'), isNull);
      expect(value.noteEnhancement(4), isNull);
      expect(() => value.samples.add(1), throwsUnsupportedError);
      expect(() => value.peaks.clear(), throwsUnsupportedError);
      expect(() => value.volumes.clear(), throwsUnsupportedError);
      expect(() => value.provisional.clear(), throwsUnsupportedError);
      expect(() => proactive.pendingMeetings.clear(), throwsUnsupportedError);
      expect(() => proactive.errors.clear(), throwsUnsupportedError);
      expect(() => value.summaries.clear(), throwsUnsupportedError);
      expect(() => value.workflows.clear(), throwsUnsupportedError);
      expect(() => value.noteEnhancements.clear(), throwsUnsupportedError);
    },
  );

  test('absent optional v1 state keeps disconnected and idle defaults', () {
    final capture = CapturePresentation.fromWire(null);
    expect(capture.meetingId, isNull);
    expect(capture.active, isFalse);
    expect(capture.state, 'idle');
    expect(capture.elapsedMilliseconds, 0);
    expect(capture.samples, isEmpty);
    expect(capture.peaks, isEmpty);
    expect(capture.volumes, isEmpty);
    expect(capture.provisional, isEmpty);
    expect(capture.questionDetector.configured, isFalse);
    expect(capture.echoCancellation.active, isFalse);
    expect(capture.proactive.stage, 'idle');
    expect(capture.proactive.activeMeeting, isNull);
    expect(capture.proactive.errors, isEmpty);
    expect(capture.summaries, isEmpty);
    expect(capture.workflows, isEmpty);
    expect(capture.noteEnhancements, isEmpty);
    final settled = MeetingRunPresentation.fromWire({'phase': 'completed'});
    expect(settled.preview, isEmpty);
    expect(settled.active, isFalse);
    expect(NoteEnhancementPresentation.fromWire(null).activeIndex, isNull);
    final google = GooglePresentation.fromWire(null);
    expect(google.connected, isFalse);
    expect(google.configured, isFalse);
    expect(google.driveAvailable, isTrue);
    expect(google.provider, 'google');
    expect(google.accounts, isEmpty);
    final generation = GenerationPresentation.fromWire(null);
    expect(generation.state, 'unconfigured');
    expect(generation.generating, isFalse);
    expect(generation.contextLength, isNull);
    expect(generation.tools, isNull);
    expect(generation.thinking, isNull);
    expect(generation.text, isNull);
  });

  test(
    'native v1 generation JSON retains diagnostics and absent capabilities',
    () {
      const litert =
          '{"state":"ready","backend":"litert-lm-cpu-native",'
          '"load_policy":"persistent_worker","native_stop_token_sequences":true,'
          '"context_length":4096,"temperature":0.4,"top_k":40,"top_p":0.9,'
          '"thinking":false,"json":"ll_guidance_and_application_validation",'
          '"text":true,"tools":true,"error":""}';
      const llama =
          '{"state":"ready","backend":"llama.cpp-cpu-cli",'
          '"load_policy":"per_request","context_length":4096,'
          '"max_output_tokens":256,"temperature":0,"text":true,'
          '"tools":false,"error":""}';
      final first = GenerationPresentation.fromWire(jsonDecode(litert));
      final second = GenerationPresentation.fromWire(jsonDecode(llama));
      expect(first.tools, isTrue);
      expect(second.tools, isFalse);
      expect(first.thinking, isFalse);
      expect(second.thinking, isNull);
      expect(first.temperature, 0.4);
      expect(second.temperature, 0);
      expect(first.diagnosticText, jsonDecode(litert).toString());
      expect(second.diagnosticText, jsonDecode(llama).toString());
      final diagnostic = {'state': 'loading', 'future_native_detail': 'kept'};
      final value = GenerationPresentation.fromWire(diagnostic);
      diagnostic.clear();
      expect(
        value.diagnosticText,
        '{state: loading, future_native_detail: kept}',
      );
      expect(value.tools, isNull);
    },
  );

  test('macOS echo fallback keeps a zero status with a startup reason', () {
    final echo = EchoCancellationPresentation.fromWire(
      jsonDecode('''{
      "type":"echo_cancellation", "supported":true, "requested":true,
      "active":false, "restart_required":true, "fallback_status":0,
      "fallback_reason":"tap_startup_timeout"
    }'''),
    );
    expect(echo.supported, isTrue);
    expect(echo.fallbackStatus, 0);
    expect(echo.fallbackReason, 'tap_startup_timeout');
  });

  test('value-equal status slices preserve selector and hash identities', () {
    final constructors = <Object Function(Object?)>[
      EchoCancellationPresentation.fromWire,
      MeetingRunPresentation.fromWire,
      NoteEnhancementPresentation.fromWire,
      QuestionDetectorPresentation.fromWire,
      ProactivePresentation.fromWire,
      CapturePresentation.fromWire,
      GoogleAccountPresentation.fromWire,
      GooglePresentation.fromWire,
      GenerationPresentation.fromWire,
    ];
    for (final decode in constructors) {
      final first = decode(null), second = decode({});
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first, isNot(equals(Object())));
    }
    final wire = {
      'meeting_summaries': {
        '3': {'phase': 'synthesizing', 'preview': 'same'},
      },
      'proactive': {
        'pending_meetings': [3, 4],
        'errors': {'3': 'one', '4': 'two'},
      },
    };
    final first = CapturePresentation.fromWire(wire);
    final equal = CapturePresentation.fromWire(jsonDecode(jsonEncode(wire)));
    expect(first, equal);
    expect(first.hashCode, equal.hashCode);
    expect(first.summary(3), equal.summary(3));
    expect(first.proactive, equal.proactive);
    expect(
      first.proactive,
      ProactivePresentation.fromWire({
        'pending_meetings': [3, 4],
        'errors': {'4': 'two', '3': 'one'},
      }),
    );
    expect(
      first.proactive.hashCode,
      ProactivePresentation.fromWire({
        'pending_meetings': [3, 4],
        'errors': {'4': 'two', '3': 'one'},
      }).hashCode,
    );
    expect(first, isNot(CapturePresentation.fromWire({'meeting_id': 4})));
    expect(first.summary(3), isNot(MeetingRunPresentation.fromWire({})));
    expect(first.proactive, isNot(ProactivePresentation.fromWire({})));
    expect(
      EchoCancellationPresentation.fromWire({}),
      isNot(QuestionDetectorPresentation.fromWire({})),
    );
  });

  test('Google status exposes typed account values without credentials', () {
    final account = {
      'id': 'account-1',
      'email': 'test@example.invalid',
      'displayName': 'Test',
      'photoUrl': 'https://example.invalid/avatar',
      'current': true,
    };
    final accounts = [account];
    final google = GooglePresentation.fromWire({
      'connected': true,
      'syncing': true,
      'configured': true,
      'signingIn': true,
      'driveAvailable': false,
      'provider': 'granola',
      'account': 'account-1',
      'email': account['email'],
      'displayName': account['displayName'],
      'photoUrl': account['photoUrl'],
      'loadError': 'refresh failed',
      'lastRefresh': 1234,
      'accounts': accounts,
    });
    accounts.clear();
    account['displayName'] = 'Changed';
    expect(google.connected, isTrue);
    expect(google.syncing, isTrue);
    expect(google.configured, isTrue);
    expect(google.signingIn, isTrue);
    expect(google.driveAvailable, isFalse);
    expect(google.provider, 'granola');
    expect(google.account, 'account-1');
    expect(google.email, 'test@example.invalid');
    expect(google.displayName, 'Test');
    expect(google.photoUrl, 'https://example.invalid/avatar');
    expect(google.loadError, 'refresh failed');
    expect(google.lastRefreshMilliseconds, 1234);
    final first = google.accounts.single;
    expect(first.id, 'account-1');
    expect(first.email, google.email);
    expect(first.displayName, 'Test');
    expect(first.photoUrl, google.photoUrl);
    expect(first.current, isTrue);
    expect(() => google.accounts.clear(), throwsUnsupportedError);
  });

  test(
    'generation state preserves unknown phase and optional native fields',
    () {
      final generation = GenerationPresentation.fromWire({
        'state': 'future-phase',
        'error': 'runtime detail',
        'backend': 'litert_lm',
        'load_policy': 'persistent_worker',
        'json': 'll_guidance_and_application_validation',
        'generating': true,
        'tools': true,
        'text': true,
        'thinking': false,
        'native_stop_token_sequences': true,
        'context_length': 4096,
        'max_output_tokens': 256,
        'temperature': 0,
        'top_k': 40,
        'top_p': 0.9,
        'new_native_capability': true,
      });
      expect(generation.state, 'future-phase');
      expect(generation.error, 'runtime detail');
      expect(generation.backend, 'litert_lm');
      expect(generation.generating, isTrue);
      expect(generation.tools, isTrue);
      expect(generation.contextLength, 4096);
      expect(generation.loadPolicy, 'persistent_worker');
      expect(generation.json, 'll_guidance_and_application_validation');
      expect(generation.text, isTrue);
      expect(generation.thinking, isFalse);
      expect(generation.nativeStopTokenSequences, isTrue);
      expect(generation.maxOutputTokens, 256);
      expect(generation.temperature, 0.0);
      expect(generation.topK, 40);
      expect(generation.topP, 0.9);
    },
  );

  test('malformed typed values fail decoding instead of changing identity', () {
    expect(
      () => CapturePresentation.fromWire({'meeting_id': '3'}),
      throwsA(isA<TypeError>()),
    );
    expect(
      () => CapturePresentation.fromWire({
        'samples': [0.5],
      }),
      throwsA(isA<TypeError>()),
    );
    expect(
      () => GooglePresentation.fromWire({
        'accounts': ['account'],
      }),
      throwsA(isA<TypeError>()),
    );
  });
}
