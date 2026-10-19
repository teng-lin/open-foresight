import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'package:open_foresight/agent_approval_surface.dart';
import '../integration_test/meeting_workflow_test.dart' as workflow;

class ApprovalClient implements ServiceClient {
  final decisions = <Map<String, dynamic>>[];
  @override
  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'security.decide') decisions.add(args);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ApprovalDomain implements RemoteDomain {
  @override
  final ApprovalClient client = ApprovalClient();
  @override
  final capture = <String, dynamic>{};
  void Function(Map<String, dynamic>)? events;
  bool attached = false;
  bool failAttach = false;
  @override
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) value,
  ) async {
    if (failAttach) throw StateError('Fixture approval attachment unavailable');
    events = value;
    attached = true;
  }

  @override
  Future<void> disableDesktopApprovals() async {
    attached = false;
  }

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) => client.call(operation.wire, args);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'setup keeps the desktop authenticated while denying external agent requests',
    (tester) async {
      final domain = ApprovalDomain();
      Widget app(bool ready) => MaterialApp(
        home: AgentApprovalSurface(
          domain: domain,
          allowAgentRequests: ready,
          child: const Scaffold(body: Text('Setup')),
        ),
      );
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(domain.attached, isTrue);
      domain.events!({
        'event': 'approval',
        'approval_id': 'during-setup',
        'method': 'meetings.start',
        'args': {},
      });
      await tester.pumpAndSettle();
      expect(domain.client.decisions.single, {
        'approval_id': 'during-setup',
        'allow': false,
      });
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsNothing,
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(domain.attached, isTrue);
      domain.events!({
        'event': 'approval',
        'approval_id': 'after-setup',
        'method': 'meetings.start',
        'args': {},
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'external recording still requires explicit approval without a duplicate capture bar',
    (tester) async {
      final domain = ApprovalDomain();
      Widget app() => MaterialApp(
        home: AgentApprovalSurface(
          domain: domain,
          child: const Scaffold(body: Text('Workspace')),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(domain.attached, true);
      domain.events!({
        'event': 'approval',
        'approval_id': 'one',
        'method': 'meetings.start',
        'args': {'id': 7},
        'requester': 'External client (identity unverified)',
        'risk_flags': ['Private network access requested'],
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsOneWidget,
      );
      expect(
        find.text('External client (identity unverified)'),
        findsOneWidget,
      );
      expect(find.text('Private network access requested'), findsOneWidget);
      expect(domain.client.decisions, isEmpty);
      await workflow.allowRecording(tester);
      await tester.pumpAndSettle();
      expect(domain.client.decisions.single, {
        'approval_id': 'one',
        'allow': true,
      });
      domain.capture['active'] = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Microphone and system audio recording'), findsNothing);
      expect(find.text('Stop recording'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pumpAndSettle();
      expect(domain.attached, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(domain.attached, true);
      await tester.pumpWidget(const SizedBox());
      expect(domain.attached, false);
    },
  );
  testWidgets(
    'approval attachment failures remain visible without a capture banner',
    (tester) async {
      final domain = ApprovalDomain()..failAttach = true;
      await tester.pumpWidget(
        MaterialApp(
          home: AgentApprovalSurface(
            domain: domain,
            child: const Scaffold(body: Text('Workspace')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Agent approvals unavailable:'),
        findsOneWidget,
      );
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Microphone and system audio recording'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'expired approvals close the prompt without granting permission',
    (tester) async {
      final domain = ApprovalDomain();
      await tester.pumpWidget(
        MaterialApp(
          home: AgentApprovalSurface(domain: domain, child: const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      domain.events!({
        'event': 'approval',
        'approval_id': 'old',
        'method': 'workspace.clear',
        'args': {},
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Clear all workspace data and disconnect Google'),
        findsOneWidget,
      );
      domain.events!({'event': 'approval_closed', 'approval_id': 'old'});
      await tester.pumpAndSettle();
      expect(find.text('Allow once'), findsNothing);
      expect(domain.client.decisions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
