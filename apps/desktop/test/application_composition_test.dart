import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

import 'controller_fixture.dart';

void main() {
  testWidgets('application shell supplies the narrow host and feature ports', (
    tester,
  ) async {
    final fixture = await ControllerFixture.mount(tester);
    final host = fixture.shell as FeatureHost;
    final navigation = fixture.shell as WorkspaceNavigation;
    final operations = fixture.shell as OperationGate;
    final lifecycle = fixture.shell as WorkspaceLifecycle;
    expect(fixture.shell, isA<WorkspaceDialogs>());
    expect(host.connection, same(fixture.connection));
    expect(host.vsync, same(fixture.shell));
    expect(host.environment.variables, isEmpty);
    expect(host.sourceLinkOpener, host.environment.openUri);
    expect(host.commands, isNull);
    expect(host.deviceLoader, isNotNull);
    expect(host.serviceUiRevision, same(fixture.shell.serviceUiRevision));
    expect(host.captureVolumes, same(fixture.shell.captureVolumes));

    navigation.navigate(WorkspaceTab.notes);
    await tester.pumpAndSettle();
    expect(navigation.selectedTab, WorkspaceTab.notes);
    expect(find.text('Save note'), findsOneWidget);
    operations.setError('Presented through the operation port');
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == 'Presented through the operation port',
      ),
      findsOneWidget,
    );
    lifecycle.setClearingWorkspace(true);
    expect(lifecycle.clearingWorkspace, isTrue);
    lifecycle.setClearingWorkspace(false);
    expect(lifecycle.clearingWorkspace, isFalse);

    final preferences = fixture.shell.preferenceCommands as PreferenceCommands;
    await preferences.preference('serviceIdleMinutes', '45');
    expect(fixture.store.preference('serviceIdleMinutes'), '45');
    final meetings = fixture.shell.meetingPorts as MeetingActivity;
    final meetingCommands = fixture.shell.meetingPorts as MeetingCommands;
    expect(meetings.recording, isNull);
    final snapshot = RecordingSnapshot({'paused': true});
    fixture.shell.meetingFeature.recording = snapshot;
    expect(meetings.recording, same(snapshot));
    expect(meetings.recording!.paused, isTrue);
    final selected = fixture.store.meeting('Selected meeting');
    fixture.shell.meetingFeature.meetingId = selected;
    fixture.shell.meetingFeature.meetingPreviewId = selected;
    expect(meetings.selectedMeetingId, selected);
    expect(meetings.previewMeetingId, selected);
    meetingCommands.setSystemAudioSetupReviewed(true);
    expect(meetings.systemAudioSetupReviewed, isTrue);
    expect(fixture.shell.meetingFeature.systemAudioSetupReviewed, isTrue);
    final onboarding = fixture.shell.onboardingActivity as OnboardingActivity;
    expect(onboarding.active, fixture.shell.onboardingFeature.active);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
