/// Service-side abstraction over a platform meeting-speaker helper. An observer
/// reports what is on screen; it never touches capture, speech processing or
/// persistence, and its failures never interrupt recording.
library;

import 'speaker_observation.dart';

/// What the helper reported about its ability to observe, without prompting.
final class ObserverCapabilities {
  const ObserverCapabilities({
    required this.state,
    this.reason = '',
    this.zoomVersion,
    this.locale,
    this.helper,
    this.helperVersion,
    this.parserVersion,
    this.platform,
  });
  final ObserverAvailability state;

  /// A short stable token, never user content.
  final String reason;
  final String? zoomVersion, locale;
  final String? helper, helperVersion, parserVersion, platform;

  bool get available => state == ObserverAvailability.available;
}

enum ObserverStatus { running, restarting, failed, stopped }

enum SpeakerObserverFailure {
  launchFailed,
  handshakeTimeout,
  requestTimeout,
  protocolError,
  helperError,
  helperExited,
  stalled,
  unavailable,
  shutdownTimeout,
  reapFailed,
  busy,
  cancelled,
}

/// Failure with a fixed description. It never includes helper-supplied text,
/// participant names or transcript content.
final class SpeakerObserverException implements Exception {
  const SpeakerObserverException(
    this.failure, {
    this.availability,
    this.helperCode,
  });
  final SpeakerObserverFailure failure;

  /// Set when [failure] is [SpeakerObserverFailure.unavailable].
  final ObserverAvailability? availability;

  /// Helper-supplied stable token for [SpeakerObserverFailure.helperError].
  final String? helperCode;

  @override
  String toString() => 'SpeakerObserverException(${failure.name})';
}

sealed class SpeakerObserverEvent {
  const SpeakerObserverEvent(this.epoch);

  /// Counts helper process starts within one session. References from different
  /// epochs are never equal (see [ObservationEvent]).
  final int epoch;
}

/// A read in the capture clock domain. Participant references are qualified as
/// `<epoch>:<ref>` so a restarted helper can never alias an earlier helper's
/// references; a rejoining or restarted participant is a new reference.
final class ObservationEvent extends SpeakerObserverEvent {
  const ObservationEvent(super.epoch, this.observation);
  final SpeakerObservation observation;
}

/// The helper could not observe the meeting from [sinceUs] (capture clock).
final class UnavailableEvent extends SpeakerObserverEvent {
  const UnavailableEvent(
    super.epoch, {
    required this.sinceUs,
    required this.reason,
  });
  final int sinceUs;
  final String reason;
}

/// Lifecycle change, stamped with the capture clock. A [restarting] or
/// [failed] status means observations stopped at [atUs]; consumers must treat
/// the time until the next observation as blind.
final class ObserverStateEvent extends SpeakerObserverEvent {
  const ObserverStateEvent(
    super.epoch, {
    required this.status,
    required this.atUs,
    required this.restartCount,
    this.failure,
  });
  final ObserverStatus status;
  final int atUs, restartCount;
  final SpeakerObserverFailure? failure;
}

abstract interface class MeetingSpeakerObserver {
  /// Events of the current session. A broadcast stream: events with no listener
  /// are dropped, so listen before [start].
  Stream<SpeakerObserverEvent> get events;

  /// Report availability. Must not prompt or change settings.
  Future<ObserverCapabilities> inspect();

  /// Explicit accessibility setup; may prompt and guide the user.
  Future<ObserverCapabilities> setup();

  /// Begin observing the selected meeting for recording [session]. Completes
  /// once the helper confirmed it is observing, or throws
  /// [SpeakerObserverException].
  Future<void> start(String session);

  /// Finish the interval and terminate and reap the helper within its deadline.
  Future<void> stop();

  /// [stop] and release the event stream. The observer is unusable afterwards.
  Future<void> dispose();
}

/// Observer for a platform without a helper. Recording is unaffected.
final class UnsupportedMeetingSpeakerObserver
    implements MeetingSpeakerObserver {
  const UnsupportedMeetingSpeakerObserver();
  static const _capabilities = ObserverCapabilities(
    state: ObserverAvailability.unsupportedPlatform,
    reason: 'no_helper',
  );

  @override
  Stream<SpeakerObserverEvent> get events => const Stream.empty();

  @override
  Future<ObserverCapabilities> inspect() async => _capabilities;

  @override
  Future<ObserverCapabilities> setup() async => _capabilities;

  @override
  Future<void> start(String session) => Future.error(
    const SpeakerObserverException(
      SpeakerObserverFailure.unavailable,
      availability: ObserverAvailability.unsupportedPlatform,
    ),
  );

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
