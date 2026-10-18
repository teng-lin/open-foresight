part of 'main.dart';

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
  _IntegrationsController get integrationFeature => shell.integrationFeature;
  void update(VoidCallback action) => shell.update(action);
  void setState(VoidCallback action) => shell.update(action);
  Widget pill(
    String title,
    VoidCallback? action, {
    IconData? icon,
    bool selected = false,
  }) => FilledButton.tonalIcon(
    onPressed: action,
    style: FilledButton.styleFrom(
      backgroundColor: selected ? _blue : Colors.white,
      foregroundColor: _ink,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),
    icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 20),
    label: Text(title),
  );

  Widget heading(String title, {List<Widget> actions = const []}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Text(title, style: DesktopVisuals.pageTitle);
        final controls = Wrap(spacing: 12, runSpacing: 8, children: actions);
        if (constraints.maxWidth < 700 && actions.isNotEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 12), controls],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            if (actions.isNotEmpty) controls,
          ],
        );
      },
    ),
  );

  Widget searchBox(
    String hint,
    ValueChanged<String> onChanged, {
    TextEditingController? controller,
  }) => TextField(
    controller: controller,
    style: DesktopVisuals.field,
    onChanged: (value) => shell.update(() => onChanged(value)),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: Color(0xffb8babd),
        fontWeight: FontWeight.w400,
      ),
      prefixIcon: const Icon(Icons.search, color: Color(0xffb8babd)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(40),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(40),
        borderSide: BorderSide.none,
      ),
    ),
  );

  String timeLabel(Object? stamp) {
    if (stamp == null || stamp == 0) return 'Unknown';
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(stamp as int),
    );
    return elapsed.inMinutes < 1
        ? 'Just now'
        : elapsed.inHours < 1
        ? '${elapsed.inMinutes} ${elapsed.inMinutes == 1 ? 'min' : 'mins'} ago'
        : elapsed.inDays < 1
        ? '${elapsed.inHours} ${elapsed.inHours == 1 ? 'hour' : 'hours'} ago'
        : '${elapsed.inDays} ${elapsed.inDays == 1 ? 'day' : 'days'} ago';
  }
}
