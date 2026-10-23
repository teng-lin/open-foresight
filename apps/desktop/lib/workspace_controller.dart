part of 'application.dart';

/// Feature controllers own their state. The host supplies lifecycle and the
/// single UI update boundary; cross-feature work names the receiving feature.
abstract class _FeatureController {
  final _WorkspaceState shell;
  _FeatureController(this.shell);
  Workspace get widget => shell.widget;
  DesktopConnection get d => widget.domain;
  bool get mounted => shell.mounted;
  BuildContext get context => shell.context;
  _SourcesController get sourceFeature => shell.sourceFeature;
  _ChatController get chatFeature => shell.chatFeature;
  _MeetingsController get meetingFeature => shell.meetingFeature;
  _SettingsController get settingsFeature => shell.settingsFeature;
  IntegrationsPort get integrationFeature => shell.integrationFeature;

  /// UI futures share the shell's gate while retaining their original owner.
  Future<void> runAction(
    Future<void> Function() action, {
    bool Function()? selectionCurrent,
  }) async {
    final identity = FeatureRequestIdentity.capture(d);
    final tab = shell.tab;
    final selectedMeeting = meetingFeature.meetingId;
    final preview = meetingFeature.meetingPreviewId;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        shell.tab == tab &&
        meetingFeature.meetingId == selectedMeeting &&
        meetingFeature.meetingPreviewId == preview &&
        (selectionCurrent?.call() ?? true);
    if (!current()) return;
    await shell.run(() async {
      try {
        await action();
      } catch (_) {
        if (current()) rethrow;
      }
    });
  }

  void update(VoidCallback action) => shell.update(action);
  void setState(VoidCallback action) => shell.update(action);
  Widget pill(
    String title,
    VoidCallback? action, {
    IconData? icon,
    bool selected = false,
  }) => workspacePill(title, action, icon: icon, selected: selected);

  Widget heading(String title, {List<Widget> actions = const []}) =>
      workspaceHeading(title, actions: actions);

  Widget searchBox(
    String hint,
    ValueChanged<String> onChanged, {
    TextEditingController? controller,
  }) => workspaceSearchBox(
    hint,
    (value) => shell.update(() => onChanged(value)),
    controller: controller,
  );

  String timeLabel(Object? stamp) => workspaceTimeLabel(stamp);
}
