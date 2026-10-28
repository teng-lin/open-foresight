/// Wire codec for the meeting speaker observer protocol; the contract is
/// docs/architecture/speaker-observer-protocol.md. The decoder is bounded and
/// strict: any violation poisons it so the owner closes the session. Errors
/// carry a stable code and a fixed message, never frame content.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'speaker_observation.dart';

const speakerObserverProtocolVersion = 1;
const speakerObserverMaxLineBytes = 262144;
const speakerObserverMaxParticipants = 256;
const speakerObserverMaxSpeakers = 256;
const speakerObserverMaxNameRunes = 256;
const _maxOpaqueLength = 128;
const _maxTokenLength = 64;
const _maxMessageRunes = 256;

/// Larger values cannot be multiplied to microseconds or round-tripped.
const _maxMs = 1 << 50;
const _minPollMs = 50, _maxPollMs = 60000, _maxDeadlineMs = 600000;

enum ObserverProtocolErrorCode {
  malformed,
  unknownType,
  unsupportedVersion,
  sequence,
  lineTooLong,
  truncated,
  limit,
}

final class ObserverProtocolException implements Exception {
  const ObserverProtocolException(this.code, this.message);
  final ObserverProtocolErrorCode code;

  /// A fixed description. It never includes any received bytes.
  final String message;

  @override
  String toString() => 'ObserverProtocolException(${code.name}): $message';
}

// Requests (service to helper).

sealed class ObserverRequest {
  const ObserverRequest(this.id);
  final String id;
  String get type;
  Map<String, Object?> get fields => const {};
}

final class CapabilitiesRequest extends ObserverRequest {
  const CapabilitiesRequest(super.id);
  @override
  String get type => 'capabilities';
}

final class SetupRequest extends ObserverRequest {
  const SetupRequest(super.id);
  @override
  String get type => 'setup';
}

final class StartRequest extends ObserverRequest {
  const StartRequest({
    required String id,
    required this.session,
    required this.pollMs,
    required this.deadlineMs,
  }) : super(id);
  final String session;
  final int pollMs, deadlineMs;
  @override
  String get type => 'start';
  @override
  Map<String, Object?> get fields => {
    'session': session,
    'poll_ms': pollMs,
    'deadline_ms': deadlineMs,
  };
}

final class StopRequest extends ObserverRequest {
  const StopRequest(super.id);
  @override
  String get type => 'stop';
}

final class ClockRequest extends ObserverRequest {
  const ClockRequest(super.id);
  @override
  String get type => 'clock';
}

// Frames (helper to service).

sealed class ObserverFrame {
  const ObserverFrame(this.seq);
  final int seq;
}

final class HelloFrame extends ObserverFrame {
  const HelloFrame(
    super.seq, {
    required this.helper,
    required this.helperVersion,
    required this.parserVersion,
    required this.platform,
  });
  final String helper, helperVersion, parserVersion, platform;
}

final class CapabilitiesFrame extends ObserverFrame {
  const CapabilitiesFrame(
    super.seq, {
    required this.id,
    required this.state,
    required this.reason,
    this.zoomVersion,
    this.locale,
  });
  final String id, reason;
  final ObserverAvailability state;
  final String? zoomVersion, locale;
}

final class StartedFrame extends ObserverFrame {
  const StartedFrame(
    super.seq, {
    required this.id,
    required this.session,
    required this.target,
  });
  final String id, session;
  final ObservationTarget target;
}

final class ObservationFrame extends ObserverFrame {
  const ObservationFrame(super.seq, this.observation);
  final SpeakerObservation observation;
}

final class UnavailableFrame extends ObserverFrame {
  const UnavailableFrame(
    super.seq, {
    required this.session,
    required this.reason,
    required this.sinceUs,
  });
  final String session, reason;
  final int sinceUs;
}

final class ClockFrame extends ObserverFrame {
  const ClockFrame(super.seq, {required this.id, required this.monotonicUs});
  final String id;
  final int monotonicUs;
}

final class ErrorFrame extends ObserverFrame {
  const ErrorFrame(
    super.seq, {
    required this.code,
    required this.message,
    this.id,
  });
  final String? id;
  final String code;

  /// Untrusted helper text, sanitized and bounded. Do not log it by default.
  final String message;
}

final class StoppedFrame extends ObserverFrame {
  const StoppedFrame(super.seq, {required this.id, this.session});
  final String id;

  /// The session the stopped `start` belonged to; null when `stop` arrived
  /// before any `start` was accepted.
  final String? session;
}

// Encoding.

final class ObserverFrameEncoder {
  ObserverFrameEncoder({this.maxLineBytes = speakerObserverMaxLineBytes});
  final int maxLineBytes;
  int _seq = 0;
  int get nextSeq => _seq;

  /// One UTF-8 JSON line. A rejected request does not consume a sequence number.
  List<int> encode(ObserverRequest request) {
    _requireOpaque(request.id, 'request id');
    if (request case StartRequest start) {
      _requireOpaque(start.session, 'session');
      if (start.pollMs < _minPollMs || start.pollMs > _maxPollMs) {
        throw ArgumentError.value(start.pollMs, 'pollMs', 'out of range');
      }
      if (start.deadlineMs < 1 || start.deadlineMs > _maxDeadlineMs) {
        throw ArgumentError.value(
          start.deadlineMs,
          'deadlineMs',
          'out of range',
        );
      }
    }
    final bytes = utf8.encode(
      jsonEncode({
        'v': speakerObserverProtocolVersion,
        'type': request.type,
        'seq': _seq,
        'id': request.id,
        ...request.fields,
      }),
    );
    if (bytes.length > maxLineBytes) {
      throw ArgumentError('Request exceeds the protocol line limit');
    }
    _seq++;
    return [...bytes, 0x0a];
  }

  static void _requireOpaque(String value, String name) {
    if (!_isOpaque(value)) throw ArgumentError.value(name, name, 'invalid');
  }
}

bool _isOpaque(String value) {
  if (value.isEmpty || value.length > _maxOpaqueLength) return false;
  for (final unit in value.codeUnits) {
    if (_isControl(unit)) return false;
  }
  return true;
}

bool _isControl(int unit) =>
    unit < 0x20 ||
    (unit >= 0x7f && unit <= 0x9f) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    (unit >= 0x202a && unit <= 0x202e) ||
    (unit >= 0x2066 && unit <= 0x2069) ||
    unit == 0x200e ||
    unit == 0x200f ||
    unit == 0x061c;

final _token = RegExp(r'^[A-Za-z0-9_.:\-]{1,64}$');

// Decoding.

/// Incremental decoder. Memory is bounded by [maxLineBytes] plus one chunk.
final class ObserverFrameDecoder {
  ObserverFrameDecoder({this.maxLineBytes = speakerObserverMaxLineBytes});
  final int maxLineBytes;
  final BytesBuilder _line = BytesBuilder(copy: false);
  int _expectedSeq = 0;
  bool _failed = false;
  ObserverProtocolException? _deferred;

  int get expectedSeq => _expectedSeq;
  bool get failed => _failed;

  /// Returns every complete frame in [chunk]. A violation throws once and every
  /// later call rethrows, so frames following a bad frame are never delivered.
  List<ObserverFrame> add(List<int> chunk) {
    _requireHealthy();
    final frames = <ObserverFrame>[];
    try {
      var start = 0;
      while (start < chunk.length) {
        final newline = chunk.indexOf(0x0a, start);
        final end = newline < 0 ? chunk.length : newline;
        if (_line.length + (end - start) > maxLineBytes) {
          throw const ObserverProtocolException(
            ObserverProtocolErrorCode.lineTooLong,
            'Observer line exceeds the protocol limit',
          );
        }
        _line.add(
          chunk is Uint8List
              ? Uint8List.sublistView(chunk, start, end)
              : chunk.sublist(start, end),
        );
        if (newline < 0) break;
        frames.add(_decodeLine(_line.takeBytes()));
        start = newline + 1;
      }
    } on ObserverProtocolException catch (error) {
      _failed = true;
      // Frames decoded ahead of the violation are valid and are delivered
      // first; the violation surfaces on the next call.
      if (frames.isEmpty) rethrow;
      _deferred = error;
    }
    return frames;
  }

  /// End of input. A pending unterminated line means the helper was cut off.
  void close() {
    _requireHealthy();
    if (_line.isNotEmpty) {
      _failed = true;
      throw const ObserverProtocolException(
        ObserverProtocolErrorCode.truncated,
        'Observer stream ended inside a frame',
      );
    }
  }

  /// Throws a violation deferred behind already delivered frames, if any.
  void throwIfFailed() => _requireHealthy();

  void _requireHealthy() {
    final deferred = _deferred;
    if (deferred != null) {
      _deferred = null;
      throw deferred;
    }
    if (_failed) {
      throw const ObserverProtocolException(
        ObserverProtocolErrorCode.malformed,
        'Observer decoder already failed',
      );
    }
  }

  ObserverFrame _decodeLine(Uint8List bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw _malformed('Observer frame is not valid UTF-8 JSON');
    }
    if (json is! Map<String, dynamic>) {
      throw _malformed('Observer frame is not an object');
    }
    final version = json['v'];
    if (version != speakerObserverProtocolVersion) {
      throw const ObserverProtocolException(
        ObserverProtocolErrorCode.unsupportedVersion,
        'Unsupported observer protocol version',
      );
    }
    final type = json['type'];
    final seq = json['seq'];
    if (type is! String || seq is! int) {
      throw _malformed('Observer frame lacks type or sequence');
    }
    final frame = _FrameReader(json).frame(type, seq);
    if (seq != _expectedSeq) {
      throw const ObserverProtocolException(
        ObserverProtocolErrorCode.sequence,
        'Observer frame sequence gap or repeat',
      );
    }
    _expectedSeq++;
    return frame;
  }
}

/// Adapts a byte stream (a child's stdout) to frames. The stream ends with an
/// [ObserverProtocolException] on any violation or truncation.
Stream<ObserverFrame> decodeObserverFrames(
  Stream<List<int>> bytes, {
  int maxLineBytes = speakerObserverMaxLineBytes,
}) async* {
  final decoder = ObserverFrameDecoder(maxLineBytes: maxLineBytes);
  await for (final chunk in bytes) {
    for (final frame in decoder.add(chunk)) {
      yield frame;
    }
    decoder.throwIfFailed();
  }
  decoder.close();
}

ObserverProtocolException _malformed(String message) =>
    ObserverProtocolException(ObserverProtocolErrorCode.malformed, message);

ObserverProtocolException _limit(String message) =>
    ObserverProtocolException(ObserverProtocolErrorCode.limit, message);

final class _FrameReader {
  _FrameReader(this.json);
  final Map<String, dynamic> json;

  ObserverFrame frame(String type, int seq) => switch (type) {
    'hello' => HelloFrame(
      seq,
      helper: _tokenField(json, 'helper'),
      helperVersion: _tokenField(json, 'helper_version'),
      parserVersion: _tokenField(json, 'parser_version'),
      platform: _tokenField(json, 'platform'),
    ),
    'capabilities' => CapabilitiesFrame(
      seq,
      id: _opaqueField(json, 'id'),
      state:
          ObserverAvailability.fromWire(json['state']) ??
          (throw _malformed('Unknown observer availability state')),
      reason: json['reason'] == null ? '' : _reasonField(json, 'reason'),
      zoomVersion: _optionalText(json, 'zoom_version'),
      locale: _optionalText(json, 'locale'),
    ),
    'started' => StartedFrame(
      seq,
      id: _opaqueField(json, 'id'),
      session: _opaqueField(json, 'session'),
      target: _target(json['target']),
    ),
    'observation' => ObservationFrame(seq, _observation(json)),
    'unavailable' => UnavailableFrame(
      seq,
      session: _opaqueField(json, 'session'),
      reason: json['reason'] == null ? '' : _reasonField(json, 'reason'),
      sinceUs: _msField(json, 'since_ms') * 1000,
    ),
    'clock' => ClockFrame(
      seq,
      id: _opaqueField(json, 'id'),
      monotonicUs: _msField(json, 'monotonic_ms') * 1000,
    ),
    'error' => ErrorFrame(
      seq,
      id: json['id'] == null ? null : _opaqueField(json, 'id'),
      code: _tokenField(json, 'code'),
      message: _boundedMessage(json['message']),
    ),
    'stopped' => StoppedFrame(
      seq,
      id: _opaqueField(json, 'id'),
      session: json['session'] == null ? null : _opaqueField(json, 'session'),
    ),
    _ => throw const ObserverProtocolException(
      ObserverProtocolErrorCode.unknownType,
      'Unknown observer frame type',
    ),
  };

  SpeakerObservation _observation(Map<String, dynamic> json) {
    final complete = json['complete'];
    if (complete is! bool) throw _malformed('Observation completeness invalid');
    final startMs = _msField(json, 'read_start_ms');
    final endMs = _msField(json, 'read_end_ms');
    if (endMs < startMs) throw _malformed('Observation read ends before start');
    final rawParticipants = json['participants'];
    final rawSpeakers = json['speakers'];
    if (rawParticipants is! List || rawSpeakers is! List) {
      throw _malformed('Observation lists invalid');
    }
    if (rawParticipants.length > speakerObserverMaxParticipants ||
        rawSpeakers.length > speakerObserverMaxSpeakers) {
      throw _limit('Observation exceeds the participant bound');
    }
    final participants = <ObservedParticipant>[];
    final refs = <String>{};
    for (final entry in rawParticipants) {
      if (entry is! Map<String, dynamic>) {
        throw _malformed('Participant is not an object');
      }
      final ref = _opaqueField(entry, 'ref');
      if (!refs.add(ref)) throw _malformed('Duplicate participant reference');
      final self = entry['self'];
      if (self != null && self is! bool) {
        throw _malformed('Participant self marker invalid');
      }
      participants.add(
        ObservedParticipant(
          ref: ref,
          name: _name(entry['name']),
          isSelf: self == true,
        ),
      );
    }
    final speakers = <SpeakerCandidate>[];
    final speakerRefs = <String>{};
    for (final entry in rawSpeakers) {
      if (entry is! Map<String, dynamic>) {
        throw _malformed('Speaker is not an object');
      }
      final ref = _opaqueField(entry, 'ref');
      if (!refs.contains(ref) || !speakerRefs.add(ref)) {
        throw _malformed('Speaker reference is not a unique roster entry');
      }
      speakers.add(
        SpeakerCandidate(
          ref: ref,
          method:
              SpeakerEvidenceMethod.fromWire(entry['method']) ??
              (throw _malformed('Unknown speaker evidence method')),
        ),
      );
    }
    return SpeakerObservation(
      session: _opaqueField(json, 'session'),
      readStartUs: startMs * 1000,
      readEndUs: endMs * 1000,
      target: _target(json['target']),
      complete: complete,
      parserVersion: _tokenField(json, 'parser_version'),
      participants: participants,
      speakers: speakers,
    );
  }
}

ObservationTarget _target(Object? value) {
  if (value is! Map<String, dynamic>) throw _malformed('Target invalid');
  final pid = value['pid'];
  if (pid is! int || pid < 0 || pid > 0xffffffff) {
    throw _malformed('Target process id invalid');
  }
  return ObservationTarget(
    pid: pid,
    window: _opaqueField(value, 'window'),
    zoomVersion: _optionalText(value, 'zoom_version'),
    locale: _optionalText(value, 'locale'),
  );
}

String _opaqueField(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !_isOpaque(value)) {
    throw _malformed('Observer identifier field invalid');
  }
  return value;
}

String _tokenField(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !_token.hasMatch(value)) {
    throw _malformed('Observer token field invalid');
  }
  return value;
}

/// A reason is a short stable token, or empty when none applies.
String _reasonField(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isEmpty) return '';
  return _tokenField(json, key);
}

String? _optionalText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty || value.length > _maxTokenLength) {
    throw _malformed('Observer text field invalid');
  }
  for (final unit in value.codeUnits) {
    if (_isControl(unit)) throw _malformed('Observer text field invalid');
  }
  return value;
}

int _msField(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0 || value >= _maxMs) {
    throw _malformed('Observer time field invalid');
  }
  return value;
}

/// Display names keep their spelling, including commas and punctuation. Control
/// and bidirectional-override characters are removed, line breaks become
/// spaces, and the result must be non-empty and bounded.
String _name(Object? value) {
  if (value is! String) throw _malformed('Participant name invalid');
  if (value.runes.length > speakerObserverMaxNameRunes * 2) {
    throw _limit('Participant name exceeds the length bound');
  }
  final text = _sanitize(value).trim();
  // Joiners survive inside names but are not a name by themselves.
  if (!hasVisibleNameCharacter(text)) {
    throw _malformed('Participant name empty');
  }
  if (text.runes.length > speakerObserverMaxNameRunes) {
    throw _limit('Participant name exceeds the length bound');
  }
  return text;
}

String _boundedMessage(Object? value) {
  if (value is! String) return '';
  final text = _sanitize(value).trim();
  final runes = text.runes;
  if (runes.length <= _maxMessageRunes) return text;
  return String.fromCharCodes(runes.take(_maxMessageRunes));
}

String _sanitize(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x09 || rune == 0x0a || rune == 0x0d || rune == 0x85) {
      out.write(' ');
    } else if (rune == 0x2028 || rune == 0x2029) {
      out.write(' ');
    } else if (_isControl(rune) || isStrippedNameRune(rune)) {
      continue;
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
