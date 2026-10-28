/// Client-side presentation values decoded from the unchanged v1 status wire.
/// Missing optional fields retain the v1 defaults; unknown fields are ignored.
/// These values contain no transport, persistence, or model-runtime handles.
library;

Map<String, Object?> _map(Object? value) =>
    value == null ? const {} : Map<String, Object?>.from(value as Map);
String _text(Map<String, Object?> value, String key, [String fallback = '']) =>
    value[key] as String? ?? fallback;
bool _flag(Map<String, Object?> value, String key) => value[key] == true;
int _int(Map<String, Object?> value, String key) => value[key] as int? ?? 0;
List<T> _list<T>(Object? value, T Function(Object?) decode) =>
    List.unmodifiable((value as List? ?? const []).map(decode));
Map<String, T> _values<T>(Object? value, T Function(Object?) decode) =>
    Map.unmodifiable(
      _map(value).map((key, item) => MapEntry(key, decode(item))),
    );

/// Structural equality lets selectors ignore newly decoded value-equal slices.
abstract base class _Presentation {
  List<Object?> get _fields;
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _Presentation &&
          runtimeType == other.runtimeType &&
          _equal(_fields, other._fields);
  @override
  int get hashCode => Object.hash(runtimeType, _hash(_fields));
}

bool _equal(Object? left, Object? right) {
  if (left is List && right is List) {
    return left.length == right.length &&
        Iterable<int>.generate(
          left.length,
        ).every((i) => _equal(left[i], right[i]));
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _equal(left[key], right[key]),
        );
  }
  return left == right;
}

int _hash(Object? value) => switch (value) {
  List() => Object.hashAll(value.map(_hash)),
  Map() => Object.hashAllUnordered(
    value.entries.map((entry) => Object.hash(entry.key, _hash(entry.value))),
  ),
  _ => value.hashCode,
};

final class EchoCancellationPresentation extends _Presentation {
  EchoCancellationPresentation.fromWire(Object? wire) : this._(_map(wire));
  EchoCancellationPresentation._(Map<String, Object?> value)
    : requested = _flag(value, 'requested'),
      active = _flag(value, 'active'),
      pending = _flag(value, 'pending'),
      restartRequired = _flag(value, 'restart_required'),
      fallbackStatus = _int(value, 'fallback_status'),
      fallbackReason = _text(value, 'fallback_reason'),
      supported = value['supported'] as bool?;
  final bool requested, active, pending, restartRequired;
  final int fallbackStatus;
  final String fallbackReason;
  final bool? supported;
  @override
  List<Object?> get _fields => [
    requested,
    active,
    pending,
    restartRequired,
    fallbackStatus,
    fallbackReason,
    supported,
  ];
}

/// Shared Summary and workflow progress. Settled output is read from artifacts,
/// never accepted from a streamed preview.
final class MeetingRunPresentation extends _Presentation {
  MeetingRunPresentation.fromWire(Object? wire) : this._(_map(wire));
  MeetingRunPresentation._(Map<String, Object?> value)
    : phase = _text(value, 'phase'),
      preview = _text(value, 'preview'),
      error = _text(value, 'error'),
      completed = _int(value, 'completed'),
      total = _int(value, 'total'),
      active = _flag(value, 'active'),
      cancelled = _flag(value, 'cancelled');
  final String phase, preview, error;
  final int completed, total;
  final bool active, cancelled;
  @override
  List<Object?> get _fields => [
    phase,
    preview,
    error,
    completed,
    total,
    active,
    cancelled,
  ];
}

final class NoteEnhancementPresentation extends _Presentation {
  NoteEnhancementPresentation.fromWire(Object? wire) : this._(_map(wire));
  NoteEnhancementPresentation._(Map<String, Object?> value)
    : requestId = _text(value, 'request_id'),
      body = _text(value, 'body'),
      bodyProvided = value['body'] != null,
      status = _text(value, 'status'),
      active = _flag(value, 'active'),
      cancelRequested = _flag(value, 'cancel_requested'),
      activeIndex = value['active_index'] as int?;
  final String requestId, body, status;
  // Retain the legacy missing-body fallback separately from an empty preview.
  final bool active, cancelRequested, bodyProvided;
  final int? activeIndex;
  @override
  List<Object?> get _fields => [
    requestId,
    body,
    bodyProvided,
    status,
    active,
    cancelRequested,
    activeIndex,
  ];
}

final class QuestionDetectorPresentation extends _Presentation {
  QuestionDetectorPresentation.fromWire(Object? wire) : this._(_map(wire));
  QuestionDetectorPresentation._(Map<String, Object?> value)
    : configured = _flag(value, 'configured'),
      ready = _flag(value, 'ready'),
      backend = value['backend'] as String?,
      outputPolicy = _text(value, 'output_policy');
  final bool configured, ready;
  final String? backend;
  final String outputPolicy;
  @override
  List<Object?> get _fields => [configured, ready, backend, outputPolicy];
}

final class ProactivePresentation extends _Presentation {
  ProactivePresentation.fromWire(Object? wire) : this._(_map(wire));
  ProactivePresentation._(Map<String, Object?> value)
    : enabled = _flag(value, 'enabled'),
      running = _flag(value, 'running'),
      activeMeeting = value['active_meeting'] as int?,
      pendingMeetings = _list(value['pending_meetings'], (item) => item as int),
      errors = _values(value['errors'], (item) => item as String),
      queuedAnswers = _int(value, 'queued_answers'),
      oldestQueueAgeMs = _int(value, 'oldest_queue_age_ms'),
      stage = _text(value, 'stage', 'idle');
  final bool enabled, running;
  final int? activeMeeting;
  final List<int> pendingMeetings;
  final Map<String, String> errors;
  final int queuedAnswers, oldestQueueAgeMs;
  final String stage;
  @override
  List<Object?> get _fields => [
    enabled,
    running,
    activeMeeting,
    pendingMeetings,
    errors,
    queuedAnswers,
    oldestQueueAgeMs,
    stage,
  ];
}

final class CapturePresentation extends _Presentation {
  CapturePresentation.fromWire(Object? wire) : this._(_map(wire));
  CapturePresentation._(Map<String, Object?> value)
    : meetingId = value['meeting_id'] as int?,
      active = _flag(value, 'active'),
      finishing = _flag(value, 'finishing'),
      paused = _flag(value, 'paused'),
      beganMilliseconds = value['began'] as int?,
      elapsedMilliseconds = _int(value, 'elapsed_ms'),
      elapsedMillisecondsProvided = value['elapsed_ms'] != null,
      state = _text(value, 'state', 'idle'),
      error = _text(value, 'error'),
      samples = _list(value['samples'], (item) => item as int),
      peaks = _list(value['peaks'], (item) => (item as num).toDouble()),
      volumes = _list(value['volumes'], (item) => (item as num).toDouble()),
      lastAudioMilliseconds = value['last_audio'] as int?,
      provisional = _values(value['provisional'], (item) => item as String),
      echoCancellation = EchoCancellationPresentation.fromWire(
        value['echo_cancellation'],
      ),
      proactive = ProactivePresentation.fromWire(value['proactive']),
      questionDetector = QuestionDetectorPresentation.fromWire(
        value['question_detector'],
      ),
      summaries = _values(
        value['meeting_summaries'],
        MeetingRunPresentation.fromWire,
      ),
      workflows = _values(
        value['meeting_workflows'],
        MeetingRunPresentation.fromWire,
      ),
      noteEnhancements = _values(
        value['note_enhancements'],
        NoteEnhancementPresentation.fromWire,
      );
  final int? meetingId, beganMilliseconds, lastAudioMilliseconds;
  // Missing elapsed time uses the consumer's began-time fallback; zero does not.
  final bool active, finishing, paused, elapsedMillisecondsProvided;
  final int elapsedMilliseconds;
  final String state, error;
  final List<int> samples;
  final List<double> peaks, volumes;
  final Map<String, String> provisional;
  final EchoCancellationPresentation echoCancellation;
  final ProactivePresentation proactive;
  final QuestionDetectorPresentation questionDetector;
  final Map<String, MeetingRunPresentation> summaries, workflows;
  final Map<String, NoteEnhancementPresentation> noteEnhancements;

  MeetingRunPresentation? summary(int meeting) => summaries['$meeting'];
  MeetingRunPresentation? workflow(int meeting, String kind) =>
      workflows['$meeting:$kind'];
  NoteEnhancementPresentation? noteEnhancement(int meeting) =>
      noteEnhancements['$meeting'];
  @override
  List<Object?> get _fields => [
    meetingId,
    beganMilliseconds,
    lastAudioMilliseconds,
    active,
    finishing,
    paused,
    elapsedMilliseconds,
    elapsedMillisecondsProvided,
    state,
    error,
    samples,
    peaks,
    volumes,
    provisional,
    echoCancellation,
    proactive,
    questionDetector,
    summaries,
    workflows,
    noteEnhancements,
  ];
}

final class GoogleAccountPresentation extends _Presentation {
  GoogleAccountPresentation({
    required this.id,
    this.email = '',
    this.displayName = '',
    this.photoUrl = '',
    this.current = false,
  });
  GoogleAccountPresentation.fromWire(Object? wire) : this._(_map(wire));
  GoogleAccountPresentation._(Map<String, Object?> value)
    : id = _text(value, 'id'),
      email = _text(value, 'email'),
      displayName = _text(value, 'displayName'),
      photoUrl = _text(value, 'photoUrl'),
      current = _flag(value, 'current');
  final String id, email, displayName, photoUrl;
  final bool current;
  @override
  List<Object?> get _fields => [id, email, displayName, photoUrl, current];
}

final class GooglePresentation extends _Presentation {
  GooglePresentation.fromWire(Object? wire) : this._(_map(wire));
  GooglePresentation._(Map<String, Object?> value)
    : connected = _flag(value, 'connected'),
      syncing = _flag(value, 'syncing'),
      configured = _flag(value, 'configured'),
      signingIn = _flag(value, 'signingIn'),
      driveAvailable = value['driveAvailable'] != false,
      email = _text(value, 'email'),
      displayName = _text(value, 'displayName'),
      photoUrl = _text(value, 'photoUrl'),
      account = _text(value, 'account'),
      provider = _text(value, 'provider', 'google'),
      loadError = _text(value, 'loadError'),
      lastRefreshMilliseconds = _int(value, 'lastRefresh'),
      accounts = _list(value['accounts'], GoogleAccountPresentation.fromWire);
  final bool connected, syncing, configured, signingIn, driveAvailable;
  final String email, displayName, photoUrl, account, provider, loadError;
  final int lastRefreshMilliseconds;
  final List<GoogleAccountPresentation> accounts;
  @override
  List<Object?> get _fields => [
    connected,
    syncing,
    configured,
    signingIn,
    driveAvailable,
    email,
    displayName,
    photoUrl,
    account,
    provider,
    loadError,
    lastRefreshMilliseconds,
    accounts,
  ];
}

final class GenerationPresentation extends _Presentation {
  GenerationPresentation.fromWire(Object? wire, {bool? generating})
    : this._(_map(wire), generating: generating);
  GenerationPresentation._(Map<String, Object?> value, {bool? generating})
    : state = _text(value, 'state', 'unconfigured'),
      error = _text(value, 'error'),
      backend = _text(value, 'backend'),
      loadPolicy = _text(value, 'load_policy'),
      json = _text(value, 'json'),
      generating = generating ?? _flag(value, 'generating'),
      tools = value['tools'] as bool?,
      text = value['text'] as bool?,
      thinking = value['thinking'] as bool?,
      nativeStopTokenSequences = value['native_stop_token_sequences'] as bool?,
      contextLength = value['context_length'] as int?,
      maxOutputTokens = value['max_output_tokens'] as int?,
      temperature = (value['temperature'] as num?)?.toDouble(),
      topK = value['top_k'] as int?,
      topP = (value['top_p'] as num?)?.toDouble(),
      diagnosticText = value.toString();
  final String state, error, backend, loadPolicy, json;
  final bool generating;
  final bool? tools, text, thinking, nativeStopTokenSequences;
  final String diagnosticText;
  final int? contextLength, maxOutputTokens, topK;
  final double? temperature, topP;
  @override
  List<Object?> get _fields => [
    state,
    error,
    backend,
    loadPolicy,
    json,
    generating,
    tools,
    text,
    thinking,
    nativeStopTokenSequences,
    contextLength,
    maxOutputTokens,
    topK,
    temperature,
    topP,
    diagnosticText,
  ];
}
