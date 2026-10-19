import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/audio_devices.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class ReadyGeneration implements GenerationStatus {
  bool closed = false;
  @override
  Map<String, dynamic> get effectiveState => {'state': 'ready'};
  @override
  bool get generating => false;
  @override
  bool cancel({String? requestId}) => true;
  @override
  void close() => closed = true;
}

class ControllerConnection extends TestDesktopConnection {
  final calls = <(Operation, Map<String, dynamic>)>[];
  final replies = <Operation, Object?>{};
  final failures = <Operation, Object>{};
  final indexed = <String>[];
  final status = ReadyGeneration();
  ConnectedSources? connectedSources;
  GoogleAccount? account;
  final fileFailures = <String, Object>{};
  final deleted = <String>[];
  Stream<String> Function(String, String, int?)? answerStream;
  Object? graphFailure;
  final graphRequests = <List<String>>[];
  Map<String, dynamic>? googleState;
  Map<String, dynamic> captureState = {};
  int resumes = 0;
  int closes = 0;
  ControllerConnection(super.domain);
  @override
  ConnectedSources get google => connectedSources ?? super.google;
  @override
  GoogleAccount get googleAuth => account ?? super.googleAuth;
  @override
  Map<String, dynamic> get googleStatus => googleState ?? super.googleStatus;
  @override
  void close() {
    closes++;
    super.close();
  }

  @override
  GenerationStatus get runtime => status;
  @override
  GenerationStatus get generator => status;
  @override
  Map<String, dynamic> get capture => captureState;
  @override
  Future<void> resume() async => resumes++;
  @override
  Future<void> index(String id) async => indexed.add(id);
  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) {
    graphRequests.add(sources.map((source) => source['id'] as String).toList());
    if (graphFailure != null) return Future.error(graphFailure!);
    return super.graphEmbeddings(sources);
  }

  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) => answerStream != null
      ? answerStream!(question, conversation, meetingId)
      : super.askInConversation(
          question,
          conversation,
          requestId: requestId,
          meetingId: meetingId,
          current: current,
        );
  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    store.tombstone(id);
  }

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) async {
    if (!current()) return null;
    return command(operation, args);
  }

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add((operation, Map.of(args)));
    if (operation == Operation.sourcesImportFile &&
        fileFailures.containsKey(args['path'])) {
      throw fileFailures[args['path']]!;
    }
    if (failures.containsKey(operation)) throw failures[operation]!;
    if (replies.containsKey(operation)) return replies[operation];
    if (operation == Operation.notificationsCapabilities)
      return {'available': true};
    if (operation == Operation.notificationsRequestPermission)
      return {'granted': true};
    if (operation == Operation.audioCapabilities)
      return {
        'microphone': 'authorized',
        'microphone_purpose_present': true,
        'system_audio_purpose_present': true,
      };
    if (operation.wire.startsWith('models.') ||
        operation == Operation.meetingsEnhance ||
        operation == Operation.meetingsGenerate ||
        operation == Operation.meetingsIndex)
      return {};
    return super.command(operation, args);
  }
}

class ControllerFixture {
  final Directory root;
  final Store store;
  final ControllerConnection connection;
  final dynamic shell;
  ControllerFixture(this.root, this.store, this.connection, this.shell);
  static Future<ControllerFixture> mount(
    WidgetTester tester, {
    Future<List<AudioDevice>> Function()? devices,
  }) async {
    final root = createTestTempDirectorySync('desktop-controls-');
    final store = Store('${root.path}/app.db');
    final connection = ControllerConnection(
      Domain(
        store,
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(
      Foresight(connection, deviceLoader: devices ?? () async => []),
    );
    await tester.pumpAndSettle();
    final fixture = ControllerFixture(
      root,
      store,
      connection,
      tester.state(find.byType(Workspace)),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(null);
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return fixture;
  }
}
