import 'dart:async';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';

/// Explicit test adapter for the desktop capability contract. Production only
/// constructs RemoteDomain; widget fixtures can control core services directly.
class TestDesktopConnection implements DesktopConnection {
  final Domain domain;
  late final Application application = domain.application;
  StreamSubscription<void>? _changes;
  TestDesktopConnection(this.domain) {
    _changes = application.changes.stream.listen((_) => helper.changed?.call());
  }
  @override
  Store get store => domain.store;
  @override
  Helper get helper => domain.helper;
  @override
  GenerationStatus? get generator => domain.generator;
  @override
  GenerationStatus get runtime => domain.generator!;
  @override
  GoogleAccount get googleAuth => application.googleAuth;
  @override
  ConnectedSources get google => application.google;
  @override
  Map<String, dynamic> get capture => Map<String, dynamic>.from(application.captureState);
  @override
  Map<String, dynamic> get googleStatus => Map<String, dynamic>.from(application.googleState);
  @override
  bool get webSearchAvailable => domain.webSearchAvailable;
  @override
  bool get sourcesPaused => domain.sourcesPaused;
  @override
  Future<Object?> command(String method, [Map<String, dynamic> args = const {}]) => domain is CommandFixtureDomain
      ? (domain as CommandFixtureDomain).command(method, args)
      : application.call(method, args);
  @override
  Future<Object?> commandCurrent(String method, Map<String, dynamic> args, bool Function() current) => application.call(method, args, current: current);
  @override
  Future<void> index(String id) => domain.index(id);
  @override
  Future<void> delete(String id) => domain.delete(id);
  @override
  Future<void> resume() => domain.resume();
  @override
  void pauseSources() => domain.pauseSources();
  @override
  void resumeSources() => domain.resumeSources();
  @override
  Future<void> waitForSourceWork() => domain.waitForSourceWork();
  @override
  Stream<String> askInConversation(String question, String conversation, {String? requestId, int? meetingId, bool Function()? current}) => domain.askInConversation(question, conversation, requestId: requestId, meetingId: meetingId, current: current);
  @override
  Stream<String> askWithWebInConversation(String question, String conversation, {String? requestId, int? meetingId, bool Function()? current}) => domain.askWithWebInConversation(question, conversation, requestId: requestId, meetingId: meetingId, current: current);
  @override
  Future<Map<String, List<double>>> graphEmbeddings(List<Map<String, Object?>> sources) => domain.graphEmbeddings(sources);
  @override
  Future<void> enableDesktopApprovals(void Function(Map<String, dynamic>) events) async {}
  @override
  Future<void> disableDesktopApprovals() async {}
  @override
  void close() {
    unawaited(_changes?.cancel());
    application.google.close();
    unawaited(application.close());
    domain.close();
  }
}

class CommandFixtureDomain extends Domain {
  CommandFixtureDomain(super.store, super.helper);
  Future<Object?> command(String method, [Map<String, dynamic> args = const {}]) =>
      application.call(method, args);
}
