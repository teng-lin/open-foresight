import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/integrations/integrations_controller.dart';
import 'package:open_foresight/features/integrations/widgets.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

class _Reader implements StoreReader {
  final subscriptions = <StreamController<ReadResult<String>>>[];
  @override
  String get workspaceEpoch => 'fixture-epoch';
  @override
  String get dataRevision => 'fixture-revision';
  @override
  RpcError? get failure => null;

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    if (query.projection != 'preference') {
      throw StateError('Unexpected query ${query.projection}');
    }
    final controller = StreamController<ReadResult<String>>();
    subscriptions.add(controller);
    controller.add(
      ReadResult(
        freshness: ReadFreshness.current,
        value: query.arguments['fallback']! as String,
        requestTag: dataRevision,
        sequence: 1,
      ),
    );
    return controller.stream.map((result) => result.asType<T>());
  }

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) =>
      throw StateError('Rendering must use its prepared preference watches');

  Future<void> close() async {
    for (final subscription in subscriptions) {
      await subscription.close();
    }
  }
}

class _Account implements GoogleAccount {
  int closes = 0;
  @override
  Future<void> close() async => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected account access ${invocation.memberName}');
}

class _Connection implements DesktopConnection {
  @override
  final _Reader store = _Reader();
  @override
  final _Account googleAuth = _Account();
  final events = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => events.stream;
  @override
  final Object clientSessionGeneration = Object();
  @override
  String get workspaceEpoch => store.workspaceEpoch;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected connection access ${invocation.memberName}');

  Future<void> dispose() async {
    await events.close();
    await store.close();
  }
}

class _Ports
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceDialogs,
        PreferenceCommands,
        MeetingActivity,
        MeetingCommands,
        OnboardingActivity {
  @override
  final _Connection connection = _Connection();
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
  bool get busy => false;
  @override
  String get error => '';
  @override
  int? get selectedMeetingId => null;
  @override
  int? get previewMeetingId => null;
  @override
  RecordingSnapshot? get recording => null;
  @override
  bool get active => false;
  final preferences = <(String, String)>[];
  StateSetter rebuild = (action) => action();
  @override
  void update(VoidCallback action) {
    if (mounted) rebuild(action);
  }

  @override
  Future<void> preference(String key, String value) async {
    preferences.add((key, value));
  }

  @override
  Future<void> run(Future<void> Function() action) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected port access ${invocation.memberName}');

  Future<void> dispose() async {
    serviceUiRevision.dispose();
    captureVolumes.dispose();
    await connection.dispose();
  }
}

class _IntegrationsRoot extends StatefulWidget {
  const _IntegrationsRoot(this.ports);
  final _Ports ports;
  @override
  State<_IntegrationsRoot> createState() => _IntegrationsRootState();
}

class _IntegrationsRootState extends State<_IntegrationsRoot> {
  late final owner = IntegrationsController(
    host: widget.ports,
    navigation: widget.ports,
    operations: widget.ports,
    dialogs: widget.ports,
    preferences: widget.ports,
    meetings: widget.ports,
    meetingCommands: widget.ports,
    onboarding: widget.ports,
  );

  @override
  void initState() {
    super.initState();
    widget.ports.rebuild = setState;
    owner.availableAudioDevices = [
      AudioDevice('usb-microphone', 'USB microphone', false),
    ];
    owner.initialize();
  }

  @override
  Widget build(BuildContext context) {
    widget.ports.context = context;
    return owner.deviceChoice(false);
  }

  @override
  void dispose() {
    widget.ports.mounted = false;
    owner.dispose();
    super.dispose();
  }
}

void main() {
  testWidgets(
    'Integrations mounts with fake ports, forwards device choice and retires owned watches',
    (tester) async {
      final ports = _Ports();
      addTearDown(ports.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _IntegrationsRoot(ports))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(IntegrationDeviceChoice), findsOneWidget);
      expect(find.text('System default'), findsOneWidget);
      expect(ports.connection.events.hasListener, isTrue);
      expect(ports.connection.store.subscriptions, isNotEmpty);
      expect(
        ports.connection.store.subscriptions.every((read) => read.hasListener),
        isTrue,
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USB microphone').last);
      await tester.pumpAndSettle();
      expect(ports.preferences, [('microphoneTarget', 'usb-microphone')]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(ports.connection.events.hasListener, isFalse);
      expect(
        ports.connection.store.subscriptions.every((read) => !read.hasListener),
        isTrue,
      );
      expect(ports.connection.googleAuth.closes, 1);
      ports.connection.events.add(null);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
