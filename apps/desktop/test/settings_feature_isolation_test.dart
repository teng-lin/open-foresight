import 'desktop_fixture_owner.dart';
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import '../test_support/core_fixture.dart';

import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/settings/settings_controller.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

import 'controller_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class _Host
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceLifecycle {
  _Host(this.connection);
  @override
  final ControllerConnection connection;
  @override
  late BuildContext context;
  @override
  bool mounted = true;
  @override
  final environment = const DesktopEnvironment();
  @override
  final ValueNotifier<int> serviceUiRevision = ValueNotifier<int>(0);
  @override
  final ValueNotifier<List<double>> captureVolumes =
      ValueNotifier<List<double>>(const []);
  @override
  WorkspaceTab selectedTab = WorkspaceTab.settings;
  @override
  bool busy = false;
  @override
  String error = '';
  @override
  bool clearingWorkspace = false;
  StateSetter rebuild = (action) => action();
  @override
  void update(VoidCallback action) {
    if (mounted) rebuild(action);
  }

  @override
  void navigate(WorkspaceTab tab) => selectedTab = tab;
  @override
  void setError(String message) => error = message;
  @override
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (failure) {
      error = '$failure';
    }
  }

  @override
  void reportAsyncError(Object failure) => error = '$failure';
  @override
  void serviceChanged() => update(() {});
  @override
  void resetWorkspaceViews() {}
  @override
  void setClearingWorkspace(bool value) => clearingWorkspace = value;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _IntegrationPorts implements IntegrationActivity, IntegrationCommands {
  @override
  GooglePresentation get googlePresentation =>
      GooglePresentation.fromWire(const {});
  @override
  bool get granolaCalendar => false;
  @override
  bool get googleSyncing => false;
  @override
  bool get openAtLogin => false;
  @override
  bool get notifications => false;
  @override
  String get loginState => '';
  @override
  String get globalShortcutState => '';
  @override
  String get captureCapabilityError => '';
  @override
  String get microphoneAccessLabel => 'Fixture microphone';
  @override
  String get systemAudioAccessLabel => 'Fixture system audio';
  @override
  String get audioDeviceState => '';
  @override
  String get notificationState => 'Unavailable in fixture';
  @override
  String get googleState => '';
  @override
  Widget deviceChoice(bool playback) =>
      Text(playback ? 'Fixture playback' : 'Fixture microphone');
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MeetingFacts implements MeetingActivity {
  @override
  int? get selectedMeetingId => null;
  @override
  int? get previewMeetingId => null;
  @override
  RecordingSnapshot? get recording => null;
  @override
  String get echoCancellationDescription => 'Fixture echo cancellation';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ModelConnection extends ControllerConnection {
  _ModelConnection(super.application);
  _ModelReader? _reader;
  @override
  _ModelReader get store => _reader ??= _ModelReader(super.store);
}

class _ModelReader implements StoreReader {
  _ModelReader(this.delegate);
  final StoreReader delegate;
  // Closed by the owning fixture.
  // ignore: close_sinks
  final modelsReply =
      StreamController<ReadResult<List<ModelRegistration>>>.broadcast(
        sync: true,
      );
  @override
  String get workspaceEpoch => delegate.workspaceEpoch;
  @override
  String get dataRevision => delegate.dataRevision;
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) =>
      query.projection == 'models'
      ? modelsReply.stream.map((result) => result.asType<T>())
      : delegate.watch(query);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected synchronous model read ${invocation.memberName}',
  );
}

void main() {
  testWidgets(
    'same-owner preview displays a model but cannot certify embedding readiness',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('settings-preview-');
      final model = File('${root.path}/embedding.litertlm')
        ..writeAsStringSync('UI fixture');
      final connection = _ModelConnection(
        Application(
          Domain(
            Store('${root.path}/app.db'),
            OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          ),
        ),
      );
      final host = _Host(connection), integrations = _IntegrationPorts();
      final controller = SettingsController(
        host: host,
        navigation: host,
        operations: host,
        lifecycle: host,
        integrations: integrations,
        integrationCommands: integrations,
        meetings: _MeetingFacts(),
      );
      controller.start();
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: SettingsView(controller));
            },
          ),
        ),
      );
      addTearDown(() async {
        controller.dispose();
        connection.close();
        await connection.store.modelsReply.close();
        host.serviceUiRevision.dispose();
        host.captureVolumes.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      final registration = ModelRegistration.fromRow({
        'kind': 'embedding',
        'path': model.path,
        'backend': 'litert_lm_embedding_cpu',
      });
      void publish(ReadFreshness freshness) => connection.store.modelsReply.add(
        ReadResult(
          freshness: freshness,
          value: [registration],
          requestTag: 'fixture',
          sequence: 0,
        ),
      );
      publish(ReadFreshness.preview);
      await tester.pumpAndSettle();
      expect(find.text('Download EmbeddingGemma 2'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Download EmbeddingGemma 2'),
            )
            .onPressed,
        isNotNull,
      );
      publish(ReadFreshness.current);
      await tester.pumpAndSettle();
      expect(find.text('Embedding model ready'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Embedding model ready'),
            )
            .onPressed,
        isNull,
      );
      publish(ReadFreshness.preview);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Download EmbeddingGemma 2'),
            )
            .onPressed,
        isNotNull,
      );
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }),
  );

  testWidgets(
    'Settings mounts with ports and owns setup state without a Workspace',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('settings-feature-');
      final connection = ControllerConnection(
        Application(
          Domain(
            Store('${root.path}/app.db'),
            OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          ),
        ),
      );
      final host = _Host(connection);
      final integrations = _IntegrationPorts();
      final controller = SettingsController(
        host: host,
        navigation: host,
        operations: host,
        lifecycle: host,
        integrations: integrations,
        integrationCommands: integrations,
        meetings: _MeetingFacts(),
      );
      controller.start();
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: SettingsView(controller));
            },
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        host.mounted = false;
        controller.dispose();
        connection.close();
        host.serviceUiRevision.dispose();
        host.captureVolumes.dispose();
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpAndSettle();
      expect(find.text('General'), findsOneWidget);
      expect(find.text('Connected services'), findsOneWidget);
      await controller.preference('noteStyle', 'Brief');
      expect(connection.calls.last.$1, Operation.preferencesSet);
      expect(connection.calls.last.$2, {'key': 'noteStyle', 'value': 'Brief'});
      controller.showModelSetup('speech');
      await tester.pump();
      expect(host.selectedTab, WorkspaceTab.models);
      expect(controller.modelKind, 'speech');
      final failure = Completer<void>();
      final action = controller.runAction(() => failure.future);
      host.selectedTab = WorkspaceTab.notes;
      failure.completeError(StateError('retired failure'));
      await action;
      expect(host.error, isEmpty);
      expect(tester.takeException(), isNull);
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }),
  );
}
