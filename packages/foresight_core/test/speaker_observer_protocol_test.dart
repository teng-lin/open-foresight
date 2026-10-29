import 'dart:async';
import 'dart:convert';

import 'package:foresight_core/src/speaker_observation.dart';
import 'package:foresight_core/src/speaker_observer_protocol.dart';
import 'package:test/test.dart';

String line(Map<String, Object?> frame) => '${jsonEncode(frame)}\n';

Map<String, Object?> frame(
  String type,
  int seq, [
  Map<String, Object?> fields = const {},
]) => {'v': 1, 'type': type, 'seq': seq, ...fields};

Map<String, Object?> hello(int seq) => frame('hello', seq, {
  'helper': 'zoom_observer_macos',
  'helper_version': '1.0.0',
  'parser_version': 'mac-1',
  'platform': 'macos',
});

Map<String, Object?> observation(
  int seq, {
  Map<String, Object?> overrides = const {},
}) => frame('observation', seq, {
  'session': 's1',
  'read_start_ms': 123456,
  'read_end_ms': 123492,
  'target': {
    'pid': 4242,
    'window': 'w1',
    'zoom_version': '7.2.2.88465',
    'locale': 'en',
  },
  'complete': true,
  'parser_version': 'mac-1',
  'participants': [
    {'ref': 'p1', 'name': 'Ada Lovelace', 'self': false},
    {'ref': 'p2', 'name': 'Lovelace, Ada', 'self': true},
  ],
  'speakers': [
    {'ref': 'p1', 'method': 'participant_status'},
  ],
  ...overrides,
});

ObserverProtocolException decodeFailure(
  String text, {
  int maxLineBytes = speakerObserverMaxLineBytes,
}) {
  final decoder = ObserverFrameDecoder(maxLineBytes: maxLineBytes);
  try {
    decoder.add(utf8.encode(text));
    decoder.close();
  } on ObserverProtocolException catch (error) {
    return error;
  }
  fail('Expected a protocol error');
}

void main() {
  group('encoder', () {
    test('numbers requests from zero and writes one object per line', () {
      final encoder = ObserverFrameEncoder();
      final first = utf8.decode(encoder.encode(const CapabilitiesRequest('a')));
      final second = utf8.decode(
        encoder.encode(
          const StartRequest(
            id: 'b',
            session: 's1',
            pollMs: 500,
            deadlineMs: 2000,
          ),
        ),
      );
      expect(first.endsWith('\n'), true);
      expect(jsonDecode(first), {
        'v': 1,
        'type': 'capabilities',
        'seq': 0,
        'id': 'a',
      });
      expect(jsonDecode(second), {
        'v': 1,
        'type': 'start',
        'seq': 1,
        'id': 'b',
        'session': 's1',
        'poll_ms': 500,
        'deadline_ms': 2000,
      });
    });

    test('encodes every request type', () {
      final encoder = ObserverFrameEncoder();
      final types = [
        const CapabilitiesRequest('1'),
        const SetupRequest('2'),
        const StopRequest('3'),
        const ClockRequest('4'),
      ].map((r) => jsonDecode(utf8.decode(encoder.encode(r)))['type']);
      expect(types, ['capabilities', 'setup', 'stop', 'clock']);
    });

    test('bounds identifiers by escaped UTF-8 bytes, as the helpers do', () {
      String encodeSession(String session) => utf8.decode(
        ObserverFrameEncoder().encode(
          StartRequest(
            id: 'i1',
            session: session,
            pollMs: 500,
            deadlineMs: 2000,
          ),
        ),
      );
      expect(encodeSession('a' * 128), contains('"session":"${'a' * 128}"'));
      expect(() => encodeSession('a' * 129), throwsArgumentError);
      // 64 two-byte characters are exactly 128 bytes; one more is not.
      expect(encodeSession('\u00e9' * 64), contains('\u00e9'));
      expect(() => encodeSession('\u00e9' * 65), throwsArgumentError);
      expect(() => encodeSession('\u{1F600}' * 33), throwsArgumentError);
      // A quote costs two bytes, so 64 quotes are 128 and 65 are not.
      expect(encodeSession('"' * 64), isNotEmpty);
      expect(() => encodeSession('"' * 65), throwsArgumentError);
    });

    test('rejects a request larger than the line limit', () {
      final encoder = ObserverFrameEncoder(maxLineBytes: 20);
      expect(
        () => encoder.encode(const CapabilitiesRequest('a')),
        throwsArgumentError,
      );
      expect(encoder.nextSeq, 0);
    });

    test('request bounds match what the helper accepts', () {
      final encoder = ObserverFrameEncoder();
      for (final (poll, deadline) in [(100, 100), (5000, 30000)]) {
        expect(
          () => encoder.encode(
            StartRequest(
              id: 'a',
              session: 's',
              pollMs: poll,
              deadlineMs: deadline,
            ),
          ),
          returnsNormally,
        );
      }
      for (final (poll, deadline) in [
        (99, 1000),
        (5001, 1000),
        (500, 99),
        (500, 30001),
      ]) {
        expect(
          () => encoder.encode(
            StartRequest(
              id: 'a',
              session: 's',
              pollMs: poll,
              deadlineMs: deadline,
            ),
          ),
          throwsArgumentError,
          reason: '$poll/$deadline',
        );
      }
    });

    test('rejects identifiers and bounds that the helper must refuse', () {
      final encoder = ObserverFrameEncoder();
      expect(
        () => encoder.encode(const CapabilitiesRequest('')),
        throwsArgumentError,
      );
      expect(
        () => encoder.encode(CapabilitiesRequest('x' * 129)),
        throwsArgumentError,
      );
      expect(
        () => encoder.encode(const CapabilitiesRequest('bad\nid')),
        throwsArgumentError,
      );
      expect(
        () => encoder.encode(
          const StartRequest(
            id: 'b',
            session: 's',
            pollMs: 0,
            deadlineMs: 1000,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => encoder.encode(
          const StartRequest(id: 'b', session: 's', pollMs: 500, deadlineMs: 0),
        ),
        throwsArgumentError,
      );
      // Rejected requests do not consume sequence numbers.
      expect(
        jsonDecode(
          utf8.decode(encoder.encode(const CapabilitiesRequest('ok'))),
        )['seq'],
        0,
      );
    });
  });

  group('decoder', () {
    test('decodes every helper frame with strict sequence', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode(
          [
            hello(0),
            frame('capabilities', 1, {
              'id': 'a',
              'state': 'needs_setup',
              'reason': 'ax_untrusted',
              'zoom_version': '7.2.2.88465',
              'locale': 'en',
            }),
            frame('started', 2, {
              'id': 'b',
              'session': 's1',
              'target': {'pid': 7, 'window': 'w'},
            }),
            observation(3),
            frame('unavailable', 4, {
              'session': 's1',
              'reason': 'window_lost',
              'since_ms': 99,
            }),
            frame('clock', 5, {'id': 'c', 'monotonic_ms': 1234}),
            frame('error', 6, {
              'id': 'b',
              'code': 'ax_timeout',
              'message': 'read exceeded deadline',
            }),
            frame('error', 7, {'code': 'x', 'message': 'no id'}),
            frame('stopped', 8, {'id': 'd', 'session': 's1'}),
          ].map(line).join(),
        ),
      );
      expect(frames.map((f) => f.runtimeType.toString()), [
        'HelloFrame',
        'CapabilitiesFrame',
        'StartedFrame',
        'ObservationFrame',
        'UnavailableFrame',
        'ClockFrame',
        'ErrorFrame',
        'ErrorFrame',
        'StoppedFrame',
      ]);
      final hello0 = frames[0] as HelloFrame;
      expect(hello0.platform, 'macos');
      expect(hello0.parserVersion, 'mac-1');
      final caps = frames[1] as CapabilitiesFrame;
      expect(caps.state, ObserverAvailability.needsSetup);
      expect(caps.reason, 'ax_untrusted');
      expect(caps.zoomVersion, '7.2.2.88465');
      final started = frames[2] as StartedFrame;
      expect(started.pid, 7);
      expect(started.zoomVersion, isNull);
      final unavailable = frames[4] as UnavailableFrame;
      expect(unavailable.sinceUs, 99000);
      expect((frames[5] as ClockFrame).monotonicUs, 1234000);
      expect((frames[6] as ErrorFrame).id, 'b');
      expect((frames[7] as ErrorFrame).id, isNull);
      expect((frames[8] as StoppedFrame).session, 's1');
      expect(decoder.expectedSeq, 9);
    });

    test('maps observations to microseconds and preserves spelling', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode(line(hello(0)) + line(observation(1))),
      );
      final observed = (frames[1] as ObservationFrame).observation;
      expect(observed.session, 's1');
      expect(observed.readStartUs, 123456000);
      expect(observed.readEndUs, 123492000);
      expect(observed.complete, true);
      expect(observed.target.pid, 4242);
      expect(observed.target.zoomVersion, '7.2.2.88465');
      expect(observed.participants.map((p) => p.name), [
        'Ada Lovelace',
        'Lovelace, Ada',
      ]);
      expect(observed.participants[1].isSelf, true);
      expect(
        observed.speakers.single.method,
        SpeakerEvidenceMethod.participantStatus,
      );
      expect(observed.observedNoSpeaker, false);
    });

    test('empty speakers on a complete read is an observed absence', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode(
          line(hello(0)) + line(observation(1, overrides: {'speakers': []})),
        ),
      );
      expect(
        (frames[1] as ObservationFrame).observation.observedNoSpeaker,
        true,
      );
      final partial = ObserverFrameDecoder()..add(utf8.encode(line(hello(0))));
      final frame2 = partial.add(
        utf8.encode(
          line(observation(1, overrides: {'speakers': [], 'complete': false})),
        ),
      );
      expect(
        (frame2.single as ObservationFrame).observation.observedNoSpeaker,
        false,
      );
    });

    test('reassembles frames split across arbitrary chunk boundaries', () {
      final bytes = utf8.encode(line(hello(0)) + line(observation(1)));
      final decoder = ObserverFrameDecoder();
      final frames = <ObserverFrame>[];
      for (var i = 0; i < bytes.length; i += 7) {
        frames.addAll(
          decoder.add(
            bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7),
          ),
        );
      }
      expect(frames, hasLength(2));
      // Multi-byte names split inside a code point still decode.
      final emoji = utf8.encode(
        line(hello(0)) +
            line(
              observation(
                1,
                overrides: {
                  'participants': [
                    {'ref': 'p1', 'name': '林 \u{1F600}', 'self': false},
                  ],
                },
              ),
            ),
      );
      final split = ObserverFrameDecoder();
      final out = <ObserverFrame>[];
      for (final byte in emoji) {
        out.addAll(split.add([byte]));
      }
      expect(
        (out[1] as ObservationFrame).observation.participants.single.name,
        '林 \u{1F600}',
      );
    });

    test('ignores unknown fields', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode(
          line({
                ...hello(0),
                'future': {'a': 1},
              }) +
              line(observation(1, overrides: {'extra': true})),
        ),
      );
      expect(frames, hasLength(2));
    });

    test('rejects unknown frame types, versions and missing fields', () {
      expect(
        decodeFailure(line(frame('mystery', 0))).code,
        ObserverProtocolErrorCode.unknownType,
      );
      expect(
        decodeFailure(line({...hello(0), 'v': 2})).code,
        ObserverProtocolErrorCode.unsupportedVersion,
      );
      expect(
        decodeFailure(line({...hello(0), 'v': '1'})).code,
        ObserverProtocolErrorCode.unsupportedVersion,
      );
      expect(
        decodeFailure(line({'v': 1, 'seq': 0})).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        decodeFailure(line(frame('hello', 0, {'helper': 'x'}))).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        decodeFailure(line({'v': 1, 'type': 'hello'})).code,
        ObserverProtocolErrorCode.malformed,
      );
      // Request-only types are not valid helper frames.
      expect(
        decodeFailure(line(frame('start', 0, {'id': 'a'}))).code,
        ObserverProtocolErrorCode.unknownType,
      );
    });

    test('rejects sequence gaps, repeats and a nonzero start', () {
      expect(
        decodeFailure(line(hello(1))).code,
        ObserverProtocolErrorCode.sequence,
      );
      expect(
        decodeFailure(line(hello(0)) + line(hello(0))).code,
        ObserverProtocolErrorCode.sequence,
      );
      expect(
        decodeFailure(line(hello(0)) + line(observation(2))).code,
        ObserverProtocolErrorCode.sequence,
      );
      expect(
        decodeFailure(line({...hello(0), 'seq': -1})).code,
        ObserverProtocolErrorCode.sequence,
      );
    });

    test('rejects malformed JSON, non-objects, blanks and invalid UTF-8', () {
      expect(
        decodeFailure('{not json}\n').code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        decodeFailure('[1,2]\n').code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(decodeFailure('\n').code, ObserverProtocolErrorCode.malformed);
      final decoder = ObserverFrameDecoder();
      expect(
        () => decoder.add([0xff, 0xfe, 0x0a]),
        throwsA(
          isA<ObserverProtocolException>().having(
            (e) => e.code,
            'code',
            ObserverProtocolErrorCode.malformed,
          ),
        ),
      );
    });

    test('rejects an over-long line before buffering it', () {
      final decoder = ObserverFrameDecoder(maxLineBytes: 64);
      // No newline ever arrives: the cap applies to the unterminated prefix.
      expect(
        () => decoder.add(List.filled(65, 0x61)),
        throwsA(
          isA<ObserverProtocolException>().having(
            (e) => e.code,
            'code',
            ObserverProtocolErrorCode.lineTooLong,
          ),
        ),
      );
      expect(
        decodeFailure('${'x' * 100}\n', maxLineBytes: 64).code,
        ObserverProtocolErrorCode.lineTooLong,
      );
      // A line exactly at the limit (excluding the newline) is accepted.
      final exact = jsonEncode(hello(0));
      final ok = ObserverFrameDecoder(maxLineBytes: utf8.encode(exact).length);
      expect(ok.add(utf8.encode('$exact\n')), hasLength(1));
      final one = ObserverFrameDecoder(
        maxLineBytes: utf8.encode(exact).length - 1,
      );
      expect(
        () => one.add(utf8.encode('$exact\n')),
        throwsA(isA<ObserverProtocolException>()),
      );
    });

    test('line limit spans chunks and applies per line', () {
      final decoder = ObserverFrameDecoder(maxLineBytes: 200);
      final text = utf8.encode('${jsonEncode(hello(0))}\n');
      expect(decoder.add(text.sublist(0, 30)), isEmpty);
      expect(decoder.add(text.sublist(30)), hasLength(1));
      // Previous lines do not count toward the next one.
      final next = utf8.encode(
        '${jsonEncode(frame('stopped', 1, {'id': 'a', 'session': 's'}))}\n',
      );
      expect(decoder.add(next), hasLength(1));
    });

    test('a trailing partial line at close is a truncation error', () {
      final decoder = ObserverFrameDecoder();
      decoder.add(utf8.encode(jsonEncode(hello(0))));
      expect(
        decoder.close,
        throwsA(
          isA<ObserverProtocolException>().having(
            (e) => e.code,
            'code',
            ObserverProtocolErrorCode.truncated,
          ),
        ),
      );
      final clean = ObserverFrameDecoder()..add(utf8.encode(line(hello(0))));
      expect(clean.close, returnsNormally);
    });

    test('frames before a violation in one chunk are delivered first', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode('${line(hello(0))}garbage\n${line(hello(1))}'),
      );
      expect(frames, hasLength(1));
      expect(decoder.failed, true);
      expect(
        () => decoder.add(utf8.encode(line(hello(1)))),
        throwsA(
          isA<ObserverProtocolException>().having(
            (e) => e.code,
            'code',
            ObserverProtocolErrorCode.malformed,
          ),
        ),
      );
      // Later calls repeat a generic failure.
      expect(decoder.close, throwsA(isA<ObserverProtocolException>()));
    });

    test('a failed decoder stays failed', () {
      final decoder = ObserverFrameDecoder();
      expect(
        () => decoder.add(utf8.encode('nope\n')),
        throwsA(isA<ObserverProtocolException>()),
      );
      expect(
        () => decoder.add(utf8.encode(line(hello(0)))),
        throwsA(isA<ObserverProtocolException>()),
      );
      expect(decoder.failed, true);
    });

    test('error text never carries frame content', () {
      final error = decodeFailure(
        line(
          observation(
            0,
            overrides: {
              'participants': [
                {'ref': 'p1', 'name': 'Secret Person\u0000', 'self': false},
              ],
              'speakers': [
                {'ref': 'p1', 'method': 'guess'},
              ],
            },
          ),
        ),
      );
      expect(error.toString(), isNot(contains('Secret')));
      expect(error.message, isNot(contains('Secret')));
    });
  });

  group('observation validation', () {
    ObserverProtocolException reject(Map<String, Object?> overrides) =>
        decodeFailure(line(observation(0, overrides: overrides)));

    test('bounds participants and rejects inconsistent rosters', () {
      List<Map<String, Object?>> roster(int n) => [
        for (var i = 0; i < n; i++)
          {'ref': 'p$i', 'name': 'N$i', 'self': false},
      ];
      final ok = ObserverFrameDecoder();
      expect(
        ok.add(
          utf8.encode(
            line(
              observation(
                0,
                overrides: {'participants': roster(256), 'speakers': []},
              ),
            ),
          ),
        ),
        hasLength(1),
      );
      expect(
        reject({'participants': roster(257), 'speakers': []}).code,
        ObserverProtocolErrorCode.limit,
      );
      expect(
        reject({
          'participants': [
            {'ref': 'p1', 'name': 'A', 'self': false},
            {'ref': 'p1', 'name': 'B', 'self': false},
          ],
          'speakers': [],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      // A speaker must be on the roster of the same observation.
      expect(
        reject({
          'speakers': [
            {'ref': 'ghost', 'method': 'participant_status'},
          ],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'speakers': [
            {'ref': 'p1', 'method': 'participant_status'},
            {'ref': 'p1', 'method': 'compact_talking_label'},
          ],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
    });

    test('rejects bad methods, times, counters and field types', () {
      expect(
        reject({
          'speakers': [
            {'ref': 'p1', 'method': 'psychic'},
          ],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({'read_start_ms': 10, 'read_end_ms': 9}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({'read_start_ms': -1}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({'read_start_ms': 1.5}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({'complete': 'yes'}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({'participants': {}}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({'target': 'w1'}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'target': {'pid': -3, 'window': 'w'},
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'participants': [
            {'ref': 'p1', 'name': 7, 'self': false},
          ],
          'speakers': [],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(reject({'session': ''}).code, ObserverProtocolErrorCode.malformed);
      // Times beyond 2^53 ms cannot round trip through JSON doubles.
      expect(
        reject({'read_end_ms': 1 << 60, 'read_start_ms': 1 << 59}).code,
        ObserverProtocolErrorCode.malformed,
      );
    });

    test('times must be strictly below 2^50 ms', () {
      final top = (1 << 50) - 1;
      final accepted = ObserverFrameDecoder().add(
        utf8.encode(
          line(
            observation(
              0,
              overrides: {'read_start_ms': top, 'read_end_ms': top},
            ),
          ),
        ),
      );
      expect(accepted, hasLength(1));
      expect(
        reject({'read_start_ms': 1 << 50, 'read_end_ms': 1 << 50}).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        decodeFailure(
          line(frame('clock', 0, {'id': 'a', 'monotonic_ms': 1 << 50})),
        ).code,
        ObserverProtocolErrorCode.malformed,
      );
    });

    test('started carries what the helper knew, which may be nothing', () {
      final frames = ObserverFrameDecoder().add(
        utf8.encode(
          line(
                frame('started', 0, {
                  'id': 'a',
                  'session': 's1',
                  'target': {'pid': null, 'zoom_version': null},
                }),
              ) +
              line(
                frame('started', 1, {
                  'id': 'b',
                  'session': 's1',
                  'target': {'pid': 42, 'zoom_version': '7.2.2.88465'},
                }),
              ),
        ),
      );
      final nothing = frames[0] as StartedFrame;
      expect(nothing.pid, isNull);
      expect(nothing.zoomVersion, isNull);
      final known = frames[1] as StartedFrame;
      expect(known.pid, 42);
      expect(known.zoomVersion, '7.2.2.88465');
      for (final bad in [
        <String, Object?>{'id': 'a', 'session': 's'},
        {'id': 'a', 'session': 's', 'target': 'x'},
        {
          'id': 'a',
          'session': 's',
          'target': {'pid': -1},
        },
        {
          'id': 'a',
          'session': 's',
          'target': {'pid': 'x'},
        },
      ]) {
        expect(
          decodeFailure(line(frame('started', 0, bad))).code,
          ObserverProtocolErrorCode.malformed,
        );
      }
    });

    test('stopped may carry a null or absent session, never a bad one', () {
      final frames = ObserverFrameDecoder().add(
        utf8.encode(
          line(frame('stopped', 0, {'id': 'a', 'session': null})) +
              line(frame('stopped', 1, {'id': 'b'})) +
              line(frame('stopped', 2, {'id': 'c', 'session': 's1'})),
        ),
      );
      expect(frames.map((f) => (f as StoppedFrame).session), [
        null,
        null,
        's1',
      ]);
      for (final bad in ['', 'bad\nid', 7]) {
        expect(
          decodeFailure(
            line(frame('stopped', 0, {'id': 'a', 'session': bad})),
          ).code,
          ObserverProtocolErrorCode.malformed,
        );
      }
    });

    test('a busy refusal is an ordinary error frame', () {
      final frames = ObserverFrameDecoder().add(
        utf8.encode(
          line(
            frame('error', 0, {
              'id': 'r1',
              'code': 'busy',
              'message': 'queue full',
            }),
          ),
        ),
      );
      final error = frames.single as ErrorFrame;
      expect(error.code, 'busy');
      expect(error.id, 'r1');
    });

    test('an unavailable frame may omit its reason', () {
      final frames = ObserverFrameDecoder().add(
        utf8.encode(
          line(frame('unavailable', 0, {'session': 's', 'since_ms': 5})),
        ),
      );
      expect((frames.single as UnavailableFrame).reason, '');
      expect(
        decodeFailure(
          line(
            frame('unavailable', 0, {
              'session': 's',
              'since_ms': 5,
              'reason': 'A name',
            }),
          ),
        ).code,
        ObserverProtocolErrorCode.malformed,
      );
    });

    ObservationFrame withName(String name) =>
        ObserverFrameDecoder()
                .add(
                  utf8.encode(
                    line(
                      observation(
                        0,
                        overrides: {
                          'participants': [
                            {'ref': 'p1', 'name': name, 'self': false},
                          ],
                          'speakers': [],
                        },
                      ),
                    ),
                  ),
                )
                .single
            as ObservationFrame;

    // The persistence layer strips and judges exactly this set.
    const strippedCharacters = [
      '\u00ad',
      '\u061c',
      '\u200b',
      '\u200e',
      '\u200f',
      '\u202a',
      '\u202e',
      '\u2060',
      '\u2061',
      '\u2062',
      '\u2063',
      '\u2064',
      '\u2066',
      '\u2069',
      '\u206a',
      '\u206f',
      '\ufe00',
      '\ufe0f',
      '\ufeff',
      '\u{e0001}',
      '\u{e0041}',
      '\u{e007f}',
      '\u{e0100}',
      '\u{e01ef}',
    ];

    test('invisible characters cannot disguise or become a name', () {
      for (final character in strippedCharacters) {
        final reason = character.runes.first.toRadixString(16);
        expect(
          withName(
            'A${character}d${character}a',
          ).observation.participants.single.name,
          'Ada',
          reason: reason,
        );
        // The native filters let these through, so a roster entry that is only
        // invisible is a dropped entry and an incomplete read, not a violation.
        final dropped = withName(character).observation;
        expect(dropped.participants, isEmpty, reason: reason);
        expect(dropped.complete, false, reason: reason);
      }
    });

    test('joiners stay inside names but never make one', () {
      expect(
        withName('a\u200db\u200cc').observation.participants.single.name,
        'a\u200db\u200cc',
      );
      for (final name in [
        '\u200d',
        '\u200c\u200d',
        ' \u200d ',
        '\u00a0',
        '\u200d\u00ad\u00a0',
      ]) {
        final dropped = withName(name).observation;
        final reason = name.runes.map((r) => r.toRadixString(16)).join(' ');
        expect(dropped.participants, isEmpty, reason: reason);
        expect(dropped.complete, false, reason: reason);
      }
      expect(
        withName('\u{1F600}').observation.participants.single.name,
        '\u{1F600}',
      );
    });

    group('a roster name the native filters allowed but Dart cannot use', () {
      ObservationFrame decodeRoster(
        List<Map<String, Object?>> participants,
        List<Map<String, Object?>> speakers,
      ) =>
          ObserverFrameDecoder()
                  .add(
                    utf8.encode(
                      line(
                        observation(
                          0,
                          overrides: {
                            'participants': participants,
                            'speakers': speakers,
                          },
                        ),
                      ),
                    ),
                  )
                  .single
              as ObservationFrame;

      test('is dropped locally; the rest of the roster survives', () {
        final read = decodeRoster(
          [
            {'ref': 'p1', 'name': 'Ada', 'self': false},
            {'ref': 'p2', 'name': '\u{FE0F}', 'self': false},
            {'ref': 'p3', 'name': '\u{E0041}\u{E0042}', 'self': false},
          ],
          [
            {'ref': 'p1', 'method': 'participant_status'},
          ],
        ).observation;
        expect([for (final p in read.participants) p.name], ['Ada']);
        expect(read.speakers.single.ref, 'p1');
        expect(read.complete, false);
      });

      test('never makes its owner an active speaker', () {
        final read = decodeRoster(
          [
            {'ref': 'p1', 'name': 'Ada', 'self': false},
            {'ref': 'p2', 'name': '\u{FE0F}', 'self': false},
          ],
          [
            {'ref': 'p2', 'method': 'participant_status'},
          ],
        ).observation;
        expect(read.speakers, isEmpty);
        expect(read.complete, false);
        expect(read.observedNoSpeaker, false);
      });

      test(
        'a name over the bound is clamped, and not trusted as a speaker',
        () {
          final long = 'x' * 300;
          final read = decodeRoster(
            [
              {'ref': 'p1', 'name': long, 'self': false},
              {'ref': 'p2', 'name': 'Bo', 'self': false},
            ],
            [
              {'ref': 'p1', 'method': 'participant_status'},
              {'ref': 'p2', 'method': 'participant_status'},
            ],
          ).observation;
          expect(read.participants.first.name.runes.length, 256);
          expect(read.participants.last.name, 'Bo');
          expect([for (final s in read.speakers) s.ref], ['p2']);
          expect(read.complete, false);
        },
      );

      test('a complete roster stays complete', () {
        final read = decodeRoster(
          [
            {'ref': 'p1', 'name': 'x' * 256, 'self': false},
          ],
          [
            {'ref': 'p1', 'method': 'participant_status'},
          ],
        ).observation;
        expect(read.complete, true);
        expect(read.speakers, hasLength(1));
      });

      test('structural violations still fail the frame', () {
        expect(
          reject({
            'participants': [
              {'ref': 'p1', 'name': null, 'self': false},
            ],
            'speakers': [],
          }).code,
          ObserverProtocolErrorCode.malformed,
        );
        expect(
          reject({
            'participants': [
              {'ref': 'p1', 'name': 'A', 'self': false},
            ],
            'speakers': [
              {'ref': 'unknown', 'method': 'participant_status'},
            ],
          }).code,
          ObserverProtocolErrorCode.malformed,
        );
      });
    });

    test('rejects malformed roster entries', () {
      expect(
        reject({
          'participants': ['p1'],
          'speakers': [],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'participants': [
            {'ref': 'p1', 'name': 'A', 'self': 'no'},
          ],
          'speakers': [],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'speakers': ['p1'],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'target': {'pid': 1, 'window': 'w', 'locale': ''},
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        reject({
          'target': {'pid': 1, 'window': 'w', 'zoom_version': 'v' * 65},
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
    });

    test('turns tabs and line breaks in names into spaces', () {
      final frames = ObserverFrameDecoder().add(
        utf8.encode(
          line(
            observation(
              0,
              overrides: {
                'participants': [
                  {'ref': 'p1', 'name': 'Ada\tLovelace\nJr', 'self': false},
                ],
                'speakers': [],
              },
            ),
          ),
        ),
      );
      expect(
        (frames.single as ObservationFrame)
            .observation
            .participants
            .single
            .name,
        'Ada Lovelace Jr',
      );
      final huge = ObserverFrameDecoder().add(
        utf8.encode(
          line(
            observation(
              0,
              overrides: {
                'participants': [
                  {'ref': 'p1', 'name': '\u{1F600}' * 600, 'self': false},
                ],
                'speakers': [],
              },
            ),
          ),
        ),
      );
      final clamped = (huge.single as ObservationFrame).observation;
      expect(clamped.participants.single.name.runes.length, 256);
      expect(clamped.complete, false);
    });

    test('treats names as untrusted: sanitizes controls and bounds length', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode(
          line(
            observation(
              0,
              overrides: {
                'participants': [
                  {
                    'ref': 'p1',
                    'name': '  Ada\u0007 \u202ELove\u202Clace\u2028  ',
                    'self': false,
                  },
                ],
                'speakers': [],
              },
            ),
          ),
        ),
      );
      expect(
        (frames.single as ObservationFrame)
            .observation
            .participants
            .single
            .name,
        'Ada Lovelace',
      );
      // A name with nothing left after sanitizing is dropped, a long one
      // clamped; both make the read incomplete rather than a violation.
      expect(withName('\u0000\u0001').observation.participants, isEmpty);
      expect(withName('\u0000\u0001').observation.complete, false);
      expect(
        withName('a' * 257).observation.participants.single.name,
        'a' * 256,
      );
      expect(withName('a' * 257).observation.complete, false);
      expect(
        reject({
          'participants': [
            {'ref': 'p\n1', 'name': 'ok', 'self': false},
          ],
          'speakers': [],
        }).code,
        ObserverProtocolErrorCode.malformed,
      );
    });

    test('keeps legitimate punctuation and distinguishes equal names', () {
      final decoder = ObserverFrameDecoder();
      final frames = decoder.add(
        utf8.encode(
          line(
            observation(
              0,
              overrides: {
                'participants': [
                  {'ref': 'a', 'name': 'Smith, Jo (host)', 'self': false},
                  {'ref': 'b', 'name': 'Smith, Jo (host)', 'self': false},
                ],
                'speakers': [
                  {'ref': 'b', 'method': 'compact_talking_label'},
                ],
              },
            ),
          ),
        ),
      );
      final observed = (frames.single as ObservationFrame).observation;
      expect(observed.participants.map((p) => p.name).toSet(), {
        'Smith, Jo (host)',
      });
      expect(observed.participants, hasLength(2));
      expect(observed.speakers.single.ref, 'b');
    });
  });

  group('other frame validation', () {
    test('capabilities state and reason tokens are validated', () {
      expect(
        decodeFailure(
          line(frame('capabilities', 0, {'id': 'a', 'state': 'fine'})),
        ).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        decodeFailure(
          line(
            frame('capabilities', 0, {
              'id': 'a',
              'state': 'available',
              'reason': 'Ada Lovelace joined',
            }),
          ),
        ).code,
        ObserverProtocolErrorCode.malformed,
      );
      final ok = ObserverFrameDecoder().add(
        utf8.encode(
          line(frame('capabilities', 0, {'id': 'a', 'state': 'available'})),
        ),
      );
      expect((ok.single as CapabilitiesFrame).reason, '');
    });

    test('clock, unavailable and error frames validate numerics', () {
      expect(
        decodeFailure(
          line(frame('clock', 0, {'id': 'a', 'monotonic_ms': -1})),
        ).code,
        ObserverProtocolErrorCode.malformed,
      );
      expect(
        decodeFailure(
          line(
            frame('unavailable', 0, {
              'session': 's',
              'reason': 'x',
              'since_ms': 'now',
            }),
          ),
        ).code,
        ObserverProtocolErrorCode.malformed,
      );
      // Error messages are untrusted and bounded rather than rejected.
      final frames = ObserverFrameDecoder().add(
        utf8.encode(
          line(frame('error', 0, {'code': 'x', 'message': 'm' * 5000})),
        ),
      );
      expect(
        (frames.single as ErrorFrame).message.length,
        lessThanOrEqualTo(256),
      );
    });
  });

  group('stream adapter', () {
    test('decodeObserverFrames yields frames then a protocol error', () async {
      final controller = StreamController<List<int>>();
      final events = <Object>[];
      final done = Completer<void>();
      decodeObserverFrames(controller.stream).listen(
        events.add,
        onError: (Object error) {
          events.add(error);
          done.complete();
        },
      );
      controller
        ..add(utf8.encode(line(hello(0))))
        ..add(utf8.encode('garbage\n'))
        ..add(utf8.encode(line(hello(1))));
      await done.future;
      expect(events.first, isA<HelloFrame>());
      expect(events.last, isA<ObserverProtocolException>());
      expect(events, hasLength(2));
      await controller.close();
    });

    test('decodeObserverFrames yields earlier frames of a bad chunk', () async {
      final events = <Object>[];
      final done = Completer<void>();
      decodeObserverFrames(
        Stream.value(utf8.encode('${line(hello(0))}garbage\n')),
      ).listen(events.add, onError: events.add, onDone: done.complete);
      await done.future;
      expect(events.first, isA<HelloFrame>());
      expect(events.last, isA<ObserverProtocolException>());
      expect(events, hasLength(2));
    });

    test('decodeObserverFrames reports truncation at end of stream', () async {
      final controller = StreamController<List<int>>();
      final failure = expectLater(
        decodeObserverFrames(controller.stream).toList(),
        throwsA(isA<ObserverProtocolException>()),
      );
      controller.add(utf8.encode(jsonEncode(hello(0))));
      await controller.close();
      await failure;
    });

    test('decodeObserverFrames completes cleanly at a line boundary', () async {
      final controller = StreamController<List<int>>();
      final result = decodeObserverFrames(controller.stream).toList();
      controller.add(utf8.encode(line(hello(0))));
      await controller.close();
      expect(await result, hasLength(1));
    });
  });
}
