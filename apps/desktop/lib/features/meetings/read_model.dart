import 'dart:async';
import 'audio_read_model.dart';

import 'package:foresight_core/desktop.dart';

import '../../feature_request_identity.dart';

/// Feature-owned queries. Revisions invalidate the existing reader entries;
/// only owner/selection changes add or retire subscriptions.
class MeetingReadModel {
  MeetingReadModel({
    required this.connection,
    required this.changed,
    this.currentPreference,
  });
  final DesktopConnection Function() connection;
  late final MeetingAudioReadModel audio = MeetingAudioReadModel(
    connection: connection,
    changed: _notify,
  );
  final void Function() changed;
  final void Function(String key, String value)? currentPreference;
  static const defaults = {
    'proactiveAnswers': 'true',
    'liveEnhance': 'true',
    'noteStyle': 'Standard',
    'audio.systemSetupReviewed': 'false',
  };
  final _slots = <String, _Slot>{};
  StreamSubscription<void>? _changes;
  FeatureRequestIdentity? _identity;

  /// Captured while binding the read owner, before any widget is constructed.
  /// Retained callbacks still validate its durable epoch before acting.
  FeatureRequestIdentity? get presentationIdentity => _identity;
  int? _selected, _preview;
  int _generation = 0;
  bool _disposed = false,
      _started = false,
      _queued = false,
      _syncQueued = false;
  String? problem;

  List<MeetingCollectionEntry> get meetings =>
      _value(StoreReadQueries.meetings()) ?? const [];
  ModelRegistration? get speech => _current(StoreReadQueries.model('speech'))
      ? _value<ModelRegistration?>(StoreReadQueries.model('speech'))
      : null;
  // Same-owner previews remain display state while a newer read is pending.
  // Recording admission still requires its separate current setup read.
  ModelRegistration? get presentedSpeech =>
      _value<ModelRegistration?>(StoreReadQueries.model('speech'));
  MeetingDetails? meeting(int id, {bool preview = false}) =>
      _value<MeetingDetails?>(StoreReadQueries.meeting(id, preview: preview));
  bool meetingLoaded(int id, {bool preview = false}) =>
      _current(StoreReadQueries.meeting(id, preview: preview));
  MeetingNoteData? note(int id) =>
      _value<MeetingNoteData?>(StoreReadQueries.meetingNote(id));
  bool noteLoaded(int id) => _current(StoreReadQueries.meetingNote(id));
  bool enhancedLoaded(int id) => _current(StoreReadQueries.enhancedNotes(id));
  String enhanced(int id) => _value(StoreReadQueries.enhancedNotes(id)) ?? '';
  List<TranscriptSegment> transcript(int id) =>
      _value(StoreReadQueries.transcript(id)) ?? const [];
  List<MeetingQuestion> questions(int id) =>
      _value(StoreReadQueries.questions(id)) ?? const [];
  List<MeetingTask> tasks(int id) =>
      _value(StoreReadQueries.tasks(id)) ?? const [];
  List<MeetingArtifact> artifacts(int id, String kind) =>
      _value(StoreReadQueries.artifacts(id, kind)) ?? const [];
  List<CalendarAttachment> attachments(int id) =>
      _value(StoreReadQueries.attachments(id)) ?? const [];
  int? revision(int id) => _value<int?>(StoreReadQueries.meetingRevision(id));
  String preference(String key, [String fallback = '']) =>
      _value(StoreReadQueries.preference(key, defaults[key] ?? fallback)) ??
      defaults[key] ??
      fallback;

  T? _value<T>(ReadQuery<T> query) => _slots[query.key]?.value as T?;
  bool _current<T>(ReadQuery<T> query) => _slots[query.key]?.current ?? false;
  bool _owns(int generation) =>
      !_disposed &&
      generation == _generation &&
      (_identity?.isCurrent(connection(), alive: true) ?? false);

  void start({int? selected, int? preview}) {
    if (_disposed || _started) return;
    _started = true;
    _selected = selected;
    _preview = preview;
    _bind();
    _changes = connection().changes.listen((_) {
      if (!(_identity?.isCurrent(connection(), alive: true) ?? false)) {
        _bind();
      } else {
        unawaited(audio.refresh());
      }
    });
  }

  void select(int? selected, int? preview) {
    if (_disposed || (_selected == selected && _preview == preview)) return;
    _selected = selected;
    _preview = preview;
    if (_started) _queueSync();
  }

  void reconcile() {
    if (!_disposed &&
        _started &&
        !(_identity?.isCurrent(connection(), alive: true) ?? false))
      _bind();
  }

  void _bind() {
    _generation++;
    _identity = null;
    audio.bind(null);
    for (final slot in _slots.values) {
      unawaited(slot.subscription?.cancel());
    }
    _slots.clear();
    problem = null;
    try {
      _identity = FeatureRequestIdentity.capture(connection());
      _syncQueries();
    } catch (error) {
      problem = error.toString();
    }
    _notify();
  }

  void _queueSync() {
    if (_syncQueued || _disposed) return;
    _syncQueued = true;
    scheduleMicrotask(() {
      _syncQueued = false;
      if (!_disposed) _syncQueries();
    });
  }

  void _syncQueries() {
    if (_disposed || _identity == null) return;
    final queries = <ReadQuery<Object?>>[
      StoreReadQueries.meetings(),
      StoreReadQueries.model('speech'),
      for (final entry in defaults.entries)
        StoreReadQueries.preference(entry.key, entry.value),
    ];
    final id = _selected ?? _preview;
    audio.select(id);
    if (id != null) {
      queries.addAll([
        StoreReadQueries.meeting(id),
        StoreReadQueries.meeting(id, preview: true),
        StoreReadQueries.meetingNote(id),
        StoreReadQueries.enhancedNotes(id),
        StoreReadQueries.transcript(id),
        StoreReadQueries.questions(id),
        StoreReadQueries.tasks(id),
        StoreReadQueries.meetingRevision(id),
        for (final kind in [
          'summary',
          'actions',
          'preparation',
          'enhanced_notes',
        ])
          StoreReadQueries.artifacts(id, kind),
        StoreReadQueries.preference('proactiveScope.$id', 'meeting'),
        StoreReadQueries.preference('answerScope.meeting:$id', 'workspace'),
      ]);
    }
    final attachmentIds = {
      for (final meeting in meetings) meeting.id,
      if (id != null) id,
    };
    queries.addAll([
      for (final id in attachmentIds) StoreReadQueries.attachments(id),
    ]);
    final wanted = {for (final query in queries) query.key};
    for (final key
        in _slots.keys.where((key) => !wanted.contains(key)).toList()) {
      unawaited(_slots.remove(key)!.subscription?.cancel());
    }
    for (final query in queries) {
      if (!_slots.containsKey(query.key)) _watch(query);
    }
  }

  void _watch(ReadQuery<Object?> query) {
    final generation = _generation, slot = _Slot();
    if (query.projection == 'preference') {
      slot.value = query.arguments['fallback'];
      slot.fields = slot.value;
    } else if (const [
      'meetings',
      'transcript',
      'questions',
      'tasks',
      'artifacts',
      'attachments',
    ].contains(query.projection)) {
      slot.fields = const [];
    }
    _slots[query.key] = slot;
    bool current() => _owns(generation) && identical(_slots[query.key], slot);
    try {
      slot.subscription = connection().store
          .watch(query)
          .listen(
            (result) {
              if (!current()) return;
              final readinessChanged =
                  slot.current != result.current &&
                  (const [
                        'meeting',
                        'meeting_preview',
                        'meeting_note',
                        'enhanced_notes',
                      ].contains(query.projection) ||
                      (query.projection == 'model' &&
                          (slot.value != null || result.value != null)));
              slot.current = result.current;
              final accepted =
                  result.current || result.freshness == ReadFreshness.preview;
              final nextFields = accepted ? _fields(result.value) : slot.fields;
              final valueChanged = accepted && !_equal(slot.fields, nextFields);
              if (valueChanged) {
                slot.value = result.value;
                slot.fields = nextFields;
              }
              if (result.current &&
                  query.projection == 'preference' &&
                  result.value is String) {
                currentPreference?.call(
                  query.arguments['key'] as String,
                  result.value as String,
                );
              }
              final error = result.error?.toString();
              final errorChanged = error != null && error != problem;
              if (error != null) problem = error;
              if (query.projection == 'meetings' && valueChanged) _queueSync();
              if (valueChanged || readinessChanged || errorChanged) _notify();
            },
            onError: (Object error) {
              if (!current()) return;
              final next = error.toString();
              if (problem == next) return;
              problem = next;
              _notify();
            },
          );
    } catch (error) {
      if (current()) {
        problem = error.toString();
        _notify();
      }
    }
  }

  void _notify() {
    if (_disposed || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_disposed) changed();
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    audio.dispose();
    _generation++;
    final closing = <Future<void>>[
      if (_changes != null) _changes!.cancel(),
      for (final slot in _slots.values)
        if (slot.subscription != null) slot.subscription!.cancel(),
    ];
    _slots.clear();
    await Future.wait(closing);
  }
}

class _Slot {
  // Cancelled by the read owner when its key retires or the owner disposes.
  // ignore: cancel_subscriptions
  StreamSubscription<ReadResult<Object?>>? subscription;
  Object? value, fields;
  bool current = false;
}

// Compare the immutable fields the feature actually presents, retaining equal
// snapshots without converting projections back to SQL rows or JSON payloads.
Object? _fields(Object? value) => switch (value) {
  List() => value.map(_fields).toList(),
  MeetingCollectionEntry() => [
    _details(value),
    value.reminder,
    value.hasTranscript,
    value.calendarStatus,
  ],
  MeetingDetails() => _details(value),
  ModelRegistration() => [
    value.kind,
    value.path,
    value.digest,
    value.runtime,
    value.backend,
    value.modelType,
  ],
  MeetingNoteData() => [
    value.meetingId,
    value.body,
    value.enhancedBody,
    value.revision,
    value.timestamp,
    value.lastManualEdit,
    value.lastEnhancedAt,
  ],
  TranscriptSegment() => [
    value.id,
    value.meetingId,
    value.text,
    value.finalSegment,
    value.startMs,
    value.endMs,
    value.source,
    value.participantId,
    value.participantName,
    value.attributionState,
    value.attributionMethod,
    value.attributionManual,
  ],
  MeetingQuestion() => [
    value.id,
    value.meetingId,
    value.transcriptId,
    value.question,
    value.normalized,
    value.state,
    value.answerId,
    value.error,
    value.created,
    value.body,
    value.citations.map(_fields).toList(),
  ],
  Citation() => [
    value.kind,
    value.documentId,
    value.revision,
    value.label,
    value.excerpt,
    value.url,
    value.title,
  ],
  MeetingTask() => [
    value.id,
    value.meetingId,
    value.key,
    value.task,
    value.owner,
    value.due,
    value.status,
    value.inputRevision,
    value.stale,
    value.manual,
    value.evidence.map((e) => [e.id, e.quote]).toList(),
  ],
  MeetingArtifact() => [
    value.id,
    value.meetingId,
    value.kind,
    value.generated,
    value.edited,
    value.model,
    value.inputRevision,
    value.promptVersion,
    value.created,
    value.manifest,
  ],
  CalendarAttachment() => [
    value.fileId,
    value.fileUrl,
    value.title,
    value.mimeType,
    value.iconLink,
  ],
  _ => value,
};
Object _details(MeetingDetails value) => [
  value.id,
  value.title,
  value.state,
  value.revision,
  value.created,
  value.starts,
  value.ends,
  value.durationMs,
];
bool _equal(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List)
    return left.length == right.length &&
        Iterable<int>.generate(
          left.length,
        ).every((i) => _equal(left[i], right[i]));
  if (left is Map && right is Map)
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _equal(left[key], right[key]),
        );
  return left == right;
}

/// Actions obtain a current projection; preview values remain display state.
Future<T> readCurrentMeeting<T>(StoreReader reader, ReadQuery<T> query) async {
  final result = await reader.read(query);
  if (result.error != null) throw result.error!;
  if (!result.current) {
    throw RpcError(
      RpcErrorCode.unavailable,
      'Meeting snapshot is refreshing; retry the action.',
    );
  }
  return result.value as T;
}

/// Recording admission retains its query through transient preview replies.
/// One overall budget bounds repeated invalidations; ownership is checked before
/// accepting any reply, independently of ordinary data revisions.
Future<T> readCurrentRecordingSetup<T>(
  StoreReader reader,
  ReadQuery<T> query, {
  required bool Function() current,
  required Iterable<Stream<void>> ownerChanges,
}) async {
  if (!current()) {
    throw RpcError(RpcErrorCode.cancelled, 'Recording action was superseded.');
  }
  final result = Completer<T>();
  final timer = Timer(const Duration(seconds: 30), () {
    if (!result.isCompleted) {
      result.completeError(
        RpcError(RpcErrorCode.unavailable, 'Recording setup read timed out.'),
      );
    }
  });
  StreamSubscription<ReadResult<T>>? subscription;
  final ownership = <StreamSubscription<void>>[];
  void checkOwner() {
    if (!result.isCompleted && !current()) {
      result.completeError(
        RpcError(RpcErrorCode.cancelled, 'Recording action was superseded.'),
      );
    }
  }

  try {
    for (final changes in ownerChanges) {
      ownership.add(changes.listen((_) => checkOwner(), onDone: checkOwner));
    }
    subscription = reader
        .watch(query)
        .listen(
          (reply) {
            if (result.isCompleted) return;
            if (!current()) {
              result.completeError(
                RpcError(
                  RpcErrorCode.cancelled,
                  'Recording action was superseded.',
                ),
              );
            } else if (reply.error != null) {
              result.completeError(reply.error!);
            } else if (reply.current) {
              result.complete(reply.value as T);
            } else if (reply.freshness == ReadFreshness.cancelled ||
                reply.freshness == ReadFreshness.failed) {
              result.completeError(
                RpcError(RpcErrorCode.cancelled, 'Recording setup read ended.'),
              );
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!result.isCompleted) result.completeError(error, stack);
          },
          onDone: () {
            if (!result.isCompleted) {
              result.completeError(
                RpcError(
                  RpcErrorCode.unavailable,
                  'Recording setup read closed.',
                ),
              );
            }
          },
        );
    return await result.future;
  } finally {
    timer.cancel();
    await subscription?.cancel();
    for (final observer in ownership) {
      await observer.cancel();
    }
  }
}
