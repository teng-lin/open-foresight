import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _ChildRuntime extends NativeRuntime {
  _ChildRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final requests = <String>[];
  bool active = false, firstSettled = false;
  @override
  bool get generating => active;
  @override
  Map<String, dynamic> get effectiveState => {
    'state': 'ready',
    'context_length': 4096,
  };
  @override
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) async* {
    requests.add(id);
    active = true;
    try {
      yield {
        'type': 'delta',
        'text': systemPrompt.contains('Extract explicit meeting commitments')
            ? '{"tasks":[]}'
            : '# Overview\nMira owns the Atlas launch.',
      };
      yield {'type': 'done', 'status': 'completed'};
    } finally {
      active = false;
      if (requests.length == 1) firstSettled = true;
    }
  }

  @override
  bool cancel({String? requestId}) => true;
}

/// Hold the producer's real zero-duration yield after its first native stream
/// has settled. This pauses between children, rather than holding a child open
/// or pretending that a native request is idle while it still owns resources.
class _ChildGapTimer implements Timer {
  _ChildGapTimer(this._schedule, this._callback);
  final Timer Function(void Function()) _schedule;
  final void Function() _callback;
  Timer? _timer;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  void release() {
    if (!_active || _timer != null) return;
    _timer = _schedule(() {
      _active = false;
      _tick = 1;
      _callback();
    });
  }

  @override
  void cancel() {
    _active = false;
    _timer?.cancel();
  }
}

void main() {
  for (final kind in ['summary', 'actions', 'preparation']) {
    test('$kind retains ownership between settled native children', () async {
      final directory = createTestTempDirectorySync('child-gap-');
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
        manageProcess: false,
      );
      final domain = AdapterDomain(store, helper);
      final runtime = _ChildRuntime();
      domain.generator = runtime;
      final app = Application(domain);
      store.setPreference('liveEnhance', 'false');
      final meeting = store.meeting('Atlas');
      // Separate evidence IDs force multiple Actions windows; the same text
      // also exceeds the Summary model's byte-bound single-request context.
      for (var i = 0; i < 100; i++) {
        store.transcript(
          meeting,
          'Mira will ship the Atlas launch on Friday. Topic $i needs review.',
          true,
          i,
          i + 1,
          'microphone',
        );
      }
      final source = store.importText(
        'Atlas evidence',
        'Mira owns the Atlas launch and will ship it Friday. ' * 100,
        'text/plain',
        'fixture',
      );
      final model = File('${directory.path}/peer-model.bin')
        ..writeAsStringSync('valid peer model fixture');
      final enteredGap = Completer<void>();
      _ChildGapTimer? gap;
      final work = runZoned(
        () => switch (kind) {
          'summary' => app.generateSummary(meeting, requestId: 'owner'),
          'actions' => app.generateActions(meeting, requestId: 'owner'),
          _ => app.prepareMeeting(meeting, [source], requestId: 'owner'),
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (gap == null &&
                duration == Duration.zero &&
                runtime.firstSettled &&
                !runtime.active &&
                runtime.requests.length == 1) {
              final held = _ChildGapTimer(
                (fire) => parent.createTimer(zone, duration, fire),
                callback,
              );
              gap = held;
              enteredGap.complete();
              return held;
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      final settled = work.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      addTearDown(() async {
        gap?.release();
        await settled;
        await app.close();
        domain.close();
        runtime.close();
        await helper.close();
        store.close();
        directory.deleteSync(recursive: true);
      });
      await Future.any<void>([
        enteredGap.future,
        settled.then(
          (result) => fail('Producer ended before child gap: $result'),
        ),
      ]);
      expect(runtime.active, isFalse);
      expect(runtime.requests, hasLength(1));
      expect(app.generationReserved, isTrue);
      expect(app.backgroundBusy, isTrue);
      final busy = throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.busy,
        ),
      );
      await expectLater(
        app.call(Operation.modelsRegister.wire, {
          'kind': 'speech',
          'path': model.path,
        }),
        busy,
      );
      await expectLater(app.ask('Can a peer generate?').drain<void>(), busy);
      expect(runtime.active, isFalse);
      expect(runtime.requests, hasLength(1));
      expect(store.model('speech'), isNull);
      expect(store.meetingArtifacts(meeting, kind), isEmpty);
      gap!.release();
      expect(await settled, isNull);
      expect(runtime.requests.length, greaterThan(1));
      expect(app.generationReserved, isFalse);
      expect(app.backgroundBusy, isFalse);
      expect(store.meetingArtifacts(meeting, kind), hasLength(1));
    });
  }
}
