import 'dart:async';
import 'package:foresight_core/desktop.dart';
import '../../feature_request_identity.dart';

/// Service-owned media reads retain feature/session/epoch fences. The desktop
/// SQLite worker continues to own text queries, never media-root authority.
final class MeetingAudioReadModel {
  MeetingAudioReadModel({required this.connection, required this.changed});
  final DesktopConnection Function() connection;
  final void Function() changed;
  final _pages = <String, AudioMeetingReadPage>{};
  int? _meetingId;
  int _generation = 0;
  bool _closed = false, _reading = false, _dirty = false, _moreQueued = false;
  String? problem;
  AudioMeetingReadPage? get page => _pages[''];
  List<AudioSessionPresentation> get sessions {
    final values = <String, AudioSessionPresentation>{
      for (final page in _pages.values)
        for (final session in page.sessions) session.id: session,
    };
    final result = values.values.toList()
      ..sort((a, b) {
        final order = a.startedWallMs.compareTo(b.startedWallMs);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    return List.unmodifiable(result);
  }

  String? get nextAfterId =>
      _pages.isEmpty ? null : _pages.values.last.nextAfterId;
  bool get loading => _reading;

  void bind(int? meetingId) {
    _generation++;
    _meetingId = meetingId;
    _pages.clear();
    problem = null;
    _dirty = false;
    _moreQueued = false;
    if (meetingId != null) unawaited(refresh());
  }

  void select(int? meetingId) {
    if (meetingId != _meetingId) bind(meetingId);
  }

  Future<void> loadMore() => refresh(more: true);
  Future<void> refresh({bool more = false}) async {
    if (_closed || _meetingId == null) return;
    if (_reading) {
      if (more) {
        _moreQueued = true;
      } else {
        _dirty = true;
      }
      return;
    }
    _reading = true;
    final generation = _generation, id = _meetingId!;
    FeatureRequestIdentity identity;
    try {
      identity = FeatureRequestIdentity.capture(connection());
    } catch (_) {
      _reading = false;
      return;
    }
    bool current() =>
        !_closed &&
        generation == _generation &&
        id == _meetingId &&
        identity.isCurrent(connection(), alive: true);
    final keys = more
        ? (nextAfterId == null ? <String>[] : [nextAfterId!])
        : (_pages.isEmpty ? [''] : _pages.keys.toList());
    try {
      for (final after in keys) {
        final result = await recordingsReadDescriptor.sendCurrent(
          connection(),
          RecordingsReadInput(
            meetingId: id,
            afterSessionId: after,
            envelope: ClientEnvelope(
              workspaceEpoch: WireField(identity.workspaceEpoch),
            ),
          ),
          current,
        );
        if (!current()) return;
        _pages[after] = result;
        problem = null;
      }
      if (current()) changed();
    } catch (_) {
      if (current()) {
        problem = 'Recording audio could not be loaded.';
        changed();
      }
    } finally {
      _reading = false;
      if (_dirty && !_closed) {
        _dirty = false;
        unawaited(refresh());
      } else if (_moreQueued && !_closed) {
        _moreQueued = false;
        unawaited(refresh(more: true));
      }
    }
  }

  void dispose() {
    _closed = true;
    _generation++;
    _pages.clear();
  }
}
