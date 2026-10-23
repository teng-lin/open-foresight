import 'dart:async';

import 'package:foresight_core/desktop.dart';

import '../../feature_request_identity.dart';

/// Stats owns one period query. StoreReader owns revision invalidation and
/// actual worker settlement; widget builders only inspect the prepared value.
class SettingsStatsModel {
  SettingsStatsModel({
    required this.connection,
    required this.changed,
    DateTime Function()? clock,
    OutputStatsPeriod Function(DateTime)? capture,
    Timer Function(Duration, void Function())? schedule,
  }) : clock = clock ?? DateTime.now,
       capture = capture ?? OutputStatsPeriod.capture,
       schedule = schedule ?? Timer.new;

  static const clockRecheck = Duration(seconds: 30);
  final DesktopConnection Function() connection;
  final void Function() changed;
  final DateTime Function() clock;
  final OutputStatsPeriod Function(DateTime) capture;
  final Timer Function(Duration, void Function()) schedule;
  OutputStats? value;
  OutputStatsPeriod? displayPeriod;
  OutputStatsPeriod? _period;
  String? problem;
  FeatureRequestIdentity? _identity;
  StreamSubscription<void>? _changes;
  StreamSubscription<ReadResult<OutputStats>>? _read;
  Timer? _weekTimer, _clockTimer;
  int _generation = 0;
  bool _disposed = false, _queued = false;
  String? get periodKey => _period?.key;

  void start() {
    if (_disposed || _changes != null) return;
    recheck();
    _changes = connection().changes.listen((_) => recheck());
    _armClock();
  }

  void _notify() {
    if (_disposed || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_disposed) changed();
    });
  }

  bool _owns(int generation) =>
      !_disposed &&
      generation == _generation &&
      (_identity?.isCurrent(connection(), alive: true) ?? false);

  /// Called on resume, bounded clock checks, and ordinary connection events.
  /// Same-owner data/status events preserve the existing scheduling entry.
  void recheck() {
    if (_disposed) return;
    final now = clock();
    final period = capture(now);
    final owner = connection();
    final sameOwner = _identity?.isCurrent(owner, alive: true) ?? false;
    if (sameOwner && _period?.key == period.key) return;
    final generation = ++_generation;
    unawaited(_read?.cancel());
    _read = null;
    _identity = null;
    _period = period;
    if (!sameOwner) {
      value = null;
      displayPeriod = period;
    }
    problem = null;
    _armWeek(now);
    try {
      _identity = FeatureRequestIdentity.capture(owner);
      _read = owner.store
          .watch(
            StoreReadQueries.outputStatsForPeriod(period: period, clock: clock),
          )
          .listen(
            (result) {
              if (!_owns(generation)) return;
              recheck();
              if (!_owns(generation)) return;
              // A dispatch can observe a new calendar before a timer does.
              // Re-evaluate every failure rather than matching error wording.
              if (result.error != null ||
                  result.freshness == ReadFreshness.failed) {
                problem = result.error?.toString() ?? 'Stats read failed';
                recheck();
                return;
              }
              final stats = result.value;
              if (stats == null ||
                  !(result.current ||
                      result.freshness == ReadFreshness.preview) ||
                  (stats.period != null && stats.period!.key != period.key))
                return;
              value = stats;
              displayPeriod = period;
              problem = null;
              _notify();
            },
            onError: (Object error) {
              if (!_owns(generation)) return;
              problem = error.toString();
              recheck();
            },
          );
    } catch (error) {
      problem = error.toString();
    }
    _notify();
  }

  void _armWeek(DateTime now) {
    _weekTimer?.cancel();
    final milliseconds =
        _period!.nextWeekMilliseconds - now.millisecondsSinceEpoch;
    // A backwards clock or an early timer re-arms against the calendar. A
    // malformed/expired boundary cannot create a zero-delay spin.
    final delay = Duration(milliseconds: milliseconds > 0 ? milliseconds : 1);
    _weekTimer = schedule(delay, () {
      if (_disposed) return;
      recheck();
      _armWeek(clock());
    });
  }

  void _armClock() {
    _clockTimer?.cancel();
    _clockTimer = schedule(clockRecheck, () {
      if (_disposed) return;
      recheck();
      _armClock();
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _weekTimer?.cancel();
    _clockTimer?.cancel();
    await Future.wait([
      if (_changes != null) _changes!.cancel(),
      if (_read != null) _read!.cancel(),
    ]);
  }
}
